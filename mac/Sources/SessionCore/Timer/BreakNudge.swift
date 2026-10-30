import Foundation

/// 休息时还在用电脑吗：休息开始 `grace` 秒后，累计有键鼠输入的时间达到 `activeThreshold` 就提醒一次。
/// 每次休息新建一个；`sample` 由调用方定期（约每秒）传入距上次输入的秒数。
public struct BreakNudge: Sendable {
    public static let grace: TimeInterval = 30, activeThreshold: TimeInterval = 60
    /// 距上次输入不超过这么久，就算这一段在用电脑。
    static let inputWindow: TimeInterval = 3
    /// 两次采样间隔过长（睡眠、卡顿）时最多算这么多秒。
    static let maxStep: TimeInterval = 5

    private let startedAt: Date
    private var lastSample: Date?
    private var active: TimeInterval = 0
    public private(set) var fired = false

    public init(startedAt: Date) { self.startedAt = startedAt }

    /// 返回 true 表示现在该提醒（每次休息最多一次）。
    public mutating func sample(now: Date, idleSeconds: TimeInterval) -> Bool {
        defer { lastSample = now }
        guard !fired, now.timeIntervalSince(startedAt) >= Self.grace else { return false }
        if idleSeconds <= Self.inputWindow, let last = lastSample {
            active += min(max(0, now.timeIntervalSince(last)), Self.maxStep)
        }
        guard active >= Self.activeThreshold else { return false }
        fired = true
        return true
    }
}
