import Foundation

/// 专注之外的活动记录（补录用）：和专注时同样的采样与合并，但不拦截，只写本机的 ambient 表。
/// 由调用方在不专注时定期 `sample()`，开始专注前 `stop(at:)`。
public final class AmbientRecorder {
    /// 本机保留天数，过期的由 `prune()` 删除。
    public static let retentionDays = 7

    private let sampler: ActivitySampler
    private let store: LocalStore
    private let clock: Clock
    private let idleThreshold: TimeInterval
    private let maxGap: TimeInterval
    private var builder: SpanBuilder?

    /// `maxGap`：两次采样相隔超过它就把中间记为闲置（应略大于采样间隔）。
    public init(sampler: ActivitySampler, store: LocalStore, clock: Clock, idleThreshold: TimeInterval = 120,
                maxGap: TimeInterval = 15) {
        self.sampler = sampler; self.store = store; self.clock = clock
        self.idleThreshold = idleThreshold; self.maxGap = maxGap
    }

    public var isRunning: Bool { builder != nil }

    public func sample() {
        var b = builder ?? SpanBuilder(sessionId: "", idleThreshold: idleThreshold, maxGap: maxGap)
        let now = clock.now
        let idle = sampler.idleSeconds()
        let sample: ActivitySample
        if idle >= idleThreshold {
            sample = ActivitySample(time: now, idleSeconds: idle)
        } else {
            let f = sampler.frontmost()
            sample = ActivitySample(time: now, idleSeconds: idle, appBundleId: f.bundleId, appName: f.appName,
                                    windowTitle: f.windowTitle, urlHost: f.urlHost)
        }
        persist(b.add(sample))
        if let open = b.openSpan(at: now) { persist([open]) }
        builder = b
    }

    /// 停止（开始专注、关闭开关时）：关闭最后一个 span。下次 `sample()` 重新开始。
    public func stop(at end: Date) {
        guard var b = builder else { return }
        persist(b.finish(at: end))
        builder = nil
    }

    public func prune() {
        try? store.pruneAmbient(before: clock.now.addingTimeInterval(-TimeInterval(Self.retentionDays) * 86_400))
    }

    private func persist(_ spans: [ActivitySpan]) { try? store.appendAmbient(spans) }
}
