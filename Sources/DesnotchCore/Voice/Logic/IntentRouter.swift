import Foundation

// WP-LOGIC owns this file. Base commit: fail-closed stub with the final signature.

/// Maps one final transcript to a `RouteDecision`. Pure: same input, same output. The whole
/// utterance must match a fixed phrase; nothing is guessed and unknown things are refused.
enum IntentRouter {
    static func route(_ utterance: String, context: RouterContext) -> RouteDecision {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .reject(.emptyUtterance) }
        if trimmed.count > VoiceLimits.maxUtteranceCharacters { return .reject(.tooLong) }

        let tokens = UtteranceNormalizer.tokens(trimmed)
        if tokens.isEmpty { return .reject(.emptyUtterance) }

        if emergencyPhrases.contains(tokens) { return .emergencyStop }
        if context.agentBusy && cancelTurnPhrases.contains(tokens) { return .cancelTurn }

        let (stripped, small) = stripSmallModifier(tokens)

        if let percent = matchVolumeSet(tokens) {
            return (0...100).contains(percent)
                ? .local(.volumeSet(percent: percent))
                : .reject(.invalidArgument)
        }
        if let minutes = matchTimer(tokens) {
            return VoiceLimits.timerMinutesRange.contains(minutes)
                ? .local(.timerStart(minutes: minutes))
                : .reject(.invalidArgument)
        }
        if let app = matchOpenApp(tokens) {
            return .local(.openApp(bundleID: app.bundleID, name: app.displayName))
        }
        if small, let intent = volumeStepIntent(stripped, magnitude: VoiceLimits.volumeStepSmall) {
            return .local(intent)
        }
        if let intent = fixedPhraseIntent(tokens) {
            return .local(intent)
        }
        if tokens == ["cancel"] { return .reject(.ambiguous) }
        if let decision = attemptedShape(tokens) { return decision }

        if context.hermesLaneAvailable { return .remote(utterance: trimmed) }
        return .reject(.notLocalCommand)
    }

    // MARK: - Phrase tables

    private static let emergencyPhrases: [[String]] = [
        ["abort", "agent"], ["abort", "the", "agent"], ["abort", "agents"],
        ["batalkan", "agent"], ["batalkan", "agen"]
    ]

    private static let cancelTurnPhrases: [[String]] = [
        ["stop"], ["cancel"], ["stop", "it"], ["cancel", "that"], ["cancel", "it"],
        ["batal"], ["berhenti"], ["hentikan"]
    ]

    private static let smallEndings: [[String]] = [
        ["a", "bit"], ["a", "little"], ["slightly"], ["sedikit"], ["dikit"]
    ]

    private static let volumeUpPhrases: [[String]] = [
        ["volume", "up"], ["louder"], ["turn", "it", "up"], ["turn", "up"],
        ["turn", "up", "the", "volume"], ["turn", "the", "volume", "up"],
        ["volume", "higher"], ["increase", "volume"], ["raise", "volume"],
        ["raise", "the", "volume"],
        ["volume", "naik"], ["naikkan", "volume"], ["besarkan", "volume"],
        ["keraskan"], ["keraskan", "volume"], ["tambah", "volume"]
    ]

    private static let volumeDownPhrases: [[String]] = [
        ["volume", "down"], ["quieter"], ["softer"], ["turn", "it", "down"], ["turn", "down"],
        ["turn", "down", "the", "volume"], ["turn", "the", "volume", "down"],
        ["volume", "lower"], ["decrease", "volume"], ["lower", "volume"],
        ["lower", "the", "volume"], ["reduce", "volume"],
        ["volume", "turun"], ["turunkan", "volume"], ["kecilkan", "volume"],
        ["pelankan"], ["pelankan", "volume"], ["kurangi", "volume"]
    ]

    /// Space-separated phrases paired with their intent; split once at lookup so the tables
    /// stay cheap for the type checker.
    private static let fixedPhrases: [(phrase: String, intent: LocalIntent)] = [
        // media play
        ("play", .mediaPlay), ("play music", .mediaPlay), ("play song", .mediaPlay),
        ("resume", .mediaPlay), ("resume music", .mediaPlay), ("resume playback", .mediaPlay),
        ("unpause", .mediaPlay), ("continue", .mediaPlay), ("continue playing", .mediaPlay),
        ("putar", .mediaPlay), ("putar musik", .mediaPlay), ("mainkan", .mediaPlay),
        ("mainkan musik", .mediaPlay), ("lanjut", .mediaPlay), ("lanjutkan", .mediaPlay),
        ("lanjutkan musik", .mediaPlay),
        // media pause
        ("pause", .mediaPause), ("pause music", .mediaPause), ("pause playback", .mediaPause),
        ("stop", .mediaPause), ("stop music", .mediaPause), ("stop playing", .mediaPause),
        ("stop the music", .mediaPause),
        ("jeda", .mediaPause), ("jeda musik", .mediaPause), ("berhenti", .mediaPause),
        ("hentikan musik", .mediaPause), ("matikan musik", .mediaPause),
        // media next
        ("next", .mediaNext), ("next track", .mediaNext), ("next song", .mediaNext),
        ("skip", .mediaNext), ("skip track", .mediaNext), ("skip song", .mediaNext),
        ("skip this song", .mediaNext), ("skip this track", .mediaNext),
        ("berikutnya", .mediaNext), ("selanjutnya", .mediaNext), ("lagu berikutnya", .mediaNext),
        ("lagu selanjutnya", .mediaNext),
        // media previous
        ("previous", .mediaPrevious), ("previous track", .mediaPrevious),
        ("previous song", .mediaPrevious), ("last song", .mediaPrevious),
        ("last track", .mediaPrevious), ("go back", .mediaPrevious),
        ("sebelumnya", .mediaPrevious), ("lagu sebelumnya", .mediaPrevious),
        // mute / unmute
        ("mute", .mute), ("mute volume", .mute), ("mute sound", .mute), ("mute audio", .mute),
        ("bisukan", .mute), ("bisukan suara", .mute),
        ("unmute", .unmute), ("unmute volume", .unmute), ("unmute sound", .unmute),
        ("unmute audio", .unmute), ("un mute", .unmute),
        ("nyalakan suara", .unmute), ("buka bisu", .unmute),
        // timer cancel
        ("cancel timer", .timerCancel), ("cancel the timer", .timerCancel),
        ("stop timer", .timerCancel), ("stop the timer", .timerCancel),
        ("clear timer", .timerCancel),
        ("batalkan timer", .timerCancel), ("hentikan timer", .timerCancel),
        ("matikan timer", .timerCancel), ("batal timer", .timerCancel)
    ]

    // MARK: - Grammars

    private static let volumePrefixes: [[String]] = [
        ["set", "the", "volume"], ["set", "volume"], ["change", "the", "volume"],
        ["change", "volume"], ["atur", "volume"], ["setel", "volume"], ["ubah", "volume"],
        ["volume"]
    ]

    private static let volumeJoiners: Set<String> = ["to", "ke", "jadi"]

    private static let timerHeads: [[String]] = [
        ["set", "a", "timer"], ["start", "a", "timer"], ["set", "timer"], ["start", "timer"],
        ["setel", "timer"], ["pasang", "timer"], ["atur", "timer"], ["timer"]
    ]
    private static let timerPrefixes: [[String]] = [["set", "a"], ["start", "a"]]
    private static let timerJoiners: Set<String> = ["for", "selama", "untuk"]
    private static let timerUnits: Set<String> = ["minute", "minutes", "min", "mins", "menit"]

    private static let openVerbs: [[String]] = [["open", "up"], ["open"], ["launch"], ["buka"], ["jalankan"]]
    private static let openArticles: Set<String> = ["the", "a", "aplikasi"]
    private static let openSuffixes: Set<String> = ["app", "application", "aplikasi"]

    private static let openFirstTokens: Set<String> = ["open", "launch", "buka", "jalankan"]
    private static let volumeFirstVerbs: Set<String> = ["set", "atur", "setel", "ubah", "change"]
    private static let timerFirstVerbs: Set<String> = ["set", "start", "setel", "pasang", "atur"]

    // MARK: - Matching helpers

    private static func stripSmallModifier(_ tokens: [String]) -> ([String], Bool) {
        for ending in smallEndings where tokens.count >= ending.count
            && Array(tokens.suffix(ending.count)) == ending {
            return (Array(tokens.dropLast(ending.count)), true)
        }
        return (tokens, false)
    }

    private static func volumeStepIntent(_ tokens: [String], magnitude: Int) -> LocalIntent? {
        if volumeUpPhrases.contains(tokens) { return .volumeStep(delta: magnitude) }
        if volumeDownPhrases.contains(tokens) { return .volumeStep(delta: -magnitude) }
        return nil
    }

    private static func fixedPhraseIntent(_ tokens: [String]) -> LocalIntent? {
        if let step = volumeStepIntent(tokens, magnitude: VoiceLimits.volumeStep) { return step }
        for entry in fixedPhrases
        where entry.phrase.split(separator: " ").map(String.init) == tokens {
            return entry.intent
        }
        return nil
    }

    private static func matchVolumeSet(_ tokens: [String]) -> Int? {
        for prefix in volumePrefixes
        where tokens.count >= prefix.count && Array(tokens.prefix(prefix.count)) == prefix {
            var index = prefix.count
            if index < tokens.count, volumeJoiners.contains(tokens[index]) { index += 1 }
            guard let parsed = SpokenNumber.parse(tokens, at: index) else { continue }
            var end = index + parsed.length
            if end < tokens.count {
                guard (tokens[end] == "percent" || tokens[end] == "persen"),
                      end + 1 == tokens.count else { continue }
                end += 1
            }
            if end == tokens.count { return parsed.value }
        }
        return nil
    }

    private static func matchTimer(_ tokens: [String]) -> Int? {
        // Form 1: TIMERHEAD [for|selama|untuk] NUMBER UNIT
        for head in timerHeads
        where tokens.count > head.count && Array(tokens.prefix(head.count)) == head {
            var index = head.count
            if index < tokens.count, timerJoiners.contains(tokens[index]) { index += 1 }
            guard let parsed = SpokenNumber.parse(tokens, at: index) else { continue }
            let unitIndex = index + parsed.length
            guard unitIndex < tokens.count, timerUnits.contains(tokens[unitIndex]) else { continue }
            if unitIndex + 1 == tokens.count { return parsed.value }
        }
        // Form 2a: (set a|start a) NUMBER UNIT [timer]
        for prefix in timerPrefixes
        where tokens.count > prefix.count && Array(tokens.prefix(prefix.count)) == prefix {
            let index = prefix.count
            guard let parsed = SpokenNumber.parse(tokens, at: index) else { continue }
            let unitIndex = index + parsed.length
            guard unitIndex < tokens.count, timerUnits.contains(tokens[unitIndex]) else { continue }
            if unitIndex + 1 == tokens.count { return parsed.value }
            if unitIndex + 2 == tokens.count && tokens[unitIndex + 1] == "timer" { return parsed.value }
        }
        // Form 2b: NUMBER UNIT timer
        if let parsed = SpokenNumber.parse(tokens, at: 0) {
            let unitIndex = parsed.length
            if unitIndex < tokens.count, timerUnits.contains(tokens[unitIndex]),
               unitIndex + 2 == tokens.count, tokens[unitIndex + 1] == "timer" {
                return parsed.value
            }
        }
        return nil
    }

    private static func matchOpenApp(_ tokens: [String]) -> AppCatalog.Entry? {
        for verb in openVerbs
        where tokens.count > verb.count && Array(tokens.prefix(verb.count)) == verb {
            var name = Array(tokens.dropFirst(verb.count))
            if let first = name.first, openArticles.contains(first) { name.removeFirst() }
            if let last = name.last, openSuffixes.contains(last), name.count > 1 { name.removeLast() }
            if (1...3).contains(name.count), let entry = AppCatalog.lookup(name) { return entry }
        }
        return nil
    }

    private static func attemptedShape(_ tokens: [String]) -> RouteDecision? {
        guard let first = tokens.first else { return nil }
        if openFirstTokens.contains(first) {
            if tokens.count == 1 { return .reject(.ambiguous) }
            if tokens.count <= 5 { return .reject(.unknownApp) }
            return nil
        }
        if first == "volume" || mentioned(first, in: volumeFirstVerbs, "volume", tokens) {
            if tokens.count == 1 { return .reject(.ambiguous) }
            if tokens.count <= 6 { return .reject(.invalidArgument) }
            return nil
        }
        if first == "timer" || mentioned(first, in: timerFirstVerbs, "timer", tokens) {
            if tokens.count == 1 { return .reject(.ambiguous) }
            if tokens.count <= 8 { return .reject(.invalidArgument) }
            return nil
        }
        return nil
    }

    /// True when `verb` is the first token and `noun` is token 2 or 3.
    private static func mentioned(_ verb: String, in verbs: Set<String>, _ noun: String,
                                  _ tokens: [String]) -> Bool {
        guard verbs.contains(verb) else { return false }
        if tokens.count >= 2 && tokens[1] == noun { return true }
        if tokens.count >= 3 && tokens[2] == noun { return true }
        return false
    }
}
