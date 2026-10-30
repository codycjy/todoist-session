import Foundation

/// 今日页的任务分组：已排期（今天有具体时间）、今天、过期。
public struct TaskGroups: Sendable {
    public var scheduled: [TodoistTask] = []
    public var today: [TodoistTask] = []
    public var overdue: [TodoistTask] = []
    public var isEmpty: Bool { scheduled.isEmpty && today.isEmpty && overdue.isEmpty }

    public init(tasks: [TodoistTask], now: Date = Date(), calendar: Calendar = .current) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let todayString = f.string(from: now)
        let startOfToday = calendar.startOfDay(for: now)
        for t in tasks {
            if let time = t.dueTime {
                if time < startOfToday { overdue.append(t) }
                else if calendar.isDateInToday(time) { scheduled.append(t) }
                else { today.append(t) }
            } else if let d = t.dueDate, String(d.prefix(10)) < todayString {
                overdue.append(t)
            } else {
                today.append(t)
            }
        }
        scheduled.sort { ($0.dueTime ?? .distantPast) < ($1.dueTime ?? .distantPast) }
        today.sort { $0.priority > $1.priority }
    }

    /// 休息结束后建议的下一个任务：今天排期的最早，其次今天的按优先级，最后过期的；跳过刚做完的那个。
    public func next(excluding id: String?) -> TodoistTask? {
        (scheduled + today + overdue).first { $0.id != id }
    }
}
