import SwiftUI
import SessionCore

struct TodayView: View {
    @EnvironmentObject var model: AppModel
    @State private var title = ""
    @State private var categoryId: String?
    @State private var pickedTask: TodoistTask?

    private var idle: Bool { model.engine.phase == .idle }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HSplitView {
            left.frame(minWidth: 340)
            right.frame(minWidth: 320)
        }
        .task { await model.refreshEvaluations() }
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新")
            }
        }
    }

    private var left: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    InkSectionHeader(text: "自定义条目")
                    HStack(spacing: 8) {
                        TextField("标题", text: $title).textFieldStyle(InkFieldStyle()).onSubmit(start)
                        Picker("分类", selection: $categoryId) {
                            Text("无分类").tag(String?.none)
                            ForEach(model.categories) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        .labelsHidden().frame(width: 110)
                        Button("开始", action: start).buttonStyle(.inkPrimary).disabled(!idle || trimmedTitle.isEmpty)
                    }
                    ForEach(model.entries) { entry in
                        row(entry.title, color: model.category(for: entry.categoryId).map { Color(todoistColor: $0.color) },
                            subtitle: model.category(for: entry.categoryId)?.name, onOpen: nil) { model.startEntry(entry) }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    InkSectionHeader(text: "TODOIST 今日 / 过期")
                    if model.tasks.isEmpty { Text("没有任务").font(.callout).foregroundStyle(Ink.sub) }
                    ForEach(model.tasks) { task in
                        let cat = model.categories.first { $0.todoistProjectId == task.projectId }
                        row(task.content, color: cat.map { Color(todoistColor: $0.color) }, subtitle: cat?.name,
                            onOpen: { withAnimation(.easeOut(duration: 0.15)) { pickedTask = task } }) { model.startTask(task) }
                    }
                }
                if let message = model.errorMessage {
                    Text(message).font(.caption).foregroundStyle(Ink.now)
                }
            }
            .padding(14)
        }
    }

    private var right: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.engine.phase {
            case .focusing:
                timerPanel(title: model.currentTitle ?? "", action: AnyView(
                    Button("放弃（不记录）") { model.abandon() }.buttonStyle(.ink)))
            case .breaking:
                timerPanel(title: "休息中", action: AnyView(
                    Button("结束休息") { model.endBreak() }.buttonStyle(.ink)))
            case .idle:
                if let done = model.pendingCompletion { CompletionBanner(done: done).inkPanel() }
            }
            if model.unsynced > 0 {
                Text("\(model.unsynced) 条未同步").font(.inkMono(11)).foregroundStyle(Ink.now)
            }
            if model.accessibilityMissing, case .focusing = model.engine.phase {
                Text("未授权辅助功能：仅按 App 粒度采集").font(.inkMono(11)).foregroundStyle(Ink.now)
            }
            Text("今日　\(model.todaySessions.count) 个番茄 · \(model.todaySessions.map(\.actualSeconds).reduce(0, +) / 60) 分钟")
                .font(.inkMono(12)).foregroundStyle(Ink.sub)
            FocusTimelineView(sessions: model.todaySessions, tasks: model.tasks) { task in
                withAnimation(.easeOut(duration: 0.15)) { pickedTask = task }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let task = pickedTask {
                TaskDetailPanel(task: task,
                                category: model.categories.first { $0.todoistProjectId == task.projectId },
                                canStart: idle,
                                onStart: { model.startTask(task); pickedTask = nil },
                                onClose: { withAnimation(.easeOut(duration: 0.15)) { pickedTask = nil } })
            }
        }
        .padding(14)
    }

    private func timerPanel(title: String, action: AnyView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            Text(AppModel.format(model.engine.remainingSeconds))
                .font(.inkMono(56, weight: .medium)).monospacedDigit()
            action
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkPanel()
        .padding(.trailing, 3).padding(.bottom, 3)
    }

    private func row(_ text: String, color: Color?, subtitle: String?, onOpen: (() -> Void)?,
                     start: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            CategoryMark(color: color ?? Ink.rule)
            Button { onOpen?() } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(text).lineLimit(2).multilineTextAlignment(.leading)
                    if let subtitle { Text(subtitle).font(.inkMono(10)).foregroundStyle(Ink.sub) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(onOpen == nil)
            Button(action: start) { Image(systemName: "play.fill").font(.system(size: 10)) }
                .buttonStyle(.ink).disabled(!idle)
                .accessibilityLabel("开始专注：\(text)")
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.rule).frame(height: 1) }
    }

    private func start() {
        guard idle, !trimmedTitle.isEmpty else { return }
        model.startCustom(title: trimmedTitle, categoryId: categoryId)
        title = ""
    }
}
