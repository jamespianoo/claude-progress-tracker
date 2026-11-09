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
    /// Items per second measured only over time when workers were running (set by the store); nil until enough is
    /// observed. Deliberately not "since started" or a wall-clock window: both would include paused time.
    public var recentRate: Double?
    public var rate: Double { recentRate ?? 0 }
    /// The stage being worked on now: the first one that is not finished.
    public var currentStage: Stage? { stages.first { $0.done < $0.total } }
    /// Time left for the current stage only. Later stages are not extrapolated: their items can cost very different
    /// amounts, so any number would be a guess. Uses the rate measured while workers were actually running.
    public var currentETA: TimeInterval? {
        guard rate > 0, let c = currentStage else { return nil }
        return Double(c.total - c.done) / rate
    }
    public func stageETA(_ s: Stage) -> TimeInterval? { s.id == currentStage?.id ? currentETA : nil }
}

public struct PlanStep { public var content: String; public var status: String   // pending | in_progress | completed
    public var isDone: Bool { status == "completed" } }

public struct Progress {
    public let fraction: Double
    public let eta: TimeInterval?
    /// e.g. "3/7" for plan steps.
    public let detail: String?
}

public struct ReportedProgress: Identifiable {
    public let label: String
    public let done: Int
    public let total: Int
    public var id: String { label }
    public var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    /// Reads "1,292 of the 3,232 Zone 1 squares are reviewed" / "40/120 files" style counts from a status message.
    /// Largest total first; counts with a total under 10 are ignored as noise (dates, "2 of 3 agents").
    public static func parse(_ text: String) -> [ReportedProgress] {
        guard let re = try? NSRegularExpression(pattern: #"(\d[\d,]*)\s*(?:/|of(?: the)?)\s*(\d[\d,]*)((?:\s+[A-Za-z0-9][A-Za-z0-9\-]*){0,4})"#) else { return [] }
        let stop: Set<String> = ["are", "is", "were", "was", "have", "has", "been", "done", "complete", "completed", "reviewed", "so", "and", "but", "in", "at", "on", "for", "to"]
        var out: [ReportedProgress] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text),
                  let done = Int(text[a].replacingOccurrences(of: ",", with: "")),
                  let total = Int(text[b].replacingOccurrences(of: ",", with: "")),
                  total >= 10, done <= total else { continue }
            var words: [String] = []
            if let l = Range(m.range(at: 3), in: text) {
                for w in text[l].split(separator: " ") { if stop.contains(w.lowercased()) { break }; words.append(String(w)) }
            }
            let label = words.isEmpty ? "items" : words.joined(separator: " ")
            if !out.contains(where: { $0.label == label }) { out.append(ReportedProgress(label: label, done: done, total: total)) }
        }
        return out.sorted { $0.total > $1.total }
    }

    /// Seconds in a sentence like "roughly 10½ hours" or "4½–5 hours" (midpoint of a range); nil if none.
    public static func estimateSeconds(_ sentence: String) -> TimeInterval? {
        guard let re = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)(½)?(?:\s*[–-]\s*(\d+(?:\.\d+)?)(½)?)?\s*(hours?|hrs?|minutes?|mins?)\b"#, options: .caseInsensitive),
              let m = re.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) else { return nil }
        func grp(_ i: Int) -> String? { Range(m.range(at: i), in: sentence).map { String(sentence[$0]) } }
        guard var lo = grp(1).flatMap(Double.init), let unit = grp(5)?.lowercased() else { return nil }
        if grp(2) != nil { lo += 0.5 }
        var v = lo
        if var hi = grp(3).flatMap(Double.init) { if grp(4) != nil { hi += 0.5 }; v = (lo + hi) / 2 }
        return v * (unit.hasPrefix("h") ? 3600 : 60)
    }

    /// The sentence in which the session itself gives a time estimate ("roughly 10½ hours, so about 5am").
    /// Prefers sentences with a duration over bare clock mentions, strips markdown, and skips "the clock reads …" asides.
    public static func sessionEstimate(_ text: String) -> String? {
        let clean = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        let duration = try? NSRegularExpression(pattern: #"\d+(?:½|\.\d+)?(?:\s*[–-]\s*\d+(?:½|\.\d+)?)?\s*(?:hours?|hrs?|minutes?|mins?)\b"#, options: .caseInsensitive)
        let clock = try? NSRegularExpression(pattern: #"\b\d{1,2}(?::\d\d)?\s?(?:am|pm)\b|\bETA\b"#, options: .caseInsensitive)
        func has(_ re: NSRegularExpression?, _ s: String) -> Bool { re?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        var best: (Int, String)?
        var rest = Substring(clean)
        var sentences: [String] = []
        for line in clean.split(separator: "\n") {
            rest = line
            for part in rest.components(separatedBy: ". ") { sentences.append(part) }
        }
        for raw in sentences {
            var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " -•*\t"))
            if s.hasSuffix(".") { s.removeLast() }
            guard s.count >= 12 else { continue }
            let lower = s.lowercased()
            var score = 0
            if has(duration, s) { score += 3 }
            if has(clock, s) { score += 1 }
            if score == 0 { continue }
            if ["about", "roughly", "around", "eta", "finish", "until", "left", "remaining"].contains(where: { lower.contains($0) }) { score += 2 }
            if lower.contains("clock reads") || lower.contains("timings i gave") { score -= 4 }
            if score > (best?.0 ?? 0) { best = (score, s) }
        }
        guard let s = best?.1 else { return nil }
        return s.count > 110 ? String(s.prefix(110)) + "…" : s
    }
}

public struct ETA {
    public let seconds: TimeInterval
    /// True for a step-pace guess (shown with "~"); false for a stated or measured estimate.
    public let approximate: Bool
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
    /// Background commands this agent started that have not reported finished (it is alive while it waits on them).
    public var tasks: [BackgroundTask] = []
    /// The parent session was told this agent finished.
    public var finished = false
    /// The parent was told this agent is waiting on its own background work (alive, though its file is silent).
    public var waitingSince: Date?
    /// When the agent's file was last written (an agent waiting on tasks resumes work then).
    public var fileModified: Date?

    public var runningTasks: [BackgroundTask] { tasks.filter { $0.status == .running && Date().timeIntervalSince($0.start) < 24 * 3600 } }

    /// Running while mid-turn and recently active, or while waiting on its own background tasks (silent for hours).
    public func isRunning(at now: Date) -> Bool {
        if finished { return false }
        if busy && now.timeIntervalSince(lastActivity) < Tuning.subagentStaleAfter { return true }
        if !runningTasks.isEmpty { return true }
        if let w = waitingSince, now.timeIntervalSince(w) < 24 * 3600 { return true }
        return false
    }
    public func duration(at now: Date) -> TimeInterval {
        guard isRunning(at: now) else { return lastActivity.timeIntervalSince(start) }
        // Mid-turn: since it started. Waiting on its tasks: since its file was last written (when it last resumed).
        if busy && now.timeIntervalSince(lastActivity) < Tuning.subagentStaleAfter { return now.timeIntervalSince(start) }
        return now.timeIntervalSince(fileModified ?? start)
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
    public var planMarks: [Date] = []
    public var promptAt: Date?
    public var activity: String?
    public var activityAt: Date?
    public var statusText: String?
    public var statusAt: Date?
    public var estimateText: String?
    public var estimateAt: Date?

    /// Counts the session reported in its latest status message (recent only).
    public func reported(at now: Date) -> [ReportedProgress] {
        guard let t = statusText, let at = statusAt, now.timeIntervalSince(at) < 3 * 3600 else { return [] }
        return ReportedProgress.parse(t)
    }
    /// Time left according to the session's own latest stated estimate (any session), counted down from when it said it.
    public func statedRemaining(at now: Date) -> TimeInterval? {
        guard alive, let t = estimateText, let at = estimateAt, now.timeIntervalSince(at) < 24 * 3600 else { return nil }
        return StatedEstimate.remaining(in: t, statusAt: at, now: now, remote: remote)
    }

    /// The ETA to show, best source first: what the session itself states, then a measured rate, then (marked
    /// approximate) the pace of its own completed steps.
    public func eta(at now: Date) -> ETA? {
        if let s = statedRemaining(at: now) { return ETA(seconds: s, approximate: false) }
        if let m = progress(at: now)?.eta { return ETA(seconds: m, approximate: false) }
        if let p = planPaceRemaining(at: now) { return ETA(seconds: p, approximate: true) }
        return nil
    }

    /// Steps left x the average time the finished steps took. Only for sessions doing the steps themselves: with workers
    /// or background tasks running, the remaining step is usually the long one and its pace is unrelated.
    func planPaceRemaining(at now: Date) -> TimeInterval? {
        guard alive, plan.count >= 2, let start = planStart, let last = planMarks.max(),
              procs.isEmpty, runningTasks.isEmpty, feeds.isEmpty else { return nil }
        let remaining = plan.filter { !$0.isDone }.count
        guard remaining > 0, now.timeIntervalSince(last) < 3 * 3600 else { return nil }
        let avg = last.timeIntervalSince(start) / Double(planMarks.count)
        guard avg >= 30 else { return nil }
        let current = max(avg - now.timeIntervalSince(last), avg * 0.25)      // the step in progress is part-way
        let total = current + Double(remaining - 1) * avg
        return total < 12 * 3600 ? total : nil
    }

    public func sessionEstimate(at now: Date) -> String? {
        guard let t = statusText, let at = statusAt, now.timeIntervalSince(at) < 3 * 3600 else { return nil }
        return ReportedProgress.sessionEstimate(t)
    }

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
            return Progress(fraction: Double(f.doneTotal) / Double(f.grandTotal), eta: f.currentETA, detail: f.currentStage.map { "\($0.name) \($0.done)/\($0.total)" })
        }
        if let r = reported(at: now).first {   // the session's own count beats a coarse step count
            return Progress(fraction: r.fraction, eta: nil, detail: "\(r.done.formatted(.number.grouping(.automatic)))/\(r.total.formatted(.number.grouping(.automatic)))")
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
    /// A background command is open, subagents are running, or a progress feed is being refreshed: the session has
    /// handed work off and is waiting on it, even though its own turn has ended.
    public func hasPendingWork(at now: Date) -> Bool {
        alive && (!runningTasks.isEmpty || runningAgents(at: now) > 0 || feeds.contains(where: { $0.isFresh(at: now) }))
    }

    public func timeInState(at now: Date) -> TimeInterval {
        switch state(at: now) {
        case .working: return now.timeIntervalSince(stateSince)
        case .background:
            if let oldest = procs.map(\.elapsed).max() { return oldest }   // live workers beat an old waiter task
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
    public static let subagentStaleAfter: TimeInterval = 30 * 60   // an agent can sit in one long tool call
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
