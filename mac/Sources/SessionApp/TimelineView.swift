import SwiftUI
import SessionCore

/// 时间轴上的预览块：进行中的专注，「现在开始的话」下一次专注会占到哪里，或正在补录的那一段。
enum TimelineGhost: Equatable {
    case running(FocusRun)
    case next(title: String, seconds: Int)
    case backfill(title: String, DateInterval)

    func interval(now: Date) -> DateInterval {
        switch self {
        case .running(let run): DateInterval(start: run.startedAt, end: max(run.endAt, now))
        case .next(_, let seconds): DateInterval(start: now, duration: TimeInterval(seconds))
        case .backfill(_, let interval): interval
        }
    }

    /// 预计结束时间（进行中且已超时时就是计划结束时间）。
    func end(now: Date) -> Date {
        switch self {
        case .running(let run): run.endAt
        case .next(_, let seconds): now.addingTimeInterval(TimeInterval(seconds))
        case .backfill(_, let interval): interval.end
        }
    }
}

/// 今日时间轴。类型名避开 SwiftUI 自带的 `TimelineView`。
/// 左列：Todoist 带具体时间的任务（计划，虚线框）；右列：实际专注块（荧光黄）。
/// `ghost` 画在右列，并在结束时间画一条贯穿两列的虚线，方便和左边的计划对照。
struct FocusTimelineView: View {
    @EnvironmentObject var model: AppModel
    let sessions: [SessionRecord]
    let tasks: [TodoistTask]
    var selectedTaskId: String?
    var selectedSessionId: String?
    var ghost: TimelineGhost?
    var onSelectTask: (TodoistTask) -> Void = { _ in }
    var onSelectSession: (SessionRecord) -> Void = { _ in }

    private let pointsPerMinute = 1.6
    private let gutter: CGFloat = 46
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

    /// 「现在」停在视口约三分之一处：上面看已完成的，下面看今天剩下的。
    private static let nowAnchor = UnitPoint(x: 0.5, y: 0.3)

    @ViewBuilder private func content(now: Date) -> some View {
        let scheduled = scheduled
        let ghostInterval = ghost?.interval(now: now)
        let range = TimelineLayout.range(sessions: sessions,
                                         scheduled: scheduled.map(\.interval) + (ghostInterval.map { [$0] } ?? []), now: now)
        let blocks = TimelineLayout.blocks(sessions: sessions, rangeStart: range.start, pointsPerMinute: pointsPerMinute,
                                           minHeight: 10)
        let totalHeight = range.end.timeIntervalSince(range.start) / 60 * pointsPerMinute
        let nowY = now.timeIntervalSince(range.start) / 60 * pointsPerMinute

        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                GeometryReader { geo in
                    let columnsWidth = geo.size.width - gutter - 12
                    let planWidth = columnsWidth * 0.5 - 3
                    let doneWidth = columnsWidth * 0.5 - 3
                    ZStack(alignment: .topLeading) {
                        ForEach(gridMarks(range), id: \.self) { t in
                            let y = t.timeIntervalSince(range.start) / 60 * pointsPerMinute
                            let isHour = Calendar.current.component(.minute, from: t) == 0
                            if isHour {
                                Text(Ink.hm(t)).font(.inkMono(10)).foregroundStyle(Ink.sub)
                                    .frame(width: gutter - 8, alignment: .trailing)
                                    .offset(y: y - 6)
                            }
                            Rectangle().fill(isHour ? Ink.rule : Ink.ruleSoft).frame(height: 1)
                                .padding(.leading, gutter).offset(y: y)
                        }
                        ForEach(scheduled, id: \.task.id) { item in
                            let box = TimelineLayout.block(for: item.interval, rangeStart: range.start,
                                                           pointsPerMinute: pointsPerMinute, minHeight: 10)
                            Button { onSelectTask(item.task) } label: {
                                scheduledView(item.task, height: box.height, selected: item.task.id == selectedTaskId)
                            }
                            .buttonStyle(.plain)
                            .frame(width: planWidth)
                            .offset(x: gutter + 4, y: box.top)
                        }
                        ForEach(Array(zip(sessions, blocks)), id: \.0.id) { session, block in
                            blockView(session, block)
                                .frame(width: doneWidth)
                                .offset(x: gutter + 4 + planWidth + 6, y: block.top)
                        }
                        if let ghost, let ghostInterval {
                            let box = TimelineLayout.block(for: ghostInterval, rangeStart: range.start,
                                                           pointsPerMinute: pointsPerMinute, minHeight: 10)
                            ghostView(ghost, now: now, height: box.height)
                                .frame(width: doneWidth)
                                .offset(x: gutter + 4 + planWidth + 6, y: box.top)
                            let end = ghost.end(now: now)
                            endLine(end).offset(y: end.timeIntervalSince(range.start) / 60 * pointsPerMinute - 6.5)
                        }
                        // 现在线：左侧时间小签 + 一条横线。
                        HStack(spacing: 0) {
                            Text(Ink.hm(now)).font(.inkMono(9, weight: .bold)).foregroundStyle(Color.white)
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Ink.now)
                                .frame(width: gutter, alignment: .trailing)
                            Rectangle().fill(Ink.now).frame(height: 1.5)
                        }
                        .offset(y: nowY - 6.5)
                        .accessibilityHidden(true)
                        Color.clear.frame(width: 1, height: 1).id("now").offset(y: max(nowY - 160, 0))
                    }
                    .frame(width: geo.size.width, height: totalHeight + 16, alignment: .topLeading)
                    .padding(.top, 10)
                }
                .frame(height: totalHeight + 26)
            }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo("now", anchor: Self.nowAnchor) } }
            .onChange(of: sessions.count) { _, _ in proxy.scrollTo("now", anchor: Self.nowAnchor) }
        }
    }

    /// 整点 + 每 15 分钟的细线。
    private func gridMarks(_ range: (start: Date, end: Date)) -> [Date] {
        var out: [Date] = []
        var t = range.start
        while t <= range.end {
            out.append(t)
            t = t.addingTimeInterval(15 * 60)
        }
        return out
    }

    private func scheduledView(_ task: TodoistTask, height: Double, selected: Bool) -> some View {
        let color = model.category(for: task)
            .map { Color(todoistColor: $0.color) } ?? Ink.faint
        return VStack(alignment: .leading, spacing: 1) {
            if height >= Self.compactHeight {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    CategoryMark(color: color, size: 6)
                    Text(task.content).font(.ink(11, weight: .medium)).lineLimit(height >= 38 ? 2 : 1)
                }
                if height >= 44, let t = task.dueTime {
                    Text(Ink.hm(t)).font(.inkMono(9.5)).foregroundStyle(Ink.sub)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, height >= Self.compactHeight ? 4 : 0)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .foregroundStyle(Ink.ink)
        .background(selected ? Ink.panel : Ink.shelf)
        .overlay(Rectangle().strokeBorder(Ink.ink.opacity(selected ? 1 : 0.55),
                                          style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: selected ? [] : [3, 2])))
        .contentShape(Rectangle().inset(by: -4))
        .help("计划：\(task.content)")
    }

    private func blockView(_ session: SessionRecord, _ block: TimelineBlock) -> some View {
        let color = model.category(for: session.categoryId).map { Color(todoistColor: $0.color) } ?? Ink.faint
        let isSelected = session.id == selectedSessionId
        return Button { onSelectSession(session) } label: {
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    if block.height >= Self.compactHeight {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(session.title).font(.ink(11, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 2)
                            badge(session)
                        }
                    }
                    if block.height >= 38 {
                        Text("\(Ink.hm(session.startedAt)) · \(Ink.minutes(session.actualSeconds))").font(.inkMono(9.5)).opacity(0.7)
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, block.height >= Self.compactHeight ? 3 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: block.height, maxHeight: block.height, alignment: .topLeading)
            .foregroundStyle(Ink.onHighlight)
            .background(Ink.highlight)
            .overlay { if isSelected { Rectangle().strokeBorder(Ink.ink, lineWidth: 1.5) } }
            .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .help("\(session.title) · \(Ink.duration(session.actualSeconds))")
    }

    /// 下一次：虚线框 + 淡黄底；进行中：已过去的部分实心黄，剩余部分虚线。
    private func ghostView(_ ghost: TimelineGhost, now: Date, height: Double) -> some View {
        let interval = ghost.interval(now: now)
        let title: String, caption: String, elapsed: Double
        switch ghost {
        case .running(let run):
            title = run.title
            caption = "进行中 · 到 \(Ink.hm(run.endAt))"
            elapsed = min(1, max(0, now.timeIntervalSince(interval.start) / max(interval.duration, 1)))
        case .next(let t, let seconds):
            title = t
            caption = "现在开始 · \(Ink.hm(interval.start))–\(Ink.hm(interval.end)) · \(seconds / 60) 分钟"
            elapsed = 0
        case .backfill(let t, _):
            title = t
            caption = "补录 · \(Ink.hm(interval.start))–\(Ink.hm(interval.end)) · \(Int(interval.duration) / 60) 分钟"
            elapsed = 0
        }
        return VStack(alignment: .leading, spacing: 1) {
            if height >= Self.compactHeight {
                Text(title).font(.ink(11, weight: .semibold)).lineLimit(1)
            }
            if height >= 38 { Text(caption).font(.inkMono(9.5)).opacity(0.75).lineLimit(2) }
        }
        .padding(.horizontal, 6).padding(.vertical, height >= Self.compactHeight ? 3 : 0)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        // 文字压在实心部分上时用黄底配色，否则用正文色（深色模式下淡黄底上的深色字看不清）。
        .foregroundStyle(height * elapsed >= 30 ? Ink.onHighlight : Ink.ink)
        .background(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(Ink.highlight).frame(height: height * elapsed)
                Rectangle().fill(Ink.highlight.opacity(0.3))
            }
        }
        .overlay(Rectangle().strokeBorder(Ink.ink.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .help(caption)
        .accessibilityElement(children: .combine)
    }

    /// 预计结束时间：左侧描边小签 + 贯穿两列的虚线。
    private func endLine(_ end: Date) -> some View {
        HStack(spacing: 0) {
            Text(Ink.hm(end)).font(.inkMono(9, weight: .bold)).foregroundStyle(Ink.onHighlight)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Ink.highlight)
                .overlay(Rectangle().strokeBorder(Ink.ink, lineWidth: 1))
                .frame(width: gutter, alignment: .trailing)
            Line().stroke(Ink.ink, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(height: 1)
        }
        .help("预计 \(Ink.hm(end)) 结束")
        .accessibilityLabel("预计 \(Ink.hm(end)) 结束")
    }

    @ViewBuilder private func badge(_ session: SessionRecord) -> some View {
        if session.syncState == .pending {
            Image(systemName: "icloud.slash").font(.ink(9))
                .help("未同步").accessibilityLabel("未同步")
        } else if let badge = EvaluationDisplay.badge(for: model.evaluations[session.id]) {
            Text(badge).font(.inkMono(10, weight: .bold))
                .padding(.horizontal, 3)
                .foregroundStyle(Ink.highlight).background(Ink.onHighlight)
                .help("专注度评分").accessibilityLabel("专注度 \(badge)")
        }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: 0, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
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
