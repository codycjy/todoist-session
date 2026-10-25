import Foundation
import os

/// 排查用日志：同时写 stderr（`swift run` 终端可见）和统一日志（subsystem "session"）。
/// 拦截相关事件总是输出；逐次采样的详情需要设置 `SESSION_DEBUG=1`。
enum Log {
    static let verbose = ProcessInfo.processInfo.environment["SESSION_DEBUG"] == "1"
    private static let logger = Logger(subsystem: "session", category: "block")
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    static func info(_ message: String) {
        FileHandle.standardError.write(Data("[\(stamp.string(from: Date()))] \(message)\n".utf8))
        logger.info("\(message, privacy: .public)")
    }

    static func debug(_ message: @autoclosure () -> String) {
        if verbose { info(message()) }
    }
}
