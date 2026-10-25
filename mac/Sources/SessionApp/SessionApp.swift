import SwiftUI

/// 以裸可执行文件（swift run）启动时没有 .app 包，系统默认不把它当前台应用，
/// 窗口和菜单栏项都不会显示；显式声明为 regular 并激活。M4 打包成 .app 后可移除。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 上次异常退出时可能留下被重定向的标签页（此时不会有进行中的 session）。
        Browser.restoreAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Browser.restoreAll()
    }
}

@main
struct SessionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            Text(model.menuTitle)
        }
        .menuBarExtraStyle(.window)

        Window("Session", id: "main") {
            TodayView().environmentObject(model).frame(minWidth: 720, minHeight: 480)
        }
    }
}
