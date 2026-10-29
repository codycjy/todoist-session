import SwiftUI
import Charts
import SessionCore

/// 每日 / 每周专注时长目标（分钟），只存在本机。
enum FocusTarget {
    static let dailyKey = "target.dailyMinutes", weeklyKey = "target.weeklyMinutes"
    static let dailyDefault = 240, weeklyDefault = 1200
    static let dailyRange = 30...720, weeklyRange = 60...4200
}

/// 统计页：日 / 周切换并可前后翻页。顶部是目标进度，下面一行带环比的指标，再下面是图表面板。
/// 后端未配置 / 不可达时显示占位文案。
struct StatsView: View {
    @EnvironmentObject var model: AppModel
    @State private var period = StatsPeriod(scope: DemoData.statsScope)
    @State private var phase: Phase = .loading
    @State private var editingTarget = false
    @AppStorage(FocusTarget.dailyKey) private var dailyTarget = FocusTarget.dailyDefault
    @AppStorage(FocusTarget.weeklyKey) private var weeklyTarget = FocusTarget.weeklyDefault

    private enum Phase { case loading, unavailable, loaded(StatsSummary, previous: StatsSummary?) }
    private var calendar: Calendar { .current }
    private var isDay: Bool { period.scope == .day }
    private var targetMinutes: Int { isDay ? dailyTarget : weeklyTarget }
    /// 环比说明，例：「较昨天」「较上周」。
    private var compareLabel: String {
        switch (period.scope, period.offset) {
        case (.day, 0): "较昨天"
        case (.week, 0): "较上周"
        default: isDay ? "较前一天" : "较前一周"
        }
    }

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
                pager("chevron.left", help: isDay ? "前一天" : "前一周") { period.offset -= 1 }
                if period.offset != 0 {
                    InkChip(text: isDay ? "今天" : "本周", selected: false) { period.offset = 0 }
                }
                pager("chevron.right", help: isDay ? "后一天" : "后一周") { period.offset += 1 }
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
                        panel("时段热力") { heatmap(s) }
                    }
                    panel("分类分布") { categoryChart(s) }
                    panel("App / 网站") { appRanking(s) }
                    if !isDay { panel("专注度趋势") { trendChart(s) } }
                    panel("活跃 / 闲置") { activeIdle(s) }
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
                Text(isDay ? "每日目标" : "每周目标").font(.inkMono(10, weight: .semibold)).tracking(1).foregroundStyle(Ink.sub)
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
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { v in
                        AxisValueLabel(centered: true) { if let d = v.as(Date.self) { Text(weekday(d)) } }
                            .font(.inkMono(9)).foregroundStyle(Ink.sub)
                    }
                }
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
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { v in
                        AxisValueLabel(centered: true) { if let d = v.as(Date.self) { Text(weekday(d)) } }
                            .font(.inkMono(9)).foregroundStyle(Ink.sub)
                    }
                }
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
