import Foundation

public enum RunState: String {
    case working, waiting, idle, finished
}

public struct SubagentInfo: Identifiable {
    public let id: String
    public let description: String
    public let agentType: String
    public let start: Date
    public let lastActivity: Date
    public let busy: Bool
    public let workedClosed: TimeInterval

    /// Running while mid-turn and recently active.
    public func isRunning(at now: Date) -> Bool {
        busy && now.timeIntervalSince(lastActivity) < Tuning.subagentStaleAfter
    }
    public func duration(at now: Date) -> TimeInterval {
        (isRunning(at: now) ? now : lastActivity).timeIntervalSince(start)
    }
    public func statusLabel(at now: Date) -> String {
        if isRunning(at: now) { return "running" }
        return busy ? "stopped" : "done"
    }
}

public struct SessionInfo: Identifiable {
    public let id: String            // session id
    public let pid: Int
    public let cwd: String
    public let branch: String?
    public let title: String
    public let start: Date
    public let lastActivity: Date
    public let busySince: Date?
    public let stateSince: Date
    public let workedClosed: TimeInterval
    public let alive: Bool
    public let subagents: [SubagentInfo]

    public var project: String { (cwd as NSString).lastPathComponent }

    public func state(at now: Date) -> RunState {
        if !alive { return .finished }
        if busySince != nil && now.timeIntervalSince(lastActivity) < Tuning.sessionStaleAfter { return .working }
        // Turn finished (or silent for a long time, e.g. blocked on a permission prompt): waiting on me.
        let since = busySince != nil ? lastActivity : stateSince
        return now.timeIntervalSince(since) < Tuning.idleAfter ? .waiting : .idle
    }
    public func timeInState(at now: Date) -> TimeInterval {
        switch state(at: now) {
        case .working: return now.timeIntervalSince(stateSince)
        case .waiting, .idle: return now.timeIntervalSince(busySince != nil ? lastActivity : stateSince)
        case .finished: return now.timeIntervalSince(lastActivity)
        }
    }
    public func total(at now: Date) -> TimeInterval {
        (alive ? now : lastActivity).timeIntervalSince(start)
    }
    public func worked(at now: Date) -> TimeInterval {
        guard let b = busySince else { return workedClosed }
        let end = state(at: now) == .working ? now : lastActivity
        return workedClosed + max(0, end.timeIntervalSince(b))
    }
}

public enum Tuning {
    /// A mid-turn session with no transcript writes for this long is treated as blocked on the user.
    public static let sessionStaleAfter: TimeInterval = 15 * 60
    public static let subagentStaleAfter: TimeInterval = 5 * 60
    /// Waiting this long becomes "idle".
    public static let idleAfter: TimeInterval = 10 * 60
}

public func formatDuration(_ s: TimeInterval, compact: Bool = false) -> String {
    let t = max(0, Int(s))
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    if h > 0 { return String(format: "%dh%02d", h, m) }
    if m > 0 { return compact ? "\(m)m" : String(format: "%dm%02ds", m, sec) }
    return "\(sec)s"
}
