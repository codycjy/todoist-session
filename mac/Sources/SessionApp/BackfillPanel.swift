import SwiftUI
import SessionCore

/// 补录草稿：区间与标题由今日页持有，时间轴同步预览这一段。
struct BackfillDraft: Equatable {
    var from: Date
    var to: Date
    var title = ""
    var interval: DateInterval { DateInterval(start: from, end: max(from, to)) }
}

/// 「我刚才在干嘛」：选一段没开计时的时间，看看这段在用什么，记成一次专注。
/// 与 `TaskDetailPanel` 同一套面板样式，从底部弹出。
struct BackfillPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var draft: BackfillDraft
    let onClose: () -> Void

    @State private var categoryId: String?
    @State private var allowIdle = false

    private var trimmedTitle: String { draft.title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var problem: Backfill.Problem? { model.backfillProblem(from: draft.from, to: draft.to) }
    private var minutes: Int { max(0, Int(draft.to.timeIntervalSince(draft.from)) / 60) }

    var body: some View {
        let preview = model.backfillPreview(from: draft.from, to: draft.to)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("补录").font(.inkMono(10, weight: .semibold)).tracking(1).foregroundStyle(Ink.sub)
                    Text("刚才忘了开计时？把这段记成一次专注").font(.ink(15, weight: .semibold))
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.ink(11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Ink.sub)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("关闭")
            }

            HStack(spacing: 10) {
                timePicker($draft.from)
                Text("–").font(.inkMono(12)).foregroundStyle(Ink.sub)
                timePicker($draft.to)
                Text("\(minutes) 分钟").font(.inkMono(12, weight: .medium))
                Spacer()
            }

            usage(preview)

            Rectangle().fill(Ink.rule).frame(height: 1)
            TextField("这段在做什么？", text: $draft.title)
                .textFieldStyle(InkFieldStyle(size: 15))
                .onSubmit(save)
            HStack(spacing: 6) {
                categoryMenu
                IdleToggle(isOn: $allowIdle)
                Spacer(minLength: 8)
                if let problem { Text(text(for: problem)).font(.ink(11.5)).foregroundStyle(Ink.now).lineLimit(1) }
                Button(action: save) {
                    HStack(spacing: 6) { Image(systemName: "plus").font(.ink(10, weight: .bold)); Text("补录") }
                }
                .buttonStyle(.inkPrimary).fixedSize()
                .disabled(trimmedTitle.isEmpty || problem != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .inkPanel(padding: 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func timePicker(_ value: Binding<Date>) -> some View {
        DatePicker("", selection: value, displayedComponents: .hourAndMinute)
            .labelsHidden().datePickerStyle(.stepperField).font(.inkMono(12)).fixedSize()
    }

    /// 这段时间的活动：App / 网站按时长排，附闲置；没有记录时说明原因。
    @ViewBuilder private func usage(_ p: (top: [Backfill.Usage], idleSeconds: Int)) -> some View {
        if p.top.isEmpty && p.idleSeconds == 0 {
            Text(model.ambientEnabled ? "这段时间本机没有活动记录（Now 没在运行）。仍可补录，只是 AI 评估缺少依据。"
                                      : "「设置 › 计时」里没有打开专注外记录，这段没有活动可参考。仍可补录。")
                .font(.ink(12)).foregroundStyle(Ink.sub).fixedSize(horizontal: false, vertical: true)
        } else {
            let top = Array(p.top.prefix(4))
            let longest = max(top.first?.seconds ?? 0, p.idleSeconds, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("这段时间在用").font(.inkMono(10, weight: .semibold)).tracking(1).foregroundStyle(Ink.faint)
                ForEach(Array(top.enumerated()), id: \.offset) { i, u in
                    bar(u.name, seconds: u.seconds, fraction: Double(u.seconds) / Double(longest),
                        color: i == 0 ? Ink.highlight : Ink.ink)
                }
                if p.idleSeconds > 0 {
                    bar("闲置", seconds: p.idleSeconds, fraction: Double(p.idleSeconds) / Double(longest), color: Ink.faint)
                }
            }
        }
    }

    private func bar(_ name: String, seconds: Int, fraction: Double, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.inkMono(11)).lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
            GeometryReader { geo in
                Rectangle().fill(color).frame(width: max(2, geo.size.width * fraction))
            }
            .frame(height: 6)
            Text(StatsFormat.duration(seconds: seconds)).font(.inkMono(11)).foregroundStyle(Ink.sub)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var categoryMenu: some View {
        Menu {
            Button("无分类") { categoryId = nil }
            ForEach(model.categories) { c in Button(c.name) { categoryId = c.id } }
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
    }

    private func text(for p: Backfill.Problem) -> String {
        switch p {
        case .tooShort: "至少 1 分钟"
        case .tooLong: "一次最多补 \(Backfill.maxSeconds / 3600) 小时"
        case .inFuture: "结束时间还没到"
        case .overlaps(let title): "和「\(title)」重叠"
        }
    }

    private func save() {
        guard !trimmedTitle.isEmpty, problem == nil else { return }
        if model.backfill(title: trimmedTitle, categoryId: categoryId, from: draft.from, to: draft.to, allowIdle: allowIdle) {
            onClose()
        }
    }
}
