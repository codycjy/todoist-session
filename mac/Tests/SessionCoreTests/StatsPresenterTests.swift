import XCTest
@testable import SessionCore

final class StatsPresenterTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        c.firstWeekday = 2   // 周一
        return c
    }()

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }

    // 2026-10-25 是周日；东八区 10:30
    func testTodayRange() {
        let now = date("2026-10-25T10:30:00+08:00")
        let r = StatsRange.today.interval(now: now, calendar: cal)
        XCTAssertEqual(r.from, date("2026-10-25T00:00:00+08:00"))
        XCTAssertEqual(r.to, date("2026-10-26T00:00:00+08:00"))
    }

    func testWeekRangeStartsMondayAndSundayBelongsToIt() {
        let now = date("2026-10-25T10:30:00+08:00")
        let r = StatsRange.week.interval(now: now, calendar: cal)
        XCTAssertEqual(r.from, date("2026-10-19T00:00:00+08:00"))
        XCTAssertEqual(r.to, date("2026-10-26T00:00:00+08:00"))
    }

    func testLast30CoversThirtyDaysIncludingToday() {
        let now = date("2026-10-25T23:59:00+08:00")
        let r = StatsRange.last30.interval(now: now, calendar: cal)
        XCTAssertEqual(r.from, date("2026-09-26T00:00:00+08:00"))
        XCTAssertEqual(r.to, date("2026-10-26T00:00:00+08:00"))
    }

    func testTzOffsetMinutes() {
        XCTAssertEqual(StatsRange.tzOffsetMinutes(calendar: cal, at: date("2026-10-25T00:00:00+08:00")), 480)
    }

    func testDurationText() {
        XCTAssertEqual(StatsFormat.duration(seconds: 8100), "2小时15分")
        XCTAssertEqual(StatsFormat.duration(seconds: 7200), "2小时")
        XCTAssertEqual(StatsFormat.duration(seconds: 900), "15分")
        XCTAssertEqual(StatsFormat.duration(seconds: 0), "0分")
        XCTAssertEqual(StatsFormat.duration(seconds: 59), "0分")
        XCTAssertEqual(StatsFormat.duration(seconds: -5), "0分")
    }

    func testScoreText() {
        XCTAssertEqual(StatsFormat.score(82), "82")
        XCTAssertEqual(StatsFormat.score(nil), "—")
    }

    func testIdlePercentGuardsZero() {
        XCTAssertNil(StatsFormat.idlePercent(active: 0, idle: 0))
        XCTAssertEqual(StatsFormat.idlePercent(active: 75, idle: 25), 25)
        XCTAssertEqual(StatsFormat.idlePercent(active: 0, idle: 10), 100)
        XCTAssertEqual(StatsFormat.idlePercent(active: 2, idle: 1), 33)
    }

    func testDailyPointsMapDatesAndMinutes() {
        let days = [StatsSummary.Day(date: "2026-10-24", focusSeconds: 5400, sessionCount: 3, avgFocusScore: 80),
                    StatsSummary.Day(date: "bad", focusSeconds: 1, sessionCount: 0, avgFocusScore: nil)]
        let pts = StatsChartData.dailyFocus(days, calendar: cal)
        XCTAssertEqual(pts.count, 1)
        XCTAssertEqual(pts[0].date, date("2026-10-24T00:00:00+08:00"))
        XCTAssertEqual(pts[0].minutes, 90, accuracy: 0.001)
    }

    func testScoreSegmentsBreakAtNil() {
        func d(_ s: String, _ v: Int?) -> StatsSummary.Day { .init(date: s, focusSeconds: 0, sessionCount: 0, avgFocusScore: v) }
        let segs = StatsChartData.scoreSegments([d("2026-10-20", 70), d("2026-10-21", 80), d("2026-10-22", nil),
                                                 d("2026-10-23", 60), d("2026-10-24", nil)], calendar: cal)
        XCTAssertEqual(segs.map { $0.map(\.score) }, [[70, 80], [60]])
        XCTAssertEqual(StatsChartData.scoreSegments([], calendar: cal), [])
    }

    func testCategorySlices() {
        let cats = [Category(id: "a", name: "工作", color: "blue", todoistProjectId: nil),
                    Category(id: "b", name: "旧项目", color: "red", todoistProjectId: nil, archived: true)]
        let shares: [StatsSummary.CategoryShare] = [.init(categoryId: "a", focusSeconds: 600),
                                                    .init(categoryId: "b", focusSeconds: 300),
                                                    .init(categoryId: nil, focusSeconds: 100),
                                                    .init(categoryId: "zzz", focusSeconds: 0)]
        let s = StatsChartData.categorySlices(shares, categories: cats)
        XCTAssertEqual(s.map(\.name), ["工作", "旧项目", "无分类", "未知分类"])
        XCTAssertEqual(s[0].colorName, "blue")
        XCTAssertNil(s[2].colorName)
        XCTAssertEqual(s[0].fraction, 0.6, accuracy: 0.001)
        XCTAssertEqual(StatsChartData.categorySlices([], categories: cats), [])
        XCTAssertEqual(StatsChartData.categorySlices([.init(categoryId: nil, focusSeconds: 0)], categories: [])[0].fraction, 0)
    }
}
