import Foundation

/// 「上周同一天、同一时刻」已经专注了多少：和过去的自己赛跑。
public enum SameTimeComparison {
    /// 一周前的那一时刻。
    public static func reference(for now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -7, to: now) ?? now.addingTimeInterval(-7 * 86_400)
    }

    /// `sessions` 中截至 `moment`、且在 `moment` 当天开始的专注秒数；跨过 `moment` 的那段只算已过去的部分。
    public static func focusedSeconds(_ sessions: [SessionRecord], until moment: Date, calendar: Calendar) -> Int {
        let dayStart = calendar.startOfDay(for: moment)
        return sessions.reduce(0) { sum, s in
            guard s.startedAt >= dayStart, s.startedAt < moment else { return sum }
            return sum + min(s.actualSeconds, Int(moment.timeIntervalSince(s.startedAt)))
        }
    }
}
