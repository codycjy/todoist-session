import Foundation
import SwiftUI
import SessionCore

/// ObjectiveC 运行时也导出了 `Category`（objc_category 指针），这里显式消歧。
typealias Category = SessionCore.Category

@MainActor
final class AppModel: ObservableObject {
    @Published var tasks: [TodoistTask] = []
    /// 未归档分类：选择器与 startTask 的项目映射用。
    @Published var categories: [Category] = []
    /// 含已归档分类：历史 session 的名称/颜色查找用。
    @Published var allCategories: [Category] = []
    @Published var entries: [Entry] = []
    @Published var pendingCompletion: CompletedFocus?
    @Published var todaySessions: [SessionRecord] = []
    @Published var unsynced = 0
    @Published var accessibilityMissing = false
    @Published var errorMessage: String?
    /// 今日 session 的 LLM 评估（sessionId → 评估）。
    @Published var evaluations: [String: Evaluation] = [:]

    let engine: TimerEngine
    private(set) var api: APIClient?
    let settings: SettingsStore
    let permissions = PermissionsModel()
    /// deinit 非隔离，需要访问 Timer；Timer 只在主 actor 上创建，deinit 时已无其他引用。
    private nonisolated(unsafe) var ticker: Timer?
    private nonisolated(unsafe) var syncTimer: Timer?
    private nonisolated(unsafe) var sampleTimer: Timer?
    private nonisolated(unsafe) var activationObserver: NSObjectProtocol?

    private let store: LocalStore?
    private var tracker: ActivityTracker?
    private var sync: SyncService?
    private var askedAccessibility = false
    private var evaluationPoll: Task<Void, Never>?

    /// 专注时长：开始时读取当前生效设置（环境变量 > 设置页 > 默认 25 分钟），进行中的 session 不受影响。
    private var focusSeconds: Int { settings.effective.focusSeconds }

    init() {
        let env = ProcessInfo.processInfo.environment
        let demo = DemoData.enabled
        // 演示模式用独立的 UserDefaults，不碰真实的计时状态与设置。
        let defaults = demo ? (UserDefaults(suiteName: "session.demo") ?? .standard) : .standard
        if demo {
            defaults.removePersistentDomain(forName: "session.demo")
            defaults.set(["com.tencent.xinWeChat", "com.hnc.Discord"], forKey: "settings.blockApps")
            defaults.set(["youtube.com", "bilibili.com", "x.com"], forKey: "settings.blockDomains")
        }
        engine = TimerEngine(clock: SystemClock(), store: UserDefaultsStateStore(defaults: defaults))
        settings = SettingsStore(defaults: defaults, env: env)
        api = demo ? nil : Self.makeAPI(env: env)
        settings.remote = api
        if api == nil && !demo { errorMessage = Self.noTokenMessage }

        let dbPath: String? = demo ? nil : (env["SESSION_DB_PATH"] ?? Self.defaultDBPath())
        store = try? LocalStore(path: dbPath)
        if store == nil { errorMessage = "无法打开本地数据库，专注记录不会保存" }
        tracker = demo ? nil : Self.makeTracker(store: store, settings: settings.effective)
        if let store, let api { sync = SyncService(store: store, uploader: api) } else { sync = nil }

        // 恢复路径：没有 tracker 运行，spans 仅保留已落盘部分；完成记录照常保存。
        if let recovered = engine.recovered {
            tracker?.closeRecovered(run: recovered.run, at: recovered.endedAt)
            complete(recovered, live: false)
        } else if !demo, case .idle = engine.phase {
            // 上次异常退出时可能留下被重定向的标签页；有进行中的 session 时不能还原。
            Browser.restoreAll()
        }
        engine.onCompleted = { [weak self] done in
            // 闭包类型为非隔离（SessionCore 不依赖 MainActor），编译器无法证明在主 actor，故保留显式 hop。
            Task { @MainActor in self?.complete(done, live: true) }
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer

        var activeId: String?
        if case .focusing(let run) = engine.phase {
            activeId = run.id.uuidString.lowercased()
            tracker?.start(run: run)
            startSampling()
        }
        try? store?.pruneOrphanSpans(keeping: activeId)
        if demo { loadDemo() }
        reloadToday()

        let syncT = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sync?.isDue == true else { return }
                await self.flushSync()
            }
        }
        RunLoop.main.add(syncT, forMode: .common)
        syncTimer = syncT

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.tracker?.sample() } }

        Task {
            await settings.pull()   // 后端可达时以后端设置为准；只影响之后开始的 session
            await flushSync()
        }
        Task { await refresh() }
    }

    private static let noTokenMessage = "未配置 API Token（设置页或 SESSION_API_TOKEN），无法加载 Todoist 任务（仍可使用自定义条目）"

    private static func makeAPI(env: [String: String] = ProcessInfo.processInfo.environment) -> APIClient? {
        guard let token = ConnectionConfig.token(env: env),
              let url = URL(string: ConnectionConfig.baseURLString(env: env)) else { return nil }
        return APIClient(baseURL: url, token: token)
    }

    /// 设置页保存后端地址 / Token 后调用：重建 APIClient 与 SyncService，并重新拉取数据。
    func reconfigureAPI() {
        api = Self.makeAPI()
        settings.remote = api
        if let store, let api { sync = SyncService(store: store, uploader: api) } else { sync = nil }
        errorMessage = api == nil ? Self.noTokenMessage : nil
        Task {
            await settings.pull()
            await flushSync()
            await refresh()
        }
    }

    /// 黑名单与闲置阈值在 tracker 创建时固定，因此每个新 session 重建 tracker。
    private static func makeTracker(store: LocalStore?, settings s: AppSettings) -> ActivityTracker? {
        let blocklist = BlockList(apps: Set(s.blockApps), domains: Set(s.blockDomains))
        Log.info("黑名单 apps=\(blocklist.apps.sorted()) domains=\(blocklist.domains.sorted())，闲置阈值=\(s.idleThresholdSeconds)s，辅助功能=\(Permissions.accessibilityGranted)")
        return store.map {
            ActivityTracker(sampler: MacActivitySampler(), enforcer: MacBlockEnforcer(), store: $0, clock: SystemClock(),
                            blocklist: blocklist, idleThreshold: TimeInterval(s.idleThresholdSeconds))
        }
    }

    deinit {
        ticker?.invalidate()
        syncTimer?.invalidate()
        sampleTimer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    // MARK: 展示

    var menuTitle: String {
        switch engine.phase {
        case .idle: return pendingCompletion == nil ? "🍅" : "🍅 ✓"
        case .focusing: return "🍅 " + Self.format(engine.remainingSeconds)
        case .breaking: return "☕ " + Self.format(engine.remainingSeconds)
        }
    }

    var currentTitle: String? { currentRun?.title }

    var currentRun: FocusRun? {
        if case .focusing(let run) = engine.phase { return run }
        return nil
    }

    nonisolated static func format(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func category(for id: String?) -> Category? {
        guard let id else { return nil }
        return allCategories.first { $0.id == id } ?? categories.first { $0.id == id }
    }

    // MARK: 动作（只有显式点击/提交才会开始专注）

    /// 设置里的默认专注时长（秒），开始面板用它预选时长。
    var defaultFocusSeconds: Int { focusSeconds }

    /// `seconds` 为 nil 时用设置里的专注时长。
    func startTask(_ task: TodoistTask, seconds: Int? = nil) {
        let categoryId = categories.first { $0.todoistProjectId == task.projectId }?.id
        begin(FocusSpec(title: task.content, categoryId: categoryId, source: .todoist,
                        todoistTaskId: task.id, entryId: nil, plannedSeconds: seconds ?? focusSeconds))
    }

    func startEntry(_ entry: Entry, seconds: Int? = nil) {
        let started = begin(FocusSpec(title: entry.title, categoryId: entry.categoryId, source: .custom,
                                      todoistTaskId: nil, entryId: entry.id, plannedSeconds: seconds ?? focusSeconds))
        if started { remember(title: entry.title, categoryId: entry.categoryId) }
    }

    func startCustom(title: String, categoryId: String?, seconds: Int? = nil) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let started = begin(FocusSpec(title: title, categoryId: categoryId, source: .custom,
                                      todoistTaskId: nil, entryId: nil, plannedSeconds: seconds ?? focusSeconds))
        if started { remember(title: title, categoryId: categoryId) }
    }

    /// 放弃 = 丢弃：不写入本地 session，不计入统计，已采集的 span 一并删除。
    func abandon() {
        tracker?.discard(); stopSampling(); Browser.restoreAll()
        engine.abandon(); objectWillChange.send()
    }

    func spans(for sessionId: String) -> [ActivitySpan] { (try? store?.spans(sessionId: sessionId)) ?? [] }

    func startBreak() {
        let kind = engine.suggestedBreak
        do {
            try engine.startBreak(kind, seconds: kind == .long ? 15 * 60 : 5 * 60)
            pendingCompletion = nil
        } catch {
            errorMessage = "已有进行中的专注或休息"
        }
        objectWillChange.send()
    }

    func dismissCompletion() { pendingCompletion = nil }
    func endBreak() { engine.endBreak(); objectWillChange.send() }

    /// 请求相互独立：任何一个失败都不影响其余数据加载。
    func refresh() async {
        guard let api else { return }
        var failures: [Error] = []

        // 只关心今天：先拿今日任务，再只同步这些任务所在的项目（不做全量项目管理）。
        do { tasks = try await api.tasks(filter: .today) } catch {
            failures.append(error)
            // 瞬时失败保留旧列表；仅在认证失效/未配置时清空。
            if case let APIError.server(_, code) = error,
               code == "TODOIST_AUTH" || code == "TODOIST_NOT_CONFIGURED" {
                tasks = []
            }
        }
        let projectIds = Array(Set(tasks.map(\.projectId))).sorted()
        // 同步失败时回退到 /categories；两者都只留自定义分类和今日任务的项目。
        let fetched: [Category]?
        do { fetched = try await api.syncProjects(ids: projectIds) } catch {
            failures.append(error)
            do { fetched = try await api.categories() } catch { failures.append(error); fetched = nil }
        }
        if let fetched {
            let today = Set(projectIds)
            categories = fetched.filter { $0.todoistProjectId.map(today.contains) ?? true }
        }
        // 失败只影响历史分类查找，不计入错误提示。
        if let all = try? await api.allCategories() { allCategories = all }
        do { entries = try await api.entries() } catch { failures.append(error) }

        errorMessage = failures.isEmpty ? nil : Self.describe(failures)
    }

    /// 拉取今日评估。未配置后端或离线时静默：不改错误条，保留已有数据。
    func refreshEvaluations() async {
        guard let api else { return }
        let today = Calendar.current.startOfDay(for: Date())
        // 从昨天起取：跨午夜仍在 pending 的评估也要继续轮询到终态。
        let start = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        if let sessions = try? await api.sessions(from: start, to: end) {
            evaluations.merge(EvaluationDisplay.evaluations(from: sessions)) { _, new in new }
        }
        updateEvaluationPolling()
    }

    /// 失败的评估重新排队后立即重新拉取。用户主动触发，失败时给出短暂提示（4 秒后自动消失）。
    func retryEvaluation(sessionId: String) async {
        guard let api else { return }
        do { try await api.retryEvaluation(id: sessionId) }
        catch {
            let message = "重试评估失败，请稍后再试"
            errorMessage = message
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if self?.errorMessage == message { self?.errorMessage = nil }
            }
        }
        await refreshEvaluations()
    }

    /// 有 pending 时每 15 秒轮询一次，全部终态后停止。
    private func updateEvaluationPolling() {
        let needed = EvaluationDisplay.needsPolling(evaluations, sessionIds: Array(evaluations.keys))
        if !needed {
            evaluationPoll?.cancel(); evaluationPoll = nil
        } else if evaluationPoll == nil {
            evaluationPoll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled, let self else { return }
                    await self.refreshEvaluations()
                }
            }
        }
    }

    private static func describe(_ failures: [Error]) -> String {
        for error in failures {
            if case let APIError.server(_, code) = error {
                switch code {
                case "TODOIST_AUTH": return "Todoist token 已失效，请重新生成并运行 seed"
                case "TODOIST_NOT_CONFIGURED": return "后端未配置 Todoist token"
                case "TODOIST_TOKEN_UNREADABLE": return "后端无法解密 Todoist token（APP_SECRET 变了？），请重新运行 seed"
                default: break
                }
            }
        }
        return "无法连接后端"
    }

    // MARK: 内部

    @discardableResult
    private func begin(_ spec: FocusSpec) -> Bool {
        defer { objectWillChange.send() }
        do {
            try engine.start(spec); pendingCompletion = nil
            if case .focusing(let run) = engine.phase {
                // 此时没有运行中的 tracker（engine.start 已确认空闲），按最新设置重建。
                guard !DemoData.enabled else { return true }
                tracker = Self.makeTracker(store: store, settings: settings.effective)
                tracker?.start(run: run); startSampling()
            }
            return true
        }
        catch { errorMessage = "已有进行中的专注或休息"; return false }
    }

    /// 尽力而为：后端不可用时不影响开始专注（本地优先）。
    private func remember(title: String, categoryId: String?) {
        guard let api else { return }
        Task {
            _ = try? await api.createEntry(title: title, categoryId: categoryId)
            if let latest = try? await api.entries() { entries = latest }
        }
    }

    /// `live`：false 表示启动时从持久化状态恢复的、已在 App 关闭期间结束的 session，不再弹通知。
    private func complete(_ done: CompletedFocus, live: Bool) {
        tracker?.stop(at: done.endedAt); stopSampling(); Browser.restoreAll()
        do { try store?.save(SessionRecord(done)) }
        catch { errorMessage = "保存专注记录失败：\(error.localizedDescription)" }
        pendingCompletion = done
        if live { Notifier.focusCompleted(title: done.run.title) }
        reloadToday()
        objectWillChange.send()
        Task { await flushSync() }
    }

    private func startSampling() {
        sampleTimer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tracker?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        sampleTimer = t
        if !askedAccessibility && !Permissions.accessibilityGranted {
            askedAccessibility = true
            Permissions.requestAccessibility()
        }
        accessibilityMissing = !Permissions.accessibilityGranted
    }

    private func stopSampling() { sampleTimer?.invalidate(); sampleTimer = nil }

    private func flushSync() async {
        guard let sync else { return }
        await sync.flush()
        unsynced = (try? store?.pendingCount()) ?? 0
        reloadToday()
        await refreshEvaluations()
    }

    private func reloadToday() {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        todaySessions = (try? store?.sessions(from: start, to: end)) ?? []
    }

    private func loadDemo() {
        let now = Date()
        categories = DemoData.categories; allCategories = DemoData.categories
        entries = DemoData.entries; tasks = DemoData.tasks(now: now)
        for s in DemoData.sessions(now: now) {
            try? store?.save(s)
            try? store?.append(DemoData.spans(for: s))
        }
        evaluations = DemoData.evaluations
        if DemoData.startsFocus, let t = tasks.first { startTask(t) }
    }

    private static func defaultDBPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Session", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.db").path
    }

    private func tick() {
        engine.tick()
        objectWillChange.send()
    }
}
