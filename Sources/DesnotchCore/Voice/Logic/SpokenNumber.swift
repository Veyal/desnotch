import Foundation

// WP-LOGIC owns this file. Base commit: stub with the final signature.

enum SpokenNumber {
    private static let englishUnits: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19
    ]
    private static let englishTens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]
    /// The unit words a tens word may absorb ("twenty five"), never zero/teens/tens.
    private static let englishTensUnits: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"
    ]
    private static let indonesianSmall: [String: Int] = [
        "nol": 0, "kosong": 0, "satu": 1, "dua": 2, "tiga": 3, "empat": 4,
        "lima": 5, "enam": 6, "tujuh": 7, "delapan": 8, "sembilan": 9,
        "sepuluh": 10, "sebelas": 11, "seratus": 100
    ]
    /// Indonesian units usable after "belas" (2...9) and after "puluh" (1...9).
    private static let indonesianUnitWords: Set<String> = [
        "satu", "dua", "tiga", "empat", "lima", "enam", "tujuh", "delapan", "sembilan"
    ]

    /// Parses the longest number starting at `tokens[start]` (digits, English words, or
    /// Indonesian words). Returns the value and how many tokens it used, or nil. It never
    /// reads before `start`.
    static func parse(_ tokens: [String], at start: Int) -> (value: Int, length: Int)? {
        guard start >= 0, start < tokens.count else { return nil }
        let token = tokens[start]

        if let digits = asciiNumber(token) {
            return (digits, 1)
        }

        if let next = nextToken(tokens, at: start + 1) {
            // "one hundred" and "a hundred" are the only two-token hundreds.
            if (token == "one" || token == "a") && next == "hundred" {
                return (100, 2)
            }
            if let unit = indonesianUnitValue(token), (2...9).contains(unit) {
                if next == "belas" { return (10 + unit, 2) }
                if next == "puluh" {
                    let base = 10 * unit
                    if let tail = nextToken(tokens, at: start + 2),
                       let tailValue = indonesianUnitValue(tail) {
                        return (base + tailValue, 3)
                    }
                    return (base, 2)
                }
            }
        }

        if token == "hundred" { return (100, 1) }
        if let unit = englishUnits[token] { return (unit, 1) }
        if let tens = englishTens[token] {
            if let next = nextToken(tokens, at: start + 1), englishTensUnits.contains(next),
               let unit = englishUnits[next] {
                return (tens + unit, 2)
            }
            return (tens, 1)
        }
        if let value = indonesianSmall[token] { return (value, 1) }
        return nil
    }

    private static func asciiNumber(_ token: String) -> Int? {
        guard !token.isEmpty, token.count <= 3 else { return nil }
        guard token.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(token)
    }

    private static func nextToken(_ tokens: [String], at index: Int) -> String? {
        guard index >= 0, index < tokens.count else { return nil }
        return tokens[index]
    }

    private static func indonesianUnitValue(_ token: String) -> Int? {
        guard indonesianUnitWords.contains(token) else { return nil }
        return indonesianSmall[token]
    }
}
