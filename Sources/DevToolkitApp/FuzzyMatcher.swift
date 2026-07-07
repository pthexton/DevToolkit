import Foundation

/// A small, dependency-free fuzzy subsequence matcher. `pattern` must appear
/// as a (not necessarily contiguous) subsequence of `text`, case-insensitively.
/// Higher scores are better matches: consecutive runs, matches at the start
/// of the string, and matches right after a separator or at a camelCase
/// boundary are all weighted more heavily.
enum FuzzyMatcher {
    struct Match {
        let score: Int
        let matchedIndices: [Int]
    }

    static func match(pattern: String, in text: String) -> Match? {
        guard !pattern.isEmpty else { return Match(score: 0, matchedIndices: []) }
        guard !text.isEmpty else { return nil }

        let patternChars = Array(pattern.lowercased())
        let textChars = Array(text)
        let textLower = Array(text.lowercased())

        var patternIndex = 0
        var score = 0
        var consecutiveRun = 0
        var lastMatchIndex = -1
        var matchedIndices: [Int] = []

        for textIndex in 0..<textChars.count {
            guard patternIndex < patternChars.count else { break }
            guard textLower[textIndex] == patternChars[patternIndex] else { continue }

            var bonus = 1
            if lastMatchIndex == textIndex - 1 {
                consecutiveRun += 1
                bonus += consecutiveRun * 3
            } else {
                consecutiveRun = 0
            }

            if textIndex == 0 {
                bonus += 5
            } else {
                let previous = textChars[textIndex - 1]
                if previous == " " || previous == "-" || previous == "_" || previous == "/" || previous == "." {
                    bonus += 4
                } else if previous.isLowercase && textChars[textIndex].isUppercase {
                    bonus += 4
                }
            }

            score += bonus
            matchedIndices.append(textIndex)
            lastMatchIndex = textIndex
            patternIndex += 1
        }

        guard patternIndex == patternChars.count else { return nil }
        return Match(score: score, matchedIndices: matchedIndices)
    }
}
