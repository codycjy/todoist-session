import XCTest
@testable import SessionCore

final class BreakReminderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func run(_ nudge: inout BreakNudge, from: Int, to: Int, idle: TimeInterval) -> [Int] {
        (from...to).filter { nudge.sample(now: t0.addingTimeInterval(TimeInterval($0)), idleSeconds: idle) }
    }

    func testNudgesOnceAfterAMinuteOfInputPastGrace() {
        var n = BreakNudge(startedAt: t0)
        XCTAssertEqual(run(&n, from: 0, to: 29, idle: 0), [], "grace period ignores input")
        // 第 30 秒起每秒 +1（宽限期内的采样已记下时间点），满 60 秒在第 89 秒触发
        XCTAssertEqual(run(&n, from: 30, to: 200, idle: 0), [89])
        XCTAssertTrue(n.fired)
    }

    func testIdleTimeDoesNotCount() {
        var n = BreakNudge(startedAt: t0)
        XCTAssertEqual(run(&n, from: 0, to: 600, idle: 30), [])
    }

    func testLongGapCountsAtMostAFewSeconds() {
        var n = BreakNudge(startedAt: t0)
        XCTAssertFalse(n.sample(now: t0.addingTimeInterval(40), idleSeconds: 0))
        XCTAssertFalse(n.sample(now: t0.addingTimeInterval(400), idleSeconds: 0), "a sleep gap is not a minute of use")
    }

    private func task(_ id: String, priority: Int = 1, due: String? = nil) -> TodoistTask {
        TodoistTask(id: id, content: id, projectId: "p", priority: priority, dueDate: due, isRecurring: false)
    }

    func testNextTaskPrefersScheduledThenPrioritySkippingCurrent() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let todayAt = { (h: Int) in f.string(from: now) + String(format: "T%02d:00:00", h) }
        let g = TaskGroups(tasks: [task("low"), task("high", priority: 4), task("at10", due: todayAt(10)), task("old", due: "2000-01-01")],
                           now: now, calendar: cal)
        XCTAssertEqual(g.next(excluding: nil)?.id, "at10")
        XCTAssertEqual(g.next(excluding: "at10")?.id, "high")
        XCTAssertNil(TaskGroups(tasks: [task("only")]).next(excluding: "only"))
    }
}
