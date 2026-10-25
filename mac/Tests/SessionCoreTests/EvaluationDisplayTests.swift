import XCTest
@testable import SessionCore

final class EvaluationDisplayTests: XCTestCase {
    private func eval(_ status: Evaluation.Status, score: Int? = nil) -> Evaluation {
        Evaluation(status: status, focusScore: score, summary: nil, attempts: 0, distractions: [])
    }

    func testBadgeText() {
        XCTAssertNil(EvaluationDisplay.badge(for: nil))
        XCTAssertEqual(EvaluationDisplay.badge(for: eval(.pending)), "…")
        XCTAssertEqual(EvaluationDisplay.badge(for: eval(.failed)), "—")
        XCTAssertEqual(EvaluationDisplay.badge(for: eval(.done, score: 82)), "82")
    }

    func testDoneWithoutScoreFallsBackToDash() {
        XCTAssertEqual(EvaluationDisplay.badge(for: eval(.done)), "—")
    }

    func testNeedsPollingOnlyForPendingAmongGivenSessions() {
        let evals = ["a": eval(.done, score: 90), "b": eval(.pending), "c": eval(.failed)]
        XCTAssertTrue(EvaluationDisplay.needsPolling(evals, sessionIds: ["a", "b"]))
        XCTAssertFalse(EvaluationDisplay.needsPolling(evals, sessionIds: ["a", "c"]))
        XCTAssertFalse(EvaluationDisplay.needsPolling(evals, sessionIds: ["zzz"]))
        XCTAssertFalse(EvaluationDisplay.needsPolling([:], sessionIds: []))
    }

    func testEvaluationsMapSkipsSessionsWithoutEvaluation() {
        let s1 = RemoteSession(id: "s1", title: "a", startedAt: .distantPast, endedAt: .distantPast, evaluation: eval(.pending))
        let s2 = RemoteSession(id: "s2", title: "b", startedAt: .distantPast, endedAt: .distantPast, evaluation: nil)
        XCTAssertEqual(EvaluationDisplay.evaluations(from: [s1, s2]), ["s1": eval(.pending)])
    }
}
