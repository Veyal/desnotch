import Foundation

/// 16-bit PCM mono WAV, built in memory. The audio never touches the disk.
enum WAVEncoder {
    static let headerSize = 44

    /// Float samples in -1...1 to signed 16-bit, clamped (out-of-range input never wraps).
    static func pcm16(_ samples: [Float]) -> [Int16] {
        samples.map { sample in
            let clamped = sample.isNaN ? 0 : min(max(sample, -1), 1)
            return Int16((clamped * Float(Int16.max)).rounded())
        }
    }

    static func encode(_ samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: headerSize + dataSize)
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(&data, UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(&data, UInt32(16))
        appendLE(&data, UInt16(1))
        appendLE(&data, UInt16(1))
        appendLE(&data, UInt32(sampleRate))
        appendLE(&data, UInt32(sampleRate * 2))
        appendLE(&data, UInt16(2))
        appendLE(&data, UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        appendLE(&data, UInt32(dataSize))
        for sample in samples {
            appendLE(&data, UInt16(bitPattern: sample))
        }
        return data
    }

    private static func appendLE(_ data: inout Data, _ value: UInt32) {
        data.append(contentsOf: [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)
        ])
    }

    private static func appendLE(_ data: inout Data, _ value: UInt16) {
        data.append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }
}

/// `multipart/form-data` body for the transcription upload.
struct MultipartForm {
    let boundary: String
    private var body = Data()

    init(boundary: String = "desnotch-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func addFile(_ name: String, filename: String, contentType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    func finalized() -> Data {
        var result = body
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    private mutating func append(_ text: String) {
        body.append(Data(text.utf8))
    }
}

/// Request builders and response readers for the OpenAI-compatible audio and model-list
/// endpoints. Pure, so the request shape is unit-tested without a network.
enum OpenAIAudioWire {
    static func transcription(
        base: URL, key: String?, model: String, language: String, wav: Data, boundary: String? = nil
    ) -> URLRequest {
        var form = boundary.map { MultipartForm(boundary: $0) } ?? MultipartForm()
        form.addFile("file", filename: "audio.wav", contentType: "audio/wav", data: wav)
        form.addField("model", model)
        form.addField("response_format", "json")
        if !language.isEmpty {
            form.addField("language", language)
        }
        var request = URLRequest(url: VoiceAIEndpoint.url(base, "audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = VoiceAILimits.transcriptionTimeout
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        VoiceAIHTTP.authorize(&request, key: key)
        request.httpBody = form.finalized()
        return request
    }

    /// `{"text": "..."}`; nil when the body has another shape.
    static func transcriptText(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["text"] as? String
    }

    static func speech(base: URL, key: String?, model: String, voice: String, input: String) -> URLRequest {
        var request = URLRequest(url: VoiceAIEndpoint.url(base, "audio/speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = VoiceAILimits.speechTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        VoiceAIHTTP.authorize(&request, key: key)
        let body: [String: Any] = [
            "model": model,
            "voice": voice,
            "input": input,
            "response_format": "mp3"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func models(base: URL, key: String?) -> URLRequest {
        var request = URLRequest(url: VoiceAIEndpoint.url(base, "models"))
        request.httpMethod = "GET"
        request.timeoutInterval = VoiceAILimits.connectionTestTimeout
        VoiceAIHTTP.authorize(&request, key: key)
        return request
    }
}
