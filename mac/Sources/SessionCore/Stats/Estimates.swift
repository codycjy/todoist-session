import Foundation

/// 一组专注的计划与实际：实际时长中位数、实际 / 计划之比的中位数。
public struct Estimate: Equatable, Sendable {
    public let sampleCount: Int
    public let medianPlannedSeconds: Int
    public let medianActualSeconds: Int
    /// 实际 / 计划；1.35 表示通常超出计划 35%。
    public let medianRatio: Double

    init?(_ sessions: [SessionRecord], minSamples: Int) {
        guard sessions.count >= minSamples else { return nil }
        sampleCount = sessions.count
        medianPlannedSeconds = Int(median(sessions.map { Double($0.plannedSeconds) }).rounded())
        medianActualSeconds = Int(median(sessions.map { Double($0.actualSeconds) }).rounded())
        medianRatio = median(sessions.map { Double($0.actualSeconds) / Double($0.plannedSeconds) })
    }

    /// 实际比计划多（正）/ 少（负）的百分比，取整。
    public var deviationPercent: Int { Int(((medianRatio - 1) * 100).rounded()) }

    /// 建议的计划时长：实际中位数取整到 5 分钟（不足 5 分钟取整到分钟），并钳到可设范围。
    public var suggestedSeconds: Int {
        let m = Double(medianActualSeconds) / 60
        let minutes = m < 5 ? max(1, m.rounded()) : (m / 5).rounded() * 5
        return min(max(Int(minutes) * 60, AppSettings.focusRange.lowerBound), AppSettings.focusRange.upperBound)
    }
}

/// 近一段时间的预估准确度：按分类、按 Todoist 任务（重复任务 id 不变）分组。
public struct Estimates: Equatable, Sendable {
    public static let windowDays = 30
    public static let minCategorySamples = 5, minTaskSamples = 3
    /// 短于 1 分钟的多半是试按，不计入。
    static let minActualSeconds = 60

    /// 键为分类 id；无分类的 session 用 `nil` 键。
    public let byCategory: [String?: Estimate]
    public let byTask: [String: Estimate]

    public static let empty = Estimates(sessions: [])

    public init(sessions: [SessionRecord]) {
        let valid = sessions.filter { $0.plannedSeconds > 0 && $0.actualSeconds >= Self.minActualSeconds }
        byCategory = Dictionary(grouping: valid, by: \.categoryId)
            .compactMapValues { Estimate($0, minSamples: Self.minCategorySamples) }
        byTask = Dictionary(grouping: valid.filter { $0.todoistTaskId != nil }, by: { $0.todoistTaskId! })
            .compactMapValues { Estimate($0, minSamples: Self.minTaskSamples) }
    }

    /// 任务自己的记录够多时用任务的，否则用分类的。
    public func estimate(categoryId: String?, todoistTaskId: String? = nil) -> Estimate? {
        todoistTaskId.flatMap { byTask[$0] } ?? byCategory[categoryId] ?? nil
    }
}

private func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}
