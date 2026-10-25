import XCTest
@testable import SessionCore

final class SpanBuilderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func xcode(_ s: TimeInterval, title: String = "a.swift", idle: TimeInterval = 0, blocked: Bool = false) -> ActivitySample {
        ActivitySample(time: at(s), idleSeconds: idle, appBundleId: "com.apple.dt.Xcode", appName: "Xcode",
                       windowTitle: title, wasBlocked: blocked)
    }
    private func makeBuilder() -> SpanBuilder { SpanBuilder(sessionId: "s", idleThreshold: 120, maxGap: 10) }

    func testSameAppAndTitleExtendsOneSpan() {
        var b = makeBuilder()
        XCTAssertTrue(b.add(xcode(0)).isEmpty)
        XCTAssertTrue(b.add(xcode(2)).isEmpty)
        let closed = b.finish(at: at(4))
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].startedAt, at(0))
        XCTAssertEqual(closed[0].endedAt, at(4))
        XCTAssertEqual(closed[0].kind, .active)
    }

    func testTitleChangeClosesSpanAtNewSample() {
        var b = makeBuilder()
        _ = b.add(xcode(0, title: "a"))
        let closed = b.add(xcode(2, title: "b"))
        XCTAssertEqual(closed.map(\.windowTitle), ["a"])
        XCTAssertEqual(closed[0].endedAt, at(2))
    }

    func testBlockedFlagSplitsSpan() {
        var b = makeBuilder()
        _ = b.add(xcode(0))
        let closed = b.add(xcode(2, blocked: true))
        XCTAssertEqual(closed.count, 1)
        XCTAssertFalse(closed[0].wasBlocked)
        XCTAssertTrue(b.finish(at: at(4))[0].wasBlocked)
    }

    func testIdleStartsWhenInputStoppedNotWhenThresholdCrossed() {
        // maxGap 放宽：本用例的采样间隔（60s/140s）有意大于默认 10s，只测 idleSeconds 回溯逻辑。
        var b = SpanBuilder(sessionId: "s", idleThreshold: 120, maxGap: 1_000)
        _ = b.add(xcode(0))
        _ = b.add(xcode(60))                       // 仍有输入
        // 在 t=200 时已无输入 130 秒 → 闲置从 t=70 开始
        let closed = b.add(ActivitySample(time: at(200), idleSeconds: 130))
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].kind, .active)
        XCTAssertEqual(closed[0].endedAt, at(70))
        let rest = b.finish(at: at(210))
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest[0].kind, .idle)
        XCTAssertEqual(rest[0].startedAt, at(70))
        XCTAssertEqual(rest[0].endedAt, at(210))
        XCTAssertNil(rest[0].windowTitle)
    }

    func testIdleNeverStartsBeforeCurrentSpan() {
        var b = makeBuilder()
        _ = b.add(xcode(100))
        // idleSeconds 比 span 已存在的时间还长（专注开始前就没输入）→ 从 span 起点开始
        let closed = b.add(ActivitySample(time: at(102), idleSeconds: 500))
        XCTAssertTrue(closed.isEmpty)               // 长度为 0 的 active 被丢弃
        let rest = b.finish(at: at(110))
        XCTAssertEqual(rest.map(\.kind), [.idle])
        XCTAssertEqual(rest[0].startedAt, at(100))
    }

    func testInputResumingClosesIdleSpanAndOpensActive() {
        var b = makeBuilder()
        _ = b.add(ActivitySample(time: at(0), idleSeconds: 130))
        let closed = b.add(xcode(10))
        XCTAssertEqual(closed.map(\.kind), [.idle])
        XCTAssertEqual(closed[0].endedAt, at(10))
        XCTAssertEqual(b.finish(at: at(12)).map(\.kind), [.active])
    }

    func testBelowThresholdIsNotIdle() {
        var b = makeBuilder()
        _ = b.add(xcode(0))
        XCTAssertTrue(b.add(xcode(2, idle: 119)).isEmpty)
        XCTAssertEqual(b.finish(at: at(4)).map(\.kind), [.active])
    }

    func testLargeGapBecomesIdleSpan() {
        var b = makeBuilder()
        _ = b.add(xcode(0))
        _ = b.add(xcode(2))
        // 合盖睡眠：下一个采样在 600 秒之后
        let closed = b.add(xcode(600))
        XCTAssertEqual(closed.map(\.kind), [.active, .idle])
        XCTAssertEqual(closed[0].endedAt, at(2))
        XCTAssertEqual(closed[1].startedAt, at(2))
        XCTAssertEqual(closed[1].endedAt, at(600))
        XCTAssertEqual(b.finish(at: at(602)).map(\.kind), [.active])
    }

    func testFinishWithoutSamplesReturnsNothingAndDropsZeroLengthSpans() {
        var b = makeBuilder()
        XCTAssertTrue(b.finish(at: at(5)).isEmpty)
        _ = b.add(xcode(5))
        XCTAssertTrue(b.finish(at: at(5)).isEmpty)
    }

    func testSpansCarrySessionId() {
        var b = makeBuilder()
        _ = b.add(xcode(0))
        XCTAssertEqual(b.finish(at: at(3)).first?.sessionId, "s")
    }
}
