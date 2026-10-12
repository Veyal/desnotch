import Foundation

/// A value read from the tiny YAML subset the Hermes preflight understands.
enum ScanValue: Equatable {
    case string(String)
    case list([ScanValue])
    case map([String: ScanValue])
}

enum MiniConfigScanError: Error, Equatable {
    case unsupported
}

/// Reads only the four profile sections the preflight is allowed to trust.
/// Every other top-level section is skipped, but an anchor, alias, merge key, tab,
/// or extra document marker anywhere in the file still fails closed: a merge could
/// inject `command_allowlist` or `mcp_servers` from a section this scanner does not interpret.
struct MiniConfigScan {
    fileprivate static let sections: Set<String> = [
        "approvals", "command_allowlist", "mcp_servers", "platform_toolsets"
    ]

    private let root: [String: ScanValue]

    init(parsing text: String) throws {
        root = try MiniYAML.parse(text)
    }

    func value(at path: [String]) -> ScanValue? {
        var current = ScanValue.map(root)
        for key in path {
            guard case .map(let map) = current, let next = map[key] else { return nil }
            current = next
        }
        return current
    }
}

private enum MiniYAML {
    struct Line {
        var indent: Int
        var text: String
    }

    static func parse(_ text: String) throws -> [String: ScanValue] {
        if text.contains("\t") { throw MiniConfigScanError.unsupported }
        let rawLines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var content: [Line] = []
        for (index, raw) in rawLines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "..." || trimmed.hasPrefix("...") { throw MiniConfigScanError.unsupported }
            if trimmed == "---" || trimmed.hasPrefix("---") {
                if index > 0 { throw MiniConfigScanError.unsupported }
                continue
            }
            let stripped = stripComment(raw)
            let body = stripped.trimmingCharacters(in: .whitespaces)
            if body.isEmpty { continue }
            try validateTokens(body)
            let indent = stripped.prefix { $0 == " " }.count
            if indent % 2 != 0 { throw MiniConfigScanError.unsupported }
            content.append(Line(indent: indent, text: body))
        }
        var index = 0
        var root: [String: ScanValue] = [:]
        while index < content.count {
            let line = content[index]
            if line.indent != 0 { throw MiniConfigScanError.unsupported }
            if line.text.hasPrefix("- ") { throw MiniConfigScanError.unsupported }
            let header = try splitHeader(line.text)
            if MiniConfigScan.sections.contains(header.key) {
                if header.quoted || root[header.key] != nil { throw MiniConfigScanError.unsupported }
                root[header.key] = try parseNode(content, &index, indent: 0, inline: header.inline)
            } else {
                try skipSection(content, &index, inline: header.inline)
            }
        }
        return root
    }

    /// A section this scanner does not interpret, including its indentless list and folded text.
    private static func skipSection(_ lines: [Line], _ index: inout Int, inline: String) throws {
        index += 1
        if !inline.isEmpty { return }
        while index < lines.count {
            let line = lines[index]
            if line.indent > 0 || line.text.hasPrefix("- ") {
                index += 1
                continue
            }
            break
        }
    }

    private static func parseNode(
        _ lines: [Line], _ index: inout Int, indent: Int, inline: String
    ) throws -> ScanValue {
        index += 1
        if !inline.isEmpty {
            if isBlockScalar(inline) { throw MiniConfigScanError.unsupported }
            if inline.hasPrefix("[") || inline.hasPrefix("{") {
                return try parseFlow(inline)
            }
            return .string(try plainScalar(inline))
        }
        guard index < lines.count else { return .string("") }
        let next = lines[index]
        if next.text.hasPrefix("- "), next.indent >= indent {
            return try parseList(lines, &index, parentIndent: indent)
        }
        if next.indent > indent {
            return try parseMap(lines, &index, parentIndent: indent)
        }
        return .string("")
    }

    private static func parseMap(
        _ lines: [Line], _ index: inout Int, parentIndent: Int
    ) throws -> ScanValue {
        var map: [String: ScanValue] = [:]
        while index < lines.count {
            let line = lines[index]
            if line.indent <= parentIndent { break }
            if line.text.hasPrefix("- ") { throw MiniConfigScanError.unsupported }
            let header = try splitHeader(line.text)
            if header.quoted || map[header.key] != nil { throw MiniConfigScanError.unsupported }
            map[header.key] = try parseNode(lines, &index, indent: line.indent, inline: header.inline)
        }
        return .map(map)
    }

    private static func parseList(
        _ lines: [Line], _ index: inout Int, parentIndent: Int
    ) throws -> ScanValue {
        var items: [ScanValue] = []
        var itemIndent: Int?
        while index < lines.count {
            let line = lines[index]
            if line.indent < parentIndent { break }
            if line.indent == parentIndent && !line.text.hasPrefix("- ") { break }
            guard line.text.hasPrefix("- ") else { throw MiniConfigScanError.unsupported }
            if let itemIndent, line.indent != itemIndent { throw MiniConfigScanError.unsupported }
            itemIndent = line.indent
            let body = String(line.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if isMapItem(body) { throw MiniConfigScanError.unsupported }
            if body.hasPrefix("[") || body.hasPrefix("{") {
                items.append(try parseFlow(body))
            } else {
                items.append(.string(try plainScalar(body)))
            }
            index += 1
            if index < lines.count && lines[index].indent > line.indent {
                throw MiniConfigScanError.unsupported
            }
        }
        return .list(items)
    }

    private static func isMapItem(_ body: String) -> Bool {
        guard let colon = body.firstIndex(of: ":") else { return false }
        let key = body[..<colon]
        if key.isEmpty || key.contains(" ") { return false }
        if key.hasPrefix("\"") || key.hasPrefix("'") { return true }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    private static func isBlockScalar(_ text: String) -> Bool {
        let markers = ["|", ">", "|-", "|+", ">-", ">+"]
        if markers.contains(text) { return true }
        return markers.contains { text.hasPrefix($0 + " ") }
    }

    private struct Header {
        var key: String
        var quoted: Bool
        var inline: String
    }

    private static func splitHeader(_ text: String) throws -> Header {
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            guard let quote = text.first else { throw MiniConfigScanError.unsupported }
            var index = text.index(after: text.startIndex)
            var key = ""
            while index < text.endIndex {
                let char = text[index]
                if char == quote {
                    let after = text.index(after: index)
                    let rest = text[after...].trimmingCharacters(in: .whitespaces)
                    guard rest.hasPrefix(":") else { throw MiniConfigScanError.unsupported }
                    let inline = rest.dropFirst().trimmingCharacters(in: .whitespaces)
                    return Header(key: key, quoted: true, inline: String(inline))
                }
                key.append(char)
                index = text.index(after: index)
            }
            throw MiniConfigScanError.unsupported
        }
        guard let colon = text.firstIndex(of: ":") else { throw MiniConfigScanError.unsupported }
        let key = String(text[..<colon])
        if key.isEmpty || key.contains(" ") { throw MiniConfigScanError.unsupported }
        let inline = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return Header(key: key, quoted: false, inline: String(inline))
    }

    private static func plainScalar(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") || trimmed.hasPrefix("'") {
            return try unquote(trimmed)
        }
        return trimmed
    }

    private static func unquote(_ text: String) throws -> String {
        guard let quote = text.first, text.count >= 2, text.last == quote else {
            throw MiniConfigScanError.unsupported
        }
        let inner = text.dropFirst().dropLast()
        if quote == "'" {
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        var out = ""
        var escaped = false
        for char in inner {
            if escaped {
                switch char {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\\", "\"": out.append(char)
                default: out.append(char)
                }
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else {
                out.append(char)
            }
        }
        if escaped { throw MiniConfigScanError.unsupported }
        return out
    }

    private static func parseFlow(_ text: String) throws -> ScanValue {
        var parser = FlowParser(text)
        let value = try parser.parseValue()
        try parser.expectEnd()
        return value
    }

    private static func stripComment(_ line: String) -> String {
        var out = ""
        var quote: Character?
        var escaped = false
        for char in line {
            if let active = quote {
                out.append(char)
                if escaped {
                    escaped = false
                    continue
                }
                if active == "\"" && char == "\\" {
                    escaped = true
                    continue
                }
                if active == "'" && char == "'" {
                    continue
                }
                if char == active { quote = nil }
                continue
            }
            if char == "#" {
                if out.isEmpty || out.last == " " { break }
            }
            if char == "'" || char == "\"" { quote = char }
            out.append(char)
        }
        return out
    }

    /// An anchor or alias is a scalar whose first character is `&` or `*` followed by a name
    /// character. A merge key is a key that is exactly `<<`. Quoted text is not a token.
    private static func validateTokens(_ line: String) throws {
        let chars = Array(line)
        var index = 0
        var atToken = true
        var quote: Character?
        func isName(_ char: Character) -> Bool {
            char.isLetter || char.isNumber || char == "_" || char == "-"
        }
        while index < chars.count {
            let char = chars[index]
            if let active = quote {
                if active == "\"" && char == "\\" {
                    index += 2
                    continue
                }
                if active == "'" && char == "'" && index + 1 < chars.count && chars[index + 1] == "'" {
                    index += 2
                    continue
                }
                if char == active { quote = nil }
                index += 1
                continue
            }
            if char == "#" { return }
            if char == " " {
                index += 1
                continue
            }
            if atToken {
                if char == "<", index + 1 < chars.count, chars[index + 1] == "<" {
                    var look = index + 2
                    while look < chars.count && chars[look] == " " { look += 1 }
                    if look >= chars.count || chars[look] == ":" { throw MiniConfigScanError.unsupported }
                }
                if (char == "&" || char == "*"), index + 1 < chars.count, isName(chars[index + 1]) {
                    throw MiniConfigScanError.unsupported
                }
                if char == "'" || char == "\"" {
                    quote = char
                    atToken = false
                    index += 1
                    continue
                }
                if char == "-", index + 1 < chars.count, chars[index + 1] == " " {
                    index += 2
                    atToken = true
                    continue
                }
                atToken = false
            }
            if char == ":" {
                index += 1
                while index < chars.count && chars[index] == " " { index += 1 }
                atToken = true
                continue
            }
            if char == "[" || char == "{" || char == "," {
                index += 1
                while index < chars.count && chars[index] == " " { index += 1 }
                atToken = true
                continue
            }
            if char == "]" || char == "}" {
                atToken = false
                index += 1
                continue
            }
            index += 1
        }
    }
}

private struct FlowParser {
    let chars: [Character]
    var index = 0

    init(_ text: String) {
        chars = Array(text)
    }

    mutating func parseValue() throws -> ScanValue {
        skipSpaces()
        guard index < chars.count else { throw MiniConfigScanError.unsupported }
        if chars[index] == "[" { return try parseList() }
        if chars[index] == "{" { return try parseMap() }
        return .string(try parseScalar())
    }

    mutating func expectEnd() throws {
        skipSpaces()
        if index != chars.count { throw MiniConfigScanError.unsupported }
    }

    private mutating func parseList() throws -> ScanValue {
        index += 1
        skipSpaces()
        if peek("]") {
            index += 1
            return .list([])
        }
        var items: [ScanValue] = []
        while index < chars.count {
            items.append(try parseValue())
            skipSpaces()
            if peek("]") {
                index += 1
                return .list(items)
            }
            guard peek(",") else { throw MiniConfigScanError.unsupported }
            index += 1
            skipSpaces()
        }
        throw MiniConfigScanError.unsupported
    }

    private mutating func parseMap() throws -> ScanValue {
        index += 1
        skipSpaces()
        if peek("}") {
            index += 1
            return .map([:])
        }
        var map: [String: ScanValue] = [:]
        while index < chars.count {
            skipSpaces()
            if peek("\"") || peek("'") { throw MiniConfigScanError.unsupported }
            let key = try parseScalar()
            skipSpaces()
            guard peek(":") else { throw MiniConfigScanError.unsupported }
            index += 1
            if map[key] != nil { throw MiniConfigScanError.unsupported }
            map[key] = try parseValue()
            skipSpaces()
            if peek("}") {
                index += 1
                return .map(map)
            }
            guard peek(",") else { throw MiniConfigScanError.unsupported }
            index += 1
        }
        throw MiniConfigScanError.unsupported
    }

    private mutating func parseScalar() throws -> String {
        skipSpaces()
        guard index < chars.count else { throw MiniConfigScanError.unsupported }
        if chars[index] == "\"" || chars[index] == "'" {
            let quote = chars[index]
            index += 1
            var out = ""
            var escaped = false
            while index < chars.count {
                let char = chars[index]
                index += 1
                if quote == "'" && char == "'" && index < chars.count && chars[index] == "'" {
                    out.append("'")
                    index += 1
                    continue
                }
                if escaped {
                    out.append(char)
                    escaped = false
                    continue
                }
                if quote == "\"" && char == "\\" {
                    escaped = true
                    continue
                }
                if char == quote { return out }
                out.append(char)
            }
            throw MiniConfigScanError.unsupported
        }
        let start = index
        while index < chars.count {
            let char = chars[index]
            if char == "," || char == "]" || char == "}" || char == ":" || char == "#" {
                break
            }
            index += 1
        }
        if index == start { throw MiniConfigScanError.unsupported }
        return String(chars[start..<index]).trimmingCharacters(in: .whitespaces)
    }

    private mutating func skipSpaces() {
        while index < chars.count && chars[index] == " " { index += 1 }
    }

    private func peek(_ char: Character) -> Bool {
        index < chars.count && chars[index] == char
    }
}
