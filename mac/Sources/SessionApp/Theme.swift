import SwiftUI
import AppKit

/// 「手帐方格」风格：纸色底、墨色细线、直角、等宽数字，专注块是荧光笔黄。
/// 所有颜色同时有浅色 / 深色两套，跟随系统外观。
enum Ink {
    /// 页面底色。
    static let paper = dynamic(light: 0xF2F3EF, dark: 0x131513)
    /// 侧栏与次级区域。
    static let shelf = dynamic(light: 0xE7E9E3, dark: 0x191C19)
    /// 抬起的面板、悬停行。
    static let panel = dynamic(light: 0xFBFBF8, dark: 0x1E221E)
    static let ink = dynamic(light: 0x0F120F, dark: 0xEEF1EC)
    /// 次要文字：两套外观下对纸色底的对比度都在 7:1 左右。
    static let sub = dynamic(light: 0x4A5149, dark: 0xB0B7AF)
    /// 最弱文字（计数、说明标签），仍保持约 4.5:1。
    static let faint = dynamic(light: 0x6E756D, dark: 0x838B82)
    static let rule = dynamic(light: 0xCBD0C6, dark: 0x30362F)
    static let ruleSoft = dynamic(light: 0xE4E7E0, dark: 0x202420)
    static let highlight = dynamic(light: 0xF4DD3F, dark: 0xE3CB34)
    static let now = dynamic(light: 0xE0442B, dark: 0xFF6A50)
    /// 荧光笔块上的字永远是深色。
    static let onHighlight = Color(red: 0.08, green: 0.09, blue: 0.08)

    static let border: CGFloat = 1.5

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// 24 小时制 `HH:mm`，时间轴与列表统一用它（避免 "4:00 PM" 折行）。
    static func hm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// 「42 秒」「25 分钟」「1 小时 5 分」：不满一分钟时不显示成 0 分钟。
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(seconds, 0)) 秒" }
        let m = seconds / 60
        return m < 60 ? "\(m) 分钟" : "\(m / 60) 小时 \(m % 60) 分"
    }

    /// 时长小标签：「25m」；不满一分钟（开发用 SESSION_FOCUS_SECONDS）显示「15s」，不会出现「0m」。
    static func chip(_ seconds: Int) -> String { seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m" }

    static func minutes(_ seconds: Int) -> String {
        let m = seconds / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// 全局字体：内置 JetBrains Mono（OFL），中文由系统回退到苹方。
enum InkFont {
    /// `.app` 由 Info.plist 的 ATSApplicationFontsPath 注册；`swift run` 时从 SwiftPM 资源包注册。
    static func register() {
        guard Bundle.main.bundleURL.pathExtension != "app",
              let dir = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func name(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin, .light: "JetBrainsMono-Light"
        case .medium: "JetBrainsMono-Medium"
        case .semibold: "JetBrainsMono-SemiBold"
        case .bold, .heavy, .black: "JetBrainsMono-Bold"
        default: "JetBrainsMono-Regular"
        }
    }
}

extension Font {
    /// 界面统一用的等宽编程字体。
    static func ink(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(InkFont.name(weight), fixedSize: size)
    }
    /// 数字、时间、标签：与正文同一字体，保留这个名字方便区分用途。
    static func inkMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { ink(size, weight: weight) }
}

/// 小节标题：大写等宽小字 + 可选计数，下方一条细线。
struct InkSectionHeader: View {
    let text: String
    var count: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(text).font(.inkMono(11, weight: .semibold)).tracking(1.2).foregroundStyle(Ink.sub)
                if let count { Text("\(count)").font(.inkMono(11)).foregroundStyle(Ink.faint) }
            }
            Rectangle().fill(Ink.rule).frame(height: 1)
        }
    }
}

/// 主按钮：墨色底；次按钮：透明底细框；`quiet`：只有文字。
struct InkButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .secondary
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ink(compact ? 12 : 13, weight: .semibold))
            .padding(.horizontal, compact ? 8 : 14).padding(.vertical, compact ? 4 : 7)
            .foregroundStyle(kind == .primary ? Ink.paper : Ink.ink)
            .background(kind == .primary ? Ink.ink : Color.clear)
            .overlay { if kind == .secondary { Rectangle().strokeBorder(Ink.ink.opacity(0.7), lineWidth: 1) } }
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.3)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
    static var inkPrimary: InkButtonStyle { InkButtonStyle(kind: .primary) }
    static var inkQuiet: InkButtonStyle { InkButtonStyle(kind: .quiet, compact: true) }
}

/// 抬起的面板：浅底 + 细框 + 右下硬阴影。
struct InkPanel: ViewModifier {
    var padding: CGFloat = 14
    var shadow = true
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Ink.panel)
            .overlay(Rectangle().strokeBorder(Ink.ink.opacity(0.85), lineWidth: 1))
            .background(alignment: .topLeading) {
                if shadow { Rectangle().fill(Ink.ink.opacity(0.85)).offset(x: 3, y: 3) }
            }
            .padding(.trailing, shadow ? 3 : 0).padding(.bottom, shadow ? 3 : 0)
    }
}

extension View {
    func inkPanel(padding: CGFloat = 14, shadow: Bool = true) -> some View {
        modifier(InkPanel(padding: padding, shadow: shadow))
    }
    /// 窗口级背景：纸色，并让系统控件用墨色强调。
    func inkWindow() -> some View { background(Ink.paper).tint(Ink.ink) }
}

/// 下划线输入框。
struct InkFieldStyle: TextFieldStyle {
    var size: CGFloat = 13
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.ink(size))
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.rule).frame(height: 1) }
    }
}

/// 可选中的小标签（时长、分类）。
struct InkChip: View {
    let text: String
    var selected = false
    var mark: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let mark { CategoryMark(color: mark, size: 7) }
                Text(text).font(.inkMono(11, weight: selected ? .semibold : .regular))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(selected ? Ink.paper : Ink.ink)
            .background(selected ? Ink.ink : Color.clear)
            .overlay(Rectangle().strokeBorder(selected ? Ink.ink : Ink.rule, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 项目色小方块，用来在荧光黄块之外区分分类。
struct CategoryMark: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Rectangle().fill(color).frame(width: size, height: size)
    }
}

/// 悬停时整行抬起。
struct HoverRow: ViewModifier {
    var selected = false
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(selected ? Ink.panel : (hovering ? Ink.panel.opacity(0.6) : Color.clear))
            .overlay { if selected { Rectangle().strokeBorder(Ink.ink.opacity(0.85), lineWidth: 1) } }
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverRow(selected: Bool = false) -> some View { modifier(HoverRow(selected: selected)) }
}

/// 外观：跟随系统 / 浅色 / 深色。写 `NSApp.appearance`，主窗口和菜单栏面板一起切换。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "appearance"
    var id: String { rawValue }
    var label: String {
        switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
    }
    var icon: String {
        switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon" }
    }
    var next: AppearanceMode {
        switch self { case .system: .light; case .light: .dark; case .dark: .system }
    }

    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// 可拖动的竖分隔线：1px 细线 + 两侧加宽的拖动区域，悬停显示左右调整光标。
/// `width` 是被调整那一栏的宽度；`grows` 为 1 表示向右拖变宽（左栏），-1 表示向左拖变宽（右栏）。
struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    var grows: Double = 1
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle().fill(hovering || start != nil ? Ink.ink.opacity(0.5) : Ink.rule)
            .frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in
                            let base = start ?? width
                            if start == nil { start = width }
                            width = min(max(base + grows * g.translation.width, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in start = nil })
            }
            .zIndex(10)
    }
}
