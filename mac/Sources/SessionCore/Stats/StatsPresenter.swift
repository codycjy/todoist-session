import Foundation

/// 统计页的粒度：日 / 周 / 月。
public enum StatsScope: String, CaseIterable, Identifiable, Sendable {
    case day, week, month
    public var id: String { rawValue }
    public var title: String {
        switch self { case .day: "日"; case .week: "周"; case .month: "月" }
    }
}

/// 统计页当前看的那一天 / 那一周；`offset` 0 是今天 / 本周，-1 是昨天 / 上周。区间为 [from, to)。
public struct StatsPeriod: Hashable, Sendable {
    public var scope: StatsScope
    public var offset: Int

    public init(scope: StatsScope, offset: Int = 0) { self.scope = scope; self.offset = offset }

    public var previous: StatsPeriod { StatsPeriod(scope: scope, offset: offset - 1) }

    public func interval(now: Date, calendar: Calendar) -> (from: Date, to: Date) {
        let today = calendar.startOfDay(for: now)
        switch scope {
        case .day:
            let from = calendar.date(byAdding: .day, value: offset, to: today)!
            return (from, calendar.date(byAdding: .day, value: 1, to: from)!)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            let from = calendar.date(byAdding: .weekOfYear, value: offset, to: start)!
            return (from, calendar.date(byAdding: .weekOfYear, value: 1, to: from)!)
        case .month:
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? today
            let from = calendar.date(byAdding: .month, value: offset, to: start)!
            return (from, calendar.date(byAdding: .month, value: 1, to: from)!)
        }
    }

    /// 大标题：今天 / 昨天 / 本周 / 上周，更早的用日期。
    public func title(now: Date, calendar: Calendar) -> String {
        switch (scope, offset) {
        case (.day, 0): "今天"
        case (.day, -1): "昨天"
        case (.week, 0): "本周"
        case (.week, -1): "上周"
        case (.month, 0): "本月"
        case (.month, -1): "上月"
        case (.month, _):
            { let c = calendar.dateComponents([.year, .month], from: interval(now: now, calendar: calendar).from)
              return "\(c.year!)年\(c.month!)月" }()
        default: dates(now: now, calendar: calendar)
        }
    }

    /// 日期说明，例：「10月28日 周三」「10月26日 – 11月1日」。
    public func dates(now: Date, calendar: Calendar) -> String {
        let r = interval(now: now, calendar: calendar)
        func md(_ d: Date) -> String {
            let c = calendar.dateComponents([.month, .day], from: d)
            return "\(c.month!)月\(c.day!)日"
        }
        switch scope {
        case .day:
            let weekday = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][calendar.component(.weekday, from: r.from) - 1]
            return "\(md(r.from)) \(weekday)"
        case .week, .month:
            return "\(md(r.from)) – \(md(calendar.date(byAdding: .day, value: -1, to: r.to)!))"
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

    /// 相对上一周期的变化百分比；上一周期为 0 时没有可比基数，返回 nil。
    public static func change(_ current: Int, from previous: Int) -> Int? {
        guard previous > 0 else { return nil }
        return Int((Double(current - previous) / Double(previous) * 100).rounded())
    }

    /// part / whole 的百分比（不封顶）；whole 为 0 返回 nil。
    public static func percent(_ part: Int, of whole: Int) -> Int? {
        guard whole > 0 else { return nil }
        return Int((Double(part) / Double(whole) * 100).rounded())
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

    /// 累计曲线上的一点：`index` 是第几个小时 / 第几天结束时（0 = 起点）。
    public struct CumulativePoint: Equatable, Identifiable, Sendable {
        public let index: Int
        public let minutes: Double
        public var id: Int { index }
    }

    public struct HourPoint: Equatable, Identifiable, Sendable {
        public let hour: Int
        public let minutes: Double
        public var id: Int { hour }
    }
    public struct HeatCell: Equatable, Identifiable, Sendable {
        public let date: Date
        public let hour: Int
        public let minutes: Double
        public var id: String { "\(date.timeIntervalSince1970)-\(hour)" }
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

    /// 周 / 月：每天结束时的累计专注分钟，从 0 起。`count` 限定画到第几天（本期只画到今天）。
    public static func cumulativeByDay(_ days: [StatsSummary.Day], count: Int? = nil) -> [CumulativePoint] {
        var total = 0.0
        return [CumulativePoint(index: 0, minutes: 0)] + days.prefix(count ?? days.count).enumerated().map { i, d in
            total += Double(d.focusSeconds) / 60
            return CumulativePoint(index: i + 1, minutes: total)
        }
    }

    /// 日：每个整点结束时的累计专注分钟，从 0 点起。`through` 限定画到几点（今天只画到当前小时）。
    public static func cumulativeByHour(_ hours: [StatsSummary.HourShare], through lastHour: Int = 23) -> [CumulativePoint] {
        var total = 0.0
        let perHour = hourly(hours)
        return [CumulativePoint(index: 0, minutes: 0)] + perHour.prefix(max(0, min(23, lastHour)) + 1).map { p in
            total += p.minutes
            return CumulativePoint(index: p.hour + 1, minutes: total)
        }
    }

    /// 曲线在 `index` 处（或之前最后一点）的累计值，用于「上期同期」。
    public static func value(_ points: [CumulativePoint], at index: Int) -> Double {
        points.last { $0.index <= index }?.minutes ?? 0
    }

    /// 某一天的逐小时记录，用来画「今天对上周六」的当天累计。
    public static func hours(_ hours: [StatsSummary.HourShare], on date: String) -> [StatsSummary.HourShare] {
        hours.filter { $0.date == date }
    }

    /// 日视图：0–23 点每小时的专注分钟，没有记录的小时补 0。
    public static func hourly(_ hours: [StatsSummary.HourShare]) -> [HourPoint] {
        var minutes = [Double](repeating: 0, count: 24)
        for h in hours where (0..<24).contains(h.hour) { minutes[h.hour] += Double(h.focusSeconds) / 60 }
        return minutes.enumerated().map { HourPoint(hour: $0.offset, minutes: $0.element) }
    }

    /// 周视图热力图：每一天 × `hours` 里每个小时一格，没有记录的格子为 0。
    public static func heatmap(days: [StatsSummary.Day], hours: [StatsSummary.HourShare], range: ClosedRange<Int>,
                               calendar: Calendar) -> [HeatCell] {
        var seconds: [String: Int] = [:]
        for h in hours { seconds["\(h.date)T\(h.hour)", default: 0] += h.focusSeconds }
        return days.flatMap { d -> [HeatCell] in
            guard let date = parse(d.date, calendar: calendar) else { return [] }
            return range.map { HeatCell(date: date, hour: $0, minutes: Double(seconds["\(d.date)T\($0)"] ?? 0) / 60) }
        }
    }

    /// 要显示的小时范围：默认 8–22 点，有更早 / 更晚的记录时扩展过去。
    public static func activeHours(_ hours: [StatsSummary.HourShare], default base: ClosedRange<Int> = 8...22) -> ClosedRange<Int> {
        let used = hours.filter { $0.focusSeconds > 0 }.map(\.hour)
        return min(base.lowerBound, used.min() ?? base.lowerBound)...max(base.upperBound, used.max() ?? base.upperBound)
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
