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
    /// 编辑模式：标题、分类与实际时长（分钟）的草稿。
    @State private var editing = false
    @State private var draftTitle = ""
    @State private var draftCategoryId: String?
    @State private var draftMinutes = 0
    @State private var confirmingDelete = false

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
        .onChange(of: session.id) { _, _ in showAllSpans = false; editing = false }
        .confirmationDialog("删除这次专注？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { model.deleteSession(session.id); onClose() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「\(session.title)」和它的活动记录会从本机和后端一起删除，统计里也不再计入。")
        }
        .onAppear { if DemoData.editsSession { beginEdit() } }
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
                    IdleToggle(isOn: Binding(get: { session.allowIdle },
                                             set: { model.setAllowIdle($0, forSession: session.id) }))
                    Text(session.syncState == .pending ? "未同步" : "已同步").font(.inkMono(11))
                        .foregroundStyle(session.syncState == .pending ? Ink.now : Ink.faint)
                    if let task, let onShowTask {
                        Button { onShowTask(task) } label: {
                            HStack(spacing: 3) { Text("Todoist 任务"); Image(systemName: "arrow.right") }
                        }
                        .buttonStyle(.plain).font(.inkMono(11)).foregroundStyle(Ink.sub)
                    }
                }
                if editing {
                    editor
                } else {
                    Text(session.title).font(.ink(19, weight: .semibold))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 18) {
                        fact("时间", "\(Ink.hm(session.startedAt))–\(Ink.hm(session.endedAt))")
                        fact("实际", Ink.duration(session.actualSeconds))
                        fact("计划", Ink.duration(session.plannedSeconds))
                        if let blocked = blockedCount, blocked > 0 { fact("拦截", "\(blocked) 次") }
                    }
                }
            }
            Spacer(minLength: 8)
            scoreBox
            if !editing {
                Button(action: beginEdit) { Image(systemName: "pencil").font(.ink(12, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Ink.sub)
                    .help("编辑标题、分类和时长")
                    .accessibilityLabel("编辑")
            }
            Button(action: onClose) { Image(systemName: "xmark").font(.ink(11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Ink.sub)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭")
        }
    }

    // MARK: 编辑

    private func beginEdit() {
        draftTitle = session.title
        draftCategoryId = session.categoryId
        draftMinutes = max(1, Int((Double(session.actualSeconds) / 60).rounded()))
        editing = true
    }

    private var canSave: Bool { !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func save() {
        guard canSave else { return }
        model.editSession(session.id, title: draftTitle, categoryId: draftCategoryId, actualSeconds: min(max(draftMinutes, 1), 600) * 60)
        editing = false
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("标题", text: $draftTitle)
                .textFieldStyle(InkFieldStyle(size: 16))
                .onSubmit(save)
            HStack(spacing: 12) {
                Text("分类").font(.inkMono(10)).foregroundStyle(Ink.faint).fixedSize()
                categoryPicker
            }
            HStack(spacing: 12) {
                Text("实际").font(.inkMono(10)).foregroundStyle(Ink.faint).fixedSize()
                HStack(spacing: 0) {
                    Button { draftMinutes = max(1, draftMinutes - 5) } label: { Text("−5").frame(minWidth: 30) }
                    Rectangle().fill(Ink.ink.opacity(0.7)).frame(width: 1)
                    TextField("", value: $draftMinutes, format: .number)
                        .textFieldStyle(.plain).font(.inkMono(14, weight: .medium))
                        .multilineTextAlignment(.center).frame(width: 52)
                        .onSubmit(save)
                    Rectangle().fill(Ink.ink.opacity(0.7)).frame(width: 1)
                    Button { draftMinutes = min(600, draftMinutes + 5) } label: { Text("+5").frame(minWidth: 30) }
                }
                .buttonStyle(InkButtonStyle(kind: .quiet, compact: true))
                .font(.inkMono(11, weight: .semibold))
                .overlay(Rectangle().strokeBorder(Ink.ink.opacity(0.7), lineWidth: 1))
                .fixedSize()
                Text("分钟").font(.ink(11)).foregroundStyle(Ink.sub).fixedSize()
                Text("\(Ink.hm(session.startedAt))–\(Ink.hm(session.startedAt.addingTimeInterval(TimeInterval(draftMinutes * 60))))")
                    .font(.inkMono(11)).foregroundStyle(Ink.sub).fixedSize()
            }
            HStack(alignment: .top, spacing: 12) {
                Text("开始时间不变；缩短时会裁掉之后的活动记录。改完会重新同步，已有评估不会自动重算（改「可闲置」会）。")
                    .font(.ink(11)).foregroundStyle(Ink.sub).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { confirmingDelete = true } label: { Text("删除").foregroundStyle(Ink.now) }
                    .buttonStyle(InkButtonStyle(kind: .quiet, compact: true)).fixedSize()
                Button("取消") { editing = false }.buttonStyle(InkButtonStyle(compact: true)).fixedSize()
                Button("保存", action: save).buttonStyle(InkButtonStyle(kind: .primary, compact: true)).fixedSize()
                    .disabled(!canSave)
            }
        }
    }

    /// 可选分类：未归档的分类；原分类已归档时也保留在列表里，免得一打开编辑就被换掉。
    private var categoryChoices: [Category] {
        var list = model.categories
        if let id = session.categoryId, !list.contains(where: { $0.id == id }), let old = model.category(for: id) {
            list.append(old)
        }
        return list
    }

    private var categoryPicker: some View {
        Menu {
            Button("无分类") { draftCategoryId = nil }
            ForEach(categoryChoices) { c in Button(c.name) { draftCategoryId = c.id } }
        } label: {
            HStack(spacing: 5) {
                CategoryMark(color: model.category(for: draftCategoryId).map { Color(todoistColor: $0.color) } ?? Ink.faint, size: 7)
                Text(model.category(for: draftCategoryId)?.name ?? "无分类").font(.inkMono(11))
                Image(systemName: "chevron.down").font(.ink(8, weight: .bold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    /// 评分方块：完成时荧光黄底大号数字，其余状态是细框小字。
    @ViewBuilder private var scoreBox: some View {
        VStack(spacing: 2) {
            switch evaluation?.status {
            case .done?:
                Text(evaluation?.focusScore.map(String.init) ?? "—").font(.inkMono(28, weight: .semibold))
                Text("专注度").font(.ink(10))
            case .pending?:
                Text("…").font(.inkMono(22))
                Text("评估中").font(.ink(10))
            case .failed?:
                Text("!").font(.inkMono(22, weight: .bold))
                Text("评估失败").font(.ink(10))
            case nil:
                Text("—").font(.inkMono(22))
                Text("未评估").font(.ink(10))
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
                Text(evaluation?.summary ?? "（没有摘要）").font(.ink(13)).lineSpacing(3)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let ds = evaluation?.distractions, !ds.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(ds.enumerated()), id: \.offset) { _, d in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(Ink.hm(d.start))–\(Ink.hm(d.end))").font(.inkMono(11)).foregroundStyle(Ink.now)
                                    .frame(width: 92, alignment: .leading)
                                Text(d.reason).font(.ink(12)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Ink.now).frame(width: 2) }
                }
            case .pending?:
                Text("评估中，完成后会自动更新。").font(.ink(12.5)).foregroundStyle(Ink.sub)
            case .failed?:
                HStack {
                    Text("评估失败（已尝试 \(evaluation?.attempts ?? 0) 次）").font(.ink(12.5)).foregroundStyle(Ink.sub)
                    Spacer()
                    Button("重新评估") { Task { await model.retryEvaluation(sessionId: session.id) } }
                        .buttonStyle(InkButtonStyle(compact: true))
                }
            case nil:
                Text(session.syncState == .pending ? "同步到后端后才会评估。" : "没有评估记录。")
                    .font(.ink(12.5)).foregroundStyle(Ink.sub)
            }
        }
    }

    // MARK: 各 App 用时

    private struct Usage: Identifiable { let id: String; let seconds: TimeInterval; let idle: Bool; let blocked: Bool }

    private var usageRows: [Usage] {
        var sums: [String: (TimeInterval, Bool, Bool)] = [:]
        for s in spans {
            let name = s.kind == .idle ? idleName : (s.appName ?? "未知")
            let prev = sums[name] ?? (0, s.kind == .idle, false)
            sums[name] = (prev.0 + s.duration, prev.1, prev.2 || s.wasBlocked)
        }
        return sums.map { Usage(id: $0.key, seconds: $0.value.0, idle: $0.value.1, blocked: $0.value.2) }
            .sorted { $0.seconds > $1.seconds }
    }

    /// 可闲置的专注里，闲置多半是离开电脑在做事。
    private var idleName: String { session.allowIdle ? "离开电脑" : "闲置" }

    private var blockedCount: Int? { spans.isEmpty ? nil : spans.filter(\.wasBlocked).count }

    @ViewBuilder private var usage: some View {
        VStack(alignment: .leading, spacing: 8) {
            InkSectionHeader(text: "应用用时")
            if spans.isEmpty {
                Text("没有采集到活动（可能未授权辅助功能）").font(.ink(12.5)).foregroundStyle(Ink.sub)
            } else {
                let rows = usageRows
                let top = rows.first?.seconds ?? 1
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            Text(row.id).font(.ink(12)).lineLimit(1)
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
                    Text(detail(span)).font(.ink(12)).lineLimit(1).truncationMode(.middle)
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
        if span.kind == .idle { return idleName }
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
