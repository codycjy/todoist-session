import XCTest
@testable import SessionCore

final class TimelineLayoutTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func date(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: h, minute: m, second: s))!
    }

    private func session(_ id: String, from: Date, to: Date) -> SessionRecord {
        SessionRecord(id: id, title: id, categoryId: nil, source: .custom, todoistTaskId: nil, entryId: nil,
                      plannedSeconds: 1500, actualSeconds: Int(to.timeIntervalSince(from)), startedAt: from, endedAt: to)
    }

    private var midnight: Date { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: date(12, 0)))! }

    func testRangeStartsAtEarliestSessionHourAndRunsToEndOfDay() {
        let sessions = [session("a", from: date(10, 20), to: date(10, 45)), session("b", from: date(13, 5), to: date(13, 30))]
        let r = TimelineLayout.range(sessions: sessions, now: date(14, 10), calendar: cal)
        XCTAssertEqual(r.start, date(10, 0))
        XCTAssertEqual(r.end, midnight, "the rest of the day is drawn even with nothing scheduled")
    }

    func testRangeExtendsPastMidnightForLateItems() {
        let task = DateInterval(start: date(23, 30), duration: 60 * 60)
        let r = TimelineLayout.range(sessions: [], scheduled: [task], now: date(14, 10), calendar: cal)
        XCTAssertEqual(r.end, midnight.addingTimeInterval(3600))
    }

    func testScheduledTasksExtendRange() {
        let task = DateInterval(start: date(16, 0), duration: 45 * 60)
        let r = TimelineLayout.range(sessions: [], scheduled: [task], now: date(14, 10), calendar: cal)
        XCTAssertEqual(r.start, date(14, 0))
        XCTAssertEqual(r.end, midnight)
    }

    func testBlockForInterval() {
        let b = TimelineLayout.block(for: DateInterval(start: date(10, 30), duration: 30 * 60),
                                      rangeStart: date(10, 0), pointsPerMinute: 2)
        XCTAssertEqual(b.top, 60)
        XCTAssertEqual(b.height, 60)
    }

    func testRangeWithoutSessionsStartsNoLaterThanNineAndNowHour() {
        let late = TimelineLayout.range(sessions: [], now: date(14, 10), calendar: cal)
        XCTAssertEqual(late.start, date(9, 0))
        XCTAssertEqual(late.end, midnight)
        let early = TimelineLayout.range(sessions: [], now: date(7, 30), calendar: cal)
        XCTAssertEqual(early.start, date(7, 0))
        XCTAssertEqual(early.end, midnight)
    }

    func testBlockTopAndHeightUsePointsPerMinute() {
        let s = session("a", from: date(10, 20), to: date(10, 45))
        let b = TimelineLayout.blocks(sessions: [s], rangeStart: date(10, 0))[0]
        XCTAssertEqual(b.top, 20 * 1.4, accuracy: 0.001)
        XCTAssertEqual(b.height, 35, accuracy: 0.001)
        XCTAssertEqual(b.id, "a")
    }

    func testVeryShortSessionGetsMinHeight() {
        let s = session("a", from: date(10, 0), to: date(10, 0, 10))
        XCTAssertEqual(TimelineLayout.blocks(sessions: [s], rangeStart: date(10, 0))[0].height, 10, accuracy: 0.001)
    }

    func testBlockOrderMatchesInput() {
        let a = session("a", from: date(12, 0), to: date(12, 25))
        let b = session("b", from: date(10, 0), to: date(10, 25))
        XCTAssertEqual(TimelineLayout.blocks(sessions: [a, b], rangeStart: date(10, 0)).map(\.id), ["a", "b"])
    }
}
