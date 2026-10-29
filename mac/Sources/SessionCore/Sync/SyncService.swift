import Foundation

public protocol SessionUploading: Sendable {
    func syncSessions(_ batch: [(session: SessionRecord, spans: [ActivitySpan])]) async throws -> SyncResult
    /// 返回后端已处理的 id。
    func deleteSessions(_ ids: [String]) async throws -> [String]
}
extension APIClient: SessionUploading {}

/// 指数退避：失败 n 次后等待 min(base * 2^(n-1), cap) 秒；成功后清零。
public struct Backoff: Equatable, Sendable {
    public private(set) var failures = 0
    private let base: TimeInterval, cap: TimeInterval
    public init(base: TimeInterval = 5, cap: TimeInterval = 900) { self.base = base; self.cap = cap }
    public mutating func recordFailure() { failures += 1 }
    public mutating func recordSuccess() { failures = 0 }
    public var delay: TimeInterval { failures == 0 ? 0 : min(base * pow(2, Double(failures - 1)), cap) }
}

public enum SyncOutcome: Equatable, Sendable {
    case nothingToSync
    case synced(accepted: Int, rejected: Int)
    case failed
}

public final class SyncService: @unchecked Sendable {
    private let store: LocalStore
    private let uploader: SessionUploading
    private let batchSize: Int
    private let lock = NSLock()
    private var running = false
    private var backoff = Backoff()
    private var nextAttempt: Date = .distantPast
    private let clock: Clock

    public init(store: LocalStore, uploader: SessionUploading, clock: Clock = SystemClock(), batchSize: Int = 20) {
        self.store = store; self.uploader = uploader; self.clock = clock; self.batchSize = batchSize
    }

    /// 是否到了可以重试的时间（给定时器用）。
    public var isDue: Bool { lock.withLock { clock.now >= nextAttempt } }

    /// 先同步删除，再上传一批待同步的 session。并发调用时后来者直接返回 .nothingToSync。
    @discardableResult
    public func flush(force: Bool = false) async -> SyncOutcome {
        let proceed: Bool = lock.withLock {
            if running || (!force && clock.now < nextAttempt) { return false }
            running = true
            return true
        }
        guard proceed else { return .nothingToSync }
        defer { lock.withLock { running = false } }

        do {
            let deletions = try store.pendingDeletions(limit: 100)
            if !deletions.isEmpty { try store.clearDeletions(try await uploader.deleteSessions(deletions)) }
            let batch = try store.pending(limit: batchSize)
            guard !batch.isEmpty else {
                if !deletions.isEmpty { lock.withLock { backoff.recordSuccess(); nextAttempt = .distantPast } }
                return deletions.isEmpty ? .nothingToSync : .synced(accepted: 0, rejected: 0)
            }
            var accepted = 0, rejected = 0
            do {
                let result = try await uploader.syncSessions(batch)
                try store.markSynced(result.accepted)
                try store.markRejected(result.rejected.map(\.id))
                accepted = result.accepted.count; rejected = result.rejected.count
            } catch let e as APIError where e.isPermanentRejection && batch.count > 1 {
                // 服务端整批拒绝：逐条重试，把永久无效的 session 隔离出去，避免毒丸阻塞后续同步。
                for item in batch {
                    do {
                        let r = try await uploader.syncSessions([item])
                        try store.markSynced(r.accepted)
                        try store.markRejected(r.rejected.map(\.id))
                        accepted += r.accepted.count; rejected += r.rejected.count
                    } catch let e as APIError where e.isPermanentRejection {
                        try store.markRejected([item.session.id])
                        rejected += 1
                    }
                }
            } catch let e as APIError where e.isPermanentRejection {
                try store.markRejected(batch.map(\.session.id))
                rejected = batch.count
            }
            lock.withLock { backoff.recordSuccess(); nextAttempt = .distantPast }
            return .synced(accepted: accepted, rejected: rejected)
        } catch {
            lock.withLock {
                backoff.recordFailure()
                nextAttempt = clock.now.addingTimeInterval(backoff.delay)
            }
            return .failed
        }
    }
}
