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
    func testDayPeriodAndOffset() {
        let now = date("2026-10-25T10:30:00+08:00")
        let r = StatsPeriod(scope: .day).interval(now: now, calendar: cal)
        XCTAssertEqual(r.from, date("2026-10-25T00:00:00+08:00"))
        XCTAssertEqual(r.to, date("2026-10-26T00:00:00+08:00"))
        let y = StatsPeriod(scope: .day).previous.interval(now: now, calendar: cal)
        XCTAssertEqual(y.from, date("2026-10-24T00:00:00+08:00"))
        XCTAssertEqual(y.to, r.from)
    }

    func testWeekPeriodStartsMondayAndSundayBelongsToIt() {
        let now = date("2026-10-25T10:30:00+08:00")
        let r = StatsPeriod(scope: .week).interval(now: now, calendar: cal)
        XCTAssertEqual(r.from, date("2026-10-19T00:00:00+08:00"))
        XCTAssertEqual(r.to, date("2026-10-26T00:00:00+08:00"))
        let prev = StatsPeriod(scope: .week, offset: -1).interval(now: now, calendar: cal)
        XCTAssertEqual(prev.from, date("2026-10-12T00:00:00+08:00"))
        XCTAssertEqual(prev.to, r.from)
    }

    func testPeriodTitles() {
        let now = date("2026-10-25T10:30:00+08:00")
        XCTAssertEqual(StatsPeriod(scope: .day).title(now: now, calendar: cal), "今天")
        XCTAssertEqual(StatsPeriod(scope: .day, offset: -1).title(now: now, calendar: cal), "昨天")
        XCTAssertEqual(StatsPeriod(scope: .day, offset: -3).title(now: now, calendar: cal), "10月22日 周四")
        XCTAssertEqual(StatsPeriod(scope: .week).title(now: now, calendar: cal), "本周")
        XCTAssertEqual(StatsPeriod(scope: .week).dates(now: now, calendar: cal), "10月19日 – 10月25日")
        XCTAssertEqual(StatsPeriod(scope: .week, offset: -2).title(now: now, calendar: cal), "10月5日 – 10月11日")
    }

    func testMonthPeriod() {
        let now = date("2026-10-25T10:30:00+08:00")
        let r = StatsPeriod(scope: .month).interval(now: now, calendar: cal)
        XCTAssertEqual(r.from, date("2026-10-01T00:00:00+08:00"))
        XCTAssertEqual(r.to, date("2026-11-01T00:00:00+08:00"))
        let prev = StatsPeriod(scope: .month, offset: -1).interval(now: now, calendar: cal)
        XCTAssertEqual(prev.from, date("2026-09-01T00:00:00+08:00"))
        XCTAssertEqual(prev.to, r.from)
        XCTAssertEqual(StatsPeriod(scope: .month).title(now: now, calendar: cal), "本月")
        XCTAssertEqual(StatsPeriod(scope: .month, offset: -1).title(now: now, calendar: cal), "上月")
        XCTAssertEqual(StatsPeriod(scope: .month, offset: -10).title(now: now, calendar: cal), "2025年12月")
        XCTAssertEqual(StatsPeriod(scope: .month).dates(now: now, calendar: cal), "10月1日 – 10月31日")
    }

    func testCumulativeSeries() throws {
        let days = try JSONDecoder().decode([StatsSummary.Day].self, from: Data(#"[{"date":"2026-10-19","focusSeconds":600,"sessionCount":1,"avgFocusScore":null},{"date":"2026-10-20","focusSeconds":1200,"sessionCount":1,"avgFocusScore":null},{"date":"2026-10-21","focusSeconds":600,"sessionCount":1,"avgFocusScore":null}]"#.utf8))
        let all = StatsChartData.cumulativeByDay(days)
        XCTAssertEqual(all.map(\.minutes), [0, 10, 30, 40])
        XCTAssertEqual(StatsChartData.cumulativeByDay(days, count: 2).map(\.index), [0, 1, 2])
        XCTAssertEqual(StatsChartData.value(all, at: 2), 30)
        XCTAssertEqual(StatsChartData.value(all, at: 9), 40)

        let hours = try JSONDecoder().decode([StatsSummary.HourShare].self, from: Data(#"[{"date":"d","hour":9,"focusSeconds":1800},{"date":"d","hour":14,"focusSeconds":600}]"#.utf8))
        let h = StatsChartData.cumulativeByHour(hours, through: 12)
        XCTAssertEqual(h.count, 14)
        XCTAssertEqual(h.last?.minutes, 30)
        XCTAssertEqual(StatsChartData.cumulativeByHour(hours).last?.minutes, 40)
    }

    func testHoursOnOneDay() throws {
        let hours = try JSONDecoder().decode([StatsSummary.HourShare].self, from: Data(#"[{"date":"2026-10-24","hour":9,"focusSeconds":1800},{"date":"2026-10-31","hour":9,"focusSeconds":600},{"date":"2026-10-24","hour":14,"focusSeconds":600}]"#.utf8))
        let day = StatsChartData.hours(hours, on: "2026-10-24")
        XCTAssertEqual(day.map(\.hour), [9, 14])
        XCTAssertEqual(StatsChartData.cumulativeByHour(day, through: 10).last?.minutes, 30)
    }

    func testSameTimeLastWeekCountsOnlyElapsedPart() {
        let moment = date("2026-10-22T10:00:00+08:00")
        func s(_ start: String, _ secs: Int) -> SessionRecord {
            SessionRecord(id: start, title: "t", categoryId: nil, source: .custom, todoistTaskId: nil, entryId: nil,
                          plannedSeconds: secs, actualSeconds: secs, startedAt: date(start), endedAt: date(start).addingTimeInterval(TimeInterval(secs)))
        }
        let sessions = [s("2026-10-22T08:00:00+08:00", 1500),   // 整段
                        s("2026-10-22T09:50:00+08:00", 1500),   // 只算 10 分钟
                        s("2026-10-22T11:00:00+08:00", 1500),   // 之后
                        s("2026-10-21T23:00:00+08:00", 1500)]   // 前一天
        XCTAssertEqual(SameTimeComparison.focusedSeconds(sessions, until: moment, calendar: cal), 1500 + 600)
        XCTAssertEqual(SameTimeComparison.reference(for: moment, calendar: cal), date("2026-10-15T10:00:00+08:00"))
    }

    func testTzOffsetMinutes() {
        XCTAssertEqual(StatsPeriod.tzOffsetMinutes(calendar: cal, at: date("2026-10-25T00:00:00+08:00")), 480)
    }

    func testChangeAndPercent() {
        XCTAssertEqual(StatsFormat.change(112, from: 100), 12)
        XCTAssertEqual(StatsFormat.change(50, from: 100), -50)
        XCTAssertNil(StatsFormat.change(50, from: 0))
        XCTAssertEqual(StatsFormat.percent(3, of: 4), 75)
        XCTAssertEqual(StatsFormat.percent(5, of: 4), 125)
        XCTAssertNil(StatsFormat.percent(1, of: 0))
    }

    func testHourlyFillsAllHours() {
        let pts = StatsChartData.hourly([.init(date: "2026-10-25", hour: 9, focusSeconds: 600),
                                         .init(date: "2026-10-25", hour: 23, focusSeconds: 120)])
        XCTAssertEqual(pts.count, 24)
        XCTAssertEqual(pts[9].minutes, 10)
        XCTAssertEqual(pts[23].minutes, 2)
        XCTAssertEqual(pts[0].minutes, 0)
    }

    func testHeatmapAndActiveHours() {
        let days = [StatsSummary.Day(date: "2026-10-24", focusSeconds: 0, sessionCount: 0, avgFocusScore: nil),
                    StatsSummary.Day(date: "2026-10-25", focusSeconds: 600, sessionCount: 1, avgFocusScore: nil)]
        let hours = [StatsSummary.HourShare(date: "2026-10-25", hour: 6, focusSeconds: 600)]
        let range = StatsChartData.activeHours(hours)
        XCTAssertEqual(range, 6...22)
        let cells = StatsChartData.heatmap(days: days, hours: hours, range: range, calendar: cal)
        XCTAssertEqual(cells.count, 2 * 17)
        XCTAssertEqual(cells.first { $0.hour == 6 && $0.minutes > 0 }?.date, date("2026-10-25T00:00:00+08:00"))
        XCTAssertEqual(cells.filter { $0.minutes > 0 }.count, 1)
    }

    func testDecodesSummaryFromOldBackendWithoutNewFields() throws {
        let json = #"{"totalFocusSeconds":60,"sessionCount":1,"avgFocusScore":null,"activeSeconds":0,"idleSeconds":0,"days":[],"byCategory":[]}"#
        let s = try JSONDecoder().decode(StatsSummary.self, from: Data(json.utf8))
        XCTAssertEqual(s.plannedSeconds, 0)
        XCTAssertEqual(s.byHour, [])
        XCTAssertEqual(s.topApps, [])
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
