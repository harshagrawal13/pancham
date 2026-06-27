import Foundation

/// Maps the DSL base letter to its Devanagari glyph. Mirrors `SWARA_MAP`
/// in the original `app.js`.
enum SwaraMap {
    static let glyphs: [Character: String] = [
        "S": "सा", "R": "रे", "G": "ग", "M": "म",
        "P": "प",  "D": "ध",  "N": "नि",
        // Lowercase r/g/d/n are komal (drawn with underline via komalSet).
        "r": "रे", "g": "ग", "d": "ध", "n": "नि",
        // Sa / Pa / Ma have no komal variant — accept lowercase as shuddh
        // so multi-char inputs like "Sa" / "sa" / "pa" / "ma" render correctly.
        "s": "सा", "p": "प", "m": "म",
    ]

    static let komalSet: Set<Character> = ["r", "g", "d", "n"]
}

struct SwaraToken: Hashable {
    var glyph: String
    var komal: Bool
    var tivra: Bool
    var mandra: Bool
    var taar: Bool
    var sustain: Bool
}

enum SwaraParser {
    /// Port of `parseToken(raw)` in `app.js`.
    static func parseToken(_ raw: String) -> SwaraToken? {
        var t = raw
        guard !t.isEmpty else { return nil }

        var mandra = false, taar = false, tivra = false
        if t.hasPrefix(".") {
            mandra = true; t.removeFirst()
        } else if t.hasPrefix("^") {
            taar = true; t.removeFirst()
        }
        if t.hasSuffix("'") {
            tivra = true; t.removeLast()
        }

        if t == "-" || t == "s" {
            return SwaraToken(glyph: "ऽ", komal: false, tivra: false,
                              mandra: false, taar: false, sustain: true)
        }

        guard let base = t.first else { return nil }
        let komal = SwaraMap.komalSet.contains(base)
        let glyph = SwaraMap.glyphs[base] ?? String(base)
        return SwaraToken(glyph: glyph, komal: komal, tivra: tivra,
                          mandra: mandra, taar: taar, sustain: false)
    }

    /// Cache parsed cells by raw text. The same handful of token strings recur
    /// across the grid and every render, so memoizing avoids re-parsing. Not
    /// thread-safe on purpose — callers (SwiftUI bodies, the playback loop) are
    /// all on the main thread.
    private static var cache: [String: [SwaraToken]] = [:]

    /// Split a cell into whitespace-separated tokens and return the parsed
    /// swaras. Multi-swara cells are sized down by the caller.
    static func parse(cell raw: String) -> [SwaraToken] {
        if let hit = cache[raw] { return hit }
        let tokens = raw.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .compactMap(parseToken)
        cache[raw] = tokens
        return tokens
    }
}
