import XCTest
@testable import DevToolkitApp

/// Grounds `FuzzyMatcher` against two documented, publicly citable
/// references rather than testing ad-hoc/incidental behaviour:
///
/// - The subsequence matcher (`match`) is modelled on Forrest Smith's
///   "fts_fuzzy_match" (see FuzzyMatcher.swift's header comment for links);
///   the tests below assert the specific bonus/penalty properties that
///   reference documents (start-of-string, camelCase/separator boundaries,
///   sequential runs, leading/unmatched penalties) rather than exact score
///   values, since exact scores are an implementation detail.
/// - The typo-tolerant fallback (`editDistance`) is restricted
///   Damerau-Levenshtein, a formally documented algorithm with well-known
///   canonical distances (Wikipedia's "Damerau-Levenshtein distance" and
///   "Levenshtein distance" articles both list these), which the tests
///   assert directly.
final class FuzzyMatcherTests: XCTestCase {

    // MARK: - match: basic subsequence semantics

    func testEmptyPatternMatchesAnything() {
        XCTAssertEqual(FuzzyMatcher.match(pattern: "", in: "anything"), 0)
    }

    func testPatternNotASubsequenceReturnsNil() {
        // "xyz" never appears in order in "abc"
        XCTAssertNil(FuzzyMatcher.match(pattern: "xyz", in: "abc"))
    }

    func testPatternLongerThanTextReturnsNil() {
        XCTAssertNil(FuzzyMatcher.match(pattern: "abcdef", in: "abc"))
    }

    func testExactMatchIsCaseInsensitive() {
        let lower = FuzzyMatcher.match(pattern: "safari", in: "Safari")
        let upper = FuzzyMatcher.match(pattern: "SAFARI", in: "Safari")
        XCTAssertNotNil(lower)
        XCTAssertEqual(lower, upper)
    }

    func testNonContiguousSubsequenceStillMatches() {
        // "gubi" -> "getUserById" is the reference implementation's own
        // canonical example of an abbreviation-style subsequence match.
        XCTAssertNotNil(FuzzyMatcher.match(pattern: "gubi", in: "getUserById"))
    }

    // MARK: - match: documented scoring properties (fts_fuzzy_match)

    func testMatchAtStringStartScoresHigherThanMatchInMiddle() {
        let atStart = FuzzyMatcher.match(pattern: "abc", in: "abcxxxxxxxxxx")!
        let inMiddle = FuzzyMatcher.match(pattern: "abc", in: "xxxxxxxxxxabc")!
        XCTAssertGreaterThan(atStart, inMiddle)
    }

    func testMatchAfterSeparatorScoresHigherThanMidWordMatch() {
        // "log" right after a separator ("-log") vs. buried mid-word
        // ("xxxlogxxx") with no boundary at all.
        let afterSeparator = FuzzyMatcher.match(pattern: "log", in: "xxx-logxxx")!
        let midWord = FuzzyMatcher.match(pattern: "log", in: "xxxxlogxxxx")!
        XCTAssertGreaterThan(afterSeparator, midWord)
    }

    func testCamelCaseBoundaryScoresHigherThanMidWordMatch() {
        let atBoundary = FuzzyMatcher.match(pattern: "user", in: "getUserById")!
        let midWord = FuzzyMatcher.match(pattern: "user", in: "xxxxuserxxxx")!
        XCTAssertGreaterThan(atBoundary, midWord)
    }

    func testContiguousMatchScoresHigherThanScatteredMatch() {
        // Regression test for a real bug: a naive greedy left-to-right
        // matcher picked the "r" in "Scores" over the "r" in "Rugby",
        // scattering the rest of the match across the whole title instead
        // of finding the tight, obviously-intended "Rugby" cluster.
        let title = "Scores & Fixtures - Rugby League - BBC Sport"
        let score = FuzzyMatcher.match(pattern: "rugby", in: title)
        XCTAssertNotNil(score)
        // Should land solidly in "real match" territory, not be crushed by
        // scattering across the full ~46-character title.
        XCTAssertGreaterThan(score!, 100)
    }

    func testLongerUnmatchedTailLowersScore() {
        // Same tight match, but with a much longer irrelevant tail - the
        // unmatched-letter penalty should pull the score down.
        let short = FuzzyMatcher.match(pattern: "cat", in: "cat")!
        let long = FuzzyMatcher.match(pattern: "cat", in: "cat" + String(repeating: "x", count: 50))!
        XCTAssertGreaterThan(short, long)
    }

    func testScatteredCoincidentalMatchInLongTextScoresPoorly() {
        // A query that happens to be a subsequence of a long, unrelated
        // string (common with URLs) should score very low - low enough
        // that a genuine typo-tolerant match elsewhere can outrank it.
        let longURL = "https://www.tritonshowers.co.uk/showers-taps/electric-showers" +
            "?filt_electric_tempcontrol=Thermostatic&product_list_dir=asc"
        if let coincidental = FuzzyMatcher.match(pattern: "testlatpot", in: longURL) {
            let typoMatch = FuzzyMatcher.typoScore(pattern: "testlatpot", in: "testlaptop")!
            XCTAssertLessThan(coincidental, typoMatch)
        }
        // Whether or not "testlatpot" happens to be a coincidental
        // subsequence of this particular URL, it must never beat a real,
        // close typo match - this is the property that actually matters.
    }

    // MARK: - editDistance: canonical Damerau-Levenshtein distances

    func testEditDistanceIdenticalStringsIsZero() {
        XCTAssertEqual(FuzzyMatcher.editDistance("abc", "abc"), 0)
    }

    func testEditDistanceAgainstEmptyStringIsLength() {
        XCTAssertEqual(FuzzyMatcher.editDistance("", "abc"), 3)
        XCTAssertEqual(FuzzyMatcher.editDistance("abc", ""), 3)
    }

    func testEditDistanceKittenSitting() {
        // The textbook example (Wikipedia "Levenshtein distance"): distance 3.
        XCTAssertEqual(FuzzyMatcher.editDistance("kitten", "sitting"), 3)
    }

    func testEditDistanceRecognisesAdjacentTransposition() {
        // The defining difference between plain Levenshtein (which would
        // say 2: two substitutions) and Damerau-Levenshtein (which
        // recognises the adjacent swap as a single edit).
        XCTAssertEqual(FuzzyMatcher.editDistance("ab", "ba"), 1)
    }

    func testEditDistanceIsCaseInsensitive() {
        XCTAssertEqual(FuzzyMatcher.editDistance("ABC", "abc"), 0)
    }

    // MARK: - typoScore: today's real reported bug

    func testTypoTransposedCharactersStillFound() {
        // The actual real-world report this fallback was built for: a
        // sloppily-typed query with a transposition plus a substitution
        // that isn't a subsequence match at all.
        let score = FuzzyMatcher.typoScore(pattern: "testlatpot", in: "testlaptop")
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score!, 0)
    }

    func testTypoScoreNilForUnrelatedText() {
        XCTAssertNil(FuzzyMatcher.typoScore(pattern: "testlatpot", in: "safari"))
    }

    func testTypoScoreRequiresMinimumPatternLength() {
        // Too short to typo-match safely without excessive false positives.
        XCTAssertNil(FuzzyMatcher.typoScore(pattern: "ab", in: "abc"))
    }
}
