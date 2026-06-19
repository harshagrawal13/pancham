import SwiftUI

struct LegendView: View {
    private struct Item: Identifiable { let id = UUID(); let code: String; let desc: String }
    private let items: [Item] = [
        .init(code: "S R G M P D N", desc: "shudh"),
        .init(code: "r g d n", desc: "komal (underline)"),
        .init(code: "M'", desc: "tivra"),
        .init(code: ".S", desc: "mandra · dot below"),
        .init(code: "^S", desc: "taar · dot above"),
        .init(code: "-", desc: "sustain (ऽ)"),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Text("Cheatsheet")
                .font(Theme.ui(10))
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(Theme.muted)
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Text(item.code)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.codeBg)
                        .overlay(Rectangle().strokeBorder(Theme.ruleFaint, lineWidth: 1))
                    Text(item.desc)
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.legendBg)
        .overlay(Rectangle().strokeBorder(Theme.ruleFaint, lineWidth: 1))
    }
}
