import SwiftUI
import Charts
import SessionCore

/// 统计页：范围切换 + 指标 + 四张图。后端未配置 / 不可达时显示占位文案。
struct StatsView: View {
    @EnvironmentObject var model: AppModel
    @State private var range: StatsRange = .today
    @State private var phase: Phase = .loading

    private enum Phase { case loading, unavailable, loaded(StatsSummary) }
    private var calendar: Calendar { .current }

    var body: some View {
        VStack(spacing: 0) {
            Picker("范围", selection: $range) {
                ForEach(StatsRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding()
            Divider()
            content
        }
        .task(id: range) { await load() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            VStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.secondary)
                Text("暂时无法获取统计数据").font(.headline)
                Text("请确认后端地址与 Token 已在「设置」中配置且服务可访问。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("重试") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let s):
            ScrollView { statsBody(s).padding() }
        }
    }

    private func statsBody(_ s: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                metric("总专注时长", StatsFormat.duration(seconds: s.totalFocusSeconds))
                metric("番茄数", "\(s.sessionCount)")
                metric("平均专注度", StatsFormat.score(s.avgFocusScore))
            }
            dailyChart(s)
            categoryChart(s)
            trendChart(s)
            activeIdle(s)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); c() }
    }

    private func dailyChart(_ s: StatsSummary) -> some View {
        let pts = StatsChartData.dailyFocus(s.days, calendar: calendar)
        return section("每日专注时长") {
            if pts.isEmpty || s.totalFocusSeconds == 0 { empty("这段时间没有专注记录") } else {
                Chart(pts) { p in
                    BarMark(x: .value("日期", p.date, unit: .day), y: .value("分钟", p.minutes))
                        .foregroundStyle(Color.accentColor)
                }
                .chartYAxisLabel("分钟")
                .frame(height: 160)
            }
        }
    }

    private func categoryChart(_ s: StatsSummary) -> some View {
        let slices = StatsChartData.categorySlices(s.byCategory, categories: model.allCategories)
            .filter { $0.seconds > 0 }
        return section("分类分布") {
            if slices.isEmpty { empty("这段时间没有专注记录") } else {
                Chart(slices) { sl in
                    BarMark(x: .value("时长", sl.seconds / 60), y: .value("分类", sl.name))
                        .foregroundStyle(sl.colorName.map { Color(todoistColor: $0) } ?? Color.gray)
                        .annotation(position: .trailing) {
                            Text("\(StatsFormat.duration(seconds: sl.seconds)) · \(Int((sl.fraction * 100).rounded()))%")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxisLabel("分钟")
                .frame(height: CGFloat(max(1, slices.count)) * 32 + 30)
            }
        }
    }

    private func trendChart(_ s: StatsSummary) -> some View {
        let segs = StatsChartData.scoreSegments(s.days, calendar: calendar)
        return section("专注度趋势") {
            if segs.isEmpty { empty("暂无专注度评估") } else {
                Chart {
                    ForEach(Array(segs.enumerated()), id: \.offset) { i, seg in
                        ForEach(seg) { p in
                            LineMark(x: .value("日期", p.date, unit: .day), y: .value("专注度", p.score),
                                     series: .value("段", i))
                            PointMark(x: .value("日期", p.date, unit: .day), y: .value("专注度", p.score))
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .frame(height: 160)
            }
        }
    }

    private func activeIdle(_ s: StatsSummary) -> some View {
        section("活跃 / 闲置") {
            if let idle = StatsFormat.idlePercent(active: s.activeSeconds, idle: s.idleSeconds) {
                GeometryReader { geo in
                    let total = Double(s.activeSeconds + s.idleSeconds)
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.green).frame(width: geo.size.width * Double(s.activeSeconds) / total)
                        Rectangle().fill(Color.gray.opacity(0.5))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .frame(height: 16)
                Text("活跃 \(StatsFormat.duration(seconds: s.activeSeconds))（\(100 - idle)%） · 闲置 \(StatsFormat.duration(seconds: s.idleSeconds))（\(idle)%）")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                empty("暂无活动记录")
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
    }

    private func load() async {
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
