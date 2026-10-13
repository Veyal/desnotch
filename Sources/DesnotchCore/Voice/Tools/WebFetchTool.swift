import Foundation

/// The result of one GET, already bounded. The fetcher lives in `Voice/OpenAI/` (the only
/// folder allowed a network API); this tool only classifies and formats.
enum AgentFetchResult: Equatable, Sendable {
    case page(status: Int, contentType: String, text: String)
    /// Redirects are never followed: the model may fetch the new address, which is classified
    /// again from scratch.
    case redirect(status: Int, location: String)
    case refused(String)
    case failed(String)
    case cancelled
}

protocol AgentWebFetching: Sendable {
    func fetch(_ url: URL) async -> AgentFetchResult
    /// True when every address the name resolves to is public (a failed lookup is false). Used
    /// to classify `open_url`, which hands the URL to the browser and has no fetch of its own.
    func isPublicHost(_ host: String) async -> Bool
}

/// `web_fetch`: GET a public http(s) page and return its text. Tier from `AgentURLPolicy`
/// (T1 for a plain public URL, T2 when the URL can carry data out, T3 for local addresses).
/// The page is untrusted data and is fenced like every tool result.
struct WebFetchTool: AgentEgressTool {
    let fetcher: AgentWebFetching
    var revealsData: Bool { true }

    var definition: ChatToolDefinition {
        ChatToolDefinition(
            name: "web_fetch",
            description: "Download a public web page (http or https) and return its text. Redirects are not followed.",
            inputSchemaJSON: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#
        )
    }

    func propose(_ args: AgentToolArgs) async -> ChatToolProposal {
        guard let raw = args.text("url"), let verdict = AgentURLPolicy.classify(raw) else {
            return AgentProposals.invalid("tool.web_fetch", label: AgentToolStep.fetchPage, "a valid http(s) url is required")
        }
        return ChatToolProposal(
            tier: verdict.tier,
            stepLabel: verdict.tier == .t2 ? AgentToolStep.fetchPageApproved : AgentToolStep.fetchPage,
            summary: "Download a web page for the AI",
            literal: verdict.literal,
            risk: verdict.risk,
            isTruncated: verdict.isTruncated,
            auditCode: "tool.web_fetch"
        )
    }

    func proposeAfterDataRead(_ args: AgentToolArgs) -> ChatToolProposal {
        guard let raw = args.text("url"), let verdict = AgentURLPolicy.classify(raw) else {
            return AgentProposals.invalid("tool.web_fetch", label: AgentToolStep.fetchPageApproved, "a valid http(s) url is required")
        }
        return ChatToolProposal(
            tier: max(.t2, verdict.tier), stepLabel: AgentToolStep.fetchPageApproved,
            summary: "Download a web page for the AI", literal: verdict.literal, risk: verdict.risk,
            isTruncated: verdict.isTruncated, auditCode: "tool.web_fetch"
        )
    }

    func execute(_ args: AgentToolArgs) async -> ChatToolOutcome {
        guard let raw = args.text("url"), let verdict = AgentURLPolicy.classify(raw), verdict.tier <= .t2 else {
            return ChatToolOutcome(content: "Invalid url.", isError: true)
        }
        switch await fetcher.fetch(verdict.url) {
        case .page(let status, let type, let text):
            return ChatToolOutcome(content: "HTTP \(status) (\(type))\n\(text)", isError: !(200...299).contains(status))
        case .redirect(let status, let location):
            return ChatToolOutcome(content: "HTTP \(status): redirected to \(location) (not followed).", isError: false)
        case .refused(let reason):
            return ChatToolOutcome(content: "Refused: \(reason).", isError: true)
        case .failed(let reason):
            return ChatToolOutcome(content: "Failed: \(reason).", isError: true)
        case .cancelled:
            return ChatToolOutcome(content: "Stopped.", isError: true)
        }
    }
}

/// Plain text from an HTML or text body: scripts, styles and tags removed, entities for the
/// common characters decoded, whitespace collapsed. A display aid for the model, not a parser.
enum AgentHTMLText {
    static func extract(_ body: String, isHTML: Bool) -> String {
        guard isHTML else { return collapse(body) }
        var text = body
        for tag in ["script", "style", "noscript", "svg", "head"] {
            text = text.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", with: " ", options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "<(br|/p|/div|/li|/h[1-6]|/tr)\\b[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return collapse(text)
    }

    private static func collapse(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
