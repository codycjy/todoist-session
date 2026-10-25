import SwiftUI
import SessionCore

struct MenuPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var title = ""

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            status
            Divider()
            // 完成横幅显示时也允许显式开始新的专注（开始会清除横幅）；绝不自动开始。
            if model.engine.phase == .idle {
                HStack {
                    TextField("快速开始：输入标题", text: $title)
                        .onSubmit(quickStart)
                    Button("开始", action: quickStart).disabled(trimmedTitle.isEmpty)
                }
                ForEach(model.tasks.prefix(5)) { task in
                    Button { model.startTask(task) } label: {
                        Label(task.content, systemImage: "play.fill").lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Button("打开主窗口") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder private var status: some View {
        switch model.engine.phase {
        case .focusing:
            VStack(alignment: .leading, spacing: 6) {
                Text(model.currentTitle ?? "").font(.headline).lineLimit(2)
                Text(AppModel.format(model.engine.remainingSeconds)).font(.system(size: 34, weight: .semibold, design: .monospaced))
                Button("放弃（不记录）", role: .destructive) { model.abandon() }
            }
        case .breaking:
            VStack(alignment: .leading, spacing: 6) {
                Text("休息中").font(.headline)
                Text(AppModel.format(model.engine.remainingSeconds)).font(.system(size: 34, weight: .semibold, design: .monospaced))
                Button("结束休息") { model.endBreak() }
            }
        case .idle:
            if let done = model.pendingCompletion {
                CompletionBanner(done: done)
            } else {
                Text("空闲").font(.headline)
            }
        }
        if let message = model.errorMessage {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    private func quickStart() {
        guard !trimmedTitle.isEmpty else { return }
        model.startCustom(title: trimmedTitle, categoryId: nil)
        title = ""
    }
}

/// 完成后的默认动作是「结束」（回到空闲）；休息是可选项。没有评分/复盘。
struct CompletionBanner: View {
    @EnvironmentObject var model: AppModel
    let done: CompletedFocus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("✓ 完成：\(done.run.title)").font(.headline).lineLimit(2)
            HStack {
                Button(model.engine.suggestedBreak == .long ? "开始长休 15 分钟" : "开始休息 5 分钟") { model.startBreak() }
                Button("结束") { model.dismissCompletion() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
