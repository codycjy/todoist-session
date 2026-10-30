import XCTest
@testable import SessionCore

final class EstimatesTests: XCTestCase {
    private func session(_ planned: Int, _ actual: Int, category: String? = "c", task: String? = nil) -> SessionRecord {
        SessionRecord(id: UUID().uuidString, title: "t", categoryId: category, source: task == nil ? .custom : .todoist,
                      todoistTaskId: task, entryId: nil, plannedSeconds: planned, actualSeconds: actual,
                      startedAt: Date(), endedAt: Date())
    }

    func testCategoryNeedsEnoughSamples() {
        let four = (0..<4).map { _ in session(1500, 2000) }
        XCTAssertNil(Estimates(sessions: four).estimate(categoryId: "c"))
        XCTAssertNotNil(Estimates(sessions: four + [session(1500, 2000)]).estimate(categoryId: "c"))
    }

    func testMediansAndSuggestion() {
        let actuals = [1800, 2100, 2280, 2400, 3600]   // 中位 2280s = 38 分钟
        let e = Estimates(sessions: actuals.map { session(1500, $0) }).estimate(categoryId: "c")!
        XCTAssertEqual(e.sampleCount, 5)
        XCTAssertEqual(e.medianPlannedSeconds, 1500)
        XCTAssertEqual(e.medianActualSeconds, 2280)
        XCTAssertEqual(e.medianRatio, 2280.0 / 1500, accuracy: 0.0001)
        XCTAssertEqual(e.suggestedSeconds, 40 * 60)
    }

    func testIgnoresSubMinuteRuns() {
        let runs = (0..<5).map { _ in session(1500, 1500) } + (0..<5).map { _ in session(1500, 20) }
        XCTAssertEqual(Estimates(sessions: runs).estimate(categoryId: "c")?.sampleCount, 5)
    }

    func testTaskEstimateWinsOverCategory() {
        let cat = (0..<5).map { _ in session(1500, 1500) }
        let task = (0..<3).map { _ in session(1500, 3000, task: "t1") }
        let e = Estimates(sessions: cat + task)
        XCTAssertEqual(e.estimate(categoryId: "c", todoistTaskId: "t1")?.medianActualSeconds, 3000)
        XCTAssertEqual(e.estimate(categoryId: "c", todoistTaskId: "other")?.sampleCount, 8)
    }

    func testUncategorisedGroupedUnderNil() {
        let e = Estimates(sessions: (0..<5).map { _ in session(600, 300, category: nil) })
        XCTAssertEqual(e.estimate(categoryId: nil)?.medianRatio, 0.5)
        XCTAssertEqual(e.estimate(categoryId: nil)?.suggestedSeconds, 300)
    }

    func testShortSuggestionRoundsToMinute() {
        let e = Estimates(sessions: (0..<5).map { _ in session(600, 130) }).estimate(categoryId: "c")!
        XCTAssertEqual(e.suggestedSeconds, 120)
    }
}
