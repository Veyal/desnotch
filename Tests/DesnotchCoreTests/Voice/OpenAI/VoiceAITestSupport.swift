import Foundation
@testable import DesnotchCore

/// Stub `URLProtocol` for the AI provider tests: records every request (with its body read
/// from the stream) and answers from a scripted reply. No real network is ever touched.
/// Thread safety: the static state is guarded by `lock`.
final class AIStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case respond(status: Int, body: Data, headers: [String: String])
        case fail(URLError.Code)
        /// Never answers, so the caller has to cancel.
        case hang
    }

    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var recorded: [URLRequest] = []
    private static var bodies: [Data] = []

    static func reset(_ script: [Reply]) {
        lock.lock()
        replies = script
        recorded = []
        bodies = []
        lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }

    static var requestBodies: [Data] {
        lock.lock(); defer { lock.unlock() }; return bodies
    }

    static func json(_ status: Int, _ object: [String: Any]) -> Reply {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .respond(status: status, body: data, headers: ["Content-Type": "application/json"])
    }

    static func session() -> URLSession {
        VoiceAIHTTP.makeSession(protocolClasses: [AIStubURLProtocol.self])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.record(request, body: Self.readBody(request))
        switch reply {
        case .respond(let status, let body, let headers):
            let url = request.url ?? URL(fileURLWithPath: "/")
            if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    private static func record(_ request: URLRequest, body: Data) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        bodies.append(body)
        return replies.isEmpty ? .respond(status: 500, body: Data(), headers: [:]) : replies.removeFirst()
    }

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// In-memory key store for tests. Thread safety: guarded by `lock`.
final class AIMemoryKeyStore: VoiceAIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var reads = 0

    init(_ key: String? = nil) {
        self.key = key
    }

    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }

    func readKey() -> String? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return key
    }

    func hasKey() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return key != nil
    }

    func saveKey(_ key: String) -> Bool {
        guard let normalized = VoiceAIKeyFormat.normalized(key) else { return false }
        lock.lock(); self.key = normalized; lock.unlock()
        return true
    }

    func deleteKey() -> Bool {
        lock.lock(); key = nil; lock.unlock()
        return true
    }
}

enum AITestJSON {
    static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
