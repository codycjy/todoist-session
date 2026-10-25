import SwiftUI
import SessionCore

/// 今日专注块时间轴。类型名避开 SwiftUI 自带的 `TimelineView`。
struct FocusTimelineView: View {
    @EnvironmentObject var model: AppModel
    let sessions: [SessionRecord]
    @State private var selected: String?

    private let pointsPerMinute = 1.4
    private let gutter: CGFloat = 48

    var body: some View {
        let now = Date()
        let range = TimelineLayout.range(sessions: sessions, now: now)
        let blocks = TimelineLayout.blocks(sessions: sessions, rangeStart: range.start, pointsPerMinute: pointsPerMinute)
        let totalHeight = range.end.timeIntervalSince(range.start) / 60 * pointsPerMinute
        let nowY = now.timeIntervalSince(range.start) / 60 * pointsPerMinute

        ScrollView {
            ZStack(alignment: .topLeading) {
                ForEach(hourMarks(range), id: \.self) { hour in
                    let y = hour.timeIntervalSince(range.start) / 60 * pointsPerMinute
                    HStack(spacing: 6) {
                        Text(hour, format: .dateTime.hour().minute())
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: gutter - 6, alignment: .trailing)
                        Divider()
                    }
                    .offset(y: y - 7)
                }
                ForEach(Array(zip(sessions, blocks)), id: \.0.id) { session, block in
                    blockView(session, block)
                        .padding(.leading, gutter + 6)
                        .offset(y: block.top)
                }
                Rectangle().fill(Color.red).frame(height: 1)
                    .padding(.leading, gutter - 4)
                    .offset(y: nowY)
                    .accessibilityHidden(true)
            }
            .frame(height: max(totalHeight, 1) + 14, alignment: .topLeading)
            .padding(.trailing, 8)
        }
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
                    Text(session.title).font(.caption).lineLimit(1)
                    if block.height >= 36 {
                        Text("\(session.actualSeconds / 60) 分钟").font(.caption2).opacity(0.8)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                if session.syncState == .pending {
                    Image(systemName: "icloud.slash").font(.caption2).padding(3)
                        .help("未同步").accessibilityLabel("未同步")
                }
            }
            .frame(height: block.height)
            .foregroundStyle(.white)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { selected == session.id },
                                      set: { if !$0 { selected = nil } })) {
            SessionDetail(session: session, spans: model.spans(for: session.id))
        }
    }
}

private struct SessionDetail: View {
    let session: SessionRecord
    let spans: [ActivitySpan]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title).font(.headline)
            Text("\(session.startedAt, format: .dateTime.hour().minute())–\(session.endedAt, format: .dateTime.hour().minute())　实际 \(session.actualSeconds / 60) 分钟")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
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
