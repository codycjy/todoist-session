import SwiftUI
import SessionCore

/// 点开 Todoist 任务后从底部弹出的详情：标题不截断、元信息、标签、描述（可滚动），选时长后开始。
struct TaskDetailPanel: View {
    let task: TodoistTask
    let category: Category?
    /// 可选分类；选了之后这个 Todoist 项目的任务都默认用它。
    let categories: [Category]
    let canStart: Bool
    /// 分类 profile / 全局默认时长（秒）。
    let defaultSeconds: Int
    /// 参数是选定的专注秒数。
    let onStart: (Int) -> Void
    let onClose: () -> Void
    /// 选定时长变化时回调（时间轴据此预览结束时间）。
    var onChoose: (Int) -> Void = { _ in }
    var onPickCategory: (String?) -> Void = { _ in }

    @State private var seconds: Int?

    private var taskSeconds: Int? { task.durationMinutes.flatMap { $0 > 0 ? $0 * 60 : nil } }
    /// 可选时长（秒）：常用档位 + 默认值 + 任务自己的时长。
    private var options: [Int] {
        Array(Set(FocusPresets.seconds + [defaultSeconds] + (taskSeconds.map { [$0] } ?? []))).sorted()
    }
    private var chosen: Int { seconds ?? taskSeconds ?? defaultSeconds }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Menu {
                    Button("无分类") { onPickCategory(nil) }
                    ForEach(categories) { c in Button(c.name) { onPickCategory(c.id) } }
                } label: {
                    HStack(spacing: 5) {
                        CategoryMark(color: category.map { Color(todoistColor: $0.color) } ?? Ink.faint, size: 7)
                        Text(category?.name ?? "无分类").font(.inkMono(11))
                        Image(systemName: "chevron.down").font(.ink(8, weight: .bold))
                    }
                    .foregroundStyle(Ink.sub).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("给这个 Todoist 项目选分类，之后同项目的任务都默认用它")
                if task.priority >= 2 {
                    Text("P\(5 - task.priority)").font(.inkMono(11, weight: .bold))
                        .foregroundStyle(task.priority == 4 ? Ink.now : Ink.sub)
                }
                Spacer()
                if let url = task.url.flatMap(URL.init(string:)) {
                    Link(destination: url) {
                        HStack(spacing: 3) { Text("Todoist"); Image(systemName: "arrow.up.right") }
                            .font(.inkMono(11)).foregroundStyle(Ink.sub)
                    }
                }
                Button(action: onClose) { Image(systemName: "xmark").font(.ink(11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Ink.sub)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("关闭")
            }

            Text(task.content).font(.ink(19, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                fact("截止", dueText ?? "无")
                fact("时长", task.durationMinutes.map { "\($0) 分钟" } ?? "未设置")
                if task.isRecurring { fact("重复", "是") }
                if task.parentId != nil { fact("类型", "子任务") }
            }

            if !task.labels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(task.labels, id: \.self) { label in
                        Text("@\(label)").font(.inkMono(11))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
                    }
                }
            }

            if !task.description.isEmpty {
                // 按内容高度显示；很长的描述截到 8 行，完整内容去 Todoist 看。
                description.lineLimit(8)
                .padding(10)
                .background(Ink.paper)
                .overlay(Rectangle().strokeBorder(Ink.ruleSoft, lineWidth: 1))
            }

            Rectangle().fill(Ink.rule).frame(height: 1)
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { s in InkChip(text: Ink.chip(s), selected: s == chosen) { seconds = s } }
                Spacer(minLength: 8)
                if !canStart { Text("专注进行中").font(.inkMono(10)).foregroundStyle(Ink.sub) }
                Button { onStart(chosen) } label: {
                    HStack(spacing: 6) { Image(systemName: "play.fill").font(.ink(10)); Text("开始专注 \(Ink.duration(chosen))") }
                }
                .buttonStyle(.inkPrimary).disabled(!canStart)
            }
        }
        .inkPanel(padding: 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onChange(of: task.id) { _, _ in seconds = nil }
        .onChange(of: chosen, initial: true) { _, v in onChoose(v) }
    }

    private var description: some View {
        Text(Self.markdown(task.description)).font(.ink(13)).lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.inkMono(10)).foregroundStyle(Ink.faint)
            Text(value).font(.inkMono(12))
        }
    }

    private var dueText: String? {
        if let t = task.dueTime {
            return Calendar.current.isDateInToday(t) ? "今天 \(Ink.hm(t))" : "\(t.formatted(.dateTime.month().day())) \(Ink.hm(t))"
        }
        return task.dueDate
    }

    private static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
