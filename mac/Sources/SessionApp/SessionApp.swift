import SwiftUI

/// 启动时主窗口会打开，先按 regular 激活（裸可执行文件 swift run 也需要这样才显示窗口）。
/// 之后 Dock 图标跟着主窗口走：见 `DockIcon`。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // 演示截图用环境变量指定外观，不读用户设置。
        if DemoData.appearance == nil { AppearanceMode.current.apply() }
        NSApp.activate(ignoringOtherApps: true)
        // 启动时的残留标签页还原由 AppModel.init 负责（它知道是否恢复了进行中的 session）。
    }

    func applicationWillTerminate(_ notification: Notification) {
        Browser.restoreAll()
    }
}

/// 只有主窗口开着时才在 Dock 和 ⌘Tab 里出现；关掉主窗口后只剩菜单栏图标。
enum DockIcon {
    @MainActor static func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor static func hide() { NSApp.setActivationPolicy(.accessory) }
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
/// 演示模式下启动即打开主窗口（正常使用时由用户从菜单打开）。
private struct MenuBarLabel: View {
    let icon: String
    let text: String
    @Environment(\.openWindow) private var openWindow

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
            guard DemoData.enabled else { return }
            if let a = DemoData.appearance { NSApp.appearance = NSAppearance(named: a) }
            openWindow(id: "main")
            if let path = DemoData.snapshotPath {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { DemoData.snapshot(to: path) }
            }
        }
    }
}
