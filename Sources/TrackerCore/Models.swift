import Foundation

/// A progress feed written by a user's script to ~/.claude-progress/*.json (read-only for the tracker).
public struct ProgressFeed: Identifiable {
    public struct Stage: Identifiable { public let name: String; public let done: Int; public let total: Int; public var id: String { name }
        public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 } }
    public let id: String
    public let title: String
    public let cwd: String
    public let started: Date
    public let updated: Date
    public let stages: [Stage]
    public let now: [String]

    public func isFresh(at now: Date) -> Bool { now.timeIntervalSince(updated) < 120 }
    public var doneTotal: Int { stages.reduce(0) { $0 + $1.done } }
    public var grandTotal: Int { stages.reduce(0) { $0 + $1.total } }
    /// Items per second over the last ~30 min of observed progress (set by the store); nil if stalled or not yet measured.
    /// Deliberately not "since started": that would include paused time and overstate the time left.
    public var recentRate: Double?
    public var rate: Double { recentRate ?? 0 }
    public var overallETA: TimeInterval? { rate > 0 ? Double(grandTotal - doneTotal) / rate : nil }
    /// Stages are assumed to run in order, so a stage finishes after everything before it plus itself.
    public func stageETA(_ s: Stage) -> TimeInterval? {
        guard rate > 0, s.done < s.total, let i = stages.firstIndex(where: { $0.id == s.id }) else { return nil }
        let remaining = stages[...i].reduce(0) { $0 + ($1.total - $1.done) }
        return Double(remaining) / rate
    }
}

public struct PlanStep { public var content: String; public var status: String   // pending | in_progress | completed
    public var isDone: Bool { status == "completed" } }

public struct Progress {
    public let fraction: Double
    public let eta: TimeInterval?
    /// e.g. "3/7" for plan steps.
    public let detail: String?
}

public enum RunState: String {
    case working, background, paused, waiting, idle, finished
}

public struct BackgroundTask: Identifiable {
    public enum Status: String { case running, completed, failed }
    public let id: String
    public let label: String
    public let command: String
    public let start: Date
    public var end: Date?
    public var status: Status
    public let outputPath: String
    /// 0...1 when a percentage or "a / b" pattern was found in the task output; nil otherwise.
    public var progress: Double?
    public var progressText: String?
    public var eta: TimeInterval?

    public func elapsed(at now: Date) -> TimeInterval { (end ?? now).timeIntervalSince(start) }
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
    public var tasks: [BackgroundTask] = []
    public var feeds: [ProgressFeed] = []
    public var procs: [SubProcess] = []
    /// Started through the desktop app's SSH feature: runs on a server, transcript is mirrored locally.
    public var remote = false
    /// The session's own step list (plan / TodoWrite) since the latest user prompt.
    public var plan: [PlanStep] = []
    public var planStart: Date?
    public var promptAt: Date?

    public var currentStep: String? { (plan.first { $0.status == "in_progress" } ?? plan.first { !$0.isDone })?.content }
    /// Latest event from the optional Claude Code hook (see hooks/): Notification = Claude is asking the user.
    public var hookEvent: String?
    public var hookAt: Date?

    public func needsInput(at now: Date) -> Bool {
        alive && hookEvent == "Notification" && (hookAt.map { $0 >= lastActivity.addingTimeInterval(-2) } ?? false)
    }

    /// Best available progress: script feed, then the session's step list, then a task's own output, then worker bars.
    public func progress(at now: Date) -> Progress? {
        if let f = feeds.first(where: { $0.isFresh(at: now) }), f.grandTotal > 0 {
            return Progress(fraction: Double(f.doneTotal) / Double(f.grandTotal), eta: f.overallETA, detail: nil)
        }
        if plan.count >= 2 {
            let done = plan.filter(\.isDone).count
            return Progress(fraction: Double(done) / Double(plan.count), eta: nil, detail: "\(done)/\(plan.count)")
        }
        // Orchestrator sessions with no step list: subagents finished out of launched since the latest prompt.
        if let since = promptAt {
            let batch = subagents.filter { $0.start >= since }
            let done = batch.filter { !$0.isRunning(at: now) }.count
            if batch.count >= 2 {
                return Progress(fraction: Double(done) / Double(batch.count), eta: nil, detail: "agents \(done)/\(batch.count)")
            }
        }
        if let t = runningTasks.first(where: { $0.progress != nil }), let p = t.progress { return Progress(fraction: p, eta: t.eta, detail: t.progressText) }
        let ps = procs.compactMap(\.progress)
        if !ps.isEmpty { return Progress(fraction: ps.reduce(0, +) / Double(ps.count), eta: nil, detail: nil) }
        return nil
    }

    /// Tasks with no completion notice after 24 h are assumed dead (killed or lost), not running.
    public var runningTasks: [BackgroundTask] { tasks.filter { $0.status == .running && Date().timeIntervalSince($0.start) < 24 * 3600 } }
    public func runningAgents(at now: Date) -> Int { subagents.filter { $0.isRunning(at: now) }.count }

    public var project: String { (cwd as NSString).lastPathComponent }

    public func state(at now: Date) -> RunState {
        if !alive { return .finished }
        if needsInput(at: now) { return .waiting }
        if busySince != nil && now.timeIntervalSince(lastActivity) < Tuning.sessionStaleAfter { return .working }
        if hasPendingWork(at: now) {
            // Unfinished work but nothing alive doing it (workers killed, only a waiter left): paused.
            // Server sessions can't be scanned for processes, so they count as running.
            return (remote || !procs.isEmpty || runningAgents(at: now) > 0) ? .background : .paused
        }
        // Turn finished (or silent for a long time, e.g. blocked on a permission prompt): waiting on me.
        let since = busySince != nil ? lastActivity : stateSince
        return now.timeIntervalSince(since) < Tuning.idleAfter ? .waiting : .idle
    }
    /// A background command is open or a progress feed is being refreshed.
    public func hasPendingWork(at now: Date) -> Bool {
        alive && (!runningTasks.isEmpty || feeds.contains(where: { $0.isFresh(at: now) }))
    }

    public func timeInState(at now: Date) -> TimeInterval {
        switch state(at: now) {
        case .working: return now.timeIntervalSince(stateSince)
        case .background:
            return now.timeIntervalSince(([runningTasks.map(\.start).min(), feeds.filter { $0.isFresh(at: now) }.map(\.started).min()].compactMap { $0 }).min() ?? lastActivity)
        case .paused: return now.timeIntervalSince(busySince != nil ? lastActivity : stateSince)
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
    if h > 0 { return String(format: "%dh%02dm", h, m) }
    if m > 0 { return compact ? "\(m)m" : String(format: "%dm%02ds", m, sec) }
    return "\(sec)s"
}
