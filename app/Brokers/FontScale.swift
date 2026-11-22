import SwiftUI

/// App-wide text size (설정 > 표시 > 글자 크기, ⌘+ / ⌘- / ⌘0).
/// macOS doesn't scale SwiftUI text styles, so every font goes through `Font.s(_:)`.
enum UIScale {
    static let key = "uiFontScale"
    static let steps: [(Double, String)] = [
        (0.9, "작게"), (1.0, "기본"), (1.15, "크게"), (1.3, "더 크게"), (1.5, "아주 크게"),
    ]
    private(set) static var current: Double = {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : 1
    }()

    static func set(_ v: Double) { current = v }

    static func pt(_ base: CGFloat) -> CGFloat { (base * current).rounded() }

    /// macOS default point sizes of the text styles.
    static func base(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote, .caption, .caption2: return 10
        @unknown default: return 13
        }
    }

    static func step(_ dir: Int) {
        let vals = steps.map(\.0)
        let i = vals.firstIndex(where: { $0 >= current - 0.001 }) ?? 1
        let next = dir == 0 ? 1.0 : vals[max(0, min(vals.count - 1, i + dir))]
        UserDefaults.standard.set(next, forKey: key)
    }
}

extension Font {
    /// Scaled equivalent of a text style.
    static func s(_ style: Font.TextStyle) -> Font {
        let base = UIScale.base(style)
        let size = style == .caption2 ? base - 0.5 : base
        return .system(size: UIScale.pt(size), weight: style == .headline ? .semibold : .regular)
    }
}

/// Applied at each root view: publishes the scale, sets the default font, and redraws on change.
struct ScaledFonts: ViewModifier {
    @AppStorage(UIScale.key) private var scale = 1.0

    func body(content: Content) -> some View {
        let _ = UIScale.set(scale)
        content
            .font(.s(.body))
            .controlSize(scale >= 1.25 ? .large : .regular)
            .id(scale)
    }
}

extension View {
    func scaledFonts() -> some View { modifier(ScaledFonts()) }
}

/// View-menu commands: 글자 크게 / 작게 / 기본 크기.
struct FontScaleCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("글자 크게") { UIScale.step(1) }.keyboardShortcut("+", modifiers: .command)
            Button("글자 작게") { UIScale.step(-1) }.keyboardShortcut("-", modifiers: .command)
            Button("기본 글자 크기") { UIScale.step(0) }.keyboardShortcut("0", modifiers: .command)
        }
    }
}
