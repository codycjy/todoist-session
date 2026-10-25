import Foundation

public protocol SessionUploading: Sendable {
    func syncSessions(_ batch: [(session: SessionRecord, spans: [ActivitySpan])]) async throws -> SyncResult
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

    /// 上传一批待同步的 session。并发调用时后来者直接返回 .nothingToSync。
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
            let batch = try store.pending(limit: batchSize)
            guard !batch.isEmpty else { return .nothingToSync }
            let result = try await uploader.syncSessions(batch)
            try store.markSynced(result.accepted)
            try store.markRejected(result.rejected.map(\.id))
            lock.withLock { backoff.recordSuccess(); nextAttempt = .distantPast }
            return .synced(accepted: result.accepted.count, rejected: result.rejected.count)
        } catch {
            lock.withLock {
                backoff.recordFailure()
                nextAttempt = clock.now.addingTimeInterval(backoff.delay)
            }
            return .failed
        }
    }
}
