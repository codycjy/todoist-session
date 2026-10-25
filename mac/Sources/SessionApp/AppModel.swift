import Foundation
import SwiftUI
import SessionCore

/// ObjectiveC 运行时也导出了 `Category`（objc_category 指针），这里显式消歧。
typealias Category = SessionCore.Category

@MainActor
final class AppModel: ObservableObject {
    @Published var tasks: [TodoistTask] = []
    @Published var categories: [Category] = []
    @Published var entries: [Entry] = []
    @Published var pendingCompletion: CompletedFocus?
    @Published var finishedToday: [CompletedFocus] = []
    @Published var errorMessage: String?

    let engine: TimerEngine
    private let api: APIClient?
    private var ticker: Timer?

    /// 默认 25 分钟；开发时可用环境变量 SESSION_FOCUS_SECONDS=10 快速走完整流程。
    private let focusSeconds = Int(ProcessInfo.processInfo.environment["SESSION_FOCUS_SECONDS"] ?? "") ?? 25 * 60

    init() {
        engine = TimerEngine(clock: SystemClock(), store: UserDefaultsStateStore())
        let env = ProcessInfo.processInfo.environment
        api = env["SESSION_API_TOKEN"].flatMap { token in
            URL(string: env["SESSION_API_URL"] ?? "http://localhost:8787")
                .map { APIClient(baseURL: $0, token: token) }
        }
        if api == nil { errorMessage = "未配置 SESSION_API_TOKEN，无法加载 Todoist 任务（仍可使用自定义条目）" }

        if let recovered = engine.recovered { complete(recovered) }
        engine.onCompleted = { [weak self] done in
            // tick() 在主 actor 上调用，此处已在主 actor；闭包类型非隔离，故显式 hop。
            Task { @MainActor in self?.complete(done) }
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        Task { await refresh() }
    }

    deinit { ticker?.invalidate() }

    // MARK: 展示

    var menuTitle: String {
        switch engine.phase {
        case .idle: return pendingCompletion == nil ? "🍅" : "🍅 ✓"
        case .focusing: return "🍅 " + Self.format(engine.remainingSeconds)
        case .breaking: return "☕ " + Self.format(engine.remainingSeconds)
        }
    }

    var currentTitle: String? {
        if case .focusing(let run) = engine.phase { return run.title }
        return nil
    }

    nonisolated static func format(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func category(for id: String?) -> Category? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    // MARK: 动作（只有显式点击/提交才会开始专注）

    func startTask(_ task: TodoistTask) {
        let categoryId = categories.first { $0.todoistProjectId == task.projectId }?.id
        begin(FocusSpec(title: task.content, categoryId: categoryId, source: .todoist,
                        todoistTaskId: task.id, entryId: nil, plannedSeconds: focusSeconds))
    }

    func startEntry(_ entry: Entry) {
        let started = begin(FocusSpec(title: entry.title, categoryId: entry.categoryId, source: .custom,
                                      todoistTaskId: nil, entryId: entry.id, plannedSeconds: focusSeconds))
        if started { remember(title: entry.title, categoryId: entry.categoryId) }
    }

    func startCustom(title: String, categoryId: String?) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let started = begin(FocusSpec(title: title, categoryId: categoryId, source: .custom,
                                      todoistTaskId: nil, entryId: nil, plannedSeconds: focusSeconds))
        if started { remember(title: title, categoryId: categoryId) }
    }

    /// 放弃 = 丢弃：不进入 finishedToday，不计入统计。
    func abandon() { engine.abandon(); objectWillChange.send() }

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

    /// 三个请求相互独立：任何一个失败都不影响其余数据加载。
    func refresh() async {
        guard let api else { return }
        var failures: [Error] = []

        // /todoist/projects 会先同步 Todoist 项目，再返回全部未归档分类（含自定义），
        // 是 /categories 的超集；失败时回退到 /categories，避免重复合并。
        do {
            categories = try await api.syncProjects()
        } catch {
            failures.append(error)
            do { categories = try await api.categories() } catch { failures.append(error) }
        }
        do { tasks = try await api.tasks(filter: .today) } catch { failures.append(error); tasks = [] }
        do { entries = try await api.entries() } catch { failures.append(error) }

        errorMessage = failures.isEmpty ? nil : Self.describe(failures)
    }

    private static func describe(_ failures: [Error]) -> String {
        for error in failures {
            if case let APIError.server(_, code) = error {
                switch code {
                case "TODOIST_AUTH": return "Todoist token 已失效，请重新生成并运行 seed"
                case "TODOIST_NOT_CONFIGURED": return "后端未配置 Todoist token"
                default: break
                }
            }
        }
        return "无法连接后端：\(failures[0])"
    }

    // MARK: 内部

    @discardableResult
    private func begin(_ spec: FocusSpec) -> Bool {
        defer { objectWillChange.send() }
        do { try engine.start(spec); pendingCompletion = nil; return true }
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

    private func complete(_ done: CompletedFocus) {
        finishedToday.append(done)
        pendingCompletion = done
        objectWillChange.send()
    }

    private func tick() {
        engine.tick()
        objectWillChange.send()
    }
}
