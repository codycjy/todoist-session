import AppKit
import SessionCore

/// `SESSION_DEMO=1` 时的示例数据：内存数据库、不连后端、不采集、不拦截，只用于看界面效果。
/// `SESSION_DEMO_FOCUS=1` 额外开始一个演示专注，用来看专注中的界面。
enum DemoData {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SESSION_DEMO"] == "1" }
    static var startsFocus: Bool { ProcessInfo.processInfo.environment["SESSION_DEMO_FOCUS"] == "1" }
    /// 截图路径：渲染主窗口到 PNG 后退出（自己渲染自己的窗口，不需要屏幕录制权限）。
    static var snapshotPath: String? { ProcessInfo.processInfo.environment["SESSION_DEMO_SNAPSHOT"] }
    static var selectedTaskId: String? { enabled ? ProcessInfo.processInfo.environment["SESSION_DEMO_SELECT"] : nil }
    static var selectedSessionId: String? { enabled ? ProcessInfo.processInfo.environment["SESSION_DEMO_SESSION"] : nil }
    static var editsSession: Bool { enabled && ProcessInfo.processInfo.environment["SESSION_DEMO_EDIT"] == "1" }
    static var initialTab: String? { ProcessInfo.processInfo.environment["SESSION_DEMO_TAB"] }
    static var appearance: NSAppearance.Name? {
        switch ProcessInfo.processInfo.environment["SESSION_DEMO_APPEARANCE"] {
        case "light": return .aqua
        case "dark": return .darkAqua
        default: return nil
        }
    }

    @MainActor static func snapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true || $0.title == "Now" }),
              let view = window.contentView?.superview ?? window.contentView else { NSApp.terminate(nil); return }
        window.setContentSize(NSSize(width: 1120, height: 720))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    static let categories = [
        Category(id: "c-work", name: "工作", color: "blue", todoistProjectId: "p-work"),
        Category(id: "c-study", name: "学习", color: "green", todoistProjectId: "p-study"),
        Category(id: "c-life", name: "生活", color: "orange", todoistProjectId: "p-life"),
    ]

    static let entries = [
        Entry(id: "e1", title: "读论文", categoryId: "c-study"),
        Entry(id: "e2", title: "回邮件", categoryId: "c-work"),
        Entry(id: "e3", title: "冥想", categoryId: nil),
    ]

    static func tasks(now: Date) -> [TodoistTask] {
        func at(_ minutesFromNow: Int) -> String {
            let d = now.addingTimeInterval(TimeInterval(minutesFromNow * 60))
            let cal = Calendar.current
            let m = cal.component(.minute, from: d) / 15 * 15
            let rounded = cal.date(bySettingHour: cal.component(.hour, from: d), minute: m, second: 0, of: d) ?? d
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return f.string(from: rounded)
        }
        let today = { () -> String in
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: now)
        }()
        return [
            TodoistTask(id: "t1", content: "写周报：本周进展、风险和下周计划", projectId: "p-work", priority: 4,
                        dueDate: at(-90), isRecurring: true, durationMinutes: 45,
                        description: "按模板写，**风险**一栏要具体到负责人。\n附上 Session 的统计截图。",
                        labels: ["周期", "写作"], url: "https://app.todoist.com/app/task/t1"),
            TodoistTask(id: "t2", content: "回复设计评审意见", projectId: "p-work", priority: 3,
                        dueDate: at(-60), isRecurring: false, durationMinutes: 1),
            TodoistTask(id: "t3", content: "整理待办清单", projectId: "p-life", priority: 1,
                        dueDate: at(40), isRecurring: false, durationMinutes: 30, labels: ["整理"]),
            TodoistTask(id: "t4", content: "Swift Concurrency 第 6 章", projectId: "p-study", priority: 2,
                        dueDate: at(120), isRecurring: false, durationMinutes: 60,
                        description: "重点看 actor 隔离和 Sendable 检查。"),
            TodoistTask(id: "t5", content: "给房东转账", projectId: "p-life", priority: 4,
                        dueDate: today, isRecurring: false),
            TodoistTask(id: "t6", content: "看完 WWDC 视频笔记", projectId: "p-study", priority: 1,
                        dueDate: "2026-10-23", isRecurring: false),
        ]
    }

    static func sessions(now: Date) -> [SessionRecord] {
        func s(_ id: String, _ title: String, _ cat: String?, startMin: Int, minutes: Int, synced: Bool = true) -> SessionRecord {
            let start = now.addingTimeInterval(TimeInterval(startMin * 60))
            return SessionRecord(id: id, title: title, categoryId: cat, source: .custom, todoistTaskId: nil, entryId: nil,
                                 plannedSeconds: 1500, actualSeconds: minutes * 60, startedAt: start,
                                 endedAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
                                 syncState: synced ? .synced : .pending)
        }
        return [
            s("s1", "读论文", "c-study", startMin: -230, minutes: 25),
            s("s2", "读论文", "c-study", startMin: -200, minutes: 25),
            s("s3", "写周报", "c-work", startMin: -95, minutes: 25),
            s("s4", "回复设计评审意见", "c-work", startMin: -62, minutes: 1),
            s("s5", "冥想", nil, startMin: -40, minutes: 10, synced: false),
        ]
    }

    /// 每个演示专注的活动片段：按固定比例切成几个 App，s2 带一次被拦截的网站。
    static func spans(for s: SessionRecord) -> [ActivitySpan] {
        let plan: [(String?, String?, String?, Double, Bool)] = switch s.id {
        case "s1": [("Preview", "attention-is-all-you-need.pdf", nil, 0.45, false), ("Obsidian", "论文笔记", nil, 0.35, false),
                    ("微信", nil, nil, 0.05, false), ("Preview", "attention-is-all-you-need.pdf", nil, 0.15, false)]
        case "s2": [("Preview", "paper.pdf", nil, 0.5, false), ("Google Chrome", nil, "bilibili.com", 0.12, true),
                    (nil, nil, nil, 0.08, false), ("Google Chrome", nil, "bilibili.com", 0.12, false), ("Preview", "paper.pdf", nil, 0.18, false)]
        case "s3": [("Pages", "周报.pages", nil, 0.7, false), ("Slack", "#team", nil, 0.3, false)]
        default: [("Session", nil, nil, 1, false)]
        }
        var t = s.startedAt
        let total = s.endedAt.timeIntervalSince(s.startedAt)
        return plan.map { app, title, host, frac, blocked in
            let end = t.addingTimeInterval(total * frac)
            defer { t = end }
            return ActivitySpan(sessionId: s.id, kind: app == nil ? .idle : .active, appBundleId: nil, appName: app,
                                windowTitle: title, urlHost: host, startedAt: t, endedAt: end, wasBlocked: blocked)
        }
    }

    static let evaluations: [String: Evaluation] = [
        "s1": Evaluation(status: .done, focusScore: 88,
                         summary: "这一段基本都在 PDF 阅读器和 Obsidian 之间切换，阅读和做笔记交替进行，节奏稳定。中途打开过一次微信回复消息，约 1 分钟后回到论文，整体与「读论文」的目标高度一致。",
                         attempts: 1, distractions: []),
        "s2": Evaluation(status: .done, focusScore: 64, summary: "前半段在读论文，后半段多次打开 B 站，累计约 6 分钟与任务无关。",
                         attempts: 1, distractions: [
                            .init(start: Date().addingTimeInterval(-188 * 60), end: Date().addingTimeInterval(-185 * 60), reason: "在 bilibili.com 看推荐视频"),
                            .init(start: Date().addingTimeInterval(-181 * 60), end: Date().addingTimeInterval(-178 * 60), reason: "再次打开 bilibili.com"),
                         ]),
        "s3": Evaluation(status: .pending, focusScore: nil, summary: nil, attempts: 0, distractions: []),
        "s4": Evaluation(status: .failed, focusScore: nil, summary: nil, attempts: 3, distractions: []),
    ]

    /// 最近 7 天的示例统计（只在演示模式下代替 `GET /stats`）。
    static func stats(now: Date) -> StatsSummary? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let mins = [95, 140, 60, 0, 175, 120, 86]
        let scores: [Int?] = [72, 81, 66, nil, 85, 78, 76]
        let days = (0..<7).map { i -> String in
            let d = Calendar.current.date(byAdding: .day, value: i - 6, to: now) ?? now
            let score = scores[i].map(String.init) ?? "null"
            return #"{"date":"\#(f.string(from: d))","focusSeconds":\#(mins[i] * 60),"sessionCount":\#(mins[i] / 25),"avgFocusScore":\#(score)}"#
        }
        let json = #"{"totalFocusSeconds":40560,"sessionCount":26,"avgFocusScore":77,"activeSeconds":36200,"idleSeconds":4360,"days":[\#(days.joined(separator: ","))],"byCategory":[{"categoryId":"c-work","focusSeconds":18600},{"categoryId":"c-study","focusSeconds":13800},{"categoryId":null,"focusSeconds":4800},{"categoryId":"c-life","focusSeconds":3360}]}"#
        return try? JSONDecoder().decode(StatsSummary.self, from: Data(json.utf8))
    }
}
