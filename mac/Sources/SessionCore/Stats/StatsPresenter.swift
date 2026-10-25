import Foundation

/// 统计页范围；区间为 [from, to)，按调用方给定的日历（本地时区）计算。
public enum StatsRange: String, CaseIterable, Identifiable, Sendable {
    case today, week, last30
    public var id: String { rawValue }

    public var title: String {
        switch self { case .today: "今日"; case .week: "本周"; case .last30: "最近30天" }
    }

    public func interval(now: Date, calendar: Calendar) -> (from: Date, to: Date) {
        let startOfToday = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        switch self {
        case .today:
            return (startOfToday, tomorrow)
        case .week:
            if let w = calendar.dateInterval(of: .weekOfYear, for: now) { return (w.start, w.end) }
            return (startOfToday, tomorrow)
        case .last30:
            return (calendar.date(byAdding: .day, value: -29, to: startOfToday)!, tomorrow)
        }
    }

    /// 后端 `tzOffsetMinutes` 参数。
    public static func tzOffsetMinutes(calendar: Calendar, at date: Date) -> Int {
        calendar.timeZone.secondsFromGMT(for: date) / 60
    }
}

public enum StatsFormat {
    /// 例：8100 → "2小时15分"；整点 "2小时"；不足一小时 "15分"；0/负数/不足一分 "0分"。
    public static func duration(seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)分" }
        return m == 0 ? "\(h)小时" : "\(h)小时\(m)分"
    }

    public static func score(_ value: Int?) -> String { value.map(String.init) ?? "—" }

    /// 闲置占 (活跃+闲置) 的百分比；总量为 0 返回 nil。
    public static func idlePercent(active: Int, idle: Int) -> Int? {
        let total = active + idle
        guard total > 0 else { return nil }
        return Int((Double(idle) / Double(total) * 100).rounded())
    }
}

public enum StatsChartData {
    public struct DailyPoint: Equatable, Identifiable, Sendable {
        public let date: Date
        public let minutes: Double
        public var id: Date { date }
    }
    public struct ScorePoint: Equatable, Identifiable, Sendable {
        public let date: Date
        public let score: Int
        public var id: Date { date }
    }
    public struct CategorySlice: Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        /// nil = 无分类 / 未知，UI 用灰色。
        public let colorName: String?
        public let seconds: Int
        public let fraction: Double
    }

    static func parse(_ s: String, calendar: Calendar) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    public static func dailyFocus(_ days: [StatsSummary.Day], calendar: Calendar) -> [DailyPoint] {
        days.compactMap { d in
            parse(d.date, calendar: calendar).map { DailyPoint(date: $0, minutes: Double(d.focusSeconds) / 60) }
        }
    }

    /// 按连续有分数的日子分段；无评估的日子断开（不当作 0）。
    public static func scoreSegments(_ days: [StatsSummary.Day], calendar: Calendar) -> [[ScorePoint]] {
        var out: [[ScorePoint]] = []
        var cur: [ScorePoint] = []
        for d in days {
            if let s = d.avgFocusScore, let date = parse(d.date, calendar: calendar) {
                cur.append(ScorePoint(date: date, score: s))
            } else if !cur.isEmpty { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    public static func categorySlices(_ shares: [StatsSummary.CategoryShare], categories: [Category]) -> [CategorySlice] {
        let total = shares.reduce(0) { $0 + $1.focusSeconds }
        return shares.map { sh in
            let cat = sh.categoryId.flatMap { id in categories.first { $0.id == id } }
            let name = sh.categoryId == nil ? "无分类" : (cat?.name ?? "未知分类")
            return CategorySlice(id: sh.categoryId ?? "none", name: name, colorName: cat?.color,
                                 seconds: sh.focusSeconds,
                                 fraction: total > 0 ? Double(sh.focusSeconds) / Double(total) : 0)
        }
    }
}
