import Foundation
import GRDB

/// 本地 SQLite：已完成的专注、活动 span，以及上传状态（outbox = sync_state 为 pending 的行）。
public final class LocalStore: @unchecked Sendable {
    private let db: DatabaseQueue

    /// path 为 nil 时使用内存库（测试）。
    public init(path: String?) throws {
        if let path {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            db = try DatabaseQueue(path: path)
        } else {
            db = try DatabaseQueue()
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY, title TEXT NOT NULL, category_id TEXT, source TEXT NOT NULL,
                  todoist_task_id TEXT, entry_id TEXT, planned_seconds INTEGER NOT NULL,
                  actual_seconds INTEGER NOT NULL, started_at INTEGER NOT NULL, ended_at INTEGER NOT NULL,
                  sync_state TEXT NOT NULL DEFAULT 'pending');
                CREATE INDEX sessions_started ON sessions(started_at);
                CREATE TABLE spans (
                  id TEXT PRIMARY KEY, session_id TEXT NOT NULL, kind TEXT NOT NULL,
                  app_bundle_id TEXT, app_name TEXT, window_title TEXT, url_host TEXT, url_path TEXT,
                  started_at INTEGER NOT NULL, ended_at INTEGER NOT NULL, was_blocked INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX spans_session ON spans(session_id);
                """)
        }
        try migrator.migrate(db)
    }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    // MARK: 写

    public func save(_ r: SessionRecord) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO sessions(id, title, category_id, source, todoist_task_id, entry_id,
                  planned_seconds, actual_seconds, started_at, ended_at, sync_state)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [r.id, r.title, r.categoryId, r.source.rawValue, r.todoistTaskId, r.entryId,
                                 r.plannedSeconds, r.actualSeconds, Self.ms(r.startedAt), Self.ms(r.endedAt),
                                 r.syncState.rawValue])
        }
    }

    public func append(_ spans: [ActivitySpan]) throws {
        guard !spans.isEmpty else { return }
        try db.write { db in
            for s in spans {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO spans(id, session_id, kind, app_bundle_id, app_name, window_title,
                      url_host, url_path, started_at, ended_at, was_blocked)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [s.id, s.sessionId, s.kind.rawValue, s.appBundleId, s.appName, s.windowTitle,
                                     s.urlHost, s.urlPath, Self.ms(s.startedAt), Self.ms(s.endedAt), s.wasBlocked])
            }
        }
    }

    public func deleteSpans(sessionId: String) throws {
        try db.write { try $0.execute(sql: "DELETE FROM spans WHERE session_id = ?", arguments: [sessionId]) }
    }

    /// 清理崩溃/放弃遗留的 span：既没有对应 session，也不是当前进行中的那次。
    public func pruneOrphanSpans(keeping activeId: String?) throws {
        try db.write { db in
            try db.execute(sql: """
                DELETE FROM spans WHERE session_id NOT IN (SELECT id FROM sessions)
                  AND session_id IS NOT ?
                """, arguments: [activeId])
        }
    }

    public func markSynced(_ ids: [String]) throws { try mark(ids, .synced) }
    public func markRejected(_ ids: [String]) throws { try mark(ids, .rejected) }

    private func mark(_ ids: [String], _ state: SyncState) throws {
        guard !ids.isEmpty else { return }
        try db.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE sessions SET sync_state = ? WHERE id = ?", arguments: [state.rawValue, id])
            }
        }
    }

    // MARK: 读

    public func sessions(from: Date, to: Date) throws -> [SessionRecord] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sessions WHERE started_at >= ? AND started_at < ? ORDER BY started_at",
                             arguments: [Self.ms(from), Self.ms(to)]).map(Self.record)
        }
    }

    public func spans(sessionId: String) throws -> [ActivitySpan] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM spans WHERE session_id = ? ORDER BY started_at, rowid",
                             arguments: [sessionId]).map(Self.span)
        }
    }

    public func pending(limit: Int) throws -> [(session: SessionRecord, spans: [ActivitySpan])] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM sessions WHERE sync_state = 'pending' ORDER BY started_at LIMIT ?",
                                        arguments: [limit])
            return try rows.map { row in
                let rec = Self.record(row)
                let spans = try Row.fetchAll(db, sql: "SELECT * FROM spans WHERE session_id = ? ORDER BY started_at, rowid",
                                             arguments: [rec.id]).map(Self.span)
                return (rec, spans)
            }
        }
    }

    public func pendingCount() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions WHERE sync_state = 'pending'") ?? 0 }
    }

    private static func record(_ r: Row) -> SessionRecord {
        SessionRecord(id: r["id"], title: r["title"], categoryId: r["category_id"],
                      source: SessionSource(rawValue: r["source"]) ?? .custom,
                      todoistTaskId: r["todoist_task_id"], entryId: r["entry_id"],
                      plannedSeconds: r["planned_seconds"], actualSeconds: r["actual_seconds"],
                      startedAt: date(r["started_at"]), endedAt: date(r["ended_at"]),
                      syncState: SyncState(rawValue: r["sync_state"]) ?? .pending)
    }

    private static func span(_ r: Row) -> ActivitySpan {
        ActivitySpan(id: r["id"], sessionId: r["session_id"], kind: SpanKind(rawValue: r["kind"]) ?? .active,
                     appBundleId: r["app_bundle_id"], appName: r["app_name"], windowTitle: r["window_title"],
                     urlHost: r["url_host"], urlPath: r["url_path"],
                     startedAt: date(r["started_at"]), endedAt: date(r["ended_at"]),
                     wasBlocked: r["was_blocked"])
    }
}
