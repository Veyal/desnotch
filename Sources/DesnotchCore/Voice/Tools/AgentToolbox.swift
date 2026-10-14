import Foundation

/// The v1 machine-control catalog behind `ChatToolHandling`. One schema per tool; the
/// OpenAI-compatible and Anthropic adapters translate it to their own `tools` shape.
/// An unknown tool name classifies T3 (denied, nothing runs).
final class AgentToolbox: ChatToolHandling {
    private let catalog: [AgentTool]
    private let byName: [String: AgentTool]

    init(tools: [AgentTool]) {
        catalog = tools
        var index: [String: AgentTool] = [:]
        for tool in tools { index[tool.definition.name] = tool }
        byName = index
    }

    /// The full v1 catalog over the given services.
    static func standard(
        system: AgentSystemServing,
        paths: AgentPathContext = .live(),
        runner: AgentProcessRunning = LiveAgentProcessRunner(),
        fetcher: AgentWebFetching
    ) -> AgentToolbox {
        AgentToolbox(tools: [
            OpenAppTool(system: system),
            OpenURLTool(system: system, network: fetcher),
            MediaControlTool(system: system),
            SetVolumeTool(system: system),
            FocusTimerTool(system: system),
            SystemInfoTool(system: system),
            ListDirTool(paths: paths),
            ReadFileTool(paths: paths),
            SearchFilesTool(paths: paths),
            ClipboardReadTool(system: system),
            ClipboardWriteTool(system: system),
            WebFetchTool(fetcher: fetcher),
            WriteFileTool(paths: paths),
            RunShortcutTool(paths: paths, runner: runner),
            RunAppleScriptTool(paths: paths, runner: runner),
            RunShellTool(paths: paths, runner: runner)
        ])
    }

    var tools: [ChatToolDefinition] {
        catalog.map(\.definition)
    }

    func propose(name: String, inputJSON: String, context: ChatToolCallContext) async -> ChatToolProposal {
        guard let tool = byName[name] else { return AgentProposals.unknownTool() }
        guard let args = AgentToolArgs.parse(inputJSON) else {
            return AgentProposals.invalid("tool.\(name)", label: "Invalid", "arguments must be a JSON object")
        }
        return await Self.classify(tool, args, context)
    }

    func revealsData(name: String) -> Bool {
        byName[name]?.revealsData ?? false
    }

    private static func classify(_ tool: AgentTool, _ args: AgentToolArgs, _ context: ChatToolCallContext) async -> ChatToolProposal {
        if context.afterDataRead, let egress = tool as? AgentEgressTool {
            return egress.proposeAfterDataRead(args)
        }
        return await tool.propose(args)
    }

    /// Re-classifies first: a call whose tier rose since the gate let it through (a path that
    /// became a symlink to a protected folder, a file that appeared) is refused, not run.
    func run(name: String, inputJSON: String, approvedTier: VoiceTier, context: ChatToolCallContext) async -> ChatToolOutcome {
        guard let tool = byName[name], let args = AgentToolArgs.parse(inputJSON) else {
            return ChatToolOutcome(content: "Unknown tool.", isError: true)
        }
        let again = await Self.classify(tool, args, context)
        guard again.invalidReason == nil, again.tier <= approvedTier, again.tier <= .t2 else {
            return ChatToolOutcome(content: "Refused: the request changed since it was checked.", isError: true)
        }
        return await tool.execute(args)
    }
}
