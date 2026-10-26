import SwiftUI
import SessionCore

/// 点时间轴上的专注块后从底部弹出的复盘：评分、AI 摘要（digest）、偏离片段、各 App 用时、活动明细。
/// 与 `TaskDetailPanel` 同一套面板样式；内容多时在面板内部滚动。
struct SessionDetailPanel: View {
    @EnvironmentObject var model: AppModel
    let session: SessionRecord
    /// 来源 Todoist 任务仍在今日列表里时可以跳过去看任务详情。
    var onShowTask: ((TodoistTask) -> Void)?
    let onClose: () -> Void

    @State private var showAllSpans = false

    private var evaluation: Evaluation? { model.evaluations[session.id] }
    private var spans: [ActivitySpan] { model.spans(for: session.id) }
    private var task: TodoistTask? { session.todoistTaskId.flatMap { id in model.tasks.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 12)
            Rectangle().fill(Ink.rule).frame(height: 1)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    digest
                    usage
                    if !spans.isEmpty { timeline }
                }
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
        .inkPanel(padding: 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onChange(of: session.id) { _, _ in showAllSpans = false }
    }

    // MARK: 头部：分类、同步状态、标题、时间与评分

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let cat = model.category(for: session.categoryId) {
                        HStack(spacing: 5) {
                            CategoryMark(color: Color(todoistColor: cat.color), size: 7)
                            Text(cat.name).font(.inkMono(11)).foregroundStyle(Ink.sub)
                        }
                    }
                    Text(session.syncState == .pending ? "未同步" : "已同步").font(.inkMono(11))
                        .foregroundStyle(session.syncState == .pending ? Ink.now : Ink.faint)
                    if let task, let onShowTask {
                        Button { onShowTask(task) } label: {
                            HStack(spacing: 3) { Text("Todoist 任务"); Image(systemName: "arrow.right") }
                        }
                        .buttonStyle(.plain).font(.inkMono(11)).foregroundStyle(Ink.sub)
                    }
                }
                Text(session.title).font(.system(size: 19, weight: .semibold))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    fact("时间", "\(Ink.hm(session.startedAt))–\(Ink.hm(session.endedAt))")
                    fact("实际", Ink.duration(session.actualSeconds))
                    fact("计划", Ink.duration(session.plannedSeconds))
                    if let blocked = blockedCount, blocked > 0 { fact("拦截", "\(blocked) 次") }
                }
            }
            Spacer(minLength: 8)
            scoreBox
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Ink.sub)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭")
        }
    }

    /// 评分方块：完成时荧光黄底大号数字，其余状态是细框小字。
    @ViewBuilder private var scoreBox: some View {
        VStack(spacing: 2) {
            switch evaluation?.status {
            case .done?:
                Text(evaluation?.focusScore.map(String.init) ?? "—").font(.inkMono(28, weight: .semibold))
                Text("专注度").font(.system(size: 10))
            case .pending?:
                Text("…").font(.inkMono(22))
                Text("评估中").font(.system(size: 10))
            case .failed?:
                Text("!").font(.inkMono(22, weight: .bold))
                Text("评估失败").font(.system(size: 10))
            case nil:
                Text("—").font(.inkMono(22))
                Text("未评估").font(.system(size: 10))
            }
        }
        .frame(width: 72, height: 64)
        .foregroundStyle(evaluation?.status == .done ? Ink.onHighlight : Ink.sub)
        .background(evaluation?.status == .done ? Ink.highlight : Color.clear)
        .overlay(Rectangle().strokeBorder(evaluation?.status == .done ? Ink.ink : Ink.rule, lineWidth: 1))
    }

    // MARK: 摘要

    @ViewBuilder private var digest: some View {
        VStack(alignment: .leading, spacing: 8) {
            InkSectionHeader(text: "摘要")
            switch evaluation?.status {
            case .done?:
                Text(evaluation?.summary ?? "（没有摘要）").font(.system(size: 13)).lineSpacing(3)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let ds = evaluation?.distractions, !ds.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(ds.enumerated()), id: \.offset) { _, d in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(Ink.hm(d.start))–\(Ink.hm(d.end))").font(.inkMono(11)).foregroundStyle(Ink.now)
                                    .frame(width: 92, alignment: .leading)
                                Text(d.reason).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Ink.now).frame(width: 2) }
                }
            case .pending?:
                Text("评估中，完成后会自动更新。").font(.system(size: 12.5)).foregroundStyle(Ink.sub)
            case .failed?:
                HStack {
                    Text("评估失败（已尝试 \(evaluation?.attempts ?? 0) 次）").font(.system(size: 12.5)).foregroundStyle(Ink.sub)
                    Spacer()
                    Button("重新评估") { Task { await model.retryEvaluation(sessionId: session.id) } }
                        .buttonStyle(InkButtonStyle(compact: true))
                }
            case nil:
                Text(session.syncState == .pending ? "同步到后端后才会评估。" : "没有评估记录。")
                    .font(.system(size: 12.5)).foregroundStyle(Ink.sub)
            }
        }
    }

    // MARK: 各 App 用时

    private struct Usage: Identifiable { let id: String; let seconds: TimeInterval; let idle: Bool; let blocked: Bool }

    private var usageRows: [Usage] {
        var sums: [String: (TimeInterval, Bool, Bool)] = [:]
        for s in spans {
            let name = s.kind == .idle ? "闲置" : (s.appName ?? "未知")
            let prev = sums[name] ?? (0, s.kind == .idle, false)
            sums[name] = (prev.0 + s.duration, prev.1, prev.2 || s.wasBlocked)
        }
        return sums.map { Usage(id: $0.key, seconds: $0.value.0, idle: $0.value.1, blocked: $0.value.2) }
            .sorted { $0.seconds > $1.seconds }
    }

    private var blockedCount: Int? { spans.isEmpty ? nil : spans.filter(\.wasBlocked).count }

    @ViewBuilder private var usage: some View {
        VStack(alignment: .leading, spacing: 8) {
            InkSectionHeader(text: "应用用时")
            if spans.isEmpty {
                Text("没有采集到活动（可能未授权辅助功能）").font(.system(size: 12.5)).foregroundStyle(Ink.sub)
            } else {
                let rows = usageRows
                let top = rows.first?.seconds ?? 1
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            Text(row.id).font(.system(size: 12)).lineLimit(1)
                                .foregroundStyle(row.blocked ? Ink.now : row.idle ? Ink.sub : Ink.ink)
                                .frame(width: 120, alignment: .leading)
                            GeometryReader { geo in
                                Rectangle().fill(row.idle ? Ink.rule : row.blocked ? Ink.now : Ink.ink)
                                    .frame(width: max(2, geo.size.width * row.seconds / max(top, 1)))
                            }
                            .frame(height: 8)
                            Text(Ink.duration(Int(row.seconds))).font(.inkMono(11)).foregroundStyle(Ink.sub)
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: 活动明细

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                InkSectionHeader(text: "活动明细", count: spans.count)
            }
            let shown = showAllSpans ? spans : Array(spans.prefix(6))
            ForEach(shown) { span in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(Self.hms(span.startedAt))").font(.inkMono(11)).foregroundStyle(Ink.sub)
                        .frame(width: 60, alignment: .leading)
                    Text(detail(span)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(span.wasBlocked ? Ink.now : span.kind == .idle ? Ink.sub : Ink.ink)
                    Spacer(minLength: 6)
                    Text(Ink.duration(Int(span.duration))).font(.inkMono(11)).foregroundStyle(Ink.faint)
                }
            }
            if spans.count > 6 {
                Button(showAllSpans ? "收起" : "展开全部 \(spans.count) 条") { showAllSpans.toggle() }
                    .buttonStyle(.inkQuiet).foregroundStyle(Ink.sub)
            }
        }
    }

    private func detail(_ span: ActivitySpan) -> String {
        if span.kind == .idle { return "闲置" }
        let extra = [span.urlHost, span.windowTitle].compactMap { $0 }.first
        let base = [span.appName ?? "未知", extra].compactMap { $0 }.joined(separator: " — ")
        return span.wasBlocked ? "\(base)（已拦截）" : base
    }

    private func fact(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.inkMono(10)).foregroundStyle(Ink.faint)
            Text(value).font(.inkMono(12))
        }
    }

    private static func hms(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
