import Foundation

// WP-LOGIC owns this file. Base commit: stub with the final signature.

enum UtteranceNormalizer {
    static let leadingFillers: Set<String> = [
        "please", "tolong", "hey", "hi", "ok", "okay", "kindly", "desnotch",
        "um", "uh", "hmm", "eh", "ehm", "emm", "ah", "err"
    ]
    static let trailingFillers: Set<String> = [
        "please", "tolong", "dong", "ya", "deh", "aja", "saja", "now", "sekarang",
        "thanks", "thx", "um", "uh", "hmm"
    ]

    /// Lowercased word tokens with punctuation replaced by spaces, plus leading and
    /// trailing filler words removed. Everything that is not a letter or a number becomes
    /// a separator, so "30%" is "30" and "twenty-five" is two tokens.
    static func tokens(_ raw: String) -> [String] {
        let lowered = raw.lowercased()
        var cleaned = ""
        cleaned.reserveCapacity(lowered.count)
        for character in lowered {
            cleaned.append((character.isLetter || character.isNumber) ? character : " ")
        }
        var words = cleaned.split(separator: " ").map(String.init)
        while let first = words.first, leadingFillers.contains(first) {
            words.removeFirst()
        }
        while let last = words.last, trailingFillers.contains(last) {
            words.removeLast()
        }
        return words
    }
}
