import Foundation

public enum SpanKind: String, Codable, Sendable { case active, idle }

/// 一次采样的前台信息；闲置时不采集标题/URL，全部为 nil。
public struct ActivitySample: Equatable, Sendable {
    public let time: Date
    public let idleSeconds: TimeInterval
    public let appBundleId: String?
    public let appName: String?
    public let windowTitle: String?
    public let urlHost: String?
    public let wasBlocked: Bool

    public init(time: Date, idleSeconds: TimeInterval = 0, appBundleId: String? = nil, appName: String? = nil,
                windowTitle: String? = nil, urlHost: String? = nil, wasBlocked: Bool = false) {
        self.time = time; self.idleSeconds = idleSeconds; self.appBundleId = appBundleId
        self.appName = appName; self.windowTitle = windowTitle; self.urlHost = urlHost
        self.wasBlocked = wasBlocked
    }
}

public struct ActivitySpan: Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let kind: SpanKind
    public let appBundleId: String?
    public let appName: String?
    public let windowTitle: String?
    public let urlHost: String?
    public let urlPath: String?
    public let startedAt: Date
    public let endedAt: Date
    public let wasBlocked: Bool

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    public init(id: String = UUID().uuidString.lowercased(), sessionId: String, kind: SpanKind,
                appBundleId: String?, appName: String?, windowTitle: String?, urlHost: String?,
                urlPath: String? = nil, startedAt: Date, endedAt: Date, wasBlocked: Bool) {
        self.id = id; self.sessionId = sessionId; self.kind = kind; self.appBundleId = appBundleId
        self.appName = appName; self.windowTitle = windowTitle; self.urlHost = urlHost
        self.urlPath = urlPath; self.startedAt = startedAt; self.endedAt = endedAt
        self.wasBlocked = wasBlocked
    }
}
