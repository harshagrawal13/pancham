import SwiftUI

/// Renders a single `SwaraToken` with the komal underline, tivra tick,
/// and mandra/taar dot decorations.
struct SwaraView: View {
    let tok: SwaraToken
    var baseSize: CGFloat = 17

    var body: some View {
        if tok.sustain {
            Text("ऽ")
                .font(Theme.deva(baseSize, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.55))
        } else {
            ZStack {
                if tok.taar {
                    Text("•")
                        .font(.system(size: baseSize * 0.6))
                        .foregroundStyle(Theme.ink)
                        .offset(y: -baseSize * 0.75)
                }
                if tok.tivra {
                    Rectangle()
                        .fill(Theme.ink)
                        .frame(width: 1, height: 6)
                        .offset(y: -baseSize * 0.65)
                }
                Text(tok.glyph)
                    .font(Theme.deva(baseSize, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .underline(tok.komal, pattern: .solid, color: Theme.ink)
                if tok.mandra {
                    Text("•")
                        .font(.system(size: baseSize * 0.55))
                        .foregroundStyle(Theme.ink)
                        .offset(y: baseSize * 0.72)
                }
            }
            .fixedSize()
        }
    }
}

/// Renders a whole cell — one or more swaras separated by whitespace.
/// Multi-swara cells shrink per the CSS multi-2/3/4 sizing.
struct RenderedCell: View {
    let raw: String
    var baseSize: CGFloat = 17

    var body: some View {
        let tokens = SwaraParser.parse(cell: raw)
        let scale: CGFloat = {
            switch tokens.count {
            case 4...: return 0.56
            case 3:    return 0.68
            case 2:    return 0.78
            default:   return 1.0
            }
        }()
        HStack(spacing: 1) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, t in
                SwaraView(tok: t, baseSize: baseSize * scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
