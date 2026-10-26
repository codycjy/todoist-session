import SwiftUI
import SessionCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    let section: SettingsSection

    var body: some View {
        SettingsForm(store: model.settings, section: section)
    }
}

/// 设置页：每个侧栏子项一页，左侧标签列 + 右侧控件列。
private struct SettingsForm: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: SettingsStore
    let section: SettingsSection
    @State private var newApp = ""
    @State private var newDomain = ""
    @State private var urlText = ""
    @State private var tokenText = ""
    @State private var hasStoredToken = false
    @State private var keychainFailed = false
    @State private var editingProfile: String? = DemoData.initialTab == "profiles" ? "c-work" : nil
    @State private var profileApp = ""
    @State private var profileDomain = ""
    @AppStorage(Shortcuts.enabledKey) private var shortcutsEnabled = true

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("设置").font(.inkMono(11)).foregroundStyle(Ink.sub)
                    Text(section.rawValue).font(.ink(30, weight: .bold))
                }
                if store.unsynced {
                    Label("未同步：修改已保存在本机，后端暂不可达，稍后会自动重试", systemImage: "arrow.triangle.2.circlepath")
                        .font(.ink(12)).foregroundStyle(Ink.now)
                }
                switch section {
                case .timing: timing
                case .profiles: profiles
                case .blocking: blocking
                case .appearance: AppearancePicker()
                case .backend: backend
                case .permissions: PermissionRows().environmentObject(model.permissions)
                }
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 36)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: loadConnection)   // 只在出现时读一次；不要放进 State 初始值（每秒 tick 都会重建 View）
        .task { await model.permissions.refresh() }
    }

    // MARK: 各页

    private var timing: some View {
        VStack(alignment: .leading, spacing: 0) {
            note("修改只对下一个专注生效，进行中的不受影响。")
            row("专注时长", hint: "开始面板默认选中的时长") {
                StepperField(value: focusMinutes, range: 1...120, step: 5, unit: "分钟")
            }
            row("闲置阈值", hint: "超过这么久没有键鼠操作，记为闲置") {
                StepperField(value: idleSeconds, range: 30...1800, step: 30, unit: "秒")
            }
            row("休息", hint: "没有分类设置时") {
                Text("短休 \(AppSettings.shortBreakSeconds / 60) 分钟 · 每 4 个番茄长休 \(AppSettings.longBreakSeconds / 60) 分钟")
                    .font(.ink(12.5)).foregroundStyle(Ink.sub)
            }
            row("快捷指令", hint: "开始时运行 session_start，结束时运行 session_end") {
                VStack(alignment: .leading, spacing: 6) {
                    InkToggle(isOn: $shortcutsEnabled, label: "运行快捷指令")
                    Text("在「快捷指令」App 里新建同名快捷指令即可，没有就跳过。输入是 JSON 文本：event（start / complete / abandon）、title、category、plannedMinutes、actualMinutes。")
                        .font(.ink(11)).foregroundStyle(Ink.sub).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !store.overridden.isEmpty {
                note("环境变量正在覆盖部分设置（开发模式），此处修改不会生效。").padding(.top, 12)
            }
        }
    }

    private var blocking: some View {
        VStack(alignment: .leading, spacing: 28) {
            note("专注期间，名单里的 App 会被隐藏，网站会被重定向到拦截页；结束后自动恢复。")
            listBlock(title: "App", items: store.values.blockApps, mono: true,
                      remove: { id in store.update { $0.blockApps.removeAll { $0 == id } } }) {
                HStack(spacing: 8) {
                    TextField("bundle id，例如 com.tencent.xinWeChat", text: $newApp)
                        .textFieldStyle(InkFieldStyle()).onSubmit(addApp)
                    Button("添加", action: addApp).buttonStyle(.ink)
                        .disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    Menu("从运行中的 App") {
                        ForEach(Self.runningApps(), id: \.id) { app in
                            Button(app.name) { store.update { $0.blockApps.append(app.id) } }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            listBlock(title: "网站", items: store.values.blockDomains, mono: true,
                      remove: { d in store.update { $0.blockDomains.removeAll { $0 == d } } }) {
                HStack(spacing: 8) {
                    TextField("域名，例如 youtube.com", text: $newDomain)
                        .textFieldStyle(InkFieldStyle()).onSubmit(addDomain)
                    Button("添加", action: addDomain).buttonStyle(.ink)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var backend: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("后端地址") {
                TextField("http://127.0.0.1:8787", text: $urlText).textFieldStyle(InkFieldStyle())
            }
            row("API Token", hint: hasStoredToken ? "已保存在钥匙串，留空保持不变" : nil) {
                SecureField(hasStoredToken ? "••••••••" : "粘贴 token", text: $tokenText).textFieldStyle(InkFieldStyle())
            }
            if keychainFailed { Text("写入钥匙串失败").font(.ink(12)).foregroundStyle(Ink.now).padding(.top, 8) }
            HStack(spacing: 8) {
                Button("保存并应用", action: saveConnection).buttonStyle(.inkPrimary)
                if hasStoredToken { Button("清除 Token", action: clearToken).buttonStyle(.ink) }
            }
            .padding(.top, 16)
            note("环境变量 SESSION_API_URL / SESSION_API_TOKEN 若已设置，会优先于此处的值。").padding(.top, 16)
        }
    }

    // MARK: 分类 profile

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 18) {
            note("给分类单独设定专注 / 休息时长和黑名单，例如 Coding 专注 50 分钟、休息 25 分钟。选了这个分类（或 Todoist 项目）开始专注时生效；没设置的分类用全局设置。")
            if model.categories.isEmpty {
                Text("还没有分类。今日 Todoist 任务的项目和自定义分类会出现在这里。")
                    .font(.ink(12.5)).foregroundStyle(Ink.faint)
            }
            VStack(spacing: 0) {
                ForEach(model.categories) { c in profileRow(c) }
            }
        }
    }

    private func profileRow(_ c: Category) -> some View {
        let p = store.values.profiles[c.id]
        let open = editingProfile == c.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { editingProfile = open ? nil : c.id }
            } label: {
                HStack(spacing: 10) {
                    CategoryMark(color: Color(todoistColor: c.color), size: 9)
                    Text(c.name).font(.ink(13.5, weight: .semibold))
                    Spacer()
                    Text(p.map(profileSummary) ?? "使用全局设置").font(.inkMono(11)).foregroundStyle(p == nil ? Ink.faint : Ink.sub)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.ink(9, weight: .bold)).foregroundStyle(Ink.sub)
                }
                .padding(.horizontal, 10).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverRow(selected: open)
            if open { profileEditor(c.id).padding(.horizontal, 10).padding(.bottom, 14) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.ruleSoft).frame(height: 1) }
    }

    private func profileSummary(_ p: CategoryProfile) -> String {
        var parts = ["专注 \(p.focusSeconds / 60)m", "休息 \(p.breakSeconds / 60)m"]
        let extra = p.blockApps.count + p.blockDomains.count
        parts.append(p.inheritBlocklist ? (extra > 0 ? "全局 + \(extra)" : "全局黑名单") : "专属黑名单 \(extra)")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func profileEditor(_ id: String) -> some View {
        let p = store.values.profiles[id]
        VStack(alignment: .leading, spacing: 0) {
            InkToggle(isOn: Binding(get: { p != nil }, set: { on in
                store.update { s in
                    s.profiles[id] = on ? CategoryProfile(focusSeconds: s.focusSeconds, breakSeconds: AppSettings.shortBreakSeconds) : nil
                }
            }), label: "这个分类使用专属设置").padding(.vertical, 12)
            if p != nil {
                row("专注时长") { StepperField(value: profileBinding(id, \.focusSeconds, scale: 60), range: 5...120, step: 5, unit: "分钟") }
                row("休息时长", hint: "这个分类专注结束后的休息，长短休都用它") {
                    StepperField(value: profileBinding(id, \.breakSeconds, scale: 60), range: 1...60, step: 5, unit: "分钟")
                }
                row("黑名单", hint: "全局名单 \(store.values.blockApps.count + store.values.blockDomains.count) 条") {
                    InkToggle(isOn: Binding(get: { store.values.profiles[id]?.inheritBlocklist ?? true },
                                            set: { v in store.update { $0.profiles[id]?.inheritBlocklist = v } }),
                              label: "继承全局黑名单，再加上下面的专属条目")
                }
                HStack(alignment: .top, spacing: 24) {
                    listBlock(title: "专属 App", items: p?.blockApps ?? [], mono: true,
                              remove: { a in store.update { $0.profiles[id]?.blockApps.removeAll { $0 == a } } }) {
                        HStack(spacing: 6) {
                            TextField("bundle id", text: $profileApp).textFieldStyle(InkFieldStyle())
                                .onSubmit { addProfileItem(id, app: true) }
                            Menu("运行中") {
                                ForEach(Self.runningApps(), id: \.id) { app in
                                    Button(app.name) { store.update { $0.profiles[id]?.blockApps.append(app.id) } }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                    listBlock(title: "专属网站", items: p?.blockDomains ?? [], mono: true,
                              remove: { d in store.update { $0.profiles[id]?.blockDomains.removeAll { $0 == d } } }) {
                        TextField("域名，回车添加", text: $profileDomain).textFieldStyle(InkFieldStyle())
                            .onSubmit { addProfileItem(id, app: false) }
                    }
                }
                .padding(.top, 14)
            }
        }
    }

    private func profileBinding(_ id: String, _ key: WritableKeyPath<CategoryProfile, Int>, scale: Int) -> Binding<Int> {
        Binding(get: { (store.values.profiles[id]?[keyPath: key] ?? 0) / scale },
                set: { v in store.update { $0.profiles[id]?[keyPath: key] = v * scale } })
    }

    private func addProfileItem(_ id: String, app: Bool) {
        let value = app ? profileApp : profileDomain
        if app { profileApp = "" } else { profileDomain = "" }
        store.update { s in
            if app { s.profiles[id]?.blockApps.append(value) } else { s.profiles[id]?.blockDomains.append(value) }
        }
    }

    // MARK: 布局零件

    private func note(_ text: String) -> some View {
        Text(text).font(.ink(12.5)).foregroundStyle(Ink.sub).fixedSize(horizontal: false, vertical: true)
    }

    private func row<C: View>(_ label: String, hint: String? = nil, @ViewBuilder _ control: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.ink(13, weight: .semibold))
                if let hint { Text(hint).font(.ink(11)).foregroundStyle(Ink.sub) }
            }
            .frame(width: 180, alignment: .leading)
            control().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.ruleSoft).frame(height: 1) }
    }

    private func listBlock<Add: View>(title: String, items: [String], mono: Bool, remove: @escaping (String) -> Void,
                                      @ViewBuilder add: () -> Add) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            InkSectionHeader(text: title, count: items.count)
            if items.isEmpty {
                Text("还没有条目").font(.ink(12)).foregroundStyle(Ink.faint).padding(.vertical, 8)
            }
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item).font(mono ? .inkMono(12) : .ink(13))
                    Spacer()
                    Button { remove(item) } label: { Image(systemName: "xmark").font(.ink(10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(Ink.sub).help("删除")
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .hoverRow()
                .overlay(alignment: .bottom) { Rectangle().fill(Ink.ruleSoft).frame(height: 1) }
            }
            add().padding(.top, 6)
        }
    }

    private func loadConnection() {
        urlText = ConnectionConfig.baseURLString()
        hasStoredToken = KeychainStore.read() != nil
    }

    // MARK: 绑定与动作

    private var focusMinutes: Binding<Int> {
        Binding(get: { store.values.focusSeconds / 60 }, set: { m in store.update { $0.focusSeconds = m * 60 } })
    }

    private var idleSeconds: Binding<Int> {
        Binding(get: { store.values.idleThresholdSeconds }, set: { v in store.update { $0.idleThresholdSeconds = v } })
    }

    private func addApp() {
        let id = newApp
        newApp = ""
        store.update { $0.blockApps.append(id) }   // 去空白 / 去重由 SettingsStore 统一处理
    }

    private func addDomain() {
        let d = newDomain
        newDomain = ""
        store.update { $0.blockDomains.append(d) }   // 小写 / 去空白 / 去重由 SettingsStore 统一处理
    }

    private func saveConnection() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(url.isEmpty ? nil : url, forKey: ConnectionConfig.urlKey)
        let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            keychainFailed = !KeychainStore.write(token)
            tokenText = ""
        }
        hasStoredToken = KeychainStore.read() != nil
        model.reconfigureAPI()
    }

    private func clearToken() {
        KeychainStore.delete()
        hasStoredToken = false
        model.reconfigureAPI()
    }

    private struct RunningApp { let id: String; let name: String }

    private static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { RunningApp(id: $0, name: app.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// 「− 25 分钟 +」样式的步进器。
private struct StepperField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String

    var body: some View {
        HStack(spacing: 0) {
            button("minus") { value = max(range.lowerBound, value - step) }.disabled(value <= range.lowerBound)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)").font(.inkMono(15, weight: .medium))
                Text(unit).font(.ink(11)).foregroundStyle(Ink.sub)
            }
            .frame(minWidth: 90)
            button("plus") { value = min(range.upperBound, value + step) }.disabled(value >= range.upperBound)
        }
        .overlay(Rectangle().strokeBorder(Ink.rule, lineWidth: 1))
    }

    private func button(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.ink(10, weight: .bold)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 外观页：三张小样卡片，点选即生效。
private struct AppearancePicker: View {
    @AppStorage(AppearanceMode.key) private var raw = AppearanceMode.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("主窗口和菜单栏面板一起切换。侧栏底部的小图标也可以快速切换。")
                .font(.ink(12.5)).foregroundStyle(Ink.sub)
            HStack(spacing: 14) {
                ForEach(AppearanceMode.allCases) { mode in card(mode) }
            }
        }
    }

    private func card(_ mode: AppearanceMode) -> some View {
        let selected = raw == mode.rawValue
        return Button {
            raw = mode.rawValue
            mode.apply()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                swatch(mode).frame(height: 84)
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.square.fill" : "square").font(.ink(12))
                    Text(mode.label).font(.ink(13, weight: selected ? .semibold : .regular))
                }
            }
            .padding(10)
            .frame(width: 168)
            .background(selected ? Ink.panel : Color.clear)
            .overlay(Rectangle().strokeBorder(selected ? Ink.ink : Ink.rule, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 小样：纸色底 + 几条墨线 + 一个荧光块；跟随系统时左右各半。
    @ViewBuilder private func swatch(_ mode: AppearanceMode) -> some View {
        switch mode {
        case .light: page(dark: false)
        case .dark: page(dark: true)
        case .system:
            HStack(spacing: 0) { page(dark: false); page(dark: true) }
        }
    }

    private func page(dark: Bool) -> some View {
        let paper = dark ? Color(white: 0.08) : Color(red: 0.95, green: 0.95, blue: 0.94)
        let line = dark ? Color(white: 0.30) : Color(white: 0.78)
        let ink = dark ? Color(white: 0.88) : Color(white: 0.10)
        return VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(ink).frame(width: 34, height: 5)
            Rectangle().fill(line).frame(height: 1)
            HStack(spacing: 4) {
                Rectangle().fill(Color(red: 0.93, green: 0.82, blue: 0.22)).frame(width: 22, height: 14)
                Rectangle().fill(line).frame(height: 1)
            }
            Rectangle().fill(line).frame(height: 1)
            Rectangle().fill(line).frame(width: 40, height: 1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(paper)
    }
}

/// 方框勾选开关，替代系统 Toggle。
struct InkToggle: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square").font(.ink(13))
                Text(label).font(.ink(13))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.ink)
    }
}
