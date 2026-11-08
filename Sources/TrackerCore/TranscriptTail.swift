import Foundation

/// Incrementally reads one Claude Code JSONL transcript (main session or subagent) and
/// derives start/last-activity, busy/idle intervals, title and cwd.
///
/// Read-only. Remembers a byte offset and only reads appended bytes. If the file shrinks,
/// is replaced (different inode) or deleted, state is reset / flagged.
///
/// Field names (verified against real transcripts, Claude Code 2.1.x):
///   top-level `type`: user | assistant | system | custom-title | agent-name | queue-operation | ...
///   `timestamp` (ISO8601, fractional), `cwd`, `gitBranch`, `isMeta`
///   assistant: `message.stop_reason` = "tool_use" (turn continues) | "end_turn" (turn over) | null (streaming)
///   user: `message.content` is a String or [block]; blocks of type `tool_result` mean a tool returned
///   custom-title: `customTitle`; agent-name: `agentName`
public final class TranscriptTail {
    public let path: String
    private var offset: UInt64 = 0
    private var fileID: UInt64 = 0
    private var partial = Data()
    private var sawFirstLine = false
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public private(set) var firstTimestamp: Date?
    public private(set) var lastTimestamp: Date?
    /// Non-nil while a turn is in flight (prompt or tool result received, no end_turn yet).
    public private(set) var busySince: Date?
    /// When the current busy/idle state began.
    public private(set) var stateSince: Date?
    /// Sum of completed busy intervals.
    public private(set) var workedClosed: TimeInterval = 0
    public private(set) var customTitle: String?
    public private(set) var agentName: String?
    public private(set) var firstPrompt: String?
    public private(set) var cwd: String?
    public private(set) var gitBranch: String?
    public private(set) var missing = false

    public var isBusy: Bool { busySince != nil }

    /// Background Bash commands (`run_in_background`) launched by this session, by task id.
    public private(set) var backgroundTasks: [String: BackgroundTask] = [:]
    /// The session's own step list since the latest user prompt (desktop `update_plan` or `TodoWrite`).
    public private(set) var plan: [PlanStep] = []
    public private(set) var planStart: Date?
    /// Time of the latest real (non-injected) user prompt.
    public private(set) var promptAt: Date?
    /// What the session is doing right now, from its latest tool call (cleared when the turn ends).
    public private(set) var activity: String?
    public private(set) var activityAt: Date?
    private var pendingBackground: [String: String] = [:]   // tool_use id -> label
    private var pendingCommands: [String: String] = [:]

    /// On first open only the last `initialWindow` bytes are read (transcripts can be hundreds of MB). Start time
    /// and total worked time are then approximate; state, plan, tasks and activity come from the recent window.
    private let initialWindow: UInt64
    private var dropPartialLine = false

    public init(path: String, initialWindow: UInt64 = 24 << 20) { self.path = path; self.initialWindow = initialWindow }

    /// Worked time as of `now`. A stale open interval is capped at last activity.
    public func worked(at now: Date, staleAfter: TimeInterval) -> TimeInterval {
        guard let b = busySince else { return workedClosed }
        var end = now
        if let last = lastTimestamp, now.timeIntervalSince(last) > staleAfter { end = last }
        return workedClosed + max(0, end.timeIntervalSince(b))
    }

    private func reset() {
        offset = 0; partial = Data(); sawFirstLine = false; dropPartialLine = false
        firstTimestamp = nil; lastTimestamp = nil; busySince = nil; stateSince = nil
        workedClosed = 0; customTitle = nil; agentName = nil; firstPrompt = nil
        cwd = nil; gitBranch = nil; activity = nil; activityAt = nil; backgroundTasks = [:]; pendingBackground = [:]
        plan = []; planStart = nil
    }

    /// Reads any bytes appended since the last call.
    public func advance() {
        var st = stat()
        guard stat(path, &st) == 0 else { missing = true; return }
        missing = false
        if UInt64(st.st_ino) != fileID || UInt64(st.st_size) < offset {
            reset(); fileID = UInt64(st.st_ino)
        }
        if offset == 0, UInt64(st.st_size) > initialWindow {
            offset = UInt64(st.st_size) - initialWindow
            dropPartialLine = true
        }
        guard UInt64(st.st_size) > offset, let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: offset) } catch { return }
        while true {
            guard let chunk = try? fh.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            consume(chunk)
        }
    }

    private func consume(_ chunk: Data) {
        var chunk = chunk
        if dropPartialLine {
            // We started mid-line: discard up to and including the first newline.
            guard let nl = chunk.firstIndex(of: 0x0A) else { return }
            chunk = chunk.subdata(in: chunk.index(after: nl)..<chunk.endIndex)
            dropPartialLine = false
        }
        var buf = partial
        buf.append(chunk)
        var lines: [Range<Int>] = []
        var consumed = 0
        buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count, let nl = memchr(base + start, 0x0A, raw.count - start) {
                let end = base.distance(to: UnsafeRawPointer(nl))
                if end > start { lines.append(start..<end) }
                start = end + 1
            }
            consumed = start
        }
        for r in lines { ingest(buf.subdata(in: r)) }
        partial = consumed < buf.count ? buf.subdata(in: consumed..<buf.count) : Data()
    }

    private static func has(_ d: Data, _ needle: String) -> Bool {
        d.range(of: Data(needle.utf8)) != nil
    }
    private static let wanted = ["\"type\":\"user\"", "\"type\":\"assistant\"", "\"type\":\"system\"",
                                 "\"type\":\"custom-title\"", "\"type\":\"agent-name\"",
                                 "<task-notification>"].map { Data($0.utf8) }

    func ingest(_ line: Data) {
        let first = !sawFirstLine
        sawFirstLine = true
        if !first {
            // Cheap prefilter: skip the large api-request / snapshot lines without parsing.
            if line.starts(with: Data("{\"type\":\"api-".utf8)) { return }
            if !Self.wanted.contains(where: { line.range(of: $0) != nil }) { return }
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""
        let ts = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) }
        if let ts {
            if firstTimestamp == nil || ts < firstTimestamp! { firstTimestamp = ts }
        }
        switch type {
        case "custom-title":
            if let t = obj["customTitle"] as? String, !t.isEmpty { customTitle = t }
        case "agent-name":
            if let t = obj["agentName"] as? String, !t.isEmpty { agentName = t }
        case "user", "assistant", "system":
            guard let ts else { return }
            if lastTimestamp == nil || ts > lastTimestamp! { lastTimestamp = ts }
            if let c = obj["cwd"] as? String { cwd = c }
            if let b = obj["gitBranch"] as? String, !b.isEmpty { gitBranch = b }
            if type == "user" { handleUser(obj, ts) }
            if type == "assistant" { handleAssistant(obj, ts) }
        case "queue-operation":
            if obj["operation"] as? String == "enqueue", let c = obj["content"] as? String { handleNotification(c, ts) }
        default: break
        }
    }

    private static func match(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }

    private func handleNotification(_ c: String, _ ts: Date?) {
        guard c.contains("<task-notification>"), let id = Self.match("<task-id>([^<]+)</task-id>", in: c)?.first,
              var t = backgroundTasks[id] else { return }
        let status = Self.match("<status>([^<]+)</status>", in: c)?.first ?? "completed"
        t.status = status == "completed" ? .completed : .failed
        t.end = ts
        backgroundTasks[id] = t
    }

    private func handleUser(_ obj: [String: Any], _ ts: Date) {
        if obj["isMeta"] as? Bool == true { return }
        let content = (obj["message"] as? [String: Any])?["content"]
        var text: String?
        var onlyToolResults = false
        if let s = content as? String {
            text = s
        } else if let arr = content as? [[String: Any]] {
            for b in arr where b["type"] as? String == "tool_result" {
                guard let tid = b["tool_use_id"] as? String, let label = pendingBackground.removeValue(forKey: tid) else { continue }
                let body: String
                if let str = b["content"] as? String { body = str }
                else { body = ((b["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n") }
                if let m = Self.match("ID: (\\w+)\\. Output is being written to: (\\S+?)\\.? ", in: body + " ") ?? Self.match("ID: (\\w+)\\.? ?Output is being written to: (\\S+)", in: body) {
                    let out = m[1].hasSuffix(".") ? String(m[1].dropLast()) : m[1]
                    backgroundTasks[m[0]] = BackgroundTask(id: m[0], label: label, command: pendingCommands[tid] ?? "", start: ts, end: nil, status: .running, outputPath: out)
                }
                pendingCommands[tid] = nil
            }
            onlyToolResults = !arr.isEmpty && arr.allSatisfy { $0["type"] as? String == "tool_result" }
            text = arr.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        if let t = text, t.hasPrefix("[Request interrupted") { goIdle(ts); return }
        let injected = (text ?? "").hasPrefix("<task-notification") || (text ?? "").hasPrefix("Another Claude session")
            || (text ?? "").hasPrefix("<system-reminder")
        if !onlyToolResults, !injected { promptAt = ts }
        if !onlyToolResults, !injected, plan.allSatisfy(\.isDone) { plan = []; planStart = nil }   // a finished plan is replaced on the next prompt; an unfinished one carries over
        if !onlyToolResults, firstPrompt == nil, let t = text {
            firstPrompt = Self.summarise(t)
        }
        goBusy(ts)
    }

    private func handleAssistant(_ obj: [String: Any], _ ts: Date) {
        if let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] {
            for b in blocks where b["type"] as? String == "tool_use" {
                if let input = b["input"] as? [String: Any], let name = b["name"] as? String {
                    applyPlanTool(name, input, ts)
                    if !name.contains("update_plan"), !name.contains("wrap_up"), name != "TodoWrite" {
                        activity = Self.describe(name, input); activityAt = ts
                    }
                }
            }
            for b in blocks where b["type"] as? String == "tool_use" && b["name"] as? String == "Bash" {
                guard let input = b["input"] as? [String: Any], input["run_in_background"] as? Bool == true,
                      let tid = b["id"] as? String else { continue }
                let label = (input["description"] as? String) ?? (input["command"] as? String).map { String($0.prefix(60)) } ?? "background command"
                pendingBackground[tid] = label
                pendingCommands[tid] = input["command"] as? String ?? ""
            }
        }
        let reason = (obj["message"] as? [String: Any])?["stop_reason"] as? String
        if let reason, reason != "tool_use" { goIdle(ts) } else { goBusy(ts) }
    }

    private func applyPlanTool(_ name: String, _ input: [String: Any], _ ts: Date) {
        func steps(_ arr: [[String: Any]]) -> [PlanStep] {
            arr.compactMap { d in (d["content"] as? String).map { PlanStep(content: $0, status: d["status"] as? String ?? "pending") } }
        }
        switch name {
        case "TodoWrite":
            if let todos = input["todos"] as? [[String: Any]] { plan = steps(todos); if planStart == nil { planStart = ts } }
        case "mcp__ccd_turn__update_plan":
            if let items = input["items"] as? [[String: Any]] { plan = steps(items); if planStart == nil { planStart = ts }; return }
            if input["advance"] as? Bool == true {
                if let i = plan.firstIndex(where: { $0.status == "in_progress" }) { plan[i].status = "completed" }
                if let j = plan.firstIndex(where: { $0.status == "pending" }) { plan[j].status = "in_progress" }
            }
            for n in (input["done"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }) ?? [] where n >= 1 && n <= plan.count {
                plan[n - 1].status = "completed"
            }
            if let n = (input["start"] as? NSNumber)?.intValue, n >= 1, n <= plan.count { plan[n - 1].status = "in_progress" }
        case "mcp__ccd_turn__wrap_up":
            for i in plan.indices where plan[i].status == "in_progress" { plan[i].status = "completed" }
        default: break
        }
    }

    private func goBusy(_ ts: Date) {
        if busySince == nil { busySince = ts; stateSince = ts }
    }
    static func describe(_ name: String, _ input: [String: Any]) -> String {
        func base(_ k: String) -> String? { (input[k] as? String).map { ($0 as NSString).lastPathComponent } }
        func clip(_ s: String) -> String { let t = s.split(separator: "\n").first.map(String.init) ?? s; return t.count > 60 ? String(t.prefix(60)) + "…" : t }
        let short = name.hasPrefix("mcp__") ? (name.split(separator: "_").last.map(String.init) ?? name) : name
        switch name {
        case "Bash": return "Bash · " + clip((input["description"] as? String) ?? (input["command"] as? String) ?? "")
        case "Read", "Edit", "Write", "NotebookEdit": return "\(name) · " + (base("file_path") ?? "")
        case "Agent", "Task": return "Agent · " + clip((input["description"] as? String) ?? "")
        case "Grep", "Glob": return "\(name) · " + clip((input["pattern"] as? String) ?? "")
        case "WebSearch": return "Search · " + clip((input["query"] as? String) ?? "")
        case "WebFetch": return "Fetch · " + clip((input["url"] as? String) ?? "")
        default: return short
        }
    }

    private func goIdle(_ ts: Date) {
        activity = nil; activityAt = nil
        if let b = busySince { workedClosed += max(0, ts.timeIntervalSince(b)) }
        if busySince != nil || stateSince == nil { stateSince = ts }
        busySince = nil
    }

    static func summarise(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop wrapper tags such as <pasted_content id="..."> and take the first real line.
        while t.hasPrefix("<"), let close = t.firstIndex(of: ">") {
            t = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let line = t.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        if line.isEmpty { return nil }
        return line.count > 70 ? String(line.prefix(70)) + "…" : line
    }
}
