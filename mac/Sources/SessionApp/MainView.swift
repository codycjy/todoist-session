import SwiftUI

/// 主窗口：今日 / 统计 / 设置。首次启动弹出一次权限引导。
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showGuide = !UserDefaults.standard.bool(forKey: PermissionGuide.flagKey)

    var body: some View {
        TabView {
            TodayView().tabItem { Label("今日", systemImage: "timer") }
            StatsPlaceholderView().tabItem { Label("统计", systemImage: "chart.bar") }
            SettingsView().tabItem { Label("设置", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showGuide) {
            PermissionGuideView().environmentObject(model)
        }
    }
}

/// M-C 会替换为真正的统计页。
struct StatsPlaceholderView: View {
    var body: some View { Text("统计") }
}

enum PermissionGuide {
    static let flagKey = "didShowPermissionGuide"
}

struct PermissionGuideView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("需要的系统权限").font(.title2.bold())
            Text("Session 在专注期间需要以下权限才能完整工作。可以随时在「设置」页查看和修改。")
                .foregroundStyle(.secondary)
            PermissionRows().environmentObject(model.permissions)
            HStack { Spacer(); Button("知道了") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { UserDefaults.standard.set(true, forKey: PermissionGuide.flagKey) }   // 无论怎样关闭都只弹一次
    }
}

/// 三项权限：状态 + 打开系统设置。设置页与引导 sheet 共用。
struct PermissionRows: View {
    @EnvironmentObject var permissions: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("辅助功能", ok: permissions.accessibility,
                okText: "已授权", missingText: "未授权：无法读取前台窗口，黑名单与活动记录不可用",
                pane: .accessibility)
            VStack(alignment: .leading, spacing: 4) {
                Text("自动化").font(.headline)
                Text("无法可靠查询。macOS 会在 Session 第一次控制浏览器（Safari / Chrome 等）时弹出授权提示；若之前拒绝过，请在系统设置中手动开启。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("打开系统设置") { Permissions.openSettings(.automation) }
            }
            switch permissions.notifications {
            case .unavailable:
                VStack(alignment: .leading, spacing: 4) {
                    Text("通知").font(.headline)
                    Text("仅 .app 形态可用").font(.callout).foregroundStyle(.secondary)
                }
            case .granted:
                row("通知", ok: true, okText: "已授权", missingText: "", pane: .notifications)
            case .missing:
                row("通知", ok: false, okText: "", missingText: "未授权：专注结束时无法发送通知", pane: .notifications)
            }
        }
    }

    private func row(_ name: String, ok: Bool, okText: String, missingText: String, pane: Permissions.Pane) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.headline)
            if ok {
                Label(okText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label(missingText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button("打开系统设置") { Permissions.openSettings(pane) }
            }
        }
    }
}
