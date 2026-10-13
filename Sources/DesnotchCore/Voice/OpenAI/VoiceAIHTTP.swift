import Foundation

/// Outcome of one request to the provider. Bodies stay in memory and are never logged.
enum VoiceAIResponse: Equatable, Sendable {
    case ok(Data)
    /// A non-2xx status with its (bounded) body, so a caller can react to a specific error.
    case status(Int, Data)
    case failed(ProviderFailure)
    /// The caller cancelled (Stop, Cancel, a newer request).
    case cancelled
}

/// The one HTTP path of the voice feature. Ephemeral session (no cache, no cookies, nothing on
/// disk), redirects refused (a redirect could carry the request and its key to another host),
/// and only the URL the caller built from the configured base URL. Every request has a whole-
/// request ceiling (`VoiceAILimits.resourceTimeout`) and its body is read as it streams in, so
/// an oversized body is abandoned at `maxBytes` instead of being downloaded first.
enum VoiceAIHTTP {
    /// `protocolClasses` exists for tests (a stub `URLProtocol`); production passes nil.
    static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = VoiceAILimits.resourceTimeout
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration, delegate: VoiceAIRedirectRefuser(), delegateQueue: nil)
    }

    static func send(_ request: URLRequest, session: URLSession, maxBytes: Int) async -> VoiceAIResponse {
        if Task.isCancelled { return .cancelled }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard !Task.isCancelled, let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                return Task.isCancelled ? .cancelled : .failed(.badResponse)
            }
            let success = (200...299).contains(http.statusCode)
            // A declared length over the cap is refused before a single body byte is read.
            if success && http.expectedContentLength > Int64(maxBytes) {
                bytes.task.cancel()
                return .failed(.badResponse)
            }
            var body = Data()
            body.reserveCapacity(min(maxBytes, max(0, Int(clamping: http.expectedContentLength))))
            for try await byte in bytes {
                if body.count >= maxBytes {
                    // One byte past the cap: stop downloading. An error body keeps its prefix.
                    bytes.task.cancel()
                    return success ? .failed(.badResponse) : .status(http.statusCode, body)
                }
                body.append(byte)
            }
            if Task.isCancelled { return .cancelled }
            return success ? .ok(body) : .status(http.statusCode, body)
        } catch {
            if Task.isCancelled { return .cancelled }
            return classify(error)
        }
    }

    static func classify(status: Int) -> ProviderFailure {
        switch status {
        case 401, 403: return .unauthorized
        case 404: return .notFound
        case 413: return .audioTooLarge
        case 429: return .rateLimited
        default: return .httpError
        }
    }

    static func classify(_ error: Error) -> VoiceAIResponse {
        guard let urlError = error as? URLError else {
            return error is CancellationError ? .cancelled : .failed(.network)
        }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .failed(.timeout)
        case .cannotDecodeContentData, .cannotDecodeRawData, .cannotParseResponse, .badServerResponse:
            return .failed(.badResponse)
        default: return .failed(.network)
        }
    }

    /// Adds the bearer token when there is one. A local server may run without a key.
    static func authorize(_ request: inout URLRequest, key: String?) {
        if let key, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }
}

/// Refuses every HTTP redirect, so the request (and its Authorization header) only ever goes
/// to the configured URL; the 3xx response is then reported as an HTTP error.
final class VoiceAIRedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
