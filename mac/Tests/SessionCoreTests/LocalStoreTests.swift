import XCTest
@testable import SessionCore

final class LocalStoreTests: XCTestCase {
    private func record(_ id: String, start: TimeInterval = 1_000, end: TimeInterval = 2_500) -> SessionRecord {
        SessionRecord(id: id, title: "写周报", categoryId: "c1", source: .custom, todoistTaskId: nil,
                      entryId: nil, plannedSeconds: 1500, actualSeconds: 1500,
                      startedAt: Date(timeIntervalSince1970: start), endedAt: Date(timeIntervalSince1970: end))
    }
    private func span(_ id: String, session: String, kind: SpanKind = .active, blocked: Bool = false) -> ActivitySpan {
        ActivitySpan(id: id, sessionId: session, kind: kind, appBundleId: "com.apple.dt.Xcode", appName: "Xcode",
                     windowTitle: "a.swift", urlHost: nil, startedAt: Date(timeIntervalSince1970: 1_000),
                     endedAt: Date(timeIntervalSince1970: 1_060), wasBlocked: blocked)
    }

    func testSaveAndReadBackSession() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("s1"))
        let got = try store.sessions(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(got, [record("s1")])
    }

    func testSavingSameSessionTwiceKeepsOneRow() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("s1")); try store.save(record("s1"))
        XCTAssertEqual(try store.sessions(from: .distantPast, to: .distantFuture).count, 1)
    }

    func testSessionsFilteredByRangeAndOrderedByStart() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("late", start: 5_000, end: 6_000))
        try store.save(record("early", start: 1_000, end: 2_000))
        try store.save(record("outside", start: 90_000, end: 91_000))
        let got = try store.sessions(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(got.map(\.id), ["early", "late"])
    }

    func testSpansRoundTripAndAreDeletableBySession() throws {
        let store = try LocalStore(path: nil)
        try store.append([span("p1", session: "s1", blocked: true), span("p2", session: "s1", kind: .idle), span("p3", session: "s2")])
        let s1 = try store.spans(sessionId: "s1")
        XCTAssertEqual(s1.map(\.id), ["p1", "p2"])
        XCTAssertTrue(s1[0].wasBlocked)
        try store.deleteSpans(sessionId: "s1")
        XCTAssertTrue(try store.spans(sessionId: "s1").isEmpty)
        XCTAssertEqual(try store.spans(sessionId: "s2").count, 1)
    }

    func testPruneOrphanSpansKeepsSavedSessionsAndTheActiveOne() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("saved"))
        try store.append([span("a", session: "saved"), span("b", session: "active"), span("c", session: "dead")])
        try store.pruneOrphanSpans(keeping: "active")
        XCTAssertEqual(try store.spans(sessionId: "saved").count, 1)
        XCTAssertEqual(try store.spans(sessionId: "active").count, 1)
        XCTAssertTrue(try store.spans(sessionId: "dead").isEmpty)
    }

    func testPendingReturnsOnlyPendingWithSpansAndRespectsLimit() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("a", start: 1_000)); try store.save(record("b", start: 2_000)); try store.save(record("c", start: 3_000))
        try store.append([span("p1", session: "a")])
        try store.markSynced(["b"])
        let batch = try store.pending(limit: 5)
        XCTAssertEqual(batch.map(\.session.id), ["a", "c"])
        XCTAssertEqual(batch[0].spans.map(\.id), ["p1"])
        XCTAssertEqual(try store.pending(limit: 1).count, 1)
    }

    func testMarkSyncedAndRejectedChangeState() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("a")); try store.save(record("b"))
        try store.markSynced(["a"]); try store.markRejected(["b"])
        let all = try store.sessions(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.syncState) }), ["a": .synced, "b": .rejected])
        XCTAssertTrue(try store.pending(limit: 10).isEmpty)
    }

    func testPendingCount() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("a")); try store.save(record("b")); try store.markSynced(["a"])
        XCTAssertEqual(try store.pendingCount(), 1)
    }

    func testEditUpdatesTitleDurationAndTrimsSpans() throws {
        let store = try LocalStore(path: nil)
        try store.save(record("s1"))
        try store.markSynced(["s1"])
        func at(_ id: String, _ a: TimeInterval, _ b: TimeInterval) -> ActivitySpan {
            ActivitySpan(id: id, sessionId: "s1", kind: .active, appBundleId: nil, appName: "Xcode", windowTitle: nil,
                         urlHost: nil, startedAt: Date(timeIntervalSince1970: a), endedAt: Date(timeIntervalSince1970: b),
                         wasBlocked: false)
        }
        try store.append([at("a", 1_000, 1_500), at("b", 1_500, 1_800), at("c", 1_900, 2_500)])

        try store.edit(sessionId: "s1", title: "改过的标题", actualSeconds: 600)   // 结束于 1_600

        let got = try XCTUnwrap(store.sessions(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 10_000)).first)
        XCTAssertEqual(got.title, "改过的标题")
        XCTAssertEqual(got.actualSeconds, 600)
        XCTAssertEqual(got.endedAt, Date(timeIntervalSince1970: 1_600))
        XCTAssertEqual(got.syncState, .pending, "edited sessions are re-uploaded")
        let spans = try store.spans(sessionId: "s1")
        XCTAssertEqual(spans.map(\.id), ["a", "b"])
        XCTAssertEqual(spans.last?.endedAt, Date(timeIntervalSince1970: 1_600))
    }

    func testEditUnknownSessionIsNoOp() throws {
        let store = try LocalStore(path: nil)
        XCTAssertNoThrow(try store.edit(sessionId: "nope", title: "x", actualSeconds: 60))
        XCTAssertEqual(try store.pendingCount(), 0)
    }
}
