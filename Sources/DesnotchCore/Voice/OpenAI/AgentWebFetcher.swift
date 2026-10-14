import Darwin
import Foundation

/// The `web_fetch` tool's one network path. Same ephemeral session rules as the AI provider
/// (no cache, no cookies, nothing on disk, redirects refused), plus: the host must resolve
/// only to public addresses (never this Mac, the LAN or the tailnet), only text-like bodies are
/// read, and at most `AgentToolLimits.fetchBodyBytes` bytes are read before extraction.
/// Cancelling the calling task (Stop, Cancel) cancels the request.
struct AgentWebFetcher: AgentWebFetching {
    let session: URLSession

    init(session: URLSession = VoiceAIHTTP.makeSession()) {
        self.session = session
    }

    func fetch(_ url: URL) async -> AgentFetchResult {
        guard let host = url.host, !AgentURLPolicy.isLocalHost(host) else { return .refused("local address") }
        guard await Self.resolvesOnlyToPublicAddresses(host) else { return .refused("the name does not resolve to a public address") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = AgentToolLimits.fetchTimeout
        request.setValue("text/html,text/plain,application/json;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
        request.setValue("desnotch-voice-agent", forHTTPHeaderField: "User-Agent")
        if Task.isCancelled { return .cancelled }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("bad response") }
            if (300...399).contains(http.statusCode) {
                let location = http.value(forHTTPHeaderField: "Location") ?? "an unknown address"
                bytes.task.cancel()
                return .redirect(status: http.statusCode, location: String(location.prefix(500)))
            }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard Self.isTextual(type) else {
                bytes.task.cancel()
                return .refused("unsupported content type")
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= AgentToolLimits.fetchBodyBytes {
                    bytes.task.cancel()
                    break
                }
            }
            if Task.isCancelled { return .cancelled }
            let body = String(decoding: data, as: UTF8.self)
            let isHTML = type.contains("html") || type.isEmpty
            let mime = type.split(separator: ";").first.map(String.init) ?? "unknown"
            return .page(status: http.statusCode, contentType: mime, text: AgentHTMLText.extract(body, isHTML: isHTML))
        } catch {
            if Task.isCancelled { return .cancelled }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .cancelled: return .cancelled
                case .timedOut: return .failed("timed out")
                default: return .failed("network error")
                }
            }
            return .failed("network error")
        }
    }

    func isPublicHost(_ host: String) async -> Bool {
        guard !AgentURLPolicy.isLocalHost(host) else { return false }
        return await Self.resolvesOnlyToPublicAddresses(host)
    }

    static func isTextual(_ contentType: String) -> Bool {
        if contentType.isEmpty { return true }
        return contentType.hasPrefix("text/") || contentType.contains("json") || contentType.contains("xml")
    }

    /// True when every address the name resolves to is public. A failed lookup is false.
    /// (A name can still change its answer between this check and the connection; the
    /// residual DNS-rebinding window is documented in docs/voice/PLAN.md.)
    static func resolvesOnlyToPublicAddresses(_ host: String) async -> Bool {
        if let literal = AgentURLPolicy.isPublicAddress(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) {
            return literal
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: lookupIsPublic(host))
            }
        }
    }

    private static func lookupIsPublic(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(first) }
        var sawAny = false
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let address = entry.pointee.ai_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    let v4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    if !AgentURLPolicy.isPublicIPv4(UInt32(bigEndian: v4.s_addr)) { return false }
                    sawAny = true
                case AF_INET6:
                    let v6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    if !AgentURLPolicy.isPublicIPv6(v6) { return false }
                    sawAny = true
                default:
                    break
                }
            }
            cursor = entry.pointee.ai_next
        }
        return sawAny
    }
}
