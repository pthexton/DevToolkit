import Foundation

/// A small, dependency-free fuzzy matcher combining two documented, publicly
/// citable algorithms rather than ad-hoc scoring:
///
/// - `match`: an ordered-subsequence matcher based on Forrest Smith's
///   "fts_fuzzy_match" (the reference behind Sublime Text-style fuzzy
///   finders), dual-licensed to the public domain -
///   https://github.com/forrestthewoods/lib_fts and
///   https://www.forrestthewoods.com/blog/reverse_engineering_sublime_texts_fuzzy_match/
///   That reference performs an exhaustive recursive search for the
///   highest-scoring alignment (rather than greedily taking the first
///   occurrence of each character, which can pick a scattered match even
///   when a tight one exists elsewhere - e.g. matching "rugby"'s `r` against
///   the `r` in "Scores" instead of the `r` in "Rugby" a few words later).
///   This reimplements the same scoring rules and the same
///   exhaustive-best-alignment guarantee via dynamic programming instead of
///   raw recursion, so it scales to long strings (URLs) without the
///   reference's internal recursion-depth cap.
/// - `editDistance`/`typoScore`: restricted Damerau-Levenshtein edit
///   distance (Levenshtein 1965; Damerau 1964; "optimal string alignment"
///   variant), used as a fallback when `pattern` isn't a subsequence of
///   `text` at all - e.g. transposed or substituted characters, which no
///   subsequence matcher (including fts_fuzzy_match) can find, since the
///   characters are in the wrong order rather than merely missing.
enum FuzzyMatcher {
    // MARK: - Subsequence matching (fts_fuzzy_match-derived)

    private static let baseScore = 100
    private static let sequentialBonus = 15
    private static let separatorBonus = 30
    private static let camelBonus = 30
    private static let firstLetterBonus = 15
    private static let leadingLetterPenalty = -5
    private static let maxLeadingLetterPenalty = -15
    private static let unmatchedLetterPenalty = -1

    // Matches the reference exactly: space and underscore only. An earlier
    // version also treated '-', '/', and '.' as separators to reward
    // URL/path boundaries, but a unit test caught this backfiring badly on
    // URL-heavy text - URLs are *full* of those characters, so coincidental
    // matches could rack up huge separator bonuses (+30 each) that swamped
    // the linear unmatched-letter penalty, scoring pure noise higher than a
    // genuine typo-tolerant match. Not worth the risk for the benefit.
    private static func isSeparator(_ c: Character) -> Bool {
        c == " " || c == "_"
    }

    /// Finds the highest-scoring way to align `pattern` as a subsequence of
    /// `text` (case-insensitive) and returns its score, or nil if `pattern`
    /// isn't a subsequence of `text` at all.
    static func match(pattern: String, in text: String) -> Int? {
        guard !pattern.isEmpty else { return 0 }
        guard !text.isEmpty else { return nil }

        let patternChars = Array(pattern.lowercased())
        let textChars = Array(text)
        let textLower = Array(text.lowercased())
        let patternCount = patternChars.count
        let textCount = textChars.count
        guard textCount >= patternCount else { return nil }

        // Ordering bonus earned by matching a pattern character at text
        // position j, given whether text[j-1] was also matched
        // (`consecutive`, i.e. the sequential-match bonus).
        func orderingBonus(at j: Int, consecutive: Bool) -> Int {
            var bonus = consecutive ? sequentialBonus : 0
            if j > 0 {
                let neighbor = textChars[j - 1]
                if neighbor.isLowercase && textChars[j].isUppercase { bonus += camelBonus }
                if isSeparator(neighbor) { bonus += separatorBonus }
            }
            return bonus
        }

        // Score contribution of landing the *first* pattern character at
        // position j: either the start-of-string bonus (j == 0) or the
        // ordinary ordering bonus, plus the leading-letter penalty for
        // however many characters precede it (capped, matching the
        // reference exactly).
        func startScore(at j: Int) -> Int {
            let ordering = j == 0 ? firstLetterBonus : orderingBonus(at: j, consecutive: false)
            let leading = max(maxLeadingLetterPenalty, leadingLetterPenalty * j)
            return ordering + leading
        }

        // dpScore[j]: best cumulative score for aligning the first `i`
        // pattern characters with the i-th one landing exactly at text
        // position j (nil = unreachable). Considers every valid starting
        // and intermediate position - not just the first occurrence of each
        // character - so a tight cluster elsewhere in the string can win
        // over an earlier but more scattered false start.
        var dpScore = [Int?](repeating: nil, count: textCount)

        for j in 0..<textCount where textLower[j] == patternChars[0] {
            dpScore[j] = startScore(at: j)
        }

        for i in 1..<patternCount {
            var nextScore = [Int?](repeating: nil, count: textCount)

            // Running best of dpScore[k] for k <= j - 2, i.e. every
            // candidate predecessor *except* the immediately preceding
            // index (j - 1), which is handled separately below so the
            // sequential-match bonus can be applied correctly.
            var bestPrefixScore: Int?

            for j in 0..<textCount {
                if j >= 2, let s = dpScore[j - 2] {
                    bestPrefixScore = max(bestPrefixScore ?? Int.min, s)
                }

                guard textLower[j] == patternChars[i] else { continue }

                var best: Int?
                if j >= 1, let prevScore = dpScore[j - 1] {
                    best = prevScore + orderingBonus(at: j, consecutive: true)
                }
                if let prefixScore = bestPrefixScore {
                    let candidate = prefixScore + orderingBonus(at: j, consecutive: false)
                    best = max(best ?? Int.min, candidate)
                }
                nextScore[j] = best
            }

            dpScore = nextScore
        }

        guard let bestOrderingScore = dpScore.compactMap({ $0 }).max() else { return nil }

        // Unmatched-letter penalty applies to every character in `text`
        // that isn't part of the match, regardless of where it falls -
        // this is what keeps a query whose letters coincidentally appear
        // scattered across a long string (e.g. a URL) from outscoring a
        // genuinely tight match elsewhere, without needing an ad-hoc
        // density heuristic layered on top.
        let unmatched = textCount - patternCount
        return baseScore + bestOrderingScore + unmatchedLetterPenalty * unmatched
    }

    // MARK: - Typo-tolerant fallback (Damerau-Levenshtein)

    /// Restricted Damerau-Levenshtein edit distance (insertions, deletions,
    /// substitutions, and adjacent transpositions), case-insensitive. Unlike
    /// `match`, this tolerates characters being in the *wrong* order, not
    /// just missing - e.g. "testlatpot" vs "testlaptop" (a transposition
    /// plus a substitution) is not a subsequence match at all, but is only
    /// distance 2 here.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.lowercased())
        let b = Array(b.lowercased())
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var twoRowsAgo = [Int](repeating: 0, count: b.count + 1)
        var previousRow = Array(0...b.count)
        var currentRow = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            currentRow[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(
                    previousRow[j] + 1,       // deletion
                    currentRow[j - 1] + 1,    // insertion
                    previousRow[j - 1] + cost // substitution
                )
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, twoRowsAgo[j - 2] + 1) // transposition
                }
                currentRow[j] = value
            }
            twoRowsAgo = previousRow
            previousRow = currentRow
            currentRow = [Int](repeating: 0, count: b.count + 1)
        }
        return previousRow[b.count]
    }

    /// A typo-tolerant fallback score for when `pattern` isn't a subsequence
    /// of `text` at all. Compares `pattern` against each whitespace/
    /// punctuation-delimited token in `text` (so a garbled word can match
    /// within a longer title) and scores by percentage closeness (1 -
    /// distance/length), scaled to sit below a clean exact/subsequence
    /// match but above a weak, scattered coincidental one - this only
    /// exists so a close-but-garbled query surfaces at all instead of
    /// vanishing entirely.
    static func typoScore(pattern: String, in text: String) -> Int? {
        guard pattern.count >= 3 else { return nil } // too short to typo-match safely
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !tokens.isEmpty else { return nil }

        var best: (distance: Int, tokenLength: Int)?
        for token in tokens {
            let distance = editDistance(pattern, String(token))
            if best == nil || distance < best!.distance {
                best = (distance, token.count)
            }
        }
        guard let best else { return nil }

        let maxAllowed = max(1, pattern.count / 3)
        guard best.distance <= maxAllowed else { return nil }

        let longer = max(pattern.count, best.tokenLength)
        let similarity = 1.0 - Double(best.distance) / Double(longer)
        return Int((similarity * 60).rounded())
    }
}
