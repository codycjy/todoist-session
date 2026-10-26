import SwiftUI
import SessionCore

/// 今日专注块时间轴。类型名避开 SwiftUI 自带的 `TimelineView`。
/// 左列：Todoist 带具体时间的任务（计划）；右列：实际专注块。
struct FocusTimelineView: View {
    @EnvironmentObject var model: AppModel
    let sessions: [SessionRecord]
    let tasks: [TodoistTask]
    var onSelectTask: (TodoistTask) -> Void = { _ in }
    @State private var selected: String?

    private let pointsPerMinute = 1.4
    private let gutter: CGFloat = 48
    private let defaultTaskMinutes = 30.0
    /// 低于此高度的块只画一条细条（标题放进 tooltip），否则文字会撑出块外。
    private static let compactHeight: Double = 18

    private var scheduled: [(task: TodoistTask, interval: DateInterval)] {
        let cal = Calendar.current
        return tasks.compactMap { task in
            guard let start = task.dueTime, cal.isDateInToday(start) else { return nil }
            let minutes = Double(task.durationMinutes ?? Int(defaultTaskMinutes))
            return (task, DateInterval(start: start, duration: minutes * 60))
        }
    }

    var body: some View {
        // 每 30 秒重绘一次，否则 `now` 与整点范围会停在首次渲染时（过了整点就缺分界线）。
        SwiftUI.TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let scheduled = scheduled
        let range = TimelineLayout.range(sessions: sessions, scheduled: scheduled.map(\.interval), now: now)
        let blocks = TimelineLayout.blocks(sessions: sessions, rangeStart: range.start, pointsPerMinute: pointsPerMinute)
        let totalHeight = range.end.timeIntervalSince(range.start) / 60 * pointsPerMinute
        let nowY = now.timeIntervalSince(range.start) / 60 * pointsPerMinute

        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                GeometryReader { geo in
                    let columnWidth = max((geo.size.width - gutter - 14) / 2, 40)
                    ZStack(alignment: .topLeading) {
                        ForEach(hourMarks(range), id: \.self) { hour in
                            let y = hour.timeIntervalSince(range.start) / 60 * pointsPerMinute
                            Text(hour, format: .dateTime.hour().minute())
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: gutter - 6, alignment: .trailing)
                                .offset(y: y - 7)
                            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 0.5)
                                .padding(.leading, gutter).offset(y: y)
                        }
                        ForEach(scheduled, id: \.task.id) { item in
                            let box = TimelineLayout.block(for: item.interval, rangeStart: range.start,
                                                           pointsPerMinute: pointsPerMinute)
                            Button { onSelectTask(item.task) } label: { scheduledView(item.task, height: box.height) }
                                .buttonStyle(.plain)
                                .frame(width: columnWidth)
                                .offset(x: gutter + 4, y: box.top)
                        }
                        ForEach(Array(zip(sessions, blocks)), id: \.0.id) { session, block in
                            blockView(session, block)
                                .frame(width: columnWidth)
                                .offset(x: gutter + 10 + columnWidth, y: block.top)
                        }
                        Rectangle().fill(Color.red).frame(height: 1)
                            .padding(.leading, gutter - 4)
                            .offset(y: nowY)
                            .accessibilityHidden(true)
                        Color.clear.frame(width: 1, height: 1).id("now").offset(y: max(nowY - 120, 0))
                    }
                    .frame(width: geo.size.width, height: totalHeight + 14, alignment: .topLeading)
                }
                .frame(height: totalHeight + 14)
            }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo("now", anchor: .top) } }
            .onChange(of: sessions.count) { _, _ in proxy.scrollTo("now", anchor: .top) }
        }
    }

    private func scheduledView(_ task: TodoistTask, height: Double) -> some View {
        let color = model.categories.first { $0.todoistProjectId == task.projectId }
            .map { Color(todoistColor: $0.color) } ?? .gray
        return VStack(alignment: .leading, spacing: 0) {
            if height >= Self.compactHeight {
                Text(task.content).font(.caption).lineLimit(height >= 36 ? 2 : 1)
                if height >= 40, let t = task.dueTime {
                    Text(t, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, height >= Self.compactHeight ? 3 : 0)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(Rectangle().inset(by: -4))
        .help("Todoist 计划：\(task.content)")
    }

    private func hourMarks(_ range: (start: Date, end: Date)) -> [Date] {
        var out: [Date] = []
        var t = range.start
        while t <= range.end {
            out.append(t)
            guard let next = Calendar.current.date(byAdding: .hour, value: 1, to: t) else { break }
            t = next
        }
        return out
    }

    private func blockView(_ session: SessionRecord, _ block: TimelineBlock) -> some View {
        let color = model.category(for: session.categoryId).map { Color(todoistColor: $0.color) } ?? .gray
        return Button { selected = session.id } label: {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    if block.height >= Self.compactHeight {
                        Text(session.title).font(.caption).lineLimit(1)
                    }
                    if block.height >= 36 {
                        Text("\(session.actualSeconds / 60) 分钟").font(.caption2).opacity(0.8)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, block.height >= Self.compactHeight ? 3 : 0)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                if session.syncState == .pending {
                    Image(systemName: "icloud.slash").font(.caption2).padding(3)
                        .help("未同步").accessibilityLabel("未同步")
                } else if let badge = EvaluationDisplay.badge(for: model.evaluations[session.id]) {
                    Text(badge).font(.caption2.bold()).monospacedDigit().padding(3)
                        .help("专注度评分").accessibilityLabel("专注度 \(badge)")
                }
            }
            .frame(height: block.height)
            .foregroundStyle(.white)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .help("\(session.title) · \(session.actualSeconds / 60) 分钟")
        .popover(isPresented: Binding(get: { selected == session.id },
                                      set: { if !$0 { selected = nil } })) {
            SessionDetail(session: session, spans: model.spans(for: session.id),
                          evaluation: model.evaluations[session.id]) {
                Task { await model.retryEvaluation(sessionId: session.id) }
            }
        }
    }
}

private struct SessionDetail: View {
    let session: SessionRecord
    let spans: [ActivitySpan]
    let evaluation: Evaluation?
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title).font(.headline)
            Text("\(session.startedAt, format: .dateTime.hour().minute())–\(session.endedAt, format: .dateTime.hour().minute())　实际 \(session.actualSeconds / 60) 分钟")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if let evaluation { evaluationView(evaluation) }
            if spans.isEmpty {
                Text("没有采集到活动（可能未授权辅助功能）").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(spans) { span in
                            Text(line(span)).font(.caption).monospacedDigit().lineLimit(2)
                                .foregroundStyle(span.wasBlocked ? Color.red : span.kind == .idle ? Color.gray : Color.primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder private func evaluationView(_ evaluation: Evaluation) -> some View {
        switch evaluation.status {
        case .pending:
            Text("评估中…").font(.caption).foregroundStyle(.secondary)
        case .failed:
            HStack {
                Text("评估失败").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重新评估", action: onRetry).controlSize(.small)
            }
        case .done:
            if let summary = evaluation.summary { Text(summary).font(.callout) }
            if !evaluation.distractions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("偏离片段").font(.caption.bold())
                    ForEach(Array(evaluation.distractions.enumerated()), id: \.offset) { _, d in
                        let f = Date.FormatStyle().hour().minute()
                        Text("\(d.start.formatted(f))–\(d.end.formatted(f))  \(d.reason)")
                            .font(.caption).monospacedDigit()
                    }
                }
            }
        }
        Divider()
    }

    private func line(_ span: ActivitySpan) -> String {
        let f = Date.FormatStyle().hour().minute()
        let range = "\(span.startedAt.formatted(f))–\(span.endedAt.formatted(f))"
        if span.kind == .idle { return "\(range)  闲置" }
        let detail = [span.windowTitle, span.urlHost].compactMap { $0 }.first
        let what = [span.appName ?? "未知", detail].compactMap { $0 }.joined(separator: " — ")
        return "\(range)  \(what)\(span.wasBlocked ? "（已拦截）" : "")"
    }
}

extension Color {
    /// Todoist 项目颜色名 → SwiftUI 颜色；未知名称回退为灰色。
    init(todoistColor name: String) {
        let table: [String: Color] = [
            "berry_red": Color(red: 0.72, green: 0.15, blue: 0.35), "red": .red, "orange": .orange,
            "yellow": .yellow, "olive_green": Color(red: 0.55, green: 0.55, blue: 0.2),
            "lime_green": Color(red: 0.5, green: 0.75, blue: 0.2), "green": .green,
            "mint_green": .mint, "teal": .teal, "sky_blue": Color(red: 0.3, green: 0.7, blue: 0.9),
            "light_blue": Color(red: 0.5, green: 0.7, blue: 0.95), "blue": .blue, "grape": .purple,
            "violet": .indigo, "lavender": Color(red: 0.65, green: 0.6, blue: 0.9), "magenta": .pink,
            "salmon": Color(red: 0.95, green: 0.5, blue: 0.45), "charcoal": Color(white: 0.3),
            "grey": .gray, "taupe": .brown,
        ]
        self = table[name] ?? .gray
    }
}
