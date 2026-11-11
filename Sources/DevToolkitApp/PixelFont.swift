import Foundation

/// A small 5x7 pixel font for the SteelSeries OLED. Uppercase only (lowercase
/// is not legible at 7px tall), with the blank columns trimmed from every glyph
/// so narrow characters ("I", ":", ".", " ") take less room.
enum PixelFont {
    static let height = 7

    private static func rows(_ spec: String) -> [String] {
        spec.split(separator: " ").map(String.init)
    }

    private static let source: [Character: [String]] = [
        "A": rows("01110 10001 10001 11111 10001 10001 10001"),
        "B": rows("11110 10001 10001 11110 10001 10001 11110"),
        "C": rows("01110 10001 10000 10000 10000 10001 01110"),
        "D": rows("11110 10001 10001 10001 10001 10001 11110"),
        "E": rows("11111 10000 10000 11110 10000 10000 11111"),
        "F": rows("11111 10000 10000 11110 10000 10000 10000"),
        "G": rows("01110 10001 10000 10111 10001 10001 01111"),
        "H": rows("10001 10001 10001 11111 10001 10001 10001"),
        "I": rows("01110 00100 00100 00100 00100 00100 01110"),
        "J": rows("00111 00010 00010 00010 00010 10010 01100"),
        "K": rows("10001 10010 10100 11000 10100 10010 10001"),
        "L": rows("10000 10000 10000 10000 10000 10000 11111"),
        "M": rows("10001 11011 10101 10101 10001 10001 10001"),
        "N": rows("10001 11001 10101 10011 10001 10001 10001"),
        "O": rows("01110 10001 10001 10001 10001 10001 01110"),
        "P": rows("11110 10001 10001 11110 10000 10000 10000"),
        "Q": rows("01110 10001 10001 10001 10101 10010 01101"),
        "R": rows("11110 10001 10001 11110 10100 10010 10001"),
        "S": rows("01111 10000 10000 01110 00001 00001 11110"),
        "T": rows("11111 00100 00100 00100 00100 00100 00100"),
        "U": rows("10001 10001 10001 10001 10001 10001 01110"),
        "V": rows("10001 10001 10001 10001 10001 01010 00100"),
        "W": rows("10001 10001 10001 10101 10101 11011 10001"),
        "X": rows("10001 10001 01010 00100 01010 10001 10001"),
        "Y": rows("10001 10001 01010 00100 00100 00100 00100"),
        "Z": rows("11111 00001 00010 00100 01000 10000 11111"),
        "0": rows("01110 10001 10011 10101 11001 10001 01110"),
        "1": rows("00100 01100 00100 00100 00100 00100 01110"),
        "2": rows("01110 10001 00001 00010 00100 01000 11111"),
        "3": rows("11110 00001 00001 01110 00001 00001 11110"),
        "4": rows("00010 00110 01010 10010 11111 00010 00010"),
        "5": rows("11111 10000 10000 11110 00001 00001 11110"),
        "6": rows("01110 10000 10000 11110 10001 10001 01110"),
        "7": rows("11111 00001 00010 00100 01000 01000 01000"),
        "8": rows("01110 10001 10001 01110 10001 10001 01110"),
        "9": rows("01110 10001 10001 01111 00001 00001 01110"),
        ":": rows("00000 00100 00100 00000 00100 00100 00000"),
        ".": rows("00000 00000 00000 00000 00000 00100 00100"),
        ",": rows("00000 00000 00000 00000 00100 00100 01000"),
        "'": rows("00100 00100 01000 00000 00000 00000 00000"),
        "-": rows("00000 00000 00000 11111 00000 00000 00000"),
        "/": rows("00001 00001 00010 00100 01000 10000 10000"),
        "(": rows("00010 00100 01000 01000 01000 00100 00010"),
        ")": rows("01000 00100 00010 00010 00010 00100 01000"),
        "!": rows("00100 00100 00100 00100 00100 00000 00100"),
        "?": rows("01110 10001 00001 00010 00100 00000 00100"),
        "&": rows("01100 10010 10100 01000 10101 10010 01101"),
        "_": rows("00000 00000 00000 00000 00000 00000 11111"),
        " ": rows("00 00 00 00 00 00 00")
    ]

    /// Glyph bitmaps as `[row][column]`, trimmed to their used columns.
    /// A blank glyph (the space) is two columns wide.
    static let glyphs: [Character: [[Bool]]] = source.mapValues { rows in
        let grid = rows.map { Array($0).map { $0 == "1" } }
        let used = (0..<grid[0].count).filter { column in grid.contains { $0[column] } }
        guard let first = used.first, let last = used.last else {
            return grid.map { _ in [false, false] }
        }
        return grid.map { Array($0[first...last]) }
    }

    /// Folds arbitrary metadata into characters the font can draw: any
    /// whitespace (players love non-breaking spaces) becomes a plain space,
    /// accents are stripped, a few common letters and punctuation marks are
    /// transliterated, text is uppercased, and anything else becomes "?".
    static func normalise(_ text: String) -> String {
        let transliterated = text
            .replacingOccurrences(of: "\u{142}", with: "l").replacingOccurrences(of: "\u{141}", with: "L")
            .replacingOccurrences(of: "\u{F8}", with: "o").replacingOccurrences(of: "\u{D8}", with: "O")
            .replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2013}", with: "-").replacingOccurrences(of: "\u{2014}", with: "-")
        var result = ""
        for scalar in transliterated.decomposedStringWithCanonicalMapping.unicodeScalars
        where scalar.properties.generalCategory != .nonspacingMark {
            let character: Character = scalar.properties.isWhitespace
                ? " "
                : Character(scalar).uppercased().first ?? "?"
            result.append(glyphs[character] != nil ? character : "?")
        }
        return result
    }

    /// Width in pixels of `text` (already normalised), with 1px between glyphs.
    static func width(of text: String) -> Int {
        let total = text.reduce(0) { $0 + (glyphs[$1]?[0].count ?? 0) + 1 }
        return max(0, total - 1)
    }
}
