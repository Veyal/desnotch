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
/// and only the URL the caller built from the configured base URL.
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
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        return URLSession(configuration: configuration, delegate: VoiceAIRedirectRefuser(), delegateQueue: nil)
    }

    static func send(_ request: URLRequest, session: URLSession, maxBytes: Int) async -> VoiceAIResponse {
        if Task.isCancelled { return .cancelled }
        do {
            let (data, response) = try await session.data(for: request)
            if Task.isCancelled { return .cancelled }
            guard let http = response as? HTTPURLResponse else { return .failed(.badResponse) }
            if (200...299).contains(http.statusCode) {
                return data.count <= maxBytes ? .ok(data) : .failed(.badResponse)
            }
            return .status(http.statusCode, Data(data.prefix(maxBytes)))
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
