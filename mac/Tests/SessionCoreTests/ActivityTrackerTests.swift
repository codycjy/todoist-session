import XCTest
@testable import SessionCore

final class FakeSampler: ActivitySampler {
    var idle: TimeInterval = 0
    var front = FrontmostInfo(bundleId: "com.apple.dt.Xcode", appName: "Xcode", windowTitle: "a.swift", urlHost: nil)
    private(set) var frontmostCalls = 0
    func idleSeconds() -> TimeInterval { idle }
    func frontmost() -> FrontmostInfo { frontmostCalls += 1; return front }
}

final class SpyEnforcer: BlockEnforcer {
    struct Call: Equatable { let decision: BlockDecision; let focusTitle: String; let remaining: Int }
    private(set) var calls: [Call] = []
    func enforce(_ decision: BlockDecision, focusTitle: String, remainingSeconds: Int) {
        calls.append(Call(decision: decision, focusTitle: focusTitle, remaining: remainingSeconds))
    }
}

final class ActivityTrackerTests: XCTestCase {
    var sampler: FakeSampler!
    var enforcer: SpyEnforcer!
    var store: LocalStore!
    var clock: FakeClock!
    var run: FocusRun!
    var sid: String { run.id.uuidString.lowercased() }

    override func setUpWithError() throws {
        sampler = FakeSampler(); enforcer = SpyEnforcer(); store = try LocalStore(path: nil); clock = FakeClock()
        run = FocusRun(id: UUID(), title: "写周报", categoryId: nil, source: .custom, todoistTaskId: nil,
                       entryId: nil, startedAt: clock.now, plannedSeconds: 1500)
    }

    private func makeTracker(_ list: BlockList = BlockList()) -> ActivityTracker {
        ActivityTracker(sampler: sampler, enforcer: enforcer, store: store, clock: clock, blocklist: list)
    }

    func testRecordsActiveSpanAcrossSamplesAndPersistsOnStop() throws {
        let t = makeTracker()
        let t0 = clock.now
        t.start(run: run)
        clock.advance(2); t.sample()
        clock.advance(2); t.sample()
        t.stop(at: clock.now)
        let spans = try store.spans(sessionId: sid)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].kind, .active)
        XCTAssertEqual(spans[0].startedAt, t0)
        XCTAssertEqual(spans[0].endedAt, t0.addingTimeInterval(4))
    }

    func testOpenSpanIsCheckpointedSoCrashKeepsCollectedActivity() throws {
        let t = makeTracker()
        let t0 = clock.now
        t.start(run: run)
        clock.advance(2); t.sample()
        clock.advance(2); t.sample()
        // 不调用 stop：模拟进程被强退
        let spans = try store.spans(sessionId: sid)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].startedAt, t0)
        XCTAssertEqual(spans[0].endedAt, t0.addingTimeInterval(4))
    }

    func testResumeAfterRestartFillsDowntimeWithIdleSpan() throws {
        let first = makeTracker()
        let t0 = clock.now
        first.start(run: run)
        clock.advance(4); first.sample()              // 崩溃前最后一次采样
        clock.advance(300)                            // 应用未运行 5 分钟
        let second = makeTracker()
        second.start(run: run)
        clock.advance(2); second.sample()
        second.stop(at: clock.now)
        let spans = try store.spans(sessionId: sid).sorted { $0.startedAt < $1.startedAt }
        let gap = try XCTUnwrap(spans.first { $0.kind == .idle })
        XCTAssertEqual(gap.startedAt, t0.addingTimeInterval(4))
        XCTAssertEqual(gap.endedAt, t0.addingTimeInterval(304))
        XCTAssertEqual(spans.count, 3)
    }

    func testCloseRecoveredFillsUntilPlannedEnd() throws {
        let first = makeTracker()
        let t0 = clock.now
        first.start(run: run)
        clock.advance(4); first.sample()
        let second = makeTracker()
        second.closeRecovered(run: run, at: run.endAt)
        let idle = try XCTUnwrap(try store.spans(sessionId: sid).first { $0.kind == .idle })
        XCTAssertEqual(idle.startedAt, t0.addingTimeInterval(4))
        XCTAssertEqual(idle.endedAt, run.endAt)
    }

    func testIdleSampleDoesNotReadFrontmost() throws {
        let t = makeTracker()
        t.start(run: run)
        XCTAssertEqual(sampler.frontmostCalls, 1)
        sampler.idle = 200
        clock.advance(2); t.sample()
        clock.advance(2); t.sample()
        XCTAssertEqual(sampler.frontmostCalls, 1)
        t.stop(at: clock.now)
        XCTAssertTrue(try store.spans(sessionId: sid).contains { $0.kind == .idle })
    }

    func testBlockedAppIsEnforcedAndSpanFlagged() throws {
        sampler.front = FrontmostInfo(bundleId: "com.tencent.xinWeChat", appName: "WeChat", windowTitle: nil, urlHost: nil)
        let t = makeTracker(BlockList(apps: ["com.tencent.xinWeChat"]))
        t.start(run: run)
        XCTAssertEqual(enforcer.calls, [.init(decision: .hideApp(bundleId: "com.tencent.xinWeChat"),
                                              focusTitle: "写周报", remaining: 1500)])
        clock.advance(2)
        t.stop(at: clock.now)
        XCTAssertEqual(try store.spans(sessionId: sid).map(\.wasBlocked), [true])
    }

    func testBlockedSiteTriggersRedirectDecision() {
        sampler.front = FrontmostInfo(bundleId: "com.google.Chrome", appName: "Chrome", windowTitle: "x", urlHost: "www.youtube.com")
        let t = makeTracker(BlockList(domains: ["youtube.com"]))
        t.start(run: run)
        XCTAssertEqual(enforcer.calls.first?.decision, .redirectSite(host: "www.youtube.com"))
    }

    func testDiscardRemovesPersistedSpans() throws {
        let t = makeTracker()
        t.start(run: run)
        clock.advance(2); sampler.front = FrontmostInfo(bundleId: "com.apple.dt.Xcode", appName: "Xcode", windowTitle: "b.swift", urlHost: nil)
        t.sample()
        XCTAssertEqual(try store.spans(sessionId: sid).count, 1)
        t.discard()
        XCTAssertTrue(try store.spans(sessionId: sid).isEmpty)
        XCTAssertFalse(t.isRunning)
    }

    func testSampleAfterStopIsNoOp() {
        let t = makeTracker()
        t.start(run: run)
        t.stop(at: clock.now)
        let before = sampler.frontmostCalls
        t.sample()
        XCTAssertEqual(sampler.frontmostCalls, before)
    }

    func testNoEnforcementWhenNothingMatches() {
        let t = makeTracker(BlockList(apps: ["x"], domains: ["y.com"]))
        t.start(run: run)
        clock.advance(2); t.sample()
        XCTAssertTrue(enforcer.calls.isEmpty)
    }
}
