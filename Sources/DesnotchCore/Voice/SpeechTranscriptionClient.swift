import Foundation

public protocol SpeechHTTPTransport {
    func data(for request: URLRequest, maxBytes: Int) async throws -> (Data, URLResponse)
}

/// Uses a per-request URLSession delegate so oversized responses are cancelled while
/// downloading rather than after Foundation has materialized the whole body.
public final class BoundedSpeechHTTPTransport: SpeechHTTPTransport {
    public init() {}

    public func data(for request: URLRequest, maxBytes: Int) async throws -> (Data, URLResponse) {
        try await BoundedSpeechRequest(maxBytes: max(1, maxBytes)).perform(request)
    }
}

public enum SpeechTranscriptionError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case malformedResponse
    case missingAPIKey
    case fileTooLarge
    case invalidBaseURL
    case responseTooLarge
    case transcriptTooLong
}

extension SpeechTranscriptionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The transcription service returned an invalid response."
        case .httpStatus(let status): return "Transcription failed (HTTP \(status))."
        case .malformedResponse: return "The transcription response did not contain text."
        case .missingAPIKey: return "Add a transcription API key in Settings."
        case .fileTooLarge: return "The recording is larger than 20 MiB."
        case .invalidBaseURL: return "The transcription provider URL is not allowed."
        case .responseTooLarge: return "The transcription response is too large."
        case .transcriptTooLong: return "The transcription is too long."
        }
    }
}

public final class SpeechTranscriptionClient {
    public static let defaultModel = "gpt-4o-mini-transcribe"
    public static let maxAudioBytes = 20 * 1024 * 1024
    public static let maxResponseBytes = 1 * 1024 * 1024
    public static let maxTranscriptBytes = 64 * 1024
    public let baseURL: URL
    public let model: String
    private let transport: SpeechHTTPTransport
    private let apiKey: () -> String?
    public init(baseURL: URL = URL(string: "https://api.openai.com")!, model: String = defaultModel,
                apiKey: @escaping () -> String?, transport: SpeechHTTPTransport = BoundedSpeechHTTPTransport()) {
        self.baseURL = baseURL; self.model = model; self.apiKey = apiKey; self.transport = transport
    }

    public func transcribe(fileURL: URL) async throws -> String {
        try Task.checkCancellation()
        guard Self.isAllowedProviderURL(baseURL) else { throw SpeechTranscriptionError.invalidBaseURL }
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw SpeechTranscriptionError.missingAPIKey
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = try Self.multipartBody(fileURL: fileURL, model: model, boundary: boundary)
        var request = URLRequest(url: Self.transcriptionURL(baseURL: baseURL))
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await transport.data(for: request, maxBytes: Self.maxResponseBytes)
                guard data.count <= Self.maxResponseBytes else { throw SpeechTranscriptionError.responseTooLarge }
                guard let http = response as? HTTPURLResponse else { throw SpeechTranscriptionError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else {
                    if attempt == 0 && ([408, 429].contains(http.statusCode) || http.statusCode >= 500) {
                        attempt += 1
                        continue
                    }
                    throw SpeechTranscriptionError.httpStatus(http.statusCode)
                }
                return try Self.text(from: data)
            } catch is CancellationError { throw CancellationError() }
              catch let error as SpeechTranscriptionError { throw error }
              catch {
                guard attempt == 0 else { throw error }; attempt += 1
            }
        }
    }

    public static func multipartBody(fileURL: URL, model: String, boundary: String) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > maxAudioBytes {
            throw SpeechTranscriptionError.fileTooLarge
        }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= maxAudioBytes else { throw SpeechTranscriptionError.fileTooLarge }
        var body = Data()
        func field(_ name: String, _ value: String) { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)) }
        field("model", model); field("response_format", "json")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)); body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8)); return body
    }
    public static func text(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String
        else { throw SpeechTranscriptionError.malformedResponse }
        guard text.utf8.count <= maxTranscriptBytes else { throw SpeechTranscriptionError.transcriptTooLong }
        return text
    }

    public static func isAllowedProviderURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ["localhost", "127.0.0.1", "::1"].contains(normalized)
    }

    /// Accept either a provider root (`https://host`) or an OpenAI-compatible `/v1`
    /// base URL without accidentally producing `/v1/v1/audio/transcriptions`.
    public static func transcriptionURL(baseURL: URL) -> URL {
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.hasSuffix("audio/transcriptions") { return baseURL }
        if normalizedPath.hasSuffix("v1") {
            return baseURL.appendingPathComponent("audio/transcriptions")
        }
        return baseURL.appendingPathComponent("v1/audio/transcriptions")
    }
}

private final class BoundedSpeechRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: URLResponse?
    private var body = Data()
    private var cancelled = false
    private var finished = false

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)

                lock.lock()
                if cancelled {
                    lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if response.expectedContentLength > Int64(maxBytes) {
            completionHandler(.cancel)
            finish(.failure(SpeechTranscriptionError.responseTooLarge))
            return
        }
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let wouldOverflow = body.count > maxBytes - data.count
        if !wouldOverflow { body.append(data) }
        lock.unlock()
        if wouldOverflow {
            dataTask.cancel()
            finish(.failure(SpeechTranscriptionError.responseTooLarge))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let response = self.response
        let body = self.body
        lock.unlock()
        guard let response else {
            finish(.failure(SpeechTranscriptionError.invalidResponse))
            return
        }
        finish(.success((body, response)))
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        let session = self.session
        self.session = nil
        task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }
}
