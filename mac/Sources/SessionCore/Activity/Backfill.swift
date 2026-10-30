import Foundation

/// 「我刚才在干嘛」补录：选一段没有专注记录的时间，用专注外的活动生成一次专注。
public enum Backfill {
    /// 一次补录最长 3 小时（也让 span 数量远低于后端上限）。
    public static let maxSeconds = 3 * 3600
    public static let minSeconds = 60

    public enum Problem: Equatable { case tooShort, tooLong, inFuture, overlaps(String) }

    /// 默认区间：从今天最后一次专注结束（没有就一小时前）到现在，最长 1 小时，取整到分钟。
    public static func suggestedRange(after sessions: [SessionRecord], now: Date, calendar: Calendar) -> (from: Date, to: Date) {
        let to = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        let hourAgo = to.addingTimeInterval(-3600)
        let lastEnd = sessions.map(\.endedAt).filter { $0 <= to }.max()
        let from = max(lastEnd.map { calendar.dateInterval(of: .minute, for: $0.addingTimeInterval(59))?.start ?? $0 } ?? hourAgo,
                       hourAgo)
        return (min(from, to), to)
    }

    /// 区间是否可补录：长度、不能晚于现在、不能和已有专注重叠。
    public static func problem(from: Date, to: Date, now: Date, existing: [SessionRecord]) -> Problem? {
        let seconds = Int(to.timeIntervalSince(from))
        if to > now.addingTimeInterval(60) { return .inFuture }
        if seconds < minSeconds { return .tooShort }
        if seconds > maxSeconds { return .tooLong }
        if let hit = existing.first(where: { $0.startedAt < to && $0.endedAt > from }) { return .overlaps(hit.title) }
        return nil
    }

    /// 裁剪到 [from, to) 并换成新 id、归到 `sessionId` 下。
    public static func spans(_ ambient: [ActivitySpan], from: Date, to: Date, sessionId: String) -> [ActivitySpan] {
        ambient.compactMap { s in
            let start = max(s.startedAt, from), end = min(s.endedAt, to)
            guard end > start else { return nil }
            return ActivitySpan(sessionId: sessionId, kind: s.kind, appBundleId: s.appBundleId, appName: s.appName,
                                windowTitle: s.windowTitle, urlHost: s.urlHost, urlPath: s.urlPath,
                                startedAt: start, endedAt: end, wasBlocked: false)
        }
    }

    public struct Usage: Equatable, Sendable {
        public let name: String
        public let seconds: Int
    }

    /// 预览：活跃时间按网站（有域名时）或 App 汇总，从多到少；另给出闲置秒数。
    public static func summary(_ spans: [ActivitySpan]) -> (top: [Usage], idleSeconds: Int) {
        var byName: [String: TimeInterval] = [:]
        var idle: TimeInterval = 0
        for s in spans {
            if s.kind == .idle { idle += s.duration; continue }
            guard let name = s.urlHost ?? s.appName else { continue }
            byName[name, default: 0] += s.duration
        }
        let top = byName.map { Usage(name: $0.key, seconds: Int($0.value.rounded())) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name }
        return (top, Int(idle.rounded()))
    }

    public static func record(id: String = UUID().uuidString.lowercased(), title: String, categoryId: String?,
                              from: Date, to: Date, allowIdle: Bool) -> SessionRecord {
        let seconds = Int(to.timeIntervalSince(from).rounded())
        return SessionRecord(id: id, title: title, categoryId: categoryId, source: .custom, todoistTaskId: nil,
                             entryId: nil, plannedSeconds: seconds, actualSeconds: seconds, startedAt: from,
                             endedAt: to, allowIdle: allowIdle)
    }
}
