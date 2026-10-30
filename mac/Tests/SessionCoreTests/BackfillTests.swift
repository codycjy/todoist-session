import XCTest
@testable import SessionCore

final class BackfillTests: XCTestCase {
    var sampler: FakeSampler!
    var store: LocalStore!
    var clock: FakeClock!

    override func setUpWithError() throws {
        sampler = FakeSampler(); store = try LocalStore(path: nil); clock = FakeClock()
    }

    private func session(_ title: String, start: Date, minutes: Int) -> SessionRecord {
        SessionRecord(id: title, title: title, categoryId: nil, source: .custom, todoistTaskId: nil, entryId: nil,
                      plannedSeconds: minutes * 60, actualSeconds: minutes * 60, startedAt: start,
                      endedAt: start.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    func testRecorderWritesAmbientSpansAndRestartsAfterStop() throws {
        let r = AmbientRecorder(sampler: sampler, store: store, clock: clock)
        let t0 = clock.now
        r.sample(); clock.advance(5); r.sample()
        sampler.front = FrontmostInfo(bundleId: "com.google.Chrome", appName: "Chrome", windowTitle: "x", urlHost: "x.com")
        clock.advance(5); r.sample()
        clock.advance(5); r.stop(at: clock.now)
        XCTAssertFalse(r.isRunning)
        let spans = try store.ambientSpans(from: t0, to: clock.now)
        XCTAssertEqual(spans.map(\.appName), ["Xcode", "Chrome"])
        XCTAssertEqual(spans.last?.endedAt, clock.now)
        XCTAssertTrue(try store.spans(sessionId: "").isEmpty, "never mixed into session spans")
    }

    func testPruneDropsOldAmbient() throws {
        let r = AmbientRecorder(sampler: sampler, store: store, clock: clock)
        let t0 = clock.now
        r.sample(); clock.advance(5); r.sample(); r.stop(at: clock.now)
        clock.advance(TimeInterval(AmbientRecorder.retentionDays + 1) * 86_400)
        r.prune()
        XCTAssertTrue(try store.ambientSpans(from: t0, to: clock.now).isEmpty)
    }

    func testClipsSpansIntoNewSession() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = ActivitySpan(sessionId: "", kind: .active, appBundleId: nil, appName: "Xcode", windowTitle: nil, urlHost: nil,
                             startedAt: t0, endedAt: t0.addingTimeInterval(600), wasBlocked: false)
        let b = ActivitySpan(sessionId: "", kind: .idle, appBundleId: nil, appName: nil, windowTitle: nil, urlHost: nil,
                             startedAt: t0.addingTimeInterval(600), endedAt: t0.addingTimeInterval(1200), wasBlocked: false)
        let out = Backfill.spans([a, b], from: t0.addingTimeInterval(300), to: t0.addingTimeInterval(900), sessionId: "s")
        XCTAssertEqual(out.map(\.duration), [300, 300])
        XCTAssertEqual(Set(out.map(\.sessionId)), ["s"])
        XCTAssertNotEqual(out[0].id, a.id)
        let sum = Backfill.summary(out)
        XCTAssertEqual(sum.top, [Backfill.Usage(name: "Xcode", seconds: 300)])
        XCTAssertEqual(sum.idleSeconds, 300)
    }

    func testProblems() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let s = session("写周报", start: now.addingTimeInterval(-3600), minutes: 25)
        XCTAssertEqual(Backfill.problem(from: now.addingTimeInterval(-30), to: now, now: now, existing: []), .tooShort)
        XCTAssertEqual(Backfill.problem(from: now.addingTimeInterval(-4 * 3600), to: now, now: now, existing: []), .tooLong)
        XCTAssertEqual(Backfill.problem(from: now, to: now.addingTimeInterval(600), now: now, existing: []), .inFuture)
        XCTAssertEqual(Backfill.problem(from: now.addingTimeInterval(-3000), to: now, now: now, existing: [s]), .overlaps("写周报"))
        XCTAssertNil(Backfill.problem(from: s.endedAt, to: now, now: now, existing: [s]))
    }

    func testSuggestedRangeStartsAfterLastSessionWithinAnHour() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_000_000 * 60 + 30)   // 某分钟的第 30 秒
        let minute = now.addingTimeInterval(-30)
        let recent = session("a", start: minute.addingTimeInterval(-1800), minutes: 10)
        XCTAssertEqual(Backfill.suggestedRange(after: [recent], now: now, calendar: cal).from, minute.addingTimeInterval(-1200))
        XCTAssertEqual(Backfill.suggestedRange(after: [recent], now: now, calendar: cal).to, minute)
        XCTAssertEqual(Backfill.suggestedRange(after: [], now: now, calendar: cal).from, minute.addingTimeInterval(-3600))
    }

    func testSaveBackfillWritesSessionAndSpansAsPending() throws {
        let t0 = clock.now
        let rec = Backfill.record(title: "调 bug", categoryId: "c", from: t0, to: t0.addingTimeInterval(600), allowIdle: false)
        let span = ActivitySpan(sessionId: rec.id, kind: .active, appBundleId: nil, appName: "Xcode", windowTitle: nil,
                                urlHost: nil, startedAt: t0, endedAt: t0.addingTimeInterval(600), wasBlocked: false)
        try store.saveBackfill(rec, spans: [span])
        let pending = try store.pending(limit: 10)
        XCTAssertEqual(pending.first?.session.actualSeconds, 600)
        XCTAssertEqual(pending.first?.spans.count, 1)
    }
}
