import SwiftUI
import Charts
import SessionCore

/// 每日 / 每周专注时长目标（分钟），只存在本机。
enum FocusTarget {
    static let dailyKey = "target.dailyMinutes", weeklyKey = "target.weeklyMinutes"
    static let dailyDefault = 240, weeklyDefault = 1200
    static let dailyRange = 30...720, weeklyRange = 60...4200
}

/// 统计页：日 / 周 / 月切换并可前后翻页。顶部是目标进度，下面一行带环比的指标，再下面是图表面板。
/// 后端未配置 / 不可达时显示占位文案。
struct StatsView: View {
    @EnvironmentObject var model: AppModel
    @State private var period = StatsPeriod(scope: DemoData.statsScope)
    @State private var phase: Phase = .loading
    @State private var editingTarget = false
    @AppStorage(FocusTarget.dailyKey) private var dailyTarget = FocusTarget.dailyDefault
    @AppStorage(FocusTarget.weeklyKey) private var weeklyTarget = FocusTarget.weeklyDefault
    @AppStorage("stats.compare") private var compare = CompareMode.slot

    private enum Phase { case loading, unavailable, loaded(StatsSummary, previous: StatsSummary?) }
    /// 周 / 月和上期怎么比：同期（只比当天：今天对上周六 / 上月同一天）或整周 / 整月的累计。
    private enum CompareMode: String { case slot, cumulative }
    private var calendar: Calendar { .current }
    private var isDay: Bool { period.scope == .day }
    private var isMonth: Bool { period.scope == .month }
    /// 月目标没有单独设置：按每周目标折算到这个月的天数。
    private var targetMinutes: Int {
        switch period.scope {
        case .day: dailyTarget
        case .week: weeklyTarget
        case .month:
            weeklyTarget * (calendar.range(of: .day, in: .month, for: period.interval(now: Date(), calendar: calendar).from)?.count ?? 30) / 7
        }
    }
    /// 本期 / 上期的叫法，例：「本周」「上周」；翻到更早时用「这周」「前一周」。
    private var periodNames: (current: String, previous: String) {
        let unit = ["day": "天", "week": "周", "month": "月"][period.scope.rawValue]!
        switch (period.scope, period.offset) {
        case (.day, 0): return ("今天", "昨天")
        case (.week, 0): return ("本周", "上周")
        case (.month, 0): return ("本月", "上月")
        default: return ("这\(unit)", "前一\(unit)")
        }
    }
    /// 环比说明，例：「较昨天」「较上周」。
    private var compareLabel: String { "较" + periodNames.previous }
    private var unitName: String { ["day": "天", "week": "周", "month": "月"][period.scope.rawValue]! }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                header
                content
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 36)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: period) { await load() }
    }

    // MARK: 标题

    private var header: some View {
        let now = Date()
        let title = period.title(now: now, calendar: calendar)
        let dates = period.dates(now: now, calendar: calendar)
        return HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title == dates ? "统计" : "统计 · \(dates)").font(.inkMono(11)).foregroundStyle(Ink.sub)
                Text(title).font(.ink(30, weight: .bold))
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(StatsScope.allCases) { s in
                    InkChip(text: s.title, selected: s == period.scope) { period = StatsPeriod(scope: s) }
                }
                Rectangle().fill(Ink.rule).frame(width: 1, height: 18).padding(.horizontal, 6)
                pager("chevron.left", help: "前一\(unitName)") { period.offset -= 1 }
                if period.offset != 0 {
                    InkChip(text: isDay ? "今天" : "本\(unitName)", selected: false) { period.offset = 0 }
                }
                pager("chevron.right", help: "后一\(unitName)") { period.offset += 1 }
                    .disabled(period.offset >= 0).opacity(period.offset >= 0 ? 0.3 : 1)
            }
        }
    }

    private func pager(_ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.ink(11, weight: .bold)).frame(width: 26, height: 26)
                .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 200)
        case .unavailable:
            VStack(alignment: .leading, spacing: 10) {
                Text("暂时拿不到统计数据").font(.ink(15, weight: .semibold))
                Text("统计由后端计算。请在「设置 › 后端」确认地址与 Token，并确认服务在运行。")
                    .font(.ink(13)).foregroundStyle(Ink.sub)
                Button("重试") { Task { await load() } }.buttonStyle(.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .inkPanel(padding: 22)
        case .loaded(let s, let prev):
            VStack(alignment: .leading, spacing: 24) {
                targetCard(s)
                ledger(s, prev)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 24, alignment: .top)],
                          alignment: .leading, spacing: 24) {
                    if isDay {
                        panel("按小时") { hourlyChart(s) }
                    } else {
                        panel("每日专注") { dailyChart(s) }
                        if !isMonth { panel("时段热力") { heatmap(s) } }
                    }
                    comparePanel(s, prev)
                    panel("分类分布") { categoryChart(s) }
                    panel("App / 网站") { appRanking(s) }
                    if !isDay { panel("专注度趋势") { trendChart(s) } }
                    panel("活跃 / 闲置") { activeIdle(s) }
                    panel("预估 · 近 \(Estimates.windowDays) 天") { estimatePanel }
                }
            }
        }
    }

    // MARK: 目标

    private func targetCard(_ s: StatsSummary) -> some View {
        let target = targetMinutes * 60
        let fraction = Double(s.totalFocusSeconds) / Double(max(1, target))
        let reached = s.totalFocusSeconds >= target
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(isDay ? "每日目标" : isMonth ? "每月目标 · 按每周目标折算" : "每周目标").font(.inkMono(10, weight: .semibold)).tracking(1).foregroundStyle(Ink.sub)
                Spacer()
                Button { editingTarget = true } label: {
                    HStack(spacing: 4) { Image(systemName: "pencil"); Text("改目标") }.font(.ink(11))
                }
                .buttonStyle(.plain).foregroundStyle(Ink.sub)
                .popover(isPresented: $editingTarget, arrowEdge: .bottom) { targetEditor }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(StatsFormat.duration(seconds: s.totalFocusSeconds)).font(.inkMono(30, weight: .medium))
                Text("/ \(StatsFormat.duration(seconds: target))").font(.inkMono(15)).foregroundStyle(Ink.sub)
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%").font(.inkMono(22, weight: .medium))
                    .foregroundStyle(reached ? Ink.ink : Ink.sub)
            }
            GeometryReader { geo in
                Rectangle().fill(Ink.highlight).frame(width: geo.size.width * min(1, fraction))
            }
            .frame(height: 12)
            .background(Ink.ruleSoft)
            .overlay(Rectangle().strokeBorder(Ink.ink, lineWidth: 1))
            Text(targetNote(done: s.totalFocusSeconds, target: target)).font(.ink(12)).foregroundStyle(Ink.sub)
        }
        .padding(18)
        .overlay(Rectangle().strokeBorder(Ink.ink, lineWidth: Ink.border))
    }

    /// 「已达成」「还差 X」；本周还会把剩余时长摊到剩下的天数（含今天）。
    private func targetNote(done: Int, target: Int) -> String {
        if done >= target { return "已达成目标，多出 \(StatsFormat.duration(seconds: done - target))" }
        let left = target - done
        guard period.offset == 0 else { return "差 \(StatsFormat.duration(seconds: left)) 未达成" }
        if isDay { return "还差 \(StatsFormat.duration(seconds: left))" }
        let end = period.interval(now: Date(), calendar: calendar).to
        let days = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: end).day ?? 1)
        return "还差 \(StatsFormat.duration(seconds: left)) · 剩 \(days) 天，每天约 \(StatsFormat.duration(seconds: left / days))"
    }

    private var targetEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("专注时长目标").font(.ink(13, weight: .semibold))
            targetRow("每日", value: $dailyTarget, range: FocusTarget.dailyRange)
            targetRow("每周", value: $weeklyTarget, range: FocusTarget.weeklyRange)
            Text("也可以在「设置 › 计时」里修改。").font(.ink(11)).foregroundStyle(Ink.sub)
        }
        .padding(16)
        .inkWindow()
    }

    private func targetRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.ink(12.5)).frame(width: 34, alignment: .leading)
            StepperField(value: value, range: range, step: 30, format: { StatsFormat.duration(seconds: $0 * 60) })
        }
    }

    // MARK: 指标行

    private func ledger(_ s: StatsSummary, _ prev: StatsSummary?) -> some View {
        HStack(spacing: 0) {
            metric("总专注", StatsFormat.duration(seconds: s.totalFocusSeconds),
                   delta: prev.flatMap { StatsFormat.change(s.totalFocusSeconds, from: $0.totalFocusSeconds) }.map { ($0, "%") })
            divider
            metric("段数", "\(s.sessionCount)", delta: prev.map { (s.sessionCount - $0.sessionCount, "") })
            divider
            metric("平均专注度", StatsFormat.score(s.avgFocusScore),
                   delta: s.avgFocusScore.flatMap { cur in prev?.avgFocusScore.map { (cur - $0, "") } })
            divider
            metric("完成率", StatsFormat.percent(s.totalFocusSeconds, of: s.plannedSeconds).map { "\($0)%" } ?? "—",
                   caption: "实际 / 计划时长")
        }
        .overlay(alignment: .top) { Rectangle().fill(Ink.ink).frame(height: Ink.border) }
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.rule).frame(height: 1) }
    }

    private var divider: some View { Rectangle().fill(Ink.rule).frame(width: 1).padding(.vertical, 12) }

    private func metric(_ title: String, _ value: String, delta: (Int, String)? = nil, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.inkMono(10, weight: .semibold)).tracking(1).foregroundStyle(Ink.sub)
            Text(value).font(.inkMono(26, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
            Group {
                if let (d, unit) = delta {
                    HStack(spacing: 4) {
                        Text(d > 0 ? "↑\(d)\(unit)" : d < 0 ? "↓\(-d)\(unit)" : "持平")
                            .foregroundStyle(d < 0 ? Ink.now : Ink.ink)
                        Text(compareLabel).foregroundStyle(Ink.faint)
                    }
                } else {
                    Text(caption ?? "\(compareLabel) —").foregroundStyle(Ink.faint)
                }
            }
            .font(.inkMono(10.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }

    private func panel<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            InkSectionHeader(text: title)
            c()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 对比面板。周 / 月标题右边可切「同期」（今天对上周六 / 上月同一天）和「累计」（整周 / 整月）；
    /// 日视图本来就只有一天，只画累计。
    private func comparePanel(_ s: StatsSummary, _ prev: StatsSummary?) -> some View {
        let sameDay = !isDay && compare == .slot
        let r = sameDay ? sameDayRace(s, prev) : cumulativeRace(s, prev)
        let title = sameDay && r.hasPrevious ? "\(r.mineLabel) vs \(r.theirLabel.replacingOccurrences(of: "此时", with: ""))"
                            : "\(periodNames.current) vs \(periodNames.previous)"
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("对比 · " + title).font(.inkMono(11, weight: .semibold)).tracking(1.2).foregroundStyle(Ink.sub)
                    Spacer()
                    if !isDay {
                        InkSegmented(options: [(CompareMode.slot, "同期"), (.cumulative, "累计")], selection: $compare)
                    }
                }
                .frame(height: 20)
                Rectangle().fill(Ink.rule).frame(height: 1)
            }
            raceChart(r, days: s.days)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: 图表

    private func hourlyChart(_ s: StatsSummary) -> some View {
        let range = StatsChartData.activeHours(s.byHour)
        let pts = StatsChartData.hourly(s.byHour).filter { range.contains($0.hour) }
        return Group {
            if s.totalFocusSeconds == 0 { empty("这一天没有专注记录") } else {
                Chart(pts) { p in
                    // 小时用分类轴：数值轴上 .ratio 宽高不生效
                    BarMark(x: .value("小时", String(p.hour)), y: .value("分钟", p.minutes), width: .ratio(0.7))
                        .foregroundStyle(Ink.ink)
                }
                .chartXScale(domain: hourDomain(range))
                .chartXAxis { hourAxis(range) }
                .chartYScale(domain: 0...60)
                .chartYAxis { inkYAxis }
                .frame(height: 170)
            }
        }
    }

    private func dailyChart(_ s: StatsSummary) -> some View {
        let pts = StatsChartData.dailyFocus(s.days, calendar: calendar)
        return Group {
            if pts.isEmpty || s.totalFocusSeconds == 0 { empty("这段时间没有专注记录") } else {
                Chart {
                    ForEach(pts) { p in
                        BarMark(x: .value("日期", p.date, unit: .day), y: .value("分钟", p.minutes), width: .ratio(0.6))
                            .foregroundStyle(p.minutes >= Double(dailyTarget) ? Ink.highlight : Ink.ink)
                    }
                    RuleMark(y: .value("每日目标", dailyTarget))
                        .foregroundStyle(Ink.now).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("目标 \(StatsFormat.duration(seconds: dailyTarget * 60))").font(.inkMono(9)).foregroundStyle(Ink.now)
                        }
                }
                .chartXAxis { dayAxis }
                .chartYAxis { inkYAxis }
                .frame(height: 170)
            }
        }
    }

    /// 行是一周的每一天，列是小时；用普通网格画，标签和格子对齐更可控。
    private func heatmap(_ s: StatsSummary) -> some View {
        let range = StatsChartData.activeHours(s.byHour)
        let cells = StatsChartData.heatmap(days: s.days, hours: s.byHour, range: range, calendar: calendar)
        let rows = Dictionary(grouping: cells, by: \.date).sorted { $0.key < $1.key }
        return Group {
            if s.totalFocusSeconds == 0 { empty("这段时间没有专注记录") } else {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    ForEach(rows, id: \.key) { date, row in
                        GridRow {
                            Text(weekday(date)).font(.inkMono(9)).foregroundStyle(Ink.sub).frame(width: 14, alignment: .leading)
                            ForEach(row.sorted { $0.hour < $1.hour }) { c in
                                Rectangle().fill(heatColor(c.minutes)).frame(height: 17)
                                    .help("\(weekday(date)) \(c.hour):00 · \(Int(c.minutes.rounded())) 分钟")
                            }
                        }
                    }
                    GridRow {
                        Color.clear.frame(width: 14, height: 1)
                        ForEach(Array(range), id: \.self) { h in
                            Text(h % 2 == 0 ? "\(h)" : "").font(.inkMono(9)).foregroundStyle(Ink.sub)
                                .fixedSize().frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 170, alignment: .top)
            }
        }
    }

    /// 月里标刻度的日子：1、5、10 … 30 号。
    private static let monthTicks: Set<Int> = [1, 5, 10, 15, 20, 25, 30]

    /// 周：每天标星期；月：只标 1、5、10 … 30 号（其余日子留空标签）。
    private var dayAxis: some AxisContent {
        AxisMarks(values: .stride(by: .day)) { v in
            AxisValueLabel(centered: true) {
                if let d = v.as(Date.self) {
                    let day = calendar.component(.day, from: d)
                    Text(!isMonth ? weekday(d) : Self.monthTicks.contains(day) ? "\(day)" : "")
                }
            }
            .font(.inkMono(9)).foregroundStyle(Ink.sub)
        }
    }

    /// 对比图的两条累计线和图例。
    private struct Race {
        let cur: [StatsChartData.CumulativePoint], old: [StatsChartData.CumulativePoint]
        let mineLabel: String, theirLabel: String
        let hasPrevious: Bool
        /// true：横轴是一天 24 小时（日视图 / 同期）；false：横轴是这一周 / 月的每一天。
        let hourly: Bool
        let xMax: Int
        var mine: Int { Int((cur.last?.minutes ?? 0) * 60) }
        var theirs: Int { Int(StatsChartData.value(old, at: cur.last?.index ?? 0) * 60) }
    }

    /// 累计：本期累计（画到此刻）对上期累计。
    private func cumulativeRace(_ s: StatsSummary, _ prev: StatsSummary?) -> Race {
        let live = period.offset == 0
        let names = periodNames
        let cur = isDay
            ? StatsChartData.cumulativeByHour(s.byHour, through: live ? calendar.component(.hour, from: Date()) : 23)
            : StatsChartData.cumulativeByDay(s.days, count: live ? elapsedDays : nil)
        let old = prev.map { isDay ? StatsChartData.cumulativeByHour($0.byHour) : StatsChartData.cumulativeByDay($0.days) } ?? []
        return Race(cur: cur, old: old, mineLabel: names.current, theirLabel: "\(names.previous)\(live ? "同期" : "")",
                    hasPrevious: prev != nil, hourly: isDay, xMax: isDay ? 24 : max(s.days.count, prev?.days.count ?? 0))
    }

    /// 同期：只比当天——今天对上周六 / 上月 31 号，按小时累计。翻到过去的周期时比它的最后一天。
    private func sameDayRace(_ s: StatsSummary, _ prev: StatsSummary?) -> Race {
        let live = period.offset == 0
        let i = live ? elapsedDays - 1 : s.days.count - 1
        let mineDay = s.days.indices.contains(i) ? s.days[i] : nil
        let theirDay = prev.flatMap { $0.days.indices.contains(i) ? $0.days[i] : nil }
        let cur = mineDay.map { StatsChartData.cumulativeByHour(StatsChartData.hours(s.byHour, on: $0.date),
                                                                through: live ? calendar.component(.hour, from: Date()) : 23) } ?? []
        let old = theirDay.map { StatsChartData.cumulativeByHour(StatsChartData.hours(prev?.byHour ?? [], on: $0.date)) } ?? []
        let date = mineDay.flatMap { StatsChartData.dailyFocus([$0], calendar: calendar).first?.date }
        let name = date.map { isMonth ? "\(calendar.component(.day, from: $0))号" : "周" + weekday($0) } ?? ""
        return Race(cur: cur, old: old, mineLabel: live ? "今天" : name,
                    theirLabel: prev != nil && theirDay == nil ? "上月没有\(name)"
                        : live ? (isMonth ? "上月" : "上") + name + "此时" : "前一\(unitName)" + name,
                    hasPrevious: theirDay != nil, hourly: true, xMax: 24)
    }

    /// 本期累计（实线，画到此刻）对上期累计（虚线）：看是领先还是落后。
    private func raceChart(_ r: Race, days: [StatsSummary.Day]) -> some View {
        let live = period.offset == 0
        // 一天内看分钟；周 / 月累计到几十上百小时，看小时。
        let scale = r.hourly ? 1.0 : 60.0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                legend(line: Ink.ink, dashed: false, "\(r.mineLabel) \(StatsFormat.duration(seconds: r.mine))")
                legend(line: Ink.faint, dashed: true, "\(r.theirLabel) \(StatsFormat.duration(seconds: r.theirs))")
                Spacer()
                if r.hasPrevious, r.mine + r.theirs > 0 {
                    Text(r.mine >= r.theirs ? "领先 \(StatsFormat.duration(seconds: r.mine - r.theirs))" : "落后 \(StatsFormat.duration(seconds: r.theirs - r.mine))")
                        .font(.inkMono(11, weight: .semibold)).foregroundStyle(r.mine >= r.theirs ? Ink.ink : Ink.now)
                }
            }
            Chart {
                ForEach(r.old) { p in
                    LineMark(x: .value("时刻", Double(p.index)), y: .value("累计", p.minutes / scale), series: .value("期", "prev"))
                        .foregroundStyle(Ink.faint).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                ForEach(r.cur) { p in
                    LineMark(x: .value("时刻", Double(p.index)), y: .value("累计", p.minutes / scale), series: .value("期", "cur"))
                        .foregroundStyle(Ink.ink).lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let last = r.cur.last, live {
                    PointMark(x: .value("时刻", Double(last.index)), y: .value("累计", last.minutes / scale))
                        .symbol(.square).symbolSize(40).foregroundStyle(Ink.highlight)
                }
            }
            .chartXScale(domain: 0...Double(max(1, r.xMax)))
            .chartXAxis {
                AxisMarks(values: raceTicks(r)) { v in
                    AxisValueLabel(anchor: .top) { if let x = v.as(Double.self) { Text(raceLabel(x, hourly: r.hourly, days: days)) } }
                        .font(.inkMono(9)).foregroundStyle(Ink.sub)
                }
            }
            .chartYAxis { inkYAxis }
            .chartYAxisLabel(r.hourly ? "分钟" : "小时", position: .topLeading)
            .frame(height: 150)
        }
    }

    /// 本期已经过了几天（含今天）。
    private var elapsedDays: Int {
        let now = Date()
        return (calendar.dateComponents([.day], from: period.interval(now: now, calendar: calendar).from, to: now).day ?? 0) + 1
    }

    /// 刻度放在每小时 / 每天的中间（第 i 段是 i-1…i）；一天只标 0、6、12、18 点。
    private func raceTicks(_ r: Race) -> [Double] {
        if r.hourly { return [0, 6, 12, 18].map { Double($0) + 0.5 } }
        if isMonth { return Self.monthTicks.sorted().filter { $0 <= r.xMax }.map { Double($0) - 0.5 } }
        return (1...max(1, r.xMax)).map { Double($0) - 0.5 }
    }

    /// 一天：几点；周：星期；月：几号。
    private func raceLabel(_ x: Double, hourly: Bool, days: [StatsSummary.Day]) -> String {
        let i = Int(x.rounded(.down))   // 0 起：第几个小时 / 第几天
        if hourly { return "\(i)" }
        if isMonth { return "\(i + 1)" }
        guard i < days.count, let d = StatsChartData.dailyFocus([days[i]], calendar: calendar).first?.date else { return "" }
        return weekday(d)
    }

    private func legend(line: Color, dashed: Bool, _ text: String) -> some View {
        HStack(spacing: 5) {
            Path { p in p.move(to: CGPoint(x: 0, y: 4)); p.addLine(to: CGPoint(x: 14, y: 4)) }
                .stroke(line, style: StrokeStyle(lineWidth: dashed ? 1.5 : 2, dash: dashed ? [3, 2] : []))
                .frame(width: 14, height: 8)
            Text(text).font(.inkMono(11))
        }
    }

    private func hourDomain(_ range: ClosedRange<Int>) -> [String] { range.map(String.init) }

    private func hourAxis(_ range: ClosedRange<Int>) -> some AxisContent {
        let ticks: [String] = stride(from: range.lowerBound, through: range.upperBound, by: 2).map(String.init)
        return AxisMarks(values: ticks) { _ in
            AxisValueLabel().font(.inkMono(9)).foregroundStyle(Ink.sub)
        }
    }

    /// 一小时专注满 60 分钟时最深。
    private func heatColor(_ minutes: Double) -> Color {
        minutes > 0 ? Ink.highlight.opacity(0.25 + 0.75 * min(1, minutes / 60)) : Ink.ruleSoft
    }

    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
    private func weekday(_ d: Date) -> String { Self.weekdays[calendar.component(.weekday, from: d) - 1] }

    private func categoryChart(_ s: StatsSummary) -> some View {
        let slices = StatsChartData.categorySlices(s.byCategory, categories: model.allCategories)
            .filter { $0.seconds > 0 }
        return VStack(alignment: .leading, spacing: 10) {
            if slices.isEmpty { empty("这段时间没有专注记录") }
            ForEach(slices) { sl in
                bar(name: sl.name, seconds: sl.seconds, fraction: sl.fraction,
                    color: sl.colorName.map { Color(todoistColor: $0) } ?? Ink.faint, mark: true)
            }
        }
    }

    private func appRanking(_ s: StatsSummary) -> some View {
        let top = s.topApps.first?.seconds ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            if s.topApps.isEmpty { empty("暂无活动记录") }
            ForEach(Array(s.topApps.enumerated()), id: \.offset) { i, app in
                bar(name: app.name, seconds: app.seconds, fraction: top > 0 ? Double(app.seconds) / Double(top) : 0,
                    color: i == 0 ? Ink.highlight : Ink.ink, mark: false, showPercent: false)
            }
        }
    }

    private func bar(name: String, seconds: Int, fraction: Double, color: Color, mark: Bool, showPercent: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if mark { CategoryMark(color: color, size: 8) }
                Text(name).font(.ink(12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(StatsFormat.duration(seconds: seconds)).font(.inkMono(11))
                if showPercent {
                    Text("\(Int((fraction * 100).rounded()))%").font(.inkMono(11)).foregroundStyle(Ink.sub)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            GeometryReader { geo in
                Rectangle().fill(color).frame(width: max(2, geo.size.width * fraction))
            }
            .frame(height: 6)
            .background(Ink.ruleSoft)
        }
    }

    private func trendChart(_ s: StatsSummary) -> some View {
        let segs = StatsChartData.scoreSegments(s.days, calendar: calendar)
        let dates = StatsChartData.dailyFocus(s.days, calendar: calendar).map(\.date)
        return Group {
            if segs.isEmpty { empty("暂无专注度评估") } else {
                Chart {
                    ForEach(Array(segs.enumerated()), id: \.offset) { i, seg in
                        ForEach(seg) { p in
                            LineMark(x: .value("日期", p.date, unit: .day), y: .value("专注度", p.score),
                                     series: .value("段", i))
                                .foregroundStyle(Ink.ink).lineStyle(StrokeStyle(lineWidth: 1.5))
                            PointMark(x: .value("日期", p.date, unit: .day), y: .value("专注度", p.score))
                                .symbol(.square).symbolSize(28).foregroundStyle(Ink.ink)
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: (dates.first ?? Date())...(dates.last ?? Date()))   // 整周都占位，没评分的日子留空
                .chartXAxis { dayAxis }
                .chartYAxis { inkYAxis }
                .frame(height: 170)
            }
        }
    }

    private var inkYAxis: some AxisContent {
        AxisMarks(position: .leading) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Ink.ruleSoft)
            AxisValueLabel().font(.inkMono(9)).foregroundStyle(Ink.sub)
        }
    }

    private func activeIdle(_ s: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let idle = StatsFormat.idlePercent(active: s.activeSeconds, idle: s.idleSeconds) {
                GeometryReader { geo in
                    let total = Double(s.activeSeconds + s.idleSeconds)
                    HStack(spacing: 0) {
                        Rectangle().fill(Ink.highlight).frame(width: geo.size.width * Double(s.activeSeconds) / total)
                        Rectangle().fill(Ink.ruleSoft)
                    }
                    .overlay(Rectangle().strokeBorder(Ink.ink, lineWidth: 1))
                }
                .frame(height: 22)
                HStack(spacing: 24) {
                    legend(Ink.highlight, "活跃", StatsFormat.duration(seconds: s.activeSeconds), 100 - idle)
                    legend(Ink.ruleSoft, "闲置", StatsFormat.duration(seconds: s.idleSeconds), idle)
                }
                Text("闲置指专注期间超过闲置阈值没有键鼠操作的时间。").font(.ink(11)).foregroundStyle(Ink.sub)
            } else {
                empty("暂无活动记录")
            }
        }
    }

    private func legend(_ color: Color, _ name: String, _ value: String, _ pct: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Rectangle().fill(color).overlay(Rectangle().strokeBorder(Ink.ink, lineWidth: 1)).frame(width: 9, height: 9)
            Text(name).font(.ink(12))
            Text(value).font(.inkMono(12, weight: .medium))
            Text("\(pct)%").font(.inkMono(11)).foregroundStyle(Ink.sub)
        }
    }

    // MARK: 预估

    /// 近 30 天每个分类计划与实际的中位数（本机记录，不随翻页变化）。
    private var estimatePanel: some View {
        let rows = model.estimates.byCategory
            .map { (id: $0.key, e: $0.value) }
            .sorted { $0.e.sampleCount > $1.e.sampleCount }
        return VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty { empty("每个分类专注满 \(Estimates.minCategorySamples) 次后显示") }
            ForEach(rows, id: \.id) { r in
                let c = model.allCategories.first { $0.id == r.id }
                let d = r.e.deviationPercent
                HStack(spacing: 6) {
                    CategoryMark(color: c.map { Color(todoistColor: $0.color) } ?? Ink.faint, size: 8)
                    Text(c?.name ?? "无分类").font(.ink(12.5, weight: .medium)).lineLimit(1)
                    Text("\(r.e.sampleCount) 次").font(.inkMono(10)).foregroundStyle(Ink.faint)
                    Spacer()
                    Text("\(Ink.minutes(r.e.medianPlannedSeconds)) → \(Ink.minutes(r.e.medianActualSeconds))").font(.inkMono(11))
                    Text(abs(d) < 5 ? "≈" : d > 0 ? "+\(d)%" : "−\(-d)%")
                        .font(.inkMono(11, weight: .semibold))
                        .foregroundStyle(d >= 15 ? Ink.now : Ink.sub)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            if !rows.isEmpty {
                Text("计划 → 实际，均为中位数；超出 15% 以上标红。开始专注时会按它建议时长。")
                    .font(.ink(11)).foregroundStyle(Ink.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.ink(12.5)).foregroundStyle(Ink.sub)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }

    // MARK: 加载

    /// 同时取本期和上一期（用于环比）；上一期失败不影响本期显示。
    private func load() async {
        let now = Date()
        if DemoData.enabled {
            phase = .loaded(DemoData.stats(period: period, now: now, calendar: calendar),
                            previous: DemoData.stats(period: period.previous, now: now, calendar: calendar))
            return
        }
        guard let api = model.api else { phase = .unavailable; return }
        phase = .loading
        let tz = StatsPeriod.tzOffsetMinutes(calendar: calendar, at: now)
        let cur = period.interval(now: now, calendar: calendar)
        let prev = period.previous.interval(now: now, calendar: calendar)
        async let current = api.stats(from: cur.from, to: cur.to, tzOffsetMinutes: tz, timeZone: calendar.timeZone)
        async let previous = try? api.stats(from: prev.from, to: prev.to, tzOffsetMinutes: tz, timeZone: calendar.timeZone)
        do {
            let s = try await current
            let p = await previous
            if Task.isCancelled { return }   // 已翻页：丢弃过期结果
            phase = .loaded(s, previous: p)
        } catch {
            if Task.isCancelled { return }
            phase = .unavailable
        }
    }
}
