import Foundation

public enum SyncState: String, Sendable { case pending, synced, rejected }

public struct SessionRecord: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let categoryId: String?
    public let source: SessionSource
    public let todoistTaskId: String?
    public let entryId: String?
    public let plannedSeconds: Int
    public let actualSeconds: Int
    public let startedAt: Date
    public let endedAt: Date
    public var syncState: SyncState

    public init(id: String, title: String, categoryId: String?, source: SessionSource,
                todoistTaskId: String?, entryId: String?, plannedSeconds: Int, actualSeconds: Int,
                startedAt: Date, endedAt: Date, syncState: SyncState = .pending) {
        self.id = id; self.title = title; self.categoryId = categoryId; self.source = source
        self.todoistTaskId = todoistTaskId; self.entryId = entryId; self.plannedSeconds = plannedSeconds
        self.actualSeconds = actualSeconds; self.startedAt = startedAt; self.endedAt = endedAt
        self.syncState = syncState
    }

    public init(_ done: CompletedFocus) {
        self.init(id: done.run.id.uuidString.lowercased(), title: done.run.title,
                  categoryId: done.run.categoryId, source: done.run.source,
                  todoistTaskId: done.run.todoistTaskId, entryId: done.run.entryId,
                  plannedSeconds: done.run.plannedSeconds, actualSeconds: done.actualSeconds,
                  startedAt: done.run.startedAt, endedAt: done.endedAt)
    }
}
