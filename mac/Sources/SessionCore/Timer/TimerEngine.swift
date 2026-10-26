import Foundation

public protocol Clock: Sendable { var now: Date { get } }
public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

public enum SessionSource: String, Codable, Sendable { case todoist, custom }
public enum BreakKind: String, Codable, Sendable { case short, long }
public enum TimerError: Error, Equatable { case busy }

/// 开始一次专注所需的信息（来自 Todoist 任务或自定义条目）。
public struct FocusSpec: Equatable, Sendable {
    public let title: String
    public let categoryId: String?
    public let source: SessionSource
    public let todoistTaskId: String?
    public let entryId: String?
    public let plannedSeconds: Int

    public init(title: String, categoryId: String?, source: SessionSource,
                todoistTaskId: String?, entryId: String?, plannedSeconds: Int) {
        self.title = title; self.categoryId = categoryId; self.source = source
        self.todoistTaskId = todoistTaskId; self.entryId = entryId; self.plannedSeconds = plannedSeconds
    }
}

public struct FocusRun: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let categoryId: String?
    public let source: SessionSource
    public let todoistTaskId: String?
    public let entryId: String?
    public let startedAt: Date
    /// 进行中可以用 `adjust(by:)` 加减。
    public internal(set) var plannedSeconds: Int
    public var endAt: Date { startedAt.addingTimeInterval(TimeInterval(plannedSeconds)) }
}

public struct CompletedFocus: Equatable, Sendable {
    public let run: FocusRun
    public let endedAt: Date
    public var actualSeconds: Int { Int(endedAt.timeIntervalSince(run.startedAt).rounded()) }
}

public enum TimerPhase: Codable, Equatable, Sendable {
    case idle
    case focusing(FocusRun)
    case breaking(kind: BreakKind, until: Date)
}

public final class TimerEngine {
    public private(set) var phase: TimerPhase
    /// 启动时发现上次的专注已经过了结束时间，在这里交给调用方入库。
    public private(set) var recovered: CompletedFocus?
    public var onCompleted: ((CompletedFocus) -> Void)?

    private let clock: Clock
    private let store: StateStore
    private let longBreakEvery: Int

    public var completedCount: Int { store.completedCount }
    public var currentRunCategoryId: String? {
        if case .focusing(let run) = phase { return run.categoryId }
        return nil
    }
    public var suggestedBreak: BreakKind {
        let n = store.completedCount
        return n > 0 && n % longBreakEvery == 0 ? .long : .short
    }

    public init(clock: Clock, store: StateStore, longBreakEvery: Int = 4) {
        self.clock = clock
        self.store = store
        self.longBreakEvery = longBreakEvery
        self.phase = store.load() ?? .idle
        if case .focusing(let run) = phase, clock.now >= run.endAt {
            recovered = finish(run)
        } else if case .breaking(_, let until) = phase, clock.now >= until {
            setPhase(.idle)
        }
    }

    public var remainingSeconds: Int {
        switch phase {
        case .idle: return 0
        case .focusing(let run): return max(0, Int(run.endAt.timeIntervalSince(clock.now).rounded(.up)))
        case .breaking(_, let until): return max(0, Int(until.timeIntervalSince(clock.now).rounded(.up)))
        }
    }

    public func start(_ spec: FocusSpec) throws {
        guard phase == .idle else { throw TimerError.busy }
        setPhase(.focusing(FocusRun(
            id: UUID(), title: spec.title, categoryId: spec.categoryId, source: spec.source,
            todoistTaskId: spec.todoistTaskId, entryId: spec.entryId,
            startedAt: clock.now, plannedSeconds: spec.plannedSeconds)))
    }

    /// 放弃：直接丢弃，不触发 onCompleted，不计入统计。
    public func abandon() {
        guard case .focusing = phase else { return }
        setPhase(.idle)
    }

    /// 进行中的专注加减时长（秒）。减到剩余不足 1 分钟时停在 1 分钟；返回是否有变化。
    @discardableResult
    public func adjust(by delta: Int) -> Bool {
        guard case .focusing(var run) = phase else { return false }
        let elapsed = Int(clock.now.timeIntervalSince(run.startedAt).rounded(.up))
        let next = max(run.plannedSeconds + delta, elapsed + 60)
        guard next != run.plannedSeconds else { return false }
        run.plannedSeconds = next
        setPhase(.focusing(run))
        return true
    }

    /// 提前完成：按现在结束并计为一次完成（照常计入长休节奏），由调用方入库。不触发 onCompleted。
    public func finishEarly() -> CompletedFocus? {
        guard case .focusing(let run) = phase else { return nil }
        store.completedCount += 1
        setPhase(.idle)
        return CompletedFocus(run: run, endedAt: clock.now)
    }

    public func startBreak(_ kind: BreakKind, seconds: Int) throws {
        guard phase == .idle else { throw TimerError.busy }
        setPhase(.breaking(kind: kind, until: clock.now.addingTimeInterval(TimeInterval(seconds))))
    }

    public func endBreak() {
        guard case .breaking = phase else { return }
        setPhase(.idle)
    }

    /// 由 UI 层每秒调用；只检查是否到点，不累计时间。
    public func tick() {
        switch phase {
        case .focusing(let run) where clock.now >= run.endAt:
            let completed = finish(run)
            onCompleted?(completed)
        case .breaking(_, let until) where clock.now >= until:
            setPhase(.idle)
        default:
            break
        }
    }

    private func finish(_ run: FocusRun) -> CompletedFocus {
        store.completedCount += 1
        setPhase(.idle)
        return CompletedFocus(run: run, endedAt: run.endAt)
    }

    private func setPhase(_ new: TimerPhase) {
        phase = new
        store.save(new)
    }
}
