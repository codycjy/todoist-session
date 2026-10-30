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
    /// 统计页初始粒度（截图用）：`SESSION_DEMO_SCOPE=week`。
    static var statsScope: StatsScope { enabled && ProcessInfo.processInfo.environment["SESSION_DEMO_SCOPE"] == "week" ? .week : .day }
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
        // 截长页面：SESSION_DEMO_HEIGHT=1400
        let height = ProcessInfo.processInfo.environment["SESSION_DEMO_HEIGHT"].flatMap(Double.init) ?? 720
        window.setContentSize(NSSize(width: 1120, height: height))
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
                        description: "重点看 actor 隔离和 Sendable 检查。", labels: ["可闲置"]),
            TodoistTask(id: "t5", content: "给房东转账", projectId: "p-life", priority: 4,
                        dueDate: today, isRecurring: false),
            TodoistTask(id: "t6", content: "看完 WWDC 视频笔记", projectId: "p-study", priority: 1,
                        dueDate: "2026-10-23", isRecurring: false),
        ]
    }

    static func sessions(now: Date) -> [SessionRecord] {
        func s(_ id: String, _ title: String, _ cat: String?, startMin: Int, minutes: Int, synced: Bool = true,
               allowIdle: Bool = false) -> SessionRecord {
            let start = now.addingTimeInterval(TimeInterval(startMin * 60))
            return SessionRecord(id: id, title: title, categoryId: cat, source: .custom, todoistTaskId: nil, entryId: nil,
                                 plannedSeconds: 1500, actualSeconds: minutes * 60, startedAt: start,
                                 endedAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
                                 allowIdle: allowIdle, syncState: synced ? .synced : .pending)
        }
        return [
            s("s1", "读论文", "c-study", startMin: -230, minutes: 25, allowIdle: true),
            s("s2", "读论文", "c-study", startMin: -200, minutes: 25),
            s("s3", "写周报", "c-work", startMin: -95, minutes: 25),
            s("s4", "回复设计评审意见", "c-work", startMin: -62, minutes: 1),
            s("s5", "冥想", nil, startMin: -40, minutes: 10, synced: false),
        ]
    }

    /// 过去 28 天的演示记录（无活动片段）：工作常超时、学习常提前结束，供预估与对比面板展示。
    static func history(now: Date) -> [SessionRecord] {
        let today = Calendar.current.startOfDay(for: now)
        var out: [SessionRecord] = []
        for day in 1...28 {
            let base = today.addingTimeInterval(TimeInterval(-day * 86_400))
            let plan: [(String, String, Int, Int, Int)] = [   // 标题、分类、开始小时、计划分钟、实际分钟
                ("写周报", "c-work", 9, 25, 30 + (day * 7) % 15),
                ("读论文", "c-study", 14, 50, 38 + (day * 5) % 14),
                ("整理房间", "c-life", 20, 25, 20 + (day * 3) % 10),
            ]
            for (i, p) in plan.enumerated() where (day + i) % 4 != 0 {
                let start = base.addingTimeInterval(TimeInterval(p.2 * 3600))
                out.append(SessionRecord(id: "h\(day)-\(i)", title: p.0, categoryId: p.1, source: .custom, todoistTaskId: nil,
                                         entryId: nil, plannedSeconds: p.3 * 60, actualSeconds: p.4 * 60, startedAt: start,
                                         endedAt: start.addingTimeInterval(TimeInterval(p.4 * 60)), syncState: .synced))
            }
        }
        return out
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

    /// 示例统计（只在演示模式下代替 `GET /stats`）：按日期确定性生成，翻页和环比都有数。
    static func stats(period: StatsPeriod, now: Date, calendar: Calendar) -> StatsSummary {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let r = period.interval(now: now, calendar: calendar)
        // 每天的专注分钟 → 铺到固定的几个时段
        let pattern = [95, 140, 60, 0, 175, 120, 205]
        let slots = [9, 10, 11, 14, 15, 16, 20, 21]
        var days: [String] = [], hours: [String] = []
        var total = 0, count = 0
        var d = r.from
        while d < r.to {
            let n = calendar.ordinality(of: .day, in: .era, for: d) ?? 0
            let future = d > now
            var mins = future ? 0 : pattern[n % pattern.count]
            if calendar.isDate(d, inSameDayAs: now) { mins = 205 }
            let date = f.string(from: d)
            var left = mins, i = n % 3
            while left > 0 {
                let m = min(left, [50, 35, 45][i % 3])
                hours.append(#"{"date":"\#(date)","hour":\#(slots[(n + i) % slots.count]),"focusSeconds":\#(m * 60)}"#)
                left -= m; i += 1
            }
            let score = mins == 0 ? "null" : String(64 + (n * 7) % 26)
            days.append(#"{"date":"\#(date)","focusSeconds":\#(mins * 60),"sessionCount":\#(mins / 25),"avgFocusScore":\#(score)}"#)
            total += mins * 60; count += mins / 25
            d = calendar.date(byAdding: .day, value: 1, to: d)!
        }
        func share(_ x: Double) -> Int { Int(Double(total) * x) }
        let apps = total == 0 ? "" : [("Preview", 0.32), ("Xcode", 0.24), ("Obsidian", 0.14), ("github.com", 0.09), ("Pages", 0.06), ("微信", 0.03)]
            .map { #"{"name":"\#($0.0)","seconds":\#(share($0.1))}"# }.joined(separator: ",")
        let cats = total == 0 ? "" : #"{"categoryId":"c-work","focusSeconds":\#(share(0.46))},{"categoryId":"c-study","focusSeconds":\#(share(0.34))},{"categoryId":null,"focusSeconds":\#(share(0.12))},{"categoryId":"c-life","focusSeconds":\#(share(0.08))}"#
        let json = #"{"totalFocusSeconds":\#(total),"plannedSeconds":\#(total * 100 / 92),"sessionCount":\#(count),"avgFocusScore":\#(total == 0 ? "null" : "77"),"activeSeconds":\#(share(0.89)),"idleSeconds":\#(share(0.11)),"days":[\#(days.joined(separator: ","))],"byCategory":[\#(cats)],"byHour":[\#(hours.joined(separator: ","))],"topApps":[\#(apps)]}"#
        return try! JSONDecoder().decode(StatsSummary.self, from: Data(json.utf8))
    }
}
