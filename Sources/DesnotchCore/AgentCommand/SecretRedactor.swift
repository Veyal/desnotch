import Foundation

public enum SecretRedactor {
    private static let patterns = [
        #"(?i)["']?(?:api[_-]?key|token|password|secret|authorization)["']?\s*[:=]\s*["'][^"']*["']"#,
        #"(?i)(api[_-]?key|token|password|secret|authorization)\s*[:=]\s*[^\s,;]+"#,
        #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
        #"\b(sk|pk)_(live|test)_[A-Za-z0-9]+\b"#,
        #"\b(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{16,}|AKIA[A-Z0-9]{16})\b"#,
        #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#
    ]
    public static func redact(_ value: String) -> String {
        let withoutANSI = value.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        let withoutControls = withoutANSI.unicodeScalars.filter {
            $0.value == 0x09 || $0.value == 0x0A || $0.value == 0x0D || $0.value >= 0x20
        }.map(String.init).joined()
        return patterns.reduce(withoutControls) { current, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return current }
            return regex.stringByReplacingMatches(in: current, range: NSRange(current.startIndex..., in: current), withTemplate: "[REDACTED]")
        }
    }

    public static func redactAndLimit(_ value: String, utf8ByteCap: Int) -> String {
        let redacted = redact(value)
        guard redacted.utf8.count > utf8ByteCap else { return redacted }
        var end = redacted.startIndex
        var bytes = 0
        while end < redacted.endIndex {
            let next = redacted.index(after: end)
            let count = redacted[end..<next].utf8.count
            if bytes + count > utf8ByteCap { break }
            bytes += count
            end = next
        }
        return String(redacted[..<end]) + "…"
    }
}
