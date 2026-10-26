import Foundation

/// 专注开始 / 结束时运行用户的快捷指令 `session_start` / `session_end`（不存在就跳过）。
/// 输入是一段 JSON 文本：{"event","title","category","plannedMinutes","actualMinutes"}。
enum Shortcuts {
    static let enabledKey = "shortcuts.enabled"
    static let startName = "session_start", endName = "session_end"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func run(_ name: String, input: [String: Any]) {
        guard enabled, !DemoData.enabled else { return }
        DispatchQueue.global(qos: .utility).async {
            guard installed().contains(name) else { return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                try JSONSerialization.data(withJSONObject: input).write(to: file)
                let status = shell(["run", name, "-i", file.path]).status
                if status != 0 { Log.info("快捷指令 \(name) 退出码 \(status)") }
            } catch {
                Log.info("快捷指令 \(name) 运行失败：\(error.localizedDescription)")
            }
        }
    }

    /// 已安装的快捷指令名称；读取失败时为空（就当没有）。
    static func installed() -> Set<String> {
        let out = shell(["list"])
        guard out.status == 0 else { return [] }
        return Set(out.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    private static func shell(_ args: [String]) -> (status: Int32, stdout: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
