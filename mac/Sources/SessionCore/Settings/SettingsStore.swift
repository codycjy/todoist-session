import Foundation

/// 分类专属的计时、黑名单与快捷指令。黑名单可继承全局名单再追加自己的条目。
public struct CategoryProfile: Codable, Equatable, Sendable {
    public static let breakRange = 60...3600

    public var focusSeconds: Int
    public var breakSeconds: Int
    public var inheritBlocklist: Bool
    public var blockApps: [String]
    public var blockDomains: [String]
    /// 开始 / 结束时运行的快捷指令名；nil 时用全局的 session_start / session_end。
    public var startShortcut: String?
    public var endShortcut: String?

    public init(focusSeconds: Int, breakSeconds: Int, inheritBlocklist: Bool = true,
                blockApps: [String] = [], blockDomains: [String] = [],
                startShortcut: String? = nil, endShortcut: String? = nil) {
        self.focusSeconds = focusSeconds; self.breakSeconds = breakSeconds; self.inheritBlocklist = inheritBlocklist
        self.blockApps = blockApps; self.blockDomains = blockDomains
        self.startShortcut = startShortcut; self.endShortcut = endShortcut
    }

    func normalized() -> CategoryProfile {
        CategoryProfile(focusSeconds: clamp(focusSeconds, AppSettings.focusRange),
                        breakSeconds: clamp(breakSeconds, Self.breakRange),
                        inheritBlocklist: inheritBlocklist,
                        blockApps: dedupe(blockApps, lowercase: false), blockDomains: dedupe(blockDomains, lowercase: true),
                        startShortcut: nonEmpty(startShortcut), endShortcut: nonEmpty(endShortcut))
    }
}

private func nonEmpty(_ s: String?) -> String? {
    guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    return t
}

private func clamp(_ v: Int, _ r: ClosedRange<Int>) -> Int { min(max(v, r.lowerBound), r.upperBound) }

/// App 去空白去重，域名另转小写。保持首次出现的顺序。
private func dedupe(_ items: [String], lowercase: Bool) -> [String] {
    var seen = Set<String>()
    return items.compactMap { raw in
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if lowercase { s = s.lowercased() }
        return s.isEmpty || !seen.insert(s).inserted ? nil : s
    }
}

/// 用户可调设置（与后端 `/settings` 同形）。
public struct AppSettings: Equatable, Sendable {
    public static let focusRange = 60...7200
    public static let idleRange = 30...1800

    public var focusSeconds: Int
    public var idleThresholdSeconds: Int
    public var blockApps: [String]
    public var blockDomains: [String]
    /// categoryId → 分类 profile；没有 profile 的分类用全局设置。
    public var profiles: [String: CategoryProfile]

    public static let defaults = AppSettings(focusSeconds: 1500, idleThresholdSeconds: 120, blockApps: [], blockDomains: [])
    /// 没有 profile 时的休息时长。
    public static let shortBreakSeconds = 300, longBreakSeconds = 900

    public init(focusSeconds: Int, idleThresholdSeconds: Int, blockApps: [String], blockDomains: [String],
                profiles: [String: CategoryProfile] = [:]) {
        self.focusSeconds = focusSeconds; self.idleThresholdSeconds = idleThresholdSeconds
        self.blockApps = blockApps; self.blockDomains = blockDomains; self.profiles = profiles
    }

    /// 范围钳制；App 去空白去重，域名另转小写。保持首次出现的顺序。
    public func normalized() -> AppSettings {
        AppSettings(
            focusSeconds: clamp(focusSeconds, Self.focusRange),
            idleThresholdSeconds: clamp(idleThresholdSeconds, Self.idleRange),
            blockApps: dedupe(blockApps, lowercase: false),
            blockDomains: dedupe(blockDomains, lowercase: true),
            profiles: profiles.mapValues { $0.normalized() })
    }

    public func profile(for categoryId: String?) -> CategoryProfile? { categoryId.flatMap { profiles[$0] } }

    /// 该分类的默认专注时长：有 profile 用 profile，否则用全局。
    public func focusSeconds(for categoryId: String?) -> Int { profile(for: categoryId)?.focusSeconds ?? focusSeconds }

    /// 该分类专注结束后的休息时长：有 profile 时长短休都用 profile 的休息时长。
    public func breakSeconds(for categoryId: String?, kind: BreakKind) -> Int {
        profile(for: categoryId)?.breakSeconds ?? (kind == .long ? Self.longBreakSeconds : Self.shortBreakSeconds)
    }

    /// 该分类开始 / 结束时运行的快捷指令：profile 指定了就用它，否则用全局默认名。
    public func shortcut(for categoryId: String?, start: Bool, fallback: String) -> String {
        let p = profile(for: categoryId)
        return (start ? p?.startShortcut : p?.endShortcut) ?? fallback
    }

    /// 该分类专注时生效的黑名单：继承时 = 全局 ∪ 专属，否则只有专属。
    public func blocklist(for categoryId: String?) -> BlockList {
        guard let p = profile(for: categoryId) else { return BlockList(apps: Set(blockApps), domains: Set(blockDomains)) }
        let apps = Set(p.blockApps).union(p.inheritBlocklist ? Set(blockApps) : [])
        let domains = Set(p.blockDomains).union(p.inheritBlocklist ? Set(blockDomains) : [])
        return BlockList(apps: apps, domains: domains)
    }

    init(_ r: RemoteSettings) {
        self.init(focusSeconds: r.focusSeconds, idleThresholdSeconds: r.idleThresholdSeconds,
                  blockApps: r.blockApps, blockDomains: r.blockDomains, profiles: r.profiles)
    }

    var patch: SettingsPatch {
        SettingsPatch(focusSeconds: focusSeconds, idleThresholdSeconds: idleThresholdSeconds,
                      blockApps: blockApps, blockDomains: blockDomains, profiles: profiles)
    }
}

public enum SettingsField: Sendable { case focusSeconds, idleThresholdSeconds, blockApps, blockDomains, profiles }

public protocol SettingsRemote: Sendable {
    func fetchSettings() async throws -> RemoteSettings
    func pushSettings(_ patch: SettingsPatch) async throws -> RemoteSettings
}

extension APIClient: SettingsRemote {
    public func fetchSettings() async throws -> RemoteSettings { try await settings() }
    public func pushSettings(_ patch: SettingsPatch) async throws -> RemoteSettings { try await updateSettings(patch) }
}

/// 可注入的防抖调度器：测试里用假实现手动触发，不使用真实计时器。
public protocol SettingsScheduling {
    @MainActor func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SettingsCancellable
}

public struct SettingsCancellable {
    private let onCancel: () -> Void
    public init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { onCancel() }
}

public struct DispatchSettingsScheduler: SettingsScheduling {
    public init() {}
    @MainActor public func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SettingsCancellable {
        let item = DispatchWorkItem { Task { @MainActor in action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return SettingsCancellable { item.cancel() }
    }
}

/// 设置的本地存储 + 后端同步。优先级：环境变量（开发覆盖）> 已存储 > 默认值。
@MainActor
public final class SettingsStore: ObservableObject {
    public enum MergeDecision: Equatable { case useRemote(AppSettings), pushLocal }

    /// 可编辑的已存储值（设置页绑定它）。
    @Published public private(set) var values: AppSettings
    /// 最近一次与后端同步失败（本地修改尚未送达）。
    @Published public private(set) var unsynced = false
    /// 实际生效值：环境变量覆盖后的结果。新 session 开始时读取。
    public var effective: AppSettings { Self.apply(env: envOverrides, to: values) }
    public let overridden: Set<SettingsField>
    public var remote: SettingsRemote?

    private let defaults: UserDefaults
    private let scheduler: SettingsScheduling
    private let envOverrides: [SettingsField: Any]
    private var debounce: SettingsCancellable?
    private var generation = 0
    private var dirty: Bool {
        get { defaults.bool(forKey: Key.dirty) }
        set { defaults.set(newValue, forKey: Key.dirty) }
    }

    private enum Key {
        static let focus = "settings.focusSeconds", idle = "settings.idleThresholdSeconds"
        static let apps = "settings.blockApps", domains = "settings.blockDomains", dirty = "settings.dirty"
        static let profiles = "settings.profiles"
    }

    public init(defaults: UserDefaults, env: [String: String], scheduler: SettingsScheduling = DispatchSettingsScheduler(),
                remote: SettingsRemote? = nil) {
        self.defaults = defaults; self.scheduler = scheduler; self.remote = remote
        var o: [SettingsField: Any] = [:]
        if let v = env["SESSION_FOCUS_SECONDS"].flatMap({ Int($0) }), v > 0 { o[.focusSeconds] = v }
        if let v = env["SESSION_IDLE_SECONDS"].flatMap({ Int($0) }), v > 0 { o[.idleThresholdSeconds] = v }
        func csv(_ s: String?) -> [String]? {
            let parts = (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts
        }
        if let v = csv(env["SESSION_BLOCK_APPS"]) { o[.blockApps] = v }
        if let v = csv(env["SESSION_BLOCK_DOMAINS"]) { o[.blockDomains] = v }
        envOverrides = o
        overridden = Set(o.keys)

        let d = AppSettings.defaults
        values = AppSettings(
            focusSeconds: defaults.object(forKey: Key.focus) as? Int ?? d.focusSeconds,
            idleThresholdSeconds: defaults.object(forKey: Key.idle) as? Int ?? d.idleThresholdSeconds,
            blockApps: defaults.stringArray(forKey: Key.apps) ?? d.blockApps,
            blockDomains: defaults.stringArray(forKey: Key.domains) ?? d.blockDomains,
            profiles: defaults.data(forKey: Key.profiles)
                .flatMap { try? JSONDecoder().decode([String: CategoryProfile].self, from: $0) } ?? [:]).normalized()
    }

    private static func apply(env: [SettingsField: Any], to base: AppSettings) -> AppSettings {
        var s = base
        if let v = env[.blockApps] as? [String] { s.blockApps = v }
        if let v = env[.blockDomains] as? [String] { s.blockDomains = v }
        s = s.normalized()
        // 数值型环境变量是开发覆盖（如 SESSION_FOCUS_SECONDS=10 快速走流程），不受设置页范围限制。
        if let v = env[.focusSeconds] as? Int { s.focusSeconds = v }
        if let v = env[.idleThresholdSeconds] as? Int { s.idleThresholdSeconds = v }
        return s
    }

    /// 纯函数：后端可达时，本地没有未送达修改 → 以后端为准；否则把本地推上去，避免丢失离线修改。
    nonisolated public static func merge(local: AppSettings, remote: AppSettings, localDirty: Bool) -> MergeDecision {
        localDirty ? .pushLocal : .useRemote(remote.normalized())
    }

    // MARK: 编辑

    /// 修改已存储的值，落盘，并在 1 秒防抖后同步到后端。
    public func update(_ change: (inout AppSettings) -> Void) {
        var next = values
        change(&next)
        next = next.normalized()
        guard next != values else { return }
        values = next
        persist(next)
        dirty = true
        generation += 1
        debounce?.cancel()
        debounce = scheduler.schedule(after: 1) { [weak self] in
            guard let self else { return }
            Task { await self.flush() }
        }
    }

    private func persist(_ s: AppSettings) {
        defaults.set(s.focusSeconds, forKey: Key.focus)
        defaults.set(s.idleThresholdSeconds, forKey: Key.idle)
        defaults.set(s.blockApps, forKey: Key.apps)
        defaults.set(s.blockDomains, forKey: Key.domains)
        defaults.set(try? JSONEncoder().encode(s.profiles), forKey: Key.profiles)
    }

    // MARK: 同步

    /// 立即把本地未送达的修改 PUT 到后端；失败时保留本地并标记未同步。
    public func flush() async {
        debounce?.cancel(); debounce = nil
        guard dirty, let remote else { return }
        let sent = generation
        do {
            _ = try await remote.pushSettings(values.patch)
            if sent == generation { dirty = false }   // 期间又有新修改则保持 dirty，由新的防抖负责
            unsynced = false
        } catch {
            unsynced = true
        }
    }

    /// 启动时调用：后端可达则以后端为准（本地有未送达修改时反向推送）。
    public func pull() async {
        guard let remote else { return }
        do {
            let r = AppSettings(try await remote.fetchSettings())
            switch Self.merge(local: values, remote: r, localDirty: dirty) {
            case .useRemote(let next):
                values = next; persist(next); unsynced = false
            case .pushLocal:
                await flush()
            }
        } catch {
            if dirty { unsynced = true }
        }
    }
}
