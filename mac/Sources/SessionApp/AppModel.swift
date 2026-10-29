import Foundation
import SwiftUI
import SessionCore

/// ObjectiveC 运行时也导出了 `Category`（objc_category 指针），这里显式消歧。
typealias Category = SessionCore.Category

@MainActor
final class AppModel: ObservableObject {
    @Published var tasks: [TodoistTask] = []
    /// 未归档分类：用户自己维护，和 Todoist 项目无关。
    @Published var categories: [Category] = []
    /// Todoist 项目 → 上次给它选的分类 id（"" 表示无分类）。只存在本机。
    @Published private(set) var projectCategories: [String: String] = [:]
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
    private let defaults: UserDefaults
    private var tracker: ActivityTracker?
    private var sync: SyncService?
    private var askedAccessibility = false
    private var evaluationPoll: Task<Void, Never>?

    /// 最近一次完成的专注所属分类：休息时长按它的 profile 取。
    private var lastCompletedCategoryId: String?

    /// 某分类的默认专注时长：环境变量覆盖（开发用）> 分类 profile > 全局设置。进行中的 session 不受影响。
    func focusSeconds(for categoryId: String?) -> Int {
        let s = settings.effective
        return settings.overridden.contains(.focusSeconds) ? s.focusSeconds : s.focusSeconds(for: categoryId)
    }

    init() {
        let env = ProcessInfo.processInfo.environment
        let demo = DemoData.enabled
        // 演示模式用独立的 UserDefaults，不碰真实的计时状态与设置。
        let defaults = demo ? (UserDefaults(suiteName: "session.demo") ?? .standard) : .standard
        if demo {
            defaults.removePersistentDomain(forName: "session.demo")
            defaults.set(["com.tencent.xinWeChat", "com.hnc.Discord"], forKey: "settings.blockApps")
            defaults.set(["youtube.com", "bilibili.com", "x.com"], forKey: "settings.blockDomains")
            let coding = ["c-work": CategoryProfile(focusSeconds: 3000, breakSeconds: 1500, inheritBlocklist: true,
                                                    blockApps: ["com.apple.Music"], blockDomains: ["news.ycombinator.com"])]
            defaults.set(try? JSONEncoder().encode(coding), forKey: "settings.profiles")
        }
        self.defaults = defaults
        projectCategories = defaults.dictionary(forKey: Self.projectCategoriesKey) as? [String: String] ?? [:]
        engine = TimerEngine(clock: SystemClock(), store: UserDefaultsStateStore(defaults: defaults),
                             autoFinish: defaults.bool(forKey: Self.autoFinishKey))
        settings = SettingsStore(defaults: defaults, env: env)
        api = demo ? nil : Self.makeAPI(env: env)
        settings.remote = api
        if api == nil && !demo { errorMessage = Self.noTokenMessage }

        let dbPath: String? = demo ? nil : (env["SESSION_DB_PATH"] ?? Self.defaultDBPath())
        store = try? LocalStore(path: dbPath)
        if store == nil { errorMessage = "无法打开本地数据库，专注记录不会保存" }
        tracker = demo ? nil : Self.makeTracker(store: store, settings: settings.effective,
                                                categoryId: engine.currentRunCategoryId)
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
        engine.onTimeUp = { phase in
            Task { @MainActor in
                switch phase {
                case .focusing(let run): Notifier.post("时间到：\(run.title)", body: "点「完成」记录这次专注")
                case .breaking: Notifier.post("休息时间到", body: "点「结束休息」回到今日")
                case .idle: break
                }
            }
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
    private static func makeTracker(store: LocalStore?, settings s: AppSettings, categoryId: String?) -> ActivityTracker? {
        let blocklist = s.blocklist(for: categoryId)
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

    /// 菜单栏：SF Symbol + 计时文字（空闲时无文字）。
    var menuLabel: (icon: String, text: String) {
        switch engine.phase {
        case .idle: return (pendingCompletion == nil ? "timer" : "checkmark.circle", "")
        case .focusing: return ("timer", timerText)
        case .breaking: return ("cup.and.saucer", timerText)
        }
    }

    /// 剩余时间；到点后（手动结束模式）显示 +超时。
    var timerText: String {
        isOvertime ? "+" + Self.format(engine.overtimeSeconds) : Self.format(engine.remainingSeconds)
    }

    var isOvertime: Bool { engine.phase != .idle && engine.remainingSeconds == 0 }

    static let autoFinishKey = "timer.autoFinish"
    /// 到点是否自动结束专注/休息。默认关：停在原处计超时，手动完成。
    var autoFinish: Bool {
        get { engine.autoFinish }
        set { engine.autoFinish = newValue; defaults.set(newValue, forKey: Self.autoFinishKey); objectWillChange.send() }
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

    /// 全局默认专注时长（秒），未选分类时开始面板用它预选时长。
    var defaultFocusSeconds: Int { focusSeconds(for: nil) }

    /// Todoist 任务开始专注时用的分类：这个项目上次选的分类；没选过时沿用旧版按项目自动建的分类（如果还在）。
    func categoryId(for task: TodoistTask) -> String? {
        if let picked = projectCategories[task.projectId] {
            return categories.contains { $0.id == picked } ? picked : nil
        }
        return categories.first { $0.todoistProjectId == task.projectId }?.id
    }

    func category(for task: TodoistTask) -> Category? { category(for: categoryId(for: task)) }

    /// 给 Todoist 项目选分类（nil = 无分类），之后这个项目的任务都默认用它。
    func setCategory(_ categoryId: String?, forProject projectId: String) {
        projectCategories[projectId] = categoryId ?? ""
        defaults.set(projectCategories, forKey: Self.projectCategoriesKey)
    }

    private static let projectCategoriesKey = "todoist.projectCategories"

    // MARK: 分类管理

    func createCategory(name: String, color: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if DemoData.enabled {
            let c = Category(id: UUID().uuidString, name: name, color: color, todoistProjectId: nil)
            categories.append(c); allCategories.append(c); return
        }
        guard let api else { return flash("没有连接后端，无法新建分类") }
        do {
            let c = try await api.createCategory(name: name, color: color)
            categories.append(c); allCategories.append(c)
        } catch { flash("新建分类失败：\(Self.describe([error]))") }
    }

    func updateCategory(_ id: String, name: String? = nil, color: String? = nil) async {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if name?.isEmpty == true { return }
        func apply(_ c: Category) {
            categories = categories.map { $0.id == c.id ? c : $0 }
            allCategories = allCategories.map { $0.id == c.id ? c : $0 }
        }
        if DemoData.enabled {
            guard let old = categories.first(where: { $0.id == id }) else { return }
            return apply(Category(id: id, name: name ?? old.name, color: color ?? old.color, todoistProjectId: old.todoistProjectId))
        }
        guard let api else { return flash("没有连接后端，无法修改分类") }
        do { apply(try await api.updateCategory(id: id, name: name, color: color)) }
        catch { flash("修改分类失败：\(Self.describe([error]))") }
    }

    /// 删除（后端归档）：历史专注仍显示原名；这个分类的专属设置一并清掉。
    func deleteCategory(_ id: String) async {
        if !DemoData.enabled {
            guard let api else { return flash("没有连接后端，无法删除分类") }
            do { try await api.deleteCategory(id: id) }
            catch { return flash("删除分类失败：\(Self.describe([error]))") }
        }
        categories.removeAll { $0.id == id }
        allCategories = allCategories.map {
            $0.id == id ? Category(id: $0.id, name: $0.name, color: $0.color, todoistProjectId: $0.todoistProjectId, archived: true) : $0
        }
        if settings.values.profiles[id] != nil { settings.update { $0.profiles[id] = nil } }
    }

    /// 短暂提示（4 秒后自动消失）。
    private func flash(_ message: String) {
        errorMessage = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.errorMessage == message { self?.errorMessage = nil }
        }
    }

    /// `seconds` 为 nil 时用分类 profile / 全局设置里的专注时长。
    func startTask(_ task: TodoistTask, seconds: Int? = nil) {
        let categoryId = categoryId(for: task)
        begin(FocusSpec(title: task.content, categoryId: categoryId, source: .todoist,
                        todoistTaskId: task.id, entryId: nil, plannedSeconds: seconds ?? focusSeconds(for: categoryId)))
    }

    func startEntry(_ entry: Entry, seconds: Int? = nil) {
        let started = begin(FocusSpec(title: entry.title, categoryId: entry.categoryId, source: .custom,
                                      todoistTaskId: nil, entryId: entry.id,
                                      plannedSeconds: seconds ?? focusSeconds(for: entry.categoryId)))
        if started { remember(title: entry.title, categoryId: entry.categoryId) }
    }

    func startCustom(title: String, categoryId: String?, seconds: Int? = nil) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let started = begin(FocusSpec(title: title, categoryId: categoryId, source: .custom,
                                      todoistTaskId: nil, entryId: nil, plannedSeconds: seconds ?? focusSeconds(for: categoryId)))
        if started { remember(title: title, categoryId: categoryId) }
    }

    /// 放弃 = 丢弃：不写入本地 session，不计入统计，已采集的 span 一并删除。
    func abandon() {
        let run = currentRun
        tracker?.discard(); stopSampling(); Browser.restoreAll()
        engine.abandon(); objectWillChange.send()
        if let run { runShortcut(Shortcuts.endName, event: "abandon", run: run, actualSeconds: nil) }
    }

    /// 进行中的专注加减分钟。
    func adjust(minutes: Int) {
        guard engine.adjust(by: minutes * 60), let run = currentRun else { return }
        tracker?.updateEnd(run.endAt)
        objectWillChange.send()
    }

    /// 提前完成：按现在结束并照常记录；之后的休息时长不变。
    func finishEarly() {
        guard let done = engine.finishEarly() else { return }
        complete(done, live: true, notify: false)
    }

    /// 下一次休息的时长（秒）：按刚完成专注的分类 profile，否则 5 / 15 分钟。
    var suggestedBreakSeconds: Int {
        settings.effective.breakSeconds(for: pendingCompletion?.run.categoryId ?? lastCompletedCategoryId,
                                        kind: engine.suggestedBreak)
    }

    /// 手动修改已完成专注的标题、分类和实际时长；改完重新上传（后端按 id 覆盖）。
    func editSession(_ id: String, title: String, categoryId: String?, actualSeconds: Int) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, actualSeconds > 0 else { return }
        if DemoData.enabled {   // 演示数据不在本地库里，直接改内存
            todaySessions = todaySessions.map { r in
                r.id != id ? r : SessionRecord(id: r.id, title: title, categoryId: categoryId, source: r.source,
                                               todoistTaskId: r.todoistTaskId, entryId: r.entryId,
                                               plannedSeconds: r.plannedSeconds, actualSeconds: actualSeconds,
                                               startedAt: r.startedAt, endedAt: r.startedAt.addingTimeInterval(TimeInterval(actualSeconds)),
                                               syncState: .pending)
            }
            return
        }
        do { try store?.edit(sessionId: id, title: title, categoryId: categoryId, actualSeconds: actualSeconds) }
        catch { errorMessage = "保存修改失败：\(error.localizedDescription)"; return }
        reloadToday()
        unsynced = (try? store?.pendingCount()) ?? unsynced
        Task { await flushSync() }
    }

    /// 删除一次已完成的专注（含活动记录）；后端的那份在下次同步时删掉。
    func deleteSession(_ id: String) {
        evaluations[id] = nil
        if DemoData.enabled { todaySessions.removeAll { $0.id == id }; return }
        do { try store?.delete(sessionId: id) }
        catch { errorMessage = "删除失败：\(error.localizedDescription)"; return }
        reloadToday()
        unsynced = (try? store?.pendingCount()) ?? unsynced
        Task { await flushSync() }
    }

    func spans(for sessionId: String) -> [ActivitySpan] { (try? store?.spans(sessionId: sessionId)) ?? [] }

    func startBreak() {
        let kind = engine.suggestedBreak
        do {
            try engine.startBreak(kind, seconds: suggestedBreakSeconds)
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

        // 只关心今天的 Todoist 任务；分类是自己维护的，不再从 Todoist 项目生成。
        do { tasks = try await api.tasks(filter: .today) } catch {
            failures.append(error)
            // 瞬时失败保留旧列表；仅在认证失效/未配置时清空。
            if case let APIError.server(_, code) = error,
               code == "TODOIST_AUTH" || code == "TODOIST_NOT_CONFIGURED" {
                tasks = []
            }
        }
        do { categories = try await api.categories() } catch { failures.append(error) }
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
            flash("重试评估失败，请稍后再试")
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
                tracker = Self.makeTracker(store: store, settings: settings.effective, categoryId: run.categoryId)
                tracker?.start(run: run); startSampling()
                runShortcut(Shortcuts.startName, event: "start", run: run, actualSeconds: nil)
                Task { await Notifier.requestAuthorization() }   // 开始时就问，免得到点才弹授权框
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
    private func complete(_ done: CompletedFocus, live: Bool, notify: Bool = true) {
        tracker?.stop(at: done.endedAt); stopSampling(); Browser.restoreAll()
        lastCompletedCategoryId = done.run.categoryId
        if live { runShortcut(Shortcuts.endName, event: "complete", run: done.run, actualSeconds: done.actualSeconds) }
        do { try store?.save(SessionRecord(done)) }
        catch { errorMessage = "保存专注记录失败：\(error.localizedDescription)" }
        pendingCompletion = done
        if live && notify { Notifier.post("专注完成：\(done.run.title)，休息一下") }
        reloadToday()
        objectWillChange.send()
        Task { await flushSync() }
    }

    private func runShortcut(_ name: String, event: String, run: FocusRun, actualSeconds: Int?) {
        var input: [String: Any] = ["event": event, "title": run.title,
                                    "category": category(for: run.categoryId)?.name ?? "",
                                    "plannedMinutes": run.plannedSeconds / 60]
        if let actualSeconds { input["actualMinutes"] = actualSeconds / 60 }
        Shortcuts.run(name, input: input)
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
