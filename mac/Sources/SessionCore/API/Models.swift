import Foundation

public struct TodoistTask: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let content: String
    public let projectId: String
    public let priority: Int
    public let dueDate: String?
    public let isRecurring: Bool

    public init(id: String, content: String, projectId: String, priority: Int, dueDate: String?, isRecurring: Bool) {
        self.id = id; self.content = content; self.projectId = projectId
        self.priority = priority; self.dueDate = dueDate; self.isRecurring = isRecurring
    }
}

public struct Category: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let color: String
    public let todoistProjectId: String?

    public init(id: String, name: String, color: String, todoistProjectId: String?) {
        self.id = id; self.name = name; self.color = color; self.todoistProjectId = todoistProjectId
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
