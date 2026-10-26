import SwiftUI

/// 主窗口：左侧栏（今日 / 统计、设置子页）+ 右侧内容。首次启动弹出一次权限引导。
enum Route: Hashable {
    case today, stats
    case settings(SettingsSection)
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case timing = "计时", profiles = "分类", blocking = "黑名单", appearance = "外观", backend = "后端", permissions = "权限"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .timing: "timer"
        case .profiles: "square.stack"
        case .blocking: "nosign"
        case .appearance: "circle.lefthalf.filled"
        case .backend: "server.rack"
        case .permissions: "lock.shield"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showGuide = !UserDefaults.standard.bool(forKey: PermissionGuide.flagKey) && !DemoData.enabled
    @AppStorage("layout.sidebarWidth") private var sidebarWidth = 200.0
    @State private var route: Route = {
        switch DemoData.initialTab {
        case "stats": .stats
        case "settings": .settings(.timing)
        case "blocking": .settings(.blocking)
        case "profiles": .settings(.profiles)
        case "appearance": .settings(.appearance)
        default: .today
        }
    }()

    private var showsToday: Bool { route == .today }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(route: $route)
                .frame(width: sidebarWidth)
            ResizeHandle(width: $sidebarWidth, range: 160...320)
            ZStack {
                if DemoData.initialTab == "menu" {
                    // 仅演示截图：把菜单栏面板放进主窗口渲染。
                    Ink.shelf.overlay(alignment: .top) { MenuPanel().inkPanel(padding: 0).padding(.top, 60) }.zIndex(1)
                }
                // 今日页常驻（保留输入草稿与选中的任务），其余按需创建。
                TodayView()
                    .opacity(showsToday ? 1 : 0).allowsHitTesting(showsToday)
                switch route {
                case .stats: StatsView()
                case .settings(let section): SettingsView(section: section)
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .inkWindow()
        .sheet(isPresented: $showGuide) {
            PermissionGuideView().environmentObject(model)
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var route: Route
    @AppStorage(AppearanceMode.key) private var appearanceRaw = AppearanceMode.system.rawValue
    private var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceRaw) ?? .system }
        nonmutating set { appearanceRaw = newValue.rawValue; newValue.apply() }
    }

    private var todayMinutes: Int { model.todaySessions.map(\.actualSeconds).reduce(0, +) }
    private var avgScore: Int? {
        let scores = model.todaySessions.compactMap { model.evaluations[$0.id]?.focusScore }
        return scores.isEmpty ? nil : scores.reduce(0, +) / scores.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Rectangle().fill(Ink.highlight).frame(width: 10, height: 10)
                Text("SESSION").font(.inkMono(12, weight: .bold)).tracking(2.4)
            }
            .padding(.top, 46).padding(.horizontal, 16).padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group(nil) {
                        item("今日", icon: "square.and.pencil", route: .today, count: model.tasks.count)
                        item("统计", icon: "chart.bar", route: .stats)
                    }
                    group("设置") {
                        ForEach(SettingsSection.allCases) { s in item(s.rawValue, icon: s.icon, route: .settings(s)) }
                    }
                }
                .padding(.horizontal, 8)
            }

            summary
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Ink.shelf)
    }

    private func group<C: View>(_ title: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title).font(.inkMono(10, weight: .semibold)).tracking(1.2).foregroundStyle(Ink.faint)
                    .padding(.horizontal, 8).padding(.bottom, 4)
            }
            content()
        }
    }

    private func item(_ title: String, icon: String, route r: Route, count: Int? = nil) -> some View {
        let selected = route == r
        return Button { route = r } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 16)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let count, count > 0 { Text("\(count)").font(.inkMono(11)).foregroundStyle(selected ? Ink.paper.opacity(0.7) : Ink.faint) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .foregroundStyle(selected ? Ink.paper : Ink.ink)
            .background(selected ? Ink.ink : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Ink.rule).frame(height: 1)
            Text("今天").font(.inkMono(10, weight: .semibold)).tracking(1.2).foregroundStyle(Ink.faint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(todayMinutes / 60)").font(.inkMono(30, weight: .medium))
                Text("分钟").font(.system(size: 11)).foregroundStyle(Ink.sub)
            }
            HStack(spacing: 14) {
                stat("\(model.todaySessions.count)", "番茄")
                stat(avgScore.map(String.init) ?? "—", "专注度")
            }
            HStack(spacing: 6) {
                Rectangle().fill(model.unsynced > 0 ? Ink.now : Ink.sub).frame(width: 6, height: 6)
                Text(model.unsynced > 0 ? "\(model.unsynced) 条未同步" : (model.api == nil ? "离线" : "已同步"))
                    .font(.inkMono(10)).foregroundStyle(Ink.sub)
                Spacer()
                Button {
                    appearance = appearance.next
                } label: { Image(systemName: appearance.icon).font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(Ink.sub).help("外观：\(appearance.label)（点击切换）")
                Button { Task { await model.refresh(); await model.refreshEvaluations() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Ink.sub).help("刷新")
            }
        }
        .padding(16)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.inkMono(15, weight: .medium))
            Text(label).font(.system(size: 10)).foregroundStyle(Ink.sub)
        }
    }
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
            HStack { Spacer(); Button("知道了") { dismiss() }.buttonStyle(.inkPrimary).keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 520)
        .inkWindow()
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
                Text("自动化").font(.system(size: 13, weight: .semibold))
                Text("无法可靠查询。macOS 会在 Session 第一次控制浏览器（Safari / Chrome 等）时弹出授权提示；若之前拒绝过，请在系统设置中手动开启。")
                    .font(.callout).foregroundStyle(Ink.sub)
                Button("打开系统设置") { Permissions.openSettings(.automation) }.buttonStyle(InkButtonStyle(compact: true))
            }
            switch permissions.notifications {
            case .unavailable:
                VStack(alignment: .leading, spacing: 4) {
                    Text("通知").font(.system(size: 13, weight: .semibold))
                    Text("仅 .app 形态可用").font(.callout).foregroundStyle(Ink.sub)
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
            Text(name).font(.system(size: 13, weight: .semibold))
            if ok {
                Label(okText, systemImage: "checkmark.square.fill").foregroundStyle(Ink.ink)
            } else {
                Label(missingText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Ink.now)
                Button("打开系统设置") { Permissions.openSettings(pane) }.buttonStyle(InkButtonStyle(compact: true))
            }
        }
    }
}
