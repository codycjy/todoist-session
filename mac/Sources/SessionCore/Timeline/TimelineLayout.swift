import Foundation

public struct TimelineBlock: Equatable, Identifiable, Sendable {
    public let id: String
    public let top: Double      // 距时间轴起点的 pt
    public let height: Double   // 至少 minHeight（约 7 分钟的视觉高度），避免 1 分钟的块看起来像 15 分钟
}

public enum TimelineLayout {
    /// 时间轴起点取最早 session 所在整点（没有 session 时取当天 9:00 或当前整点，较早者），终点固定画到当天 24:00，
    /// 后面没有任务也能看到今天剩下的时间。`scheduled` 是 Todoist 带具体时间的任务区间，同样会撑开时间轴范围（可越过午夜）。
    public static func range(sessions: [SessionRecord], scheduled: [DateInterval] = [], now: Date,
                             calendar: Calendar = .current) -> (start: Date, end: Date) {
        let dayStart = calendar.startOfDay(for: now)
        let nine = calendar.date(byAdding: .hour, value: 9, to: dayStart) ?? dayStart
        let starts = sessions.map(\.startedAt) + scheduled.map(\.start)
        let ends = sessions.map(\.endedAt) + scheduled.map(\.end)
        let earliest = starts.min() ?? min(nine, now)
        let startHour = calendar.dateInterval(of: .hour, for: min(earliest, now))?.start ?? earliest
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let lastHour = calendar.dateInterval(of: .hour, for: max(now, ends.max() ?? now))?.end ?? now
        return (startHour, max(dayEnd, lastHour))
    }

    /// 任意时间区间在时间轴上的位置（Todoist 计划块用）。
    public static func block(for interval: DateInterval, rangeStart: Date, pointsPerMinute: Double = 1.4,
                             minHeight: Double = 10) -> (top: Double, height: Double) {
        (interval.start.timeIntervalSince(rangeStart) / 60 * pointsPerMinute,
         max(minHeight, interval.duration / 60 * pointsPerMinute))
    }

    public static func blocks(sessions: [SessionRecord], rangeStart: Date, pointsPerMinute: Double = 1.4,
                              minHeight: Double = 10) -> [TimelineBlock] {
        sessions.map { s in
            let top = s.startedAt.timeIntervalSince(rangeStart) / 60 * pointsPerMinute
            let height = max(minHeight, s.endedAt.timeIntervalSince(s.startedAt) / 60 * pointsPerMinute)
            return TimelineBlock(id: s.id, top: top, height: height)
        }
    }
}
