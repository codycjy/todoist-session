import SwiftUI
import SessionCore

struct TodayView: View {
    @EnvironmentObject var model: AppModel
    @State private var title = ""
    @State private var categoryId: String?

    private var idle: Bool { model.engine.phase == .idle }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HSplitView {
            left.frame(minWidth: 340)
            right.frame(minWidth: 300)
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新")
            }
        }
    }

    private var left: some View {
        List {
            Section("自定义条目") {
                HStack {
                    TextField("标题", text: $title).onSubmit(start)
                    Picker("分类", selection: $categoryId) {
                        Text("无分类").tag(String?.none)
                        ForEach(model.categories) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .labelsHidden().frame(width: 120)
                    Button("开始", action: start).disabled(!idle || trimmedTitle.isEmpty)
                }
                ForEach(model.entries) { entry in
                    row(entry.title, subtitle: model.category(for: entry.categoryId)?.name) { model.startEntry(entry) }
                }
            }
            Section("Todoist 今日 / 过期") {
                if model.tasks.isEmpty { Text("没有任务").foregroundStyle(.secondary) }
                ForEach(model.tasks) { task in
                    row(task.content, subtitle: model.categories.first { $0.todoistProjectId == task.projectId }?.name) {
                        model.startTask(task)
                    }
                }
            }
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var right: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.engine.phase {
            case .focusing:
                Text(model.currentTitle ?? "").font(.title2)
                Text(AppModel.format(model.engine.remainingSeconds))
                    .font(.system(size: 56, weight: .semibold, design: .monospaced))
                Button("放弃（不记录）", role: .destructive) { model.abandon() }
            case .breaking:
                Text("休息中").font(.title2)
                Text(AppModel.format(model.engine.remainingSeconds))
                    .font(.system(size: 56, weight: .semibold, design: .monospaced))
                Button("结束休息") { model.endBreak() }
            case .idle:
                if let done = model.pendingCompletion { CompletionBanner(done: done) }
            }
            if model.unsynced > 0 {
                Text("\(model.unsynced) 条未同步").font(.caption).foregroundStyle(.orange)
            }
            if model.accessibilityMissing, case .focusing = model.engine.phase {
                Text("未授权辅助功能：仅按 App 粒度采集").font(.caption).foregroundStyle(.orange)
            }
            Text("今日：\(model.todaySessions.count) 个番茄 · \(model.todaySessions.map(\.actualSeconds).reduce(0, +) / 60) 分钟")
                .foregroundStyle(.secondary)
            FocusTimelineView(sessions: model.todaySessions, tasks: model.tasks)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }

    private func row(_ text: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(text).lineLimit(2)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button(action: action) { Image(systemName: "play.fill") }
                .disabled(!idle)
                .accessibilityLabel("开始专注：\(text)")
        }
    }

    private func start() {
        guard idle, !trimmedTitle.isEmpty else { return }
        model.startCustom(title: trimmedTitle, categoryId: categoryId)
        title = ""
    }
}
