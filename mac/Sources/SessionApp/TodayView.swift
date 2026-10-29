import SwiftUI
import SessionCore

/// 今日页：中间是「今天这一页」（日期、开始面板 / 计时器、任务分组），右侧是时间轴。
struct TodayView: View {
    @EnvironmentObject var model: AppModel

    @State private var title = ""
    @State private var categoryId: String?
    /// 手动选的时长（秒）；nil 表示用分类 profile / 全局默认。
    @State private var seconds: Int?
    @State private var selectedTaskId: String? = DemoData.selectedTaskId
    /// 时间轴上点开的专注块；与选中任务互斥，底部同一时间只有一个详情面板。
    @State private var selectedSessionId: String? = DemoData.selectedSessionId
    /// 任务详情里选定的时长，时间轴预览用。
    @State private var taskSeconds: Int?
    @FocusState private var composerFocused: Bool
    @AppStorage("layout.timelineWidth") private var timelineWidth = 340.0

    private var idle: Bool { model.engine.phase == .idle }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 没手动选时长时用所选分类 profile 的时长（没有 profile 就是全局默认）。
    private var effectiveSeconds: Int { seconds ?? model.focusSeconds(for: categoryId) }
    private var selectedTask: TodoistTask? { model.tasks.first { $0.id == selectedTaskId } }
    private var selectedSession: SessionRecord? { model.todaySessions.first { $0.id == selectedSessionId } }
    private var hasPanel: Bool { selectedTask != nil || selectedSession != nil }

    private func dismissPanels() {
        guard hasPanel else { return }
        select(task: nil); select(session: nil)
    }

    private func select(task id: String?) {
        withAnimation(.easeOut(duration: 0.18)) { selectedTaskId = id; if id != nil { selectedSessionId = nil } }
    }
    private func select(session id: String?) {
        withAnimation(.easeOut(duration: 0.18)) { selectedSessionId = id; if id != nil { selectedTaskId = nil } }
    }

    var body: some View {
        HStack(spacing: 0) {
            page.frame(minWidth: 460, maxWidth: .infinity)
            ResizeHandle(width: $timelineWidth, range: 260...560, grows: -1)
            dayColumn.frame(width: timelineWidth)
        }
        .task { await model.refreshEvaluations() }
    }

    // MARK: 中间页

    private static let zh = Locale(identifier: "zh_CN")

    @ViewBuilder private var page: some View {
        if case .focusing(let run) = model.engine.phase {
            // 专注中：整块中间区域只放计时卡片，数字按可用空间放大；任务列表收起，减少干扰。
            VStack(alignment: .leading, spacing: 22) {
                header
                FocusCard(run: run, task: model.tasks.first { $0.id == run.todoistTaskId })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 28)
        } else {
            planningPage
        }
    }

    private var planningPage: some View {
        // 详情面板与上方内容同一列：同样的左右边距和 720 宽上限，靠左对齐。
        ZStack(alignment: .bottom) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if case .breaking = model.engine.phase {
                        BreakCard()
                    } else {
                        if let done = model.pendingCompletion { CompletionCard(done: done) }
                        composer
                    }
                    taskSections
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle").font(.ink(12)).foregroundStyle(Ink.now)
                    }
                }
                .padding(.horizontal, 32).padding(.top, 44)
                .padding(.bottom, hasPanel ? 340 : 32)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 点页面空白处收起底部详情（行、按钮、输入框各自的点击优先）。
                .background(Color.clear.contentShape(Rectangle()).onTapGesture { dismissPanels() })
            }
            if let task = selectedTask {
                TaskDetailPanel(task: task, category: category(of: task), canStart: idle,
                                defaultSeconds: model.focusSeconds(for: model.categoryId(for: task)),
                                onStart: { secs in model.startTask(task, seconds: secs); selectedTaskId = nil },
                                onClose: { select(task: nil) },
                                onChoose: { taskSeconds = $0 })
                    .padding(.horizontal, 32).padding(.bottom, 20)
                    .frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .leading)
            } else if let session = selectedSession {
                SessionDetailPanel(session: session, onShowTask: { select(task: $0.id) },
                                   onClose: { select(session: nil) })
                    .padding(.horizontal, 32).padding(.bottom, 20)
                    .frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        let now = Date()
        return HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(now.formatted(.dateTime.weekday(.wide).locale(Self.zh)) + " · 第 \(Calendar.current.component(.weekOfYear, from: now)) 周")
                    .font(.inkMono(11)).foregroundStyle(Ink.sub)
                Text(now.formatted(.dateTime.month().day().locale(Self.zh))).font(.ink(30, weight: .bold))
            }
            Spacer()
            Text(Ink.hm(now)).font(.inkMono(15)).foregroundStyle(Ink.sub)
        }
    }

    // MARK: 开始面板

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("接下来专注什么？", text: $title)
                .textFieldStyle(InkFieldStyle(size: 18))
                .focused($composerFocused)
                .onSubmit(start)
            HStack(spacing: 6) {
                Menu {
                    Button("无分类") { categoryId = nil; seconds = nil }
                    ForEach(model.categories) { c in Button(c.name) { categoryId = c.id; seconds = nil } }
                } label: {
                    HStack(spacing: 5) {
                        CategoryMark(color: model.category(for: categoryId).map { Color(todoistColor: $0.color) } ?? Ink.faint, size: 7)
                        Text(model.category(for: categoryId)?.name ?? "无分类").font(.inkMono(11))
                        Image(systemName: "chevron.down").font(.ink(8, weight: .bold))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Rectangle().fill(Ink.rule).frame(width: 1, height: 16).padding(.horizontal, 4)
                ForEach(durationOptions, id: \.self) { s in
                    InkChip(text: Ink.chip(s), selected: s == effectiveSeconds) { seconds = s }
                }
                Spacer(minLength: 8)
                Button(action: start) {
                    HStack(spacing: 6) { Image(systemName: "play.fill").font(.ink(10)); Text("开始专注") }
                }
                .buttonStyle(.inkPrimary)
                .disabled(trimmedTitle.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            if !model.entries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("常用").font(.inkMono(10, weight: .semibold)).tracking(1).foregroundStyle(Ink.faint)
                        ForEach(model.entries) { e in
                            InkChip(text: e.title, mark: model.category(for: e.categoryId).map { Color(todoistColor: $0.color) }) {
                                title = e.title; categoryId = e.categoryId; seconds = nil; composerFocused = true
                            }
                        }
                    }
                }
            }
        }
        .inkPanel(padding: 18)
    }

    /// 可选时长（秒）：常用四档 + 当前默认值。
    private var durationOptions: [Int] {
        Array(Set([15, 25, 45, 60].map { $0 * 60 } + [model.focusSeconds(for: categoryId)])).sorted()
    }

    private func start() {
        guard idle, !trimmedTitle.isEmpty else { return }
        model.startCustom(title: trimmedTitle, categoryId: categoryId, seconds: effectiveSeconds)
        title = ""
    }

    // MARK: 任务分组

    private var taskSections: some View {
        let groups = TaskGroups(tasks: model.tasks)
        return VStack(alignment: .leading, spacing: 22) {
            if groups.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    InkSectionHeader(text: "TODOIST")
                    Text(model.api == nil ? "未连接后端，只能使用上面的自定义专注。" : "今天没有任务。")
                        .font(.ink(13)).foregroundStyle(Ink.sub).padding(.top, 6)
                }
            }
            section("已排期", groups.scheduled)
            section("今天", groups.today)
            section("过期", groups.overdue, overdue: true)
        }
    }

    @ViewBuilder private func section(_ name: String, _ tasks: [TodoistTask], overdue: Bool = false) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                InkSectionHeader(text: name, count: tasks.count)
                VStack(spacing: 0) {
                    ForEach(tasks) { task in TaskRow(task: task, overdue: overdue) }
                }
            }
        }
    }

    private func category(of task: TodoistTask) -> Category? {
        model.categories.first { $0.todoistProjectId == task.projectId }
    }

    @ViewBuilder private func TaskRow(task: TodoistTask, overdue: Bool) -> some View {
        let cat = category(of: task)
        let selected = selectedTaskId == task.id
        HStack(spacing: 12) {
            Text(timeLabel(task, overdue: overdue))
                .font(.inkMono(12)).foregroundStyle(overdue ? Ink.now : Ink.sub)
                .frame(width: 44, alignment: .leading)
            CategoryMark(color: cat.map { Color(todoistColor: $0.color) } ?? Ink.faint, size: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.content).font(.ink(13.5, weight: .medium)).lineLimit(1)
                Text(meta(task, cat)).font(.inkMono(10.5)).foregroundStyle(Ink.sub).lineLimit(1)
            }
            Spacer(minLength: 8)
            if task.priority >= 3 {
                Text("P\(5 - task.priority)").font(.inkMono(10, weight: .bold))
                    .foregroundStyle(task.priority == 4 ? Ink.now : Ink.sub)
            }
            Button { model.startTask(task, seconds: task.durationMinutes.map { max(1, $0) * 60 }) } label: {
                Image(systemName: "play.fill").font(.ink(9))
            }
            .buttonStyle(InkButtonStyle(compact: true))
            .disabled(!idle)
            .help("开始专注")
            .accessibilityLabel("开始专注：\(task.content)")
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .contentShape(Rectangle())
        .hoverRow(selected: selected)
        .overlay(alignment: .bottom) { if !selected { Rectangle().fill(Ink.ruleSoft).frame(height: 1) } }
        .onTapGesture { select(task: selected ? nil : task.id) }
    }

    private func timeLabel(_ task: TodoistTask, overdue: Bool) -> String {
        if let t = task.dueTime, !overdue { return Ink.hm(t) }
        if overdue, let d = task.dueDate, d.count >= 10 {
            return String(d.dropFirst(5).prefix(5)).replacingOccurrences(of: "-", with: "/")
        }
        return "—"
    }

    private func meta(_ task: TodoistTask, _ cat: Category?) -> String {
        var parts: [String] = []
        if let cat { parts.append(cat.name) }
        if let m = task.durationMinutes { parts.append("\(m)m") }
        if task.isRecurring { parts.append("重复") }
        parts += task.labels.map { "@\($0)" }
        return parts.joined(separator: " · ")
    }

    // MARK: 时间轴列

    private var dayColumn: some View {
        VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text("时间轴").font(.ink(13, weight: .semibold))
                Spacer()
                legend(dashed: true, "计划")
                legend(dashed: false, "实际")
            }
            .padding(.horizontal, 16).padding(.top, 46).padding(.bottom, 12)
            Rectangle().fill(Ink.rule).frame(height: 1)
            FocusTimelineView(sessions: model.todaySessions,
                              tasks: model.tasks,
                              selectedTaskId: selectedTaskId, selectedSessionId: selectedSessionId,
                              ghost: ghost,
                              onSelectTask: { select(task: $0.id) },
                              onSelectSession: { s in select(session: selectedSessionId == s.id ? nil : s.id) })
        }
        .background(Ink.shelf)
    }

    /// 专注中：进行中的这一段；空闲：现在开始的话会占到哪（选中任务时按任务详情里的时长）。
    private var ghost: TimelineGhost? {
        switch model.engine.phase {
        case .focusing(let run): return .running(run)
        case .idle:
            if let task = selectedTask {
                return .next(title: task.content,
                             seconds: taskSeconds ?? model.focusSeconds(for: model.categoryId(for: task)))
            }
            return .next(title: trimmedTitle.isEmpty ? "下一次专注" : trimmedTitle, seconds: effectiveSeconds)
        default: return nil
        }
    }

    private func legend(dashed: Bool, _ text: String) -> some View {
        HStack(spacing: 5) {
            Group {
                if dashed {
                    Rectangle().strokeBorder(Ink.ink, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                } else {
                    Rectangle().fill(Ink.highlight)
                }
            }
            .frame(width: 10, height: 10)
            Text(text).font(.inkMono(10)).foregroundStyle(Ink.sub)
        }
        .padding(.leading, 8)
    }
}

/// 任务按「已排期（今天带时间）/ 今天（只有日期）/ 过期」分组。
private struct TaskGroups {
    var scheduled: [TodoistTask] = []
    var today: [TodoistTask] = []
    var overdue: [TodoistTask] = []
    var isEmpty: Bool { scheduled.isEmpty && today.isEmpty && overdue.isEmpty }

    init(tasks: [TodoistTask], now: Date = Date(), calendar: Calendar = .current) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let todayString = f.string(from: now)
        let startOfToday = calendar.startOfDay(for: now)
        for t in tasks {
            if let time = t.dueTime {
                if time < startOfToday { overdue.append(t) }
                else if calendar.isDateInToday(time) { scheduled.append(t) }
                else { today.append(t) }
            } else if let d = t.dueDate, String(d.prefix(10)) < todayString {
                overdue.append(t)
            } else {
                today.append(t)
            }
        }
        scheduled.sort { ($0.dueTime ?? .distantPast) < ($1.dueTime ?? .distantPast) }
        today.sort { $0.priority > $1.priority }
    }
}

// MARK: 计时卡片

private struct FocusCard: View {
    @EnvironmentObject var model: AppModel
    let run: FocusRun
    let task: TodoistTask?

    var body: some View {
        let remaining = model.engine.remainingSeconds
        let progress = 1 - Double(remaining) / Double(max(run.plannedSeconds, 1))
        let cat = model.category(for: run.categoryId)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Rectangle().fill(Ink.highlight).frame(width: 8, height: 8)
                Text(model.isOvertime ? "已超时" : "专注中").font(.inkMono(11, weight: .semibold)).tracking(1.2)
                if let cat {
                    Text("·").foregroundStyle(Ink.faint)
                    CategoryMark(color: Color(todoistColor: cat.color), size: 7)
                    Text(cat.name).font(.inkMono(11)).foregroundStyle(Ink.sub)
                }
                Spacer()
                Text("\(Ink.hm(run.startedAt)) → \(Ink.hm(run.endAt))").font(.inkMono(11)).foregroundStyle(Ink.sub)
            }
            Text(run.title).font(.ink(28, weight: .semibold)).lineLimit(2)
            // 数字先按很大的字号排，再按卡片剩余的宽高缩到刚好放下。
            Text(model.timerText)
                .foregroundStyle(model.isOvertime ? Ink.now : Ink.ink)
                .font(.ink(320, weight: .regular))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.15)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            ProgressRule(progress: progress, minutes: run.plannedSeconds / 60)
            HStack(spacing: 8) {
                FocusAdjustButtons()
                Button { model.finishEarly() } label: {
                    HStack(spacing: 5) { Image(systemName: "checkmark").font(.ink(10, weight: .bold)); Text(model.isOvertime ? "完成" : "提前完成") }
                }
                .buttonStyle(.inkPrimary)
                .help(model.isOvertime ? "结束并记录这次专注（含超时）" : "现在结束并记录这次专注，休息时长不变")
                Spacer()
                Button("放弃") { model.abandon() }.buttonStyle(.ink).help("放弃这次专注，不记录")
            }
            if model.accessibilityMissing {
                Text("未授权辅助功能：只按 App 记录").font(.inkMono(10)).foregroundStyle(Ink.now)
            }
            if let task, !task.description.isEmpty {
                Rectangle().fill(Ink.rule).frame(height: 1)
                Text((try? AttributedString(markdown: task.description,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                     ?? AttributedString(task.description))
                    .font(.ink(13)).foregroundStyle(Ink.sub).lineLimit(4)
            }
        }
        .inkPanel(padding: 28)
    }
}

/// 进度尺：每分钟一个刻度，每 5 分钟长刻度，已过部分用荧光笔涂满。
struct ProgressRule: View {
    let progress: Double
    let minutes: Int

    var body: some View {
        Canvas { ctx, size in
            let barH: CGFloat = 12
            let filled = CGRect(x: 0, y: 0, width: size.width * min(max(progress, 0), 1), height: barH)
            ctx.fill(Path(filled), with: .color(Ink.highlight))
            ctx.stroke(Path(CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: barH - 1)), with: .color(Ink.ink), lineWidth: 1)
            let n = max(minutes, 1)
            for i in 0...n {
                let x = size.width * CGFloat(i) / CGFloat(n)
                let long = i % 5 == 0
                var p = Path()
                p.move(to: CGPoint(x: x, y: barH + 2)); p.addLine(to: CGPoint(x: x, y: barH + (long ? 9 : 5)))
                ctx.stroke(p, with: .color(long ? Ink.sub : Ink.faint), lineWidth: 1)
            }
        }
        .frame(height: 24)
        .accessibilityLabel("已完成 \(Int(progress * 100))%")
    }
}

private struct BreakCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("休息中").font(.inkMono(11, weight: .semibold)).tracking(1.2).foregroundStyle(Ink.sub)
            Text(model.timerText)
                .font(.ink(72, weight: .regular)).monospacedDigit()
                .foregroundStyle(model.isOvertime ? Ink.now : Ink.ink)
            Button("结束休息") { model.endBreak() }.buttonStyle(.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkPanel(padding: 22)
    }
}

private struct CompletionCard: View {
    @EnvironmentObject var model: AppModel
    let done: CompletedFocus
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark").font(.ink(13, weight: .bold))
                .foregroundStyle(Ink.onHighlight)
                .frame(width: 26, height: 26).background(Ink.highlight)
            VStack(alignment: .leading, spacing: 2) {
                Text(done.run.title).font(.ink(14, weight: .semibold)).lineLimit(1)
                Text("完成 \(done.actualSeconds / 60) 分钟 · \(Ink.hm(done.run.startedAt))–\(Ink.hm(done.endedAt))")
                    .font(.inkMono(11)).foregroundStyle(Ink.sub)
            }
            Spacer()
            Button("\(model.engine.suggestedBreak == .long ? "长休" : "休息") \(model.suggestedBreakSeconds / 60) 分钟") { model.startBreak() }
                .buttonStyle(.ink)
            Button("好") { model.dismissCompletion() }.buttonStyle(.inkPrimary)
        }
        .inkPanel(padding: 14, shadow: false)
    }
}

/// 菜单栏面板也用的完成横幅。
struct CompletionBanner: View {
    @EnvironmentObject var model: AppModel
    let done: CompletedFocus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("✓ 完成：\(done.run.title)").font(.ink(13, weight: .semibold)).lineLimit(2)
            HStack {
                Button("开始\(model.engine.suggestedBreak == .long ? "长休" : "休息") \(model.suggestedBreakSeconds / 60) 分钟") { model.startBreak() }
                    .buttonStyle(InkButtonStyle(compact: true))
                Button("结束") { model.dismissCompletion() }.buttonStyle(InkButtonStyle(kind: .primary, compact: true))
            }
        }
    }
}

/// 「−5 / +5」分钟，主窗口与菜单栏面板共用。剩余不足 6 分钟时 −5 变灰（引擎会停在 1 分钟）。
struct FocusAdjustButtons: View {
    @EnvironmentObject var model: AppModel
    var compact = false

    var body: some View {
        HStack(spacing: 0) {
            Button { model.adjust(minutes: -5) } label: { Text("−5").frame(minWidth: compact ? 26 : 34) }
                .disabled(model.engine.remainingSeconds <= 6 * 60)
                .help("减少 5 分钟")
            Rectangle().fill(Ink.ink.opacity(0.7)).frame(width: 1)
            Button { model.adjust(minutes: 5) } label: { Text("+5").frame(minWidth: compact ? 26 : 34) }
                .help("增加 5 分钟")
        }
        .buttonStyle(InkButtonStyle(kind: .quiet, compact: compact))
        .font(.inkMono(compact ? 11 : 12, weight: .semibold))
        .overlay(Rectangle().strokeBorder(Ink.ink.opacity(0.7), lineWidth: 1))
        .fixedSize()
    }
}
