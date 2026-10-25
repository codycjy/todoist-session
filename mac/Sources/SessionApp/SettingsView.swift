import SwiftUI
import SessionCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingsForm(store: model.settings)
    }
}

private struct SettingsForm: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @State private var newApp = ""
    @State private var newDomain = ""
    @State private var urlText = ""
    @State private var tokenText = ""
    @State private var hasStoredToken = false
    @State private var keychainFailed = false

    var body: some View {
        Form {
            Section {
                if store.unsynced {
                    Label("未同步：修改已保存在本机，后端暂不可达，稍后会自动重试", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
                Text("以下修改只对下一个专注 session 生效，进行中的不受影响。").font(.callout).foregroundStyle(.secondary)
            }

            Section("计时") {
                Stepper(value: focusMinutes, in: 1...120) { Text("专注时长：\(focusMinutes.wrappedValue) 分钟") }
                Stepper(value: idleSeconds, in: 30...1800, step: 30) { Text("闲置阈值：\(idleSeconds.wrappedValue) 秒") }
                if !store.overridden.isEmpty {
                    Text("环境变量正在覆盖部分设置（开发模式），此处修改不会生效。").font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("黑名单 App") {
                ForEach(store.values.blockApps, id: \.self) { id in
                    HStack {
                        Text(id)
                        Spacer()
                        Button(role: .destructive) { store.update { $0.blockApps.removeAll { $0 == id } } } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless).help("删除")
                    }
                }
                HStack {
                    TextField("bundle id，例如 com.tencent.xinWeChat", text: $newApp).onSubmit(addApp)
                    Button("添加", action: addApp).disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    Menu("从正在运行的 App 添加") {
                        ForEach(Self.runningApps(), id: \.id) { app in
                            Button(app.name) { store.update { $0.blockApps.append(app.id) } }
                        }
                    }
                }
            }

            Section("黑名单域名") {
                ForEach(store.values.blockDomains, id: \.self) { d in
                    HStack {
                        Text(d)
                        Spacer()
                        Button(role: .destructive) { store.update { $0.blockDomains.removeAll { $0 == d } } } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless).help("删除")
                    }
                }
                HStack {
                    TextField("域名，例如 youtube.com", text: $newDomain).onSubmit(addDomain)
                    Button("添加", action: addDomain).disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("后端") {
                TextField("后端地址", text: $urlText)
                SecureField(hasStoredToken ? "API Token（已保存，留空保持不变）" : "API Token", text: $tokenText)
                if keychainFailed { Text("写入钥匙串失败").foregroundStyle(.red) }
                HStack {
                    Button("保存并应用", action: saveConnection)
                    if hasStoredToken { Button("清除 Token", role: .destructive, action: clearToken) }
                }
                Text("环境变量 SESSION_API_URL / SESSION_API_TOKEN 若已设置，会优先于此处的值。").font(.callout).foregroundStyle(.secondary)
            }

            Section("权限") {
                PermissionRows().environmentObject(model.permissions)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadConnection)   // 只在出现时读一次；不要放进 State 初始值（每秒 tick 都会重建 View）
        .task { await model.permissions.refresh() }
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
