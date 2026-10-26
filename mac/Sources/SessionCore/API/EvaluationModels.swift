import Foundation

/// 后端时间戳为毫秒整数。
private func date(fromMs ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

public struct Evaluation: Decodable, Equatable, Sendable {
    public enum Status: String, Decodable, Sendable { case pending, done, failed }

    public struct Distraction: Decodable, Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let reason: String

        public init(start: Date, end: Date, reason: String) { self.start = start; self.end = end; self.reason = reason }

        private enum CodingKeys: String, CodingKey { case start, end, reason }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            start = date(fromMs: try c.decode(Int64.self, forKey: .start))
            end = date(fromMs: try c.decode(Int64.self, forKey: .end))
            reason = try c.decode(String.self, forKey: .reason)
        }
    }

    public let status: Status
    public let focusScore: Int?
    public let summary: String?
    public let attempts: Int
    public let distractions: [Distraction]

    public init(status: Status, focusScore: Int?, summary: String?, attempts: Int, distractions: [Distraction]) {
        self.status = status; self.focusScore = focusScore; self.summary = summary
        self.attempts = attempts; self.distractions = distractions
    }
}

/// `GET /sessions` 的一项；只解码 Mac 端用到的字段。
public struct RemoteSession: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let startedAt: Date
    public let endedAt: Date
    public let evaluation: Evaluation?

    public init(id: String, title: String, startedAt: Date, endedAt: Date, evaluation: Evaluation?) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.endedAt = endedAt; self.evaluation = evaluation
    }

    private enum CodingKeys: String, CodingKey { case id, title, startedAt, endedAt, evaluation }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        startedAt = date(fromMs: try c.decode(Int64.self, forKey: .startedAt))
        endedAt = date(fromMs: try c.decode(Int64.self, forKey: .endedAt))
        evaluation = try c.decodeIfPresent(Evaluation.self, forKey: .evaluation)
    }
}

/// 评估展示的纯逻辑（UI 只负责渲染）。
public enum EvaluationDisplay {
    /// 时间轴色块上的徽标：无评估 nil；pending `…`；failed（或缺分数）`—`；done 为分数。
    public static func badge(for evaluation: Evaluation?) -> String? {
        guard let evaluation else { return nil }
        switch evaluation.status {
        case .pending: return "…"
        case .failed: return "—"
        case .done: return evaluation.focusScore.map(String.init) ?? "—"
        }
    }

    /// 给定 session 中只要有一个仍是 pending 就需要继续轮询。
    public static func needsPolling(_ evaluations: [String: Evaluation], sessionIds: [String]) -> Bool {
        sessionIds.contains { evaluations[$0]?.status == .pending }
    }

    public static func evaluations(from sessions: [RemoteSession]) -> [String: Evaluation] {
        var out: [String: Evaluation] = [:]
        for s in sessions { if let e = s.evaluation { out[s.id] = e } }
        return out
    }
}

public struct StatsSummary: Decodable, Equatable, Sendable {
    public struct Day: Decodable, Equatable, Sendable {
        public let date: String
        public let focusSeconds: Int
        public let sessionCount: Int
        public let avgFocusScore: Int?
    }
    public struct CategoryShare: Decodable, Equatable, Sendable {
        public let categoryId: String?
        public let focusSeconds: Int
    }
    public let totalFocusSeconds: Int
    public let sessionCount: Int
    public let avgFocusScore: Int?
    public let activeSeconds: Int
    public let idleSeconds: Int
    public let days: [Day]
    public let byCategory: [CategoryShare]
}

/// `GET /settings` 的完整对象。
public struct RemoteSettings: Codable, Equatable, Sendable {
    public var focusSeconds: Int
    public var idleThresholdSeconds: Int
    public var blockApps: [String]
    public var blockDomains: [String]
    /// categoryId → profile。旧后端没有这个字段时为空。
    public var profiles: [String: CategoryProfile]

    public init(focusSeconds: Int, idleThresholdSeconds: Int, blockApps: [String], blockDomains: [String],
                profiles: [String: CategoryProfile] = [:]) {
        self.focusSeconds = focusSeconds; self.idleThresholdSeconds = idleThresholdSeconds
        self.blockApps = blockApps; self.blockDomains = blockDomains; self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey { case focusSeconds, idleThresholdSeconds, blockApps, blockDomains, profiles }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        focusSeconds = try c.decode(Int.self, forKey: .focusSeconds)
        idleThresholdSeconds = try c.decode(Int.self, forKey: .idleThresholdSeconds)
        blockApps = try c.decode([String].self, forKey: .blockApps)
        blockDomains = try c.decode([String].self, forKey: .blockDomains)
        profiles = try c.decodeIfPresent([String: CategoryProfile].self, forKey: .profiles) ?? [:]
    }
}

/// `PUT /settings` 的部分更新；nil 字段不会发送（Codable 默认省略 nil）。
public struct SettingsPatch: Encodable, Equatable, Sendable {
    public var focusSeconds: Int?
    public var idleThresholdSeconds: Int?
    public var blockApps: [String]?
    public var blockDomains: [String]?
    public var profiles: [String: CategoryProfile]?

    public init(focusSeconds: Int? = nil, idleThresholdSeconds: Int? = nil,
                blockApps: [String]? = nil, blockDomains: [String]? = nil, profiles: [String: CategoryProfile]? = nil) {
        self.focusSeconds = focusSeconds; self.idleThresholdSeconds = idleThresholdSeconds
        self.blockApps = blockApps; self.blockDomains = blockDomains; self.profiles = profiles
    }
}
