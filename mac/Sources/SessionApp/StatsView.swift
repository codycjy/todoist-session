import SwiftUI
import Charts
import SessionCore

/// 统计页：标题 + 范围切换，一行账本式指标，下方两列图表面板。后端未配置 / 不可达时显示占位文案。
struct StatsView: View {
    @EnvironmentObject var model: AppModel
    @State private var range: StatsRange = .week
    @State private var phase: Phase = .loading

    private enum Phase { case loading, unavailable, loaded(StatsSummary) }
    private var calendar: Calendar { .current }

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
        .task(id: range) { await load() }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("统计").font(.inkMono(11)).foregroundStyle(Ink.sub)
                Text(range.title).font(.ink(30, weight: .bold))
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(StatsRange.allCases) { r in InkChip(text: r.title, selected: r == range) { range = r } }
            }
        }
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
        case .loaded(let s):
            VStack(alignment: .leading, spacing: 24) {
                ledger(s)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 24, alignment: .top)],
                          alignment: .leading, spacing: 24) {
                    panel("每日专注") { dailyChart(s) }
                    panel("分类分布") { categoryChart(s) }
                    panel("专注度趋势") { trendChart(s) }
                    panel("活跃 / 闲置") { activeIdle(s) }
                }
            }
        }
    }

    // MARK: 指标行

    private func ledger(_ s: StatsSummary) -> some View {
        HStack(spacing: 0) {
            metric("总专注", StatsFormat.duration(seconds: s.totalFocusSeconds))
            divider
            metric("番茄", "\(s.sessionCount)")
            divider
            metric("平均专注度", StatsFormat.score(s.avgFocusScore))
            divider
            metric("活跃占比", StatsFormat.idlePercent(active: s.activeSeconds, idle: s.idleSeconds).map { "\(100 - $0)%" } ?? "—")
        }
        .overlay(alignment: .top) { Rectangle().fill(Ink.ink).frame(height: Ink.border) }
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.rule).frame(height: 1) }
    }

    private var divider: some View { Rectangle().fill(Ink.rule).frame(width: 1).padding(.vertical, 12) }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.inkMono(10, weight: .semibold)).tracking(1).foregroundStyle(Ink.sub)
            Text(value).font(.inkMono(26, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
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

    private func dailyChart(_ s: StatsSummary) -> some View {
        let pts = StatsChartData.dailyFocus(s.days, calendar: calendar)
        return Group {
            if pts.isEmpty || s.totalFocusSeconds == 0 { empty("这段时间没有专注记录") } else {
                Chart(pts) { p in
                    BarMark(x: .value("日期", p.date, unit: .day), y: .value("分钟", p.minutes), width: .ratio(0.6))
                        .foregroundStyle(calendar.isDateInToday(p.date) ? Ink.highlight : Ink.ink)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: pts.count > 10 ? 5 : 1)) { _ in
                        AxisValueLabel(format: .dateTime.day(), centered: true).font(.inkMono(9)).foregroundStyle(Ink.sub)
                    }
                }
                .chartYAxis { inkYAxis }
                .frame(height: 170)
            }
        }
    }

    private func categoryChart(_ s: StatsSummary) -> some View {
        let slices = StatsChartData.categorySlices(s.byCategory, categories: model.allCategories)
            .filter { $0.seconds > 0 }
        return VStack(alignment: .leading, spacing: 10) {
            if slices.isEmpty { empty("这段时间没有专注记录") }
            ForEach(slices) { sl in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        CategoryMark(color: sl.colorName.map { Color(todoistColor: $0) } ?? Ink.faint, size: 8)
                        Text(sl.name).font(.ink(12.5, weight: .medium))
                        Spacer()
                        Text(StatsFormat.duration(seconds: sl.seconds)).font(.inkMono(11))
                        Text("\(Int((sl.fraction * 100).rounded()))%").font(.inkMono(11)).foregroundStyle(Ink.sub)
                            .frame(width: 36, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        Rectangle().fill(sl.colorName.map { Color(todoistColor: $0) } ?? Ink.faint)
                            .frame(width: max(2, geo.size.width * sl.fraction))
                    }
                    .frame(height: 6)
                    .background(Ink.ruleSoft)
                }
            }
        }
    }

    private func trendChart(_ s: StatsSummary) -> some View {
        let segs = StatsChartData.scoreSegments(s.days, calendar: calendar)
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
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: s.days.count > 10 ? 5 : 1)) { _ in
                        AxisValueLabel(format: .dateTime.day(), centered: true).font(.inkMono(9)).foregroundStyle(Ink.sub)
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

    private func load() async {
        if DemoData.enabled, let demo = DemoData.stats(now: Date()) { phase = .loaded(demo); return }
        guard let api = model.api else { phase = .unavailable; return }
        phase = .loading
        let now = Date()
        let r = range.interval(now: now, calendar: calendar)
        do {
            let s = try await api.stats(from: r.from, to: r.to,
                                        tzOffsetMinutes: StatsRange.tzOffsetMinutes(calendar: calendar, at: now),
                                        timeZone: calendar.timeZone)
            if Task.isCancelled { return }   // 范围已切换：丢弃过期结果
            phase = .loaded(s)
        } catch {
            if Task.isCancelled { return }
            phase = .unavailable
        }
    }
}
