import Foundation

public protocol StateStore: AnyObject {
    func load() -> TimerPhase?
    func save(_ phase: TimerPhase)
    /// 自启动以来累计的完成数；用于"每 4 个专注建议长休"。
    var completedCount: Int { get set }
}

public final class UserDefaultsStateStore: StateStore {
    private let defaults: UserDefaults
    private let phaseKey = "timer.phase"
    private let countKey = "timer.completedCount"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> TimerPhase? {
        defaults.data(forKey: phaseKey).flatMap { try? JSONDecoder().decode(TimerPhase.self, from: $0) }
    }

    public func save(_ phase: TimerPhase) {
        if let data = try? JSONEncoder().encode(phase) { defaults.set(data, forKey: phaseKey) }
    }

    public var completedCount: Int {
        get { defaults.integer(forKey: countKey) }
        set { defaults.set(newValue, forKey: countKey) }
    }
}
