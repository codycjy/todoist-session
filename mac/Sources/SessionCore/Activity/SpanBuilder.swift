import Foundation

/// 把离散采样点合并为 span。纯值类型，无副作用，便于测试。
public struct SpanBuilder {
    private struct Open {
        var kind: SpanKind
        var appBundleId: String?
        var appName: String?
        var windowTitle: String?
        var urlHost: String?
        var wasBlocked: Bool
        var start: Date
        let id = UUID().uuidString.lowercased()

        func sameTarget(as s: ActivitySample) -> Bool {
            kind == .active && appBundleId == s.appBundleId && windowTitle == s.windowTitle
                && urlHost == s.urlHost && wasBlocked == s.wasBlocked
        }
    }

    private let sessionId: String
    private let idleThreshold: TimeInterval
    private let maxGap: TimeInterval
    private var current: Open?
    private var lastSampleTime: Date?

    public init(sessionId: String, idleThreshold: TimeInterval = 120, maxGap: TimeInterval = 10) {
        self.sessionId = sessionId; self.idleThreshold = idleThreshold; self.maxGap = maxGap
    }

    /// 返回因此次采样而关闭的 span（可能为空）。
    public mutating func add(_ s: ActivitySample) -> [ActivitySpan] {
        var closed: [ActivitySpan] = []

        // 采样间隔过大（睡眠/卡死）：把间隙记为闲置。
        if let last = lastSampleTime, s.time.timeIntervalSince(last) > maxGap {
            closed += close(at: last)
            current = Open(kind: .idle, appBundleId: nil, appName: nil, windowTitle: nil,
                           urlHost: nil, wasBlocked: false, start: last)
        }
        lastSampleTime = s.time

        if s.idleSeconds >= idleThreshold {
            if current?.kind == .idle { return closed }
            // 闲置从最后一次输入算起，但不早于当前 span 的起点。
            let floor = current?.start ?? s.time
            let idleStart = max(s.time.addingTimeInterval(-s.idleSeconds), floor)
            closed += close(at: idleStart)
            current = Open(kind: .idle, appBundleId: nil, appName: nil, windowTitle: nil,
                           urlHost: nil, wasBlocked: false, start: idleStart)
            return closed
        }

        if let cur = current, cur.sameTarget(as: s) { return closed }
        closed += close(at: s.time)
        current = Open(kind: .active, appBundleId: s.appBundleId, appName: s.appName,
                       windowTitle: s.windowTitle, urlHost: s.urlHost, wasBlocked: s.wasBlocked,
                       start: s.time)
        return closed
    }

    /// 专注结束：关闭仍打开的 span。
    public mutating func finish(at end: Date) -> [ActivitySpan] {
        let out = close(at: end)
        lastSampleTime = nil
        return out
    }

    /// 仍打开的 span 截至 `end` 的快照（id 与最终关闭时一致，落盘用 upsert 即可覆盖）。
    /// 用于崩溃/强退后恢复：已采集的部分不会随进程丢失。
    public func openSpan(at end: Date) -> ActivitySpan? {
        guard let cur = current, end > cur.start else { return nil }
        return ActivitySpan(id: cur.id, sessionId: sessionId, kind: cur.kind, appBundleId: cur.appBundleId,
                            appName: cur.appName, windowTitle: cur.windowTitle, urlHost: cur.urlHost,
                            startedAt: cur.start, endedAt: end, wasBlocked: cur.wasBlocked)
    }

    private mutating func close(at end: Date) -> [ActivitySpan] {
        defer { current = nil }
        guard let cur = current, end > cur.start else { return [] }
        return [ActivitySpan(id: cur.id, sessionId: sessionId, kind: cur.kind, appBundleId: cur.appBundleId,
                             appName: cur.appName, windowTitle: cur.windowTitle, urlHost: cur.urlHost,
                             startedAt: cur.start, endedAt: end, wasBlocked: cur.wasBlocked)]
    }
}
