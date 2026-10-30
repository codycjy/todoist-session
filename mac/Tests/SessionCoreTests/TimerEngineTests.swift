import XCTest
@testable import SessionCore

final class FakeClock: Clock, @unchecked Sendable {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_000_000)) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

final class InMemoryStateStore: StateStore {
    var saved: TimerPhase?
    var completedCount = 0
    func load() -> TimerPhase? { saved }
    func save(_ phase: TimerPhase) { saved = phase }
}

final class TimerEngineTests: XCTestCase {
    var clock: FakeClock!
    var store: InMemoryStateStore!

    override func setUp() {
        clock = FakeClock()
        store = InMemoryStateStore()
    }

    func makeEngine() -> TimerEngine { TimerEngine(clock: clock, store: store) }

    func spec(_ title: String = "写周报", seconds: Int = 1500) -> FocusSpec {
        FocusSpec(title: title, categoryId: "c1", source: .todoist, todoistTaskId: "t1", entryId: nil, plannedSeconds: seconds)
    }

    func testStartEntersFocusingWithFullRemaining() throws {
        let engine = makeEngine()
        try engine.start(spec())
        guard case .focusing(let run) = engine.phase else { return XCTFail("expected focusing") }
        XCTAssertEqual(run.title, "写周报")
        XCTAssertEqual(run.startedAt, clock.now)
        XCTAssertEqual(engine.remainingSeconds, 1500)
    }

    func testRemainingDecreasesWithClockNotTicks() throws {
        let engine = makeEngine()
        try engine.start(spec())
        clock.advance(600)
        XCTAssertEqual(engine.remainingSeconds, 900)
    }

    func testTickBeforeEndKeepsFocusing() throws {
        let engine = makeEngine()
        try engine.start(spec())
        clock.advance(1499)
        engine.tick()
        if case .focusing = engine.phase {} else { XCTFail("should still be focusing") }
    }

    func testTickAtEndCompletesAndReturnsToIdle() throws {
        let engine = makeEngine()
        var completed: [CompletedFocus] = []
        engine.onCompleted = { completed.append($0) }
        try engine.start(spec())
        clock.advance(1500)
        engine.tick()

        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].actualSeconds, 1500)
        XCTAssertEqual(completed[0].endedAt, completed[0].run.endAt)
    }

    func testLateTickStillRecordsPlannedEnd() throws {
        // 合盖睡眠 10 分钟后才 tick：结束时间仍是计划结束，而不是醒来的时间。
        let engine = makeEngine()
        var completed: [CompletedFocus] = []
        engine.onCompleted = { completed.append($0) }
        try engine.start(spec())
        clock.advance(1500 + 600)
        engine.tick()
        XCTAssertEqual(completed[0].actualSeconds, 1500)
    }

    func testStartWhileFocusingThrows() throws {
        let engine = makeEngine()
        try engine.start(spec())
        XCTAssertThrowsError(try engine.start(spec("另一个"))) { error in
            XCTAssertEqual(error as? TimerError, .busy)
        }
    }

    func testAbandonDiscardsWithoutCompletion() throws {
        let engine = makeEngine()
        var completed: [CompletedFocus] = []
        engine.onCompleted = { completed.append($0) }
        try engine.start(spec())
        clock.advance(300)
        engine.abandon()

        XCTAssertEqual(engine.phase, .idle)
        XCTAssertTrue(completed.isEmpty)
        XCTAssertEqual(engine.completedCount, 0)
        XCTAssertEqual(store.saved, .idle)
    }

    func testStateIsPersistedOnStart() throws {
        let engine = makeEngine()
        try engine.start(spec())
        XCTAssertEqual(store.saved, engine.phase)
    }

    func testRecoveryResumesRunningFocus() throws {
        try makeEngine().start(spec())
        clock.advance(400)
        let recovered = makeEngine()
        XCTAssertEqual(recovered.remainingSeconds, 1100)
        XCTAssertNil(recovered.recovered)
    }

    func testRecoveryAfterEndTimeCompletes() throws {
        try makeEngine().start(spec())
        clock.advance(2000)
        let recovered = makeEngine()
        XCTAssertEqual(recovered.phase, .idle)
        XCTAssertEqual(recovered.recovered?.run.title, "写周报")
        XCTAssertEqual(recovered.recovered?.actualSeconds, 1500)
    }

    func testBreakIsOptionalAndEndsByClock() throws {
        let engine = makeEngine()
        try engine.start(spec(seconds: 60))
        clock.advance(60)
        engine.tick()
        XCTAssertEqual(engine.phase, .idle)   // 默认不进入休息

        try engine.startBreak(.short, seconds: 300)
        XCTAssertEqual(engine.remainingSeconds, 300)
        clock.advance(300)
        engine.tick()
        XCTAssertEqual(engine.phase, .idle)
    }

    func testEndBreakEarly() throws {
        let engine = makeEngine()
        try engine.startBreak(.short, seconds: 300)
        engine.endBreak()
        XCTAssertEqual(engine.phase, .idle)
    }

    func testCannotStartFocusDuringBreak() throws {
        let engine = makeEngine()
        try engine.startBreak(.short, seconds: 300)
        XCTAssertThrowsError(try engine.start(spec())) { XCTAssertEqual($0 as? TimerError, .busy) }
    }

    func testEveryFourthCompletionSuggestsLongBreak() throws {
        let engine = makeEngine()
        for i in 1...4 {
            try engine.start(spec("t\(i)", seconds: 60))
            clock.advance(60)
            engine.tick()
            XCTAssertEqual(engine.suggestedBreak, i == 4 ? .long : .short)
        }
    }

    func testTickCompletesEvenWithoutOnCompletedHandler() throws {
        // Regression: `onCompleted?(finish(run))` skips finish() when the handler is nil.
        let engine = makeEngine()
        try engine.start(spec(seconds: 60))
        clock.advance(60)
        engine.tick()
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(engine.completedCount, 1)
        XCTAssertEqual(store.saved, .idle)
    }

    func testCompletionFiresOnceAndPersistsIdle() throws {
        let engine = makeEngine()
        var count = 0
        engine.onCompleted = { _ in count += 1 }
        try engine.start(spec(seconds: 60))
        clock.advance(61)
        engine.tick()
        engine.tick()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(engine.completedCount, 1)
        XCTAssertEqual(store.saved, .idle)
    }

    func testRecoveryAfterEndTimePersistsIdleAndCountsOnce() throws {
        try makeEngine().start(spec())
        clock.advance(2000)
        let first = makeEngine()
        XCTAssertNotNil(first.recovered)
        XCTAssertEqual(first.completedCount, 1)
        XCTAssertEqual(store.saved, .idle)
        let second = makeEngine()
        XCTAssertNil(second.recovered)
        XCTAssertEqual(second.completedCount, 1)
    }

    func testRecoveredIsNilWhenPersistedPhaseWasBreakOrIdle() throws {
        XCTAssertNil(makeEngine().recovered)
        try makeEngine().startBreak(.short, seconds: 60)
        clock.advance(120)
        let engine = makeEngine()
        XCTAssertNil(engine.recovered)
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(engine.completedCount, 0)
    }

    func testAbandonWhenIdleOrBreakingIsNoOp() throws {
        let engine = makeEngine()
        engine.abandon()
        XCTAssertEqual(engine.phase, .idle)
        try engine.startBreak(.long, seconds: 300)
        engine.abandon()
        if case .breaking = engine.phase {} else { XCTFail("abandon must not end a break") }
    }

    func testAdjustAddsAndSubtractsTime() throws {
        let engine = makeEngine()
        try engine.start(spec(seconds: 1500))
        XCTAssertTrue(engine.adjust(by: 300))
        XCTAssertEqual(engine.remainingSeconds, 1800)
        XCTAssertTrue(engine.adjust(by: -300))
        XCTAssertEqual(engine.remainingSeconds, 1500)
        guard case .focusing(let run) = store.saved else { return XCTFail("adjusted run must be persisted") }
        XCTAssertEqual(run.plannedSeconds, 1500)
    }

    func testAdjustNeverLeavesLessThanOneMinute() throws {
        let engine = makeEngine()
        try engine.start(spec(seconds: 600))
        clock.advance(480)
        engine.adjust(by: -300)
        XCTAssertEqual(engine.remainingSeconds, 60)
        XCTAssertFalse(engine.adjust(by: -300))
    }

    func testAllowIdleCarriesFromSpecAndToggles() throws {
        let engine = makeEngine()
        try engine.start(FocusSpec(title: "跑步", categoryId: nil, source: .custom, todoistTaskId: nil, entryId: nil,
                                   plannedSeconds: 1500, allowIdle: true))
        guard case .focusing(let run) = engine.phase else { return XCTFail("expected focusing") }
        XCTAssertTrue(run.allowIdle)
        engine.setAllowIdle(false)
        guard case .focusing(let saved) = store.saved else { return XCTFail("toggle must be persisted") }
        XCTAssertFalse(saved.allowIdle)
        XCTAssertEqual(saved.startedAt, run.startedAt)
    }

    func testRunSavedByOlderVersionDecodesWithoutAllowIdle() throws {
        let json = #"{"id":"6F1C8A52-7D0C-4F47-9E5C-0E6A7E9B1D11","title":"t","source":"custom","startedAt":0,"plannedSeconds":60}"#
        let run = try JSONDecoder().decode(FocusRun.self, from: Data(json.utf8))
        XCTAssertFalse(run.allowIdle)
    }

    func testAdjustDoesNothingWhenIdle() {
        XCTAssertFalse(makeEngine().adjust(by: 300))
    }

    func testFinishEarlyCompletesNowAndCountsTowardLongBreak() throws {
        let engine = makeEngine()
        var callbacks = 0
        engine.onCompleted = { _ in callbacks += 1 }
        try engine.start(spec(seconds: 1500))
        clock.advance(600)
        let done = try XCTUnwrap(engine.finishEarly())
        XCTAssertEqual(done.actualSeconds, 600)
        XCTAssertEqual(done.run.plannedSeconds, 1500)
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(store.completedCount, 1)
        XCTAssertEqual(callbacks, 0)
        XCTAssertNil(engine.finishEarly())
    }

    // MARK: 手动结束（autoFinish = false）

    func testManualModeKeepsFocusingPastEndAndCountsOvertime() throws {
        let engine = TimerEngine(clock: clock, store: store, autoFinish: false)
        var completed = 0, timeUps: [TimerPhase] = []
        engine.onCompleted = { _ in completed += 1 }
        engine.onTimeUp = { timeUps.append($0) }
        try engine.start(spec(seconds: 600))
        clock.advance(600); engine.tick()
        clock.advance(90); engine.tick()
        guard case .focusing = engine.phase else { return XCTFail("should still be focusing") }
        XCTAssertEqual(engine.remainingSeconds, 0)
        XCTAssertEqual(engine.overtimeSeconds, 90)
        XCTAssertEqual(completed, 0)
        XCTAssertEqual(timeUps.count, 1, "time-up fires once")
        let done = try XCTUnwrap(engine.finishEarly())
        XCTAssertEqual(done.actualSeconds, 690, "overtime counts as actual focus")
        XCTAssertEqual(engine.overtimeSeconds, 0)
    }

    func testManualModeKeepsBreakingPastEnd() throws {
        let engine = TimerEngine(clock: clock, store: store, autoFinish: false)
        var timeUps = 0
        engine.onTimeUp = { _ in timeUps += 1 }
        try engine.startBreak(.short, seconds: 300)
        clock.advance(400); engine.tick(); engine.tick()
        guard case .breaking = engine.phase else { return XCTFail("should still be breaking") }
        XCTAssertEqual(engine.overtimeSeconds, 100)
        XCTAssertEqual(timeUps, 1)
        engine.endBreak()
        XCTAssertEqual(engine.phase, .idle)
    }

    func testAutoModeBreakEndFiresTimeUpOnce() throws {
        let engine = TimerEngine(clock: clock, store: store, autoFinish: true)
        var timeUps: [TimerPhase] = []
        engine.onTimeUp = { timeUps.append($0) }
        try engine.startBreak(.short, seconds: 300)
        clock.advance(300); engine.tick(); engine.tick()
        XCTAssertEqual(engine.phase, .idle)
        XCTAssertEqual(timeUps.count, 1)
        guard case .breaking = timeUps.first else { return XCTFail("reports the break that ended") }
    }

    func testManualModeRelaunchPastEndDoesNotRecoverOrRenotify() throws {
        let first = TimerEngine(clock: clock, store: store, autoFinish: false)
        try first.start(spec(seconds: 600))
        clock.advance(900)
        let engine = TimerEngine(clock: clock, store: store, autoFinish: false)
        var timeUps = 0
        engine.onTimeUp = { _ in timeUps += 1 }
        engine.tick()
        XCTAssertNil(engine.recovered)
        guard case .focusing = engine.phase else { return XCTFail("should still be focusing") }
        XCTAssertEqual(engine.overtimeSeconds, 300)
        XCTAssertEqual(timeUps, 0)
    }

    func testAddingTimeDuringOvertimeRearmsTimeUp() throws {
        let engine = TimerEngine(clock: clock, store: store, autoFinish: false)
        var timeUps = 0
        engine.onTimeUp = { _ in timeUps += 1 }
        try engine.start(spec(seconds: 600))
        clock.advance(620); engine.tick()
        XCTAssertTrue(engine.adjust(by: 300))
        XCTAssertEqual(engine.overtimeSeconds, 0)
        XCTAssertEqual(engine.remainingSeconds, 280)
        clock.advance(280); engine.tick()
        XCTAssertEqual(timeUps, 2)
    }
}
