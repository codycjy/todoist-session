import Foundation

public struct TimelineBlock: Equatable, Identifiable, Sendable {
    public let id: String
    public let top: Double      // 距时间轴起点的 pt
    public let height: Double   // 至少 minHeight，保证短 session 也能点到
}

public enum TimelineLayout {
    /// 时间轴起点取最早 session 所在整点（没有 session 时取当天 9:00 或当前整点，较早者），终点取当前时间所在整点 + 1。
    public static func range(sessions: [SessionRecord], now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let dayStart = calendar.startOfDay(for: now)
        let nine = calendar.date(byAdding: .hour, value: 9, to: dayStart) ?? dayStart
        let earliest = sessions.map(\.startedAt).min() ?? min(nine, now)
        let startHour = calendar.dateInterval(of: .hour, for: min(earliest, now))?.start ?? earliest
        let endHour = calendar.dateInterval(of: .hour, for: max(now, sessions.map(\.endedAt).max() ?? now))?.end ?? now
        return (startHour, endHour)
    }

    public static func blocks(sessions: [SessionRecord], rangeStart: Date, pointsPerMinute: Double = 1.4,
                              minHeight: Double = 22) -> [TimelineBlock] {
        sessions.map { s in
            let top = s.startedAt.timeIntervalSince(rangeStart) / 60 * pointsPerMinute
            let height = max(minHeight, s.endedAt.timeIntervalSince(s.startedAt) / 60 * pointsPerMinute)
            return TimelineBlock(id: s.id, top: top, height: height)
        }
    }
}
