import SwiftUI
import SessionCore

/// 菜单栏面板：与主窗口同一套「手帐」样式。顶部品牌 + 今日小计，中间是计时 / 快速开始 + 今日任务，底部操作。
struct MenuPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppearanceMode.key) private var appearanceRaw = AppearanceMode.system.rawValue
    @State private var title = ""

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var appearance: AppearanceMode { AppearanceMode(rawValue: appearanceRaw) ?? .system }
    private var todayMinutes: Int { model.todaySessions.map(\.actualSeconds).reduce(0, +) / 60 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Ink.rule).frame(height: 1)
            VStack(alignment: .leading, spacing: 14) {
                status
                if model.engine.phase == .idle { tasks }
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Ink.now)
                        .lineLimit(2)
                }
            }
            .padding(14)
            Rectangle().fill(Ink.rule).frame(height: 1)
            footer
        }
        .frame(width: 340)
        .background(Ink.paper)
        .tint(Ink.ink)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Rectangle().fill(Ink.highlight).frame(width: 9, height: 9)
            Text("SESSION").font(.inkMono(11, weight: .bold)).tracking(2.2)
            Spacer()
            Text("今日 \(todayMinutes) 分钟 · \(model.todaySessions.count) 番茄").font(.inkMono(10.5)).foregroundStyle(Ink.sub)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Ink.shelf)
    }

    // MARK: 状态

    @ViewBuilder private var status: some View {
        switch model.engine.phase {
        case .focusing(let run):
            timerBlock(eyebrow: "专注中", title: run.title, categoryId: run.categoryId,
                       progress: 1 - Double(model.engine.remainingSeconds) / Double(max(run.plannedSeconds, 1)),
                       minutes: run.plannedSeconds / 60) {
                Button("放弃（不记录）") { model.abandon() }.buttonStyle(InkButtonStyle(compact: true))
            }
        case .breaking:
            timerBlock(eyebrow: "休息中", title: nil, categoryId: nil, progress: nil, minutes: 0) {
                Button("结束休息") { model.endBreak() }.buttonStyle(InkButtonStyle(compact: true))
            }
        case .idle:
            VStack(alignment: .leading, spacing: 10) {
                if let done = model.pendingCompletion {
                    CompletionBanner(done: done)
                        .padding(10)
                        .background(Ink.panel)
                        .overlay(Rectangle().strokeBorder(Ink.ink.opacity(0.85), lineWidth: 1))
                }
                HStack(spacing: 8) {
                    TextField("快速开始：输入标题", text: $title)
                        .textFieldStyle(InkFieldStyle(size: 14))
                        .onSubmit(quickStart)
                    Button(action: quickStart) {
                        HStack(spacing: 5) { Image(systemName: "play.fill").font(.system(size: 9)); Text("开始") }
                    }
                    .buttonStyle(InkButtonStyle(kind: .primary, compact: true))
                    .disabled(trimmedTitle.isEmpty)
                }
            }
        }
    }

    private func timerBlock<B: View>(eyebrow: String, title: String?, categoryId: String?, progress: Double?, minutes: Int,
                                     @ViewBuilder actions: () -> B) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Rectangle().fill(Ink.highlight).frame(width: 7, height: 7)
                Text(eyebrow).font(.inkMono(10.5, weight: .semibold)).tracking(1.1)
                if let cat = model.category(for: categoryId) {
                    Text("·").foregroundStyle(Ink.faint)
                    CategoryMark(color: Color(todoistColor: cat.color), size: 6)
                    Text(cat.name).font(.inkMono(10.5)).foregroundStyle(Ink.sub)
                }
            }
            if let title { Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(2) }
            Text(AppModel.format(model.engine.remainingSeconds))
                .font(.system(size: 46, weight: .light, design: .monospaced)).monospacedDigit()
            if let progress { ProgressRule(progress: progress, minutes: minutes) }
            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 今日任务

    @ViewBuilder private var tasks: some View {
        if !model.tasks.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                InkSectionHeader(text: "今日任务", count: model.tasks.count)
                ForEach(model.tasks.prefix(6)) { task in
                    Button { model.startTask(task, seconds: task.durationMinutes.map { max(1, $0) * 60 }) } label: {
                        HStack(spacing: 9) {
                            Text(task.dueTime.map(Ink.hm) ?? "—").font(.inkMono(11)).foregroundStyle(Ink.sub)
                                .frame(width: 38, alignment: .leading)
                            CategoryMark(color: model.categories.first { $0.todoistProjectId == task.projectId }
                                .map { Color(todoistColor: $0.color) } ?? Ink.faint, size: 7)
                            Text(task.content).font(.system(size: 12.5)).lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(Ink.sub)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverRow()
                    .help("开始专注：\(task.content)")
                }
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 14) {
            Button { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } label: {
                HStack(spacing: 5) { Image(systemName: "macwindow"); Text("打开主窗口") }
            }
            Spacer()
            Button {
                let next = appearance.next
                appearanceRaw = next.rawValue
                next.apply()
            } label: { Image(systemName: appearance.icon) }
            .help("外观：\(appearance.label)（点击切换）")
            Button("退出") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(Ink.sub)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Ink.shelf)
    }

    private func quickStart() {
        guard !trimmedTitle.isEmpty else { return }
        model.startCustom(title: trimmedTitle, categoryId: nil)
        title = ""
    }
}
