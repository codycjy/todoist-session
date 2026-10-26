import SwiftUI
import SessionCore

/// 今日页：中间是「今天这一页」（日期、开始面板 / 计时器、任务分组），右侧是时间轴。
struct TodayView: View {
    @EnvironmentObject var model: AppModel
    /// 侧栏选中某个项目时只显示该项目的任务。
    var projectFilter: String?

    @State private var title = ""
    @State private var categoryId: String?
    @State private var minutes: Int?
    @State private var selectedTaskId: String? = DemoData.selectedTaskId
    @FocusState private var composerFocused: Bool

    private var idle: Bool { model.engine.phase == .idle }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var effectiveMinutes: Int { minutes ?? model.defaultFocusSeconds / 60 }
    private var selectedTask: TodoistTask? { model.tasks.first { $0.id == selectedTaskId } }

    var body: some View {
        HStack(spacing: 0) {
            page.frame(minWidth: 460, maxWidth: .infinity)
            Rectangle().fill(Ink.rule).frame(width: 1)
            dayColumn.frame(width: 340)
        }
        .task { await model.refreshEvaluations() }
    }

    // MARK: 中间页

    private static let zh = Locale(identifier: "zh_CN")

    private var page: some View {
        ZStack(alignment: .bottom) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    switch model.engine.phase {
                    case .focusing(let run): FocusCard(run: run, task: model.tasks.first { $0.id == run.todoistTaskId })
                    case .breaking: BreakCard()
                    case .idle:
                        if let done = model.pendingCompletion { CompletionCard(done: done) }
                        composer
                    }
                    taskSections
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Ink.now)
                    }
                }
                .padding(.horizontal, 32).padding(.top, 44)
                .padding(.bottom, selectedTask == nil ? 32 : 300)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let task = selectedTask {
                TaskDetailPanel(task: task, category: category(of: task), canStart: idle,
                                defaultMinutes: model.defaultFocusSeconds / 60,
                                onStart: { secs in model.startTask(task, seconds: secs); selectedTaskId = nil },
                                onClose: { withAnimation(.easeOut(duration: 0.18)) { selectedTaskId = nil } })
                    .padding(.horizontal, 28).padding(.bottom, 20)
                    .frame(maxWidth: 720)
            }
        }
    }

    private var header: some View {
        let now = Date()
        return HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(now.formatted(.dateTime.weekday(.wide).locale(Self.zh)) + " · 第 \(Calendar.current.component(.weekOfYear, from: now)) 周")
                    .font(.inkMono(11)).foregroundStyle(Ink.sub)
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(now.formatted(.dateTime.month().day().locale(Self.zh))).font(.system(size: 30, weight: .bold))
                    if let p = projectFilter, let c = model.categories.first(where: { $0.todoistProjectId == p }) {
                        HStack(spacing: 6) {
                            CategoryMark(color: Color(todoistColor: c.color), size: 9)
                            Text(c.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.sub)
                        }
                    }
                }
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
                    Button("无分类") { categoryId = nil }
                    ForEach(model.categories) { c in Button(c.name) { categoryId = c.id } }
                } label: {
                    HStack(spacing: 5) {
                        CategoryMark(color: model.category(for: categoryId).map { Color(todoistColor: $0.color) } ?? Ink.faint, size: 7)
                        Text(model.category(for: categoryId)?.name ?? "无分类").font(.inkMono(11))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Rectangle().fill(Ink.rule).frame(width: 1, height: 16).padding(.horizontal, 4)
                ForEach(durationOptions, id: \.self) { m in
                    InkChip(text: "\(m)m", selected: m == effectiveMinutes) { minutes = m }
                }
                Spacer(minLength: 8)
                Button(action: start) {
                    HStack(spacing: 6) { Image(systemName: "play.fill").font(.system(size: 10)); Text("开始专注") }
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
                                title = e.title; categoryId = e.categoryId; composerFocused = true
                            }
                        }
                    }
                }
            }
        }
        .inkPanel(padding: 18)
    }

    private var durationOptions: [Int] {
        var opts = [15, 25, 45, 60]
        let d = model.defaultFocusSeconds / 60
        if !opts.contains(d) { opts.append(d); opts.sort() }
        return opts
    }

    private func start() {
        guard idle, !trimmedTitle.isEmpty else { return }
        model.startCustom(title: trimmedTitle, categoryId: categoryId, seconds: effectiveMinutes * 60)
        title = ""
    }

    // MARK: 任务分组

    private var taskSections: some View {
        let groups = TaskGroups(tasks: model.tasks.filter { projectFilter == nil || $0.projectId == projectFilter })
        return VStack(alignment: .leading, spacing: 22) {
            if groups.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    InkSectionHeader(text: "TODOIST")
                    Text(model.api == nil ? "未连接后端，只能使用上面的自定义专注。" : "今天没有任务。")
                        .font(.system(size: 13)).foregroundStyle(Ink.sub).padding(.top, 6)
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
                Text(task.content).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Text(meta(task, cat)).font(.inkMono(10.5)).foregroundStyle(Ink.sub).lineLimit(1)
            }
            Spacer(minLength: 8)
            if task.priority >= 3 {
                Text("P\(5 - task.priority)").font(.inkMono(10, weight: .bold))
                    .foregroundStyle(task.priority == 4 ? Ink.now : Ink.sub)
            }
            Button { model.startTask(task, seconds: task.durationMinutes.map { max(1, $0) * 60 }) } label: {
                Image(systemName: "play.fill").font(.system(size: 9))
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
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.18)) { selectedTaskId = selected ? nil : task.id }
        }
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
                Text("时间轴").font(.system(size: 13, weight: .semibold))
                Spacer()
                legend(dashed: true, "计划")
                legend(dashed: false, "实际")
            }
            .padding(.horizontal, 16).padding(.top, 46).padding(.bottom, 12)
            Rectangle().fill(Ink.rule).frame(height: 1)
            FocusTimelineView(sessions: model.todaySessions,
                              tasks: model.tasks.filter { projectFilter == nil || $0.projectId == projectFilter },
                              selectedTaskId: selectedTaskId) { task in
                withAnimation(.easeOut(duration: 0.18)) { selectedTaskId = task.id }
            }
        }
        .background(Ink.shelf)
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
                Text("专注中").font(.inkMono(11, weight: .semibold)).tracking(1.2)
                if let cat {
                    Text("·").foregroundStyle(Ink.faint)
                    CategoryMark(color: Color(todoistColor: cat.color), size: 7)
                    Text(cat.name).font(.inkMono(11)).foregroundStyle(Ink.sub)
                }
                Spacer()
                Text("\(Ink.hm(run.startedAt)) → \(Ink.hm(run.endAt))").font(.inkMono(11)).foregroundStyle(Ink.sub)
            }
            Text(run.title).font(.system(size: 22, weight: .semibold)).lineLimit(2)
            Text(AppModel.format(remaining))
                .font(.system(size: 96, weight: .light, design: .monospaced))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            ProgressRule(progress: progress, minutes: run.plannedSeconds / 60)
            HStack {
                Button("放弃（不记录）") { model.abandon() }.buttonStyle(.ink)
                Spacer()
                if model.accessibilityMissing {
                    Text("未授权辅助功能：只按 App 记录").font(.inkMono(10)).foregroundStyle(Ink.now)
                }
            }
            if let task, !task.description.isEmpty {
                Rectangle().fill(Ink.rule).frame(height: 1)
                Text((try? AttributedString(markdown: task.description,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                     ?? AttributedString(task.description))
                    .font(.system(size: 12.5)).foregroundStyle(Ink.sub).lineLimit(4)
            }
        }
        .inkPanel(padding: 22)
    }
}

/// 进度尺：每分钟一个刻度，每 5 分钟长刻度，已过部分用荧光笔涂满。
private struct ProgressRule: View {
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
            Text(AppModel.format(model.engine.remainingSeconds))
                .font(.system(size: 72, weight: .light, design: .monospaced)).monospacedDigit()
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
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                .foregroundStyle(Ink.onHighlight)
                .frame(width: 26, height: 26).background(Ink.highlight)
            VStack(alignment: .leading, spacing: 2) {
                Text(done.run.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("完成 \(done.actualSeconds / 60) 分钟 · \(Ink.hm(done.run.startedAt))–\(Ink.hm(done.endedAt))")
                    .font(.inkMono(11)).foregroundStyle(Ink.sub)
            }
            Spacer()
            Button(model.engine.suggestedBreak == .long ? "长休 15 分钟" : "休息 5 分钟") { model.startBreak() }
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
            Text("✓ 完成：\(done.run.title)").font(.system(size: 13, weight: .semibold)).lineLimit(2)
            HStack {
                Button(model.engine.suggestedBreak == .long ? "开始长休 15 分钟" : "开始休息 5 分钟") { model.startBreak() }
                    .buttonStyle(InkButtonStyle(compact: true))
                Button("结束") { model.dismissCompletion() }.buttonStyle(InkButtonStyle(kind: .primary, compact: true))
            }
        }
    }
}
