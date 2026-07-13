import SwiftUI

enum Theme {
    static let canvas    = Color(hex: 0xE8E2D3)
    static let paper     = Color(hex: 0xF4EFE6)
    static let ink       = Color(hex: 0x2B1A1F)
    static let muted     = Color(hex: 0x7A6A6F)
    static let rule      = Color(hex: 0x2B1A1F)
    static let ruleFaint = Color(hex: 0xC8BBB8)
    static let gridBg    = Color(hex: 0xFBF8F0)
    static let gridRule  = Color(hex: 0xD4C8C3)
    static let taalBg    = Color(hex: 0xECE4D5)
    static let lyricBg   = Color(hex: 0xF0E9DC)
    static let sidebar   = Color(hex: 0x2B1A1F)
    static let accent    = Color(hex: 0x7A3A3F)
    static let danger    = Color(hex: 0x8A3A3A)
    static let legendBg  = Color(hex: 0xECE4D5)
    static let codeBg    = Color(hex: 0xFBF8F0)

    enum Fonts {
        static let deva    = "Noto Serif Devanagari"
        static let display = "EB Garamond"
        static let ui      = "IBM Plex Sans"
        static let mono    = "SF Mono"
    }

    // MARK: - Font cache
    // Font.custom(...) builds a CTFontDescriptor on each call. Views call
    // Theme.ui/deva/display hundreds of times per keystroke across the grid,
    // so we memoize by (family, size, weight, italic). Not thread-safe on
    // purpose — SwiftUI bodies run on the main thread.
    private struct FontKey: Hashable {
        let family: String
        let size: CGFloat
        let weight: Font.Weight
        let italic: Bool
    }
    private static var fontCache: [FontKey: Font] = [:]

    private static func cached(_ family: String,
                               _ size: CGFloat,
                               _ weight: Font.Weight,
                               italic: Bool = false) -> Font {
        let key = FontKey(family: family, size: size, weight: weight, italic: italic)
        if let hit = fontCache[key] { return hit }
        var f = Font.custom(family, size: size).weight(weight)
        if italic { f = f.italic() }
        fontCache[key] = f
        return f
    }

    static func deva(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        cached(Fonts.deva, size, weight)
    }

    static func display(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        cached(Fonts.display, size, weight, italic: italic)
    }

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        cached(Fonts.ui, size, weight)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

struct PaperBackground: ViewModifier {
    // Shadows are drawn on a sibling Rectangle behind the content so SwiftUI
    // rasterizes only a simple shape, not the entire page tree, on every edit.
    func body(content: Content) -> some View {
        content
            .background {
                Rectangle()
                    .fill(Theme.paper)
                    .shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 8)
                    .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
            }
            .overlay(alignment: .top) {
                PaperTopRule().frame(height: 3)
            }
    }
}

struct PaperTopRule: View {
    var body: some View {
        VStack(spacing: 1) {
            Rectangle().fill(Theme.ink).frame(height: 1)
            Rectangle().fill(Theme.ink).frame(height: 1)
        }
    }
}

extension View {
    func paperBackground() -> some View { modifier(PaperBackground()) }
}
