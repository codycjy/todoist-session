import SwiftUI
import SessionCore

/// 点开 Todoist 任务后底部弹出的完整详情：标题不截断、元信息、描述可滚动，顶部即可开始。
struct TaskDetailPanel: View {
    let task: TodoistTask
    let category: Category?
    let canStart: Bool
    let onStart: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                if let category { CategoryMark(color: Color(todoistColor: category.color), size: 10).padding(.top, 5) }
                Text(task.content).font(.system(size: 15, weight: .semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Ink.sub).accessibilityLabel("关闭")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    metaGrid
                    if !task.labels.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(task.labels, id: \.self) { label in
                                Text("@\(label)").font(.inkMono(11))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .overlay(Rectangle().strokeBorder(Ink.ink, lineWidth: 1))
                            }
                        }
                    }
                    if !task.description.isEmpty {
                        InkSectionHeader(text: "描述")
                        Text(Self.markdown(task.description)).font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)

            HStack {
                Button("开始专注", action: onStart).buttonStyle(.inkPrimary).disabled(!canStart)
                if let url = task.url.flatMap(URL.init(string:)) {
                    Link("在 Todoist 打开", destination: url).font(.callout)
                }
                Spacer()
                if !canStart { Text("专注进行中").font(.caption).foregroundStyle(Ink.sub) }
            }
        }
        .inkPanel()
        .padding(.trailing, 3).padding(.bottom, 3)   // 给硬阴影留位置
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var metaGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            if let category { metaRow("项目", category.name) }
            if let due = dueText { metaRow("截止", due) }
            if let m = task.durationMinutes { metaRow("时长", "\(m) 分钟") }
            metaRow("优先级", "P\(max(1, 5 - task.priority))")
            if task.isRecurring { metaRow("重复", "是") }
            if task.parentId != nil { metaRow("类型", "子任务") }
        }
    }

    private func metaRow(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).font(.inkMono(11)).foregroundStyle(Ink.sub)
            Text(value).font(.system(size: 12))
        }
    }

    private var dueText: String? {
        if let t = task.dueTime { return t.formatted(.dateTime.month().day().hour().minute()) }
        return task.dueDate
    }

    private static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
