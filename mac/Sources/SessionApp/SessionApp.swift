import SwiftUI

/// 启动和再次打开 App（Finder / Spotlight 再点一次）时都打开主窗口；
/// Dock 图标跟着主窗口走，见 `DockIcon`。主窗口的 onAppear 可能早于这里，
/// 所以按主窗口此刻是否已显示来定，不直接设成 accessory。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if DockIcon.mainWindowVisible { DockIcon.show() } else { DockIcon.hide() }
        // 演示截图用环境变量指定外观，不读用户设置。
        if DemoData.appearance == nil { AppearanceMode.current.apply() }
        // 启动时的残留标签页还原由 AppModel.init 负责（它知道是否恢复了进行中的 session）。
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Browser.restoreAll()
    }
}

extension Notification.Name {
    /// AppDelegate 拿不到 `openWindow`，发这个通知让 SwiftUI 侧打开主窗口。
    static let openMainWindow = Notification.Name("app.now.openMainWindow")
}

/// 只有主窗口开着时才在 Dock 和 ⌘Tab 里出现；关掉主窗口后只剩菜单栏图标。
enum DockIcon {
    @MainActor static func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor static func hide() { NSApp.setActivationPolicy(.accessory) }

    @MainActor static var mainWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.contains("main") == true }
    }
}

@main
struct SessionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        LegacyDefaults.migrate()   // 早于 AppModel 读取设置
        InkFont.register()         // 早于任何视图渲染
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(model).font(.ink(13))
        } label: {
            MenuBarLabel(icon: model.menuLabel.icon, text: model.menuLabel.text)
        }
        .menuBarExtraStyle(.window)

        Window("Now", id: "main") {
            MainView().environmentObject(model).font(.ink(13)).frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 720)
    }
}

/// 菜单栏标题。MenuBarExtra 的 label 不认字体修饰，所以先渲染成模板图：
/// 等宽字体保证数字跳动时宽度不变，模板图自动跟随菜单栏深浅色。
private struct MenuBarLabel: View {
    let icon: String
    let text: String
    @Environment(\.openWindow) private var openWindow
    @MainActor private static var didLaunch = false

    private var rendered: NSImage? {
        let content = HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
            if !text.isEmpty { Text(text).font(.inkMono(13, weight: .medium)) }
        }
        .foregroundStyle(.black)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = true
        return image
    }

    var body: some View {
        Group {
            if let rendered { Image(nsImage: rendered) } else { Text(text.isEmpty ? "Now" : text) }
        }
        .onAppear {
            // 菜单栏标签在启动时出现：每次启动都打开主窗口，不依赖系统恢复上次的窗口。
            guard !Self.didLaunch else { return }
            Self.didLaunch = true
            if let a = DemoData.appearance { NSApp.appearance = NSAppearance(named: a) }
            openWindow(id: "main")
            if let path = DemoData.snapshotPath {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { DemoData.snapshot(to: path) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
            openWindow(id: "main")
            DockIcon.show()
        }
    }
}
