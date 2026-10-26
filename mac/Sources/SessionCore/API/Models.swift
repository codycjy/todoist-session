import Foundation

public struct TodoistTask: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let content: String
    public let projectId: String
    public let priority: Int
    public let dueDate: String?
    public let isRecurring: Bool
    public let durationMinutes: Int?
    /// 详情面板用。旧后端不返回这些字段时取空值。
    public let description: String
    public let labels: [String]
    public let parentId: String?
    public let url: String?

    public init(id: String, content: String, projectId: String, priority: Int, dueDate: String?, isRecurring: Bool,
                durationMinutes: Int? = nil, description: String = "", labels: [String] = [],
                parentId: String? = nil, url: String? = nil) {
        self.id = id; self.content = content; self.projectId = projectId
        self.priority = priority; self.dueDate = dueDate; self.isRecurring = isRecurring
        self.durationMinutes = durationMinutes
        self.description = description; self.labels = labels; self.parentId = parentId; self.url = url
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        projectId = try c.decode(String.self, forKey: .projectId)
        priority = try c.decode(Int.self, forKey: .priority)
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate)
        isRecurring = try c.decode(Bool.self, forKey: .isRecurring)
        durationMinutes = try c.decodeIfPresent(Int.self, forKey: .durationMinutes)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        url = try c.decodeIfPresent(String.self, forKey: .url)
    }

    /// 带具体时间的到期（`2026-10-25T15:15:00` 浮动本地时间，或带 `Z` 的 UTC）；只有日期时为 nil。
    public var dueTime: Date? {
        guard let dueDate, dueDate.count > 10 else { return nil }
        if dueDate.hasSuffix("Z") || dueDate.contains("+") {
            return ISO8601DateFormatter().date(from: dueDate)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: String(dueDate.prefix(19)))
    }
}

public struct Category: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let color: String
    public let todoistProjectId: String?
    /// 后端未带 `?all=1` 时没有该字段，缺省为 false。
    public let archived: Bool

    public init(id: String, name: String, color: String, todoistProjectId: String?, archived: Bool = false) {
        self.id = id; self.name = name; self.color = color; self.todoistProjectId = todoistProjectId
        self.archived = archived
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decode(String.self, forKey: .color)
        todoistProjectId = try c.decodeIfPresent(String.self, forKey: .todoistProjectId)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }
}

public struct Entry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let categoryId: String?

    public init(id: String, title: String, categoryId: String?) {
        self.id = id; self.title = title; self.categoryId = categoryId
    }
}

public enum TaskFilter: String, Sendable { case today, overdue }

public struct SyncResult: Decodable, Equatable, Sendable {
    public struct Rejection: Decodable, Equatable, Sendable { public let id: String; public let reason: String }
    public let accepted: [String]
    public let rejected: [Rejection]
}
