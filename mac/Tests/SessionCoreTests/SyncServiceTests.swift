import XCTest
@testable import SessionCore

final class FakeUploader: SessionUploading, @unchecked Sendable {
    var calls: [[String]] = []
    var result: Result<SyncResult, Error> = .success(SyncResult(accepted: [], rejected: []))
    /// 为 nil 时接受全部。
    var respond: (([String]) -> Result<SyncResult, Error>)?
    func syncSessions(_ batch: [(session: SessionRecord, spans: [ActivitySpan])]) async throws -> SyncResult {
        let ids = batch.map(\.session.id)
        calls.append(ids)
        return try (respond?(ids) ?? result).get()
    }
}

private struct Boom: Error {}

final class SyncServiceTests: XCTestCase {
    var store: LocalStore!
    var uploader: FakeUploader!
    var clock: FakeClock!
    var service: SyncService!

    override func setUpWithError() throws {
        store = try LocalStore(path: nil)
        uploader = FakeUploader()
        clock = FakeClock()
        service = SyncService(store: store, uploader: uploader, clock: clock)
    }

    private func save(_ id: String, start: TimeInterval = 1_000) throws {
        try store.save(SessionRecord(id: id, title: "t", categoryId: nil, source: .custom, todoistTaskId: nil,
                                     entryId: nil, plannedSeconds: 60, actualSeconds: 60,
                                     startedAt: Date(timeIntervalSince1970: start),
                                     endedAt: Date(timeIntervalSince1970: start + 60)))
    }

    func testUploadsPendingAndMarksAccepted() async throws {
        try save("a", start: 1_000); try save("b", start: 2_000)
        uploader.respond = { ids in .success(SyncResult(accepted: ids, rejected: [])) }
        let outcome = await service.flush()
        XCTAssertEqual(outcome, .synced(accepted: 2, rejected: 0))
        XCTAssertEqual(try store.pendingCount(), 0)
    }

    func testRejectedAreMarkedAndNotRetried() async throws {
        try save("a", start: 1_000); try save("b", start: 2_000)
        uploader.result = .success(SyncResult(accepted: ["a"], rejected: [.init(id: "b", reason: "CONFLICT")]))
        _ = await service.flush()
        let all = try store.sessions(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(all.first { $0.id == "b" }?.syncState, .rejected)
        let again = await service.flush()
        XCTAssertEqual(again, .nothingToSync)
    }

    func testFailureKeepsPendingAndBacksOff() async throws {
        try save("a")
        uploader.result = .failure(Boom())
        let first = await service.flush()
        XCTAssertEqual(first, .failed)
        XCTAssertEqual(try store.pendingCount(), 1)
        XCTAssertEqual(uploader.calls.count, 1)

        clock.advance(2)                       // 退避 5 秒，未到
        let early = await service.flush()
        XCTAssertEqual(early, .nothingToSync)
        XCTAssertEqual(uploader.calls.count, 1)
        XCTAssertFalse(service.isDue)

        clock.advance(4)                       // 共 6 秒，已过
        XCTAssertTrue(service.isDue)
        _ = await service.flush()
        XCTAssertEqual(uploader.calls.count, 2)

        _ = await service.flush(force: true)   // 无视退避
        XCTAssertEqual(uploader.calls.count, 3)
    }

    func testSuccessResetsBackoff() async throws {
        try save("a")
        uploader.result = .failure(Boom())
        _ = await service.flush()
        uploader.result = .success(SyncResult(accepted: ["a"], rejected: []))
        _ = await service.flush(force: true)
        XCTAssertTrue(service.isDue)
    }

    func testBackoffDoublesAndCaps() {
        var b = Backoff()
        XCTAssertEqual(b.delay, 0)
        b.recordFailure(); XCTAssertEqual(b.delay, 5)
        b.recordFailure(); XCTAssertEqual(b.delay, 10)
        b.recordFailure(); XCTAssertEqual(b.delay, 20)
        for _ in 0..<7 { b.recordFailure() }
        XCTAssertEqual(b.delay, 900)
        b.recordSuccess(); XCTAssertEqual(b.delay, 0)
    }

    func testNothingToSyncDoesNotCallUploader() async {
        let outcome = await service.flush()
        XCTAssertEqual(outcome, .nothingToSync)
        XCTAssertTrue(uploader.calls.isEmpty)
    }
}
