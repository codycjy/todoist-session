import Foundation

public struct FrontmostInfo: Equatable, Sendable {
    public let bundleId: String?
    public let appName: String?
    public let windowTitle: String?
    public let urlHost: String?
    public init(bundleId: String?, appName: String?, windowTitle: String?, urlHost: String?) {
        self.bundleId = bundleId; self.appName = appName; self.windowTitle = windowTitle; self.urlHost = urlHost
    }
}

/// 系统采样能力的抽象：真实实现在 SessionApp（AX / AppleScript / CGEventSource）。
public protocol ActivitySampler: AnyObject {
    func idleSeconds() -> TimeInterval
    func frontmost() -> FrontmostInfo
}

/// 拦截动作的抽象：真实实现在 SessionApp（隐藏 App / 重定向标签页 / 浮层）。
public protocol BlockEnforcer: AnyObject {
    func enforce(_ decision: BlockDecision, focusTitle: String, remainingSeconds: Int)
}

public final class ActivityTracker {
    private let sampler: ActivitySampler
    private let enforcer: BlockEnforcer
    private let store: LocalStore
    private let clock: Clock
    private let blocklist: BlockList
    private let idleThreshold: TimeInterval

    private var builder: SpanBuilder?
    private var sessionId: String?
    private var title = ""
    private var endAt = Date.distantFuture

    public init(sampler: ActivitySampler, enforcer: BlockEnforcer, store: LocalStore, clock: Clock,
                blocklist: BlockList, idleThreshold: TimeInterval = 120) {
        self.sampler = sampler; self.enforcer = enforcer; self.store = store; self.clock = clock
        self.blocklist = blocklist; self.idleThreshold = idleThreshold
    }

    public var isRunning: Bool { builder != nil }

    public func start(run: FocusRun) {
        sessionId = run.id.uuidString.lowercased()
        title = run.title
        endAt = run.endAt
        builder = SpanBuilder(sessionId: sessionId!, idleThreshold: idleThreshold)
        sample()
    }

    /// 正常结束：在 endedAt 处关闭最后一个 span 并落盘。
    public func stop(at end: Date) {
        guard var b = builder else { return }
        persist(b.finish(at: end))
        builder = nil; sessionId = nil
    }

    /// 放弃：丢弃已落盘的 span，不留任何记录。
    public func discard() {
        let id = sessionId
        builder = nil; sessionId = nil
        if let id { try? store.deleteSpans(sessionId: id) }
    }

    public func sample() {
        guard var b = builder else { return }
        let now = clock.now
        let idle = sampler.idleSeconds()
        let sample: ActivitySample
        if idle >= idleThreshold {
            sample = ActivitySample(time: now, idleSeconds: idle)          // 闲置期间不读标题/URL
        } else {
            let f = sampler.frontmost()
            let decision = blocklist.decide(bundleId: f.bundleId, urlHost: f.urlHost)
            if decision != .allow {
                enforcer.enforce(decision, focusTitle: title,
                                 remainingSeconds: max(0, Int(endAt.timeIntervalSince(now).rounded(.up))))
            }
            sample = ActivitySample(time: now, idleSeconds: idle, appBundleId: f.bundleId, appName: f.appName,
                                    windowTitle: f.windowTitle, urlHost: f.urlHost, wasBlocked: decision != .allow)
        }
        persist(b.add(sample))
        builder = b
    }

    private func persist(_ spans: [ActivitySpan]) {
        // 存储失败不应打断专注；丢一个 span 比崩溃更好。
        try? store.append(spans)
    }
}
