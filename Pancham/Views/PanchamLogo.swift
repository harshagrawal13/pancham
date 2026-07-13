import SwiftUI

/// The Pancham mark — the finished artwork shipped in Assets.xcassets.
struct PanchamLogo: View {
    var size: CGFloat = 72

    var body: some View {
        Image("PanchamLogo")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel("Pancham")
    }
}

/// Stacked lockup: mark · hairline rule · PANCHAM in small-caps EB Garamond.
struct PanchamStackedLockup: View {
    var markSize: CGFloat = 84
    var color: Color = Theme.ink
    var ruleColor: Color = Theme.ruleFaint

    var body: some View {
        VStack(spacing: 12) {
            PanchamLogo(size: markSize)
            Rectangle().fill(ruleColor).frame(width: 32, height: 1)
            Text("PANCHAM")
                .font(Theme.display(16, weight: .medium))
                .tracking(3)
                .foregroundStyle(color)
        }
    }
}

/// Horizontal lockup: mark alongside "Pancham" in EB Garamond.
struct PanchamHorizontalLockup: View {
    var markSize: CGFloat = 38
    var wordSize: CGFloat = 19
    var color: Color = Theme.ink

    var body: some View {
        HStack(spacing: markSize * 0.3) {
            PanchamLogo(size: markSize)
            Text("Pancham")
                .font(Theme.display(wordSize, weight: .medium))
                .tracking(0.3)
                .foregroundStyle(color)
        }
    }
}
