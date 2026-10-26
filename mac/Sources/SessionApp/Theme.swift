import SwiftUI
import AppKit

/// 「手帐方格」风格：纸色底、墨黑线、直角、等宽数字，专注块是荧光笔黄。
/// 所有颜色同时有浅色 / 深色两套，跟随系统外观。
enum Ink {
    static let paper = dynamic(light: 0xEEF0EE, dark: 0x161816)
    static let ink = dynamic(light: 0x101310, dark: 0xE9ECE8)
    static let sub = dynamic(light: 0x5A625A, dark: 0x9AA39A)
    static let rule = dynamic(light: 0xC9CEC9, dark: 0x2C322C)
    static let highlight = dynamic(light: 0xF6E24A, dark: 0xE2CC36)
    static let now = dynamic(light: 0xE5321D, dark: 0xFF5A45)
    /// 荧光笔块上的字永远是深色。
    static let onHighlight = Color(red: 0.063, green: 0.075, blue: 0.063)

    static let border: CGFloat = 1.5

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    /// 数字、时间、标签用等宽体。
    static func inkMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// 小节标题：大写等宽小字，下方一条墨线。
struct InkSectionHeader: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.inkMono(11, weight: .medium)).tracking(0.8).foregroundStyle(Ink.sub)
            Rectangle().fill(Ink.ink).frame(height: Ink.border)
        }
    }
}

/// 主按钮：墨黑底荧光黄字；次按钮：纸色底墨框。
struct InkButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(primary ? Ink.highlight : Ink.ink)
            .background(primary ? Ink.ink : Ink.paper)
            .overlay(Rectangle().strokeBorder(Ink.ink, lineWidth: Ink.border))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
    static var inkPrimary: InkButtonStyle { InkButtonStyle(primary: true) }
}

/// 带墨框与硬阴影的面板。
struct InkPanel: ViewModifier {
    var shadow = true
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(Ink.paper)
            .overlay(Rectangle().strokeBorder(Ink.ink, lineWidth: Ink.border))
            .background(alignment: .topLeading) {
                if shadow { Rectangle().fill(Ink.ink).offset(x: 3, y: 3) }
            }
    }
}

extension View {
    func inkPanel(shadow: Bool = true) -> some View { modifier(InkPanel(shadow: shadow)) }
    /// 窗口级背景：纸色，并让系统控件用墨色强调。
    func inkWindow() -> some View {
        background(Ink.paper).tint(Ink.ink)
    }
}

/// 带墨线下划线的输入框。
struct InkFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.vertical, 5).padding(.horizontal, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.ink).frame(height: Ink.border) }
            .background(Ink.rule.opacity(0.25))
    }
}

/// 项目色小方块，用来在荧光黄块之外区分分类。
struct CategoryMark: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Rectangle().fill(color).frame(width: size, height: size)
            .overlay(Rectangle().strokeBorder(Ink.ink, lineWidth: 1))
    }
}
