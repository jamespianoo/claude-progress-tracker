import Foundation

/// Discovers live Claude Code sessions and keeps one TranscriptTail per transcript.
/// Read-only: only reads ~/.claude/sessions/*.json and ~/.claude/projects/**.
/// Not thread-safe; call `refresh()` from one queue.
public final class SessionStore {
    private let claudeDir: String
    private var tails: [String: TranscriptTail] = [:]       // by path
    private var pathCache: [String: String] = [:]            // sessionId -> transcript path
    private var samples: [String: (t: Date, f: Double)] = [:]   // task id -> first progress sample
    static let remoteWindow: TimeInterval = 2 * 3600
    private var feedHistory: [String: [(t: Date, done: Int, active: Bool)]] = [:]
    private let scanner = ProcessScanner()
    private var known: [String: SessionInfo] = [:]           // sessions seen alive this run (for "finished")

    public init(claudeDir: String = NSHomeDirectory() + "/.claude") { self.claudeDir = claudeDir }

    struct Entry { let pid: Int; let sessionId: String; let cwd: String; let startedAt: Date; let name: String? }

    func registry() -> [Entry] {
        let dir = claudeDir + "/sessions"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [Entry] = []
        for n in names where n.hasSuffix(".json") {
            guard let d = FileManager.default.contents(atPath: dir + "/" + n),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let pid = o["pid"] as? Int, let sid = o["sessionId"] as? String,
                  let cwd = o["cwd"] as? String else { continue }
            let ms = (o["startedAt"] as? Double) ?? 0
            out.append(Entry(pid: pid, sessionId: sid, cwd: cwd,
                             startedAt: Date(timeIntervalSince1970: ms / 1000), name: o["name"] as? String))
        }
        return out
    }

    static func processStart(_ pid: Int) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    /// Guards against pid reuse: the live process must have started near the recorded start.
    static func isAlive(_ e: Entry) -> Bool {
        guard let s = processStart(e.pid) else { return false }
        return abs(s.timeIntervalSince(e.startedAt)) < 300
    }

    func transcriptPath(_ e: Entry) -> String? {
        if let p = pathCache[e.sessionId], FileManager.default.fileExists(atPath: p) { return p }
        let root = claudeDir + "/projects"
        let slug = String(e.cwd.unicodeScalars.map { c in
            (c.isASCII && (CharacterSet.alphanumerics.contains(c))) ? Character(c) : "-" })
        let direct = "\(root)/\(slug)/\(e.sessionId).jsonl"
        if FileManager.default.fileExists(atPath: direct) { pathCache[e.sessionId] = direct; return direct }
        for d in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let p = "\(root)/\(d)/\(e.sessionId).jsonl"
            if FileManager.default.fileExists(atPath: p) { pathCache[e.sessionId] = p; return p }
        }
        return nil
    }

    private func tail(_ path: String) -> TranscriptTail {
        if let t = tails[path] { return t }
        let t = TranscriptTail(path: path); tails[path] = t; return t
    }

    /// Subagent transcripts: `<session>/subagents/` locally, or beside the transcript for desktop-app SSH sessions.
    /// Only files touched in the last 12 h are read (an SSH folder can hold hundreds of old ones).
    func subagents(for transcript: String, descriptions: [String: String] = [:], launchNames: [String: String] = [:], finished: Set<String> = [], waiting: [String: Date] = [:]) -> [SubagentInfo] {
        let parent = (transcript as NSString).deletingLastPathComponent
        var dirs = [(transcript as NSString).deletingPathExtension + "/subagents"]
        if (parent as NSString).lastPathComponent.hasPrefix("ssh-") { dirs.append(parent) }
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        let waitingCutoff = Date().addingTimeInterval(-72 * 3600)   // an unfinished agent can be silent for a long time
        var out: [SubagentInfo] = []
        var fileMod: Date?
        for dir in dirs {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasPrefix("agent-") && n.hasSuffix(".jsonl") {
                let path = dir + "/" + n
                let aid = String(n.dropFirst(6).dropLast(6))
                guard let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      m > cutoff || (m > waitingCutoff && !finished.contains(aid)) else { continue }
                fileMod = m
                let t = tail(path)
                t.advance()
                guard let start = t.firstTimestamp, let last = t.lastTimestamp else { continue }
                let id = String(n.dropFirst(6).dropLast(6))
                var desc = launchNames[id] ?? t.firstPrompt ?? id, type = "agent"   // launch name, else the agent's first prompt
                if let d = FileManager.default.contents(atPath: dir + "/agent-\(id).meta.json"),
                   let mj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    // Name given at launch: in the meta file, else from the parent's Agent tool call (matched by tool_use id).
                    if let md = mj["description"] as? String { desc = md }
                    else if let tu = mj["toolUseId"] as? String, let ld = descriptions[tu] { desc = ld }
                    type = (mj["agentType"] as? String) ?? type
                }
                var info = SubagentInfo(id: id, description: desc, agentType: type, start: start,
                                        lastActivity: last, busy: t.isBusy, workedClosed: t.workedClosed)
                info.tasks = t.backgroundTasks.values.sorted { $0.start > $1.start }.map { $0 }
                info.finished = finished.contains(id)
                info.waitingSince = waiting[id]
                info.fileModified = fileMod
                out.append(info)
            }
        }
        return out.sorted { $0.start > $1.start }
    }

    /// Latest hook event per session id (written by hooks/claude-tracker-hook.sh).
    func readHookEvents() -> [String: (event: String, at: Date)] {
        let dir = NSHomeDirectory() + "/.claude-progress/events"
        var out: [String: (String, Date)] = [:]
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".json") {
            guard let d = FileManager.default.contents(atPath: dir + "/" + n),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let sid = o["session_id"] as? String, let ev = o["event"] as? String,
                  let at = (o["updated"] as? NSNumber)?.doubleValue else { continue }
            out[sid] = (ev, Date(timeIntervalSince1970: at))
        }
        return out
    }

    /// Feeds written by user scripts. Schema: {"title","cwd","started":epoch,"updated":epoch,
    /// "stages":[{"name","done","total"}],"now":["..."]}
    func readFeeds() -> [ProgressFeed] {
        let dir = NSHomeDirectory() + "/.claude-progress"
        var out: [ProgressFeed] = []
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".json") {
            guard let d = FileManager.default.contents(atPath: dir + "/" + n),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let upd = (o["updated"] as? NSNumber)?.doubleValue, let st = (o["started"] as? NSNumber)?.doubleValue else { continue }
            let stages = ((o["stages"] as? [[String: Any]]) ?? []).compactMap { s -> ProgressFeed.Stage? in
                guard let name = s["name"] as? String, let done = (s["done"] as? NSNumber)?.intValue,
                      let total = (s["total"] as? NSNumber)?.intValue else { return nil }
                return .init(name: name, done: done, total: total)
            }
            out.append(ProgressFeed(id: n, title: o["title"] as? String ?? n, cwd: o["cwd"] as? String ?? "",
                                    started: Date(timeIntervalSince1970: st), updated: Date(timeIntervalSince1970: upd),
                                    stages: stages, now: o["now"] as? [String] ?? []))
        }
        return out
    }

    /// Items/second counted only over intervals where workers were alive at both ends, looking back over at most
    /// `window` seconds of such active time. nil until there are 10 min of active time and at least 2 items done.
    static func recentRate(_ samples: [(t: Date, done: Int, active: Bool)], window: TimeInterval = 3600) -> Double? {
        var activeTime = 0.0, items = 0
        var i = samples.count - 1
        while i > 0, activeTime < window {
            let a = samples[i - 1], b = samples[i]
            if a.active && b.active { activeTime += b.t.timeIntervalSince(a.t); items += max(0, b.done - a.done) }
            i -= 1
        }
        return (activeTime >= 600 && items >= 2) ? Double(items) / activeTime : nil
    }

    /// Records each new feed update (with whether workers were alive) and attaches the measured rate.
    func withRates(_ feeds: [ProgressFeed], active: Bool) -> [ProgressFeed] {
        feeds.map { f in
            var f = f
            var h = feedHistory[f.id] ?? []
            if h.last?.t != f.updated { h.append((f.updated, f.doneTotal, active)) }
            h = h.filter { f.updated.timeIntervalSince($0.t) < 6 * 3600 }.suffix(3000).map { $0 }
            feedHistory[f.id] = h
            f.recentRate = Self.recentRate(h)
            return f
        }
    }

    /// Looks for "NN%" or "a / b" in the tail of the task's own output file.
    func withProgress(_ task: BackgroundTask) -> BackgroundTask {
        var t = task
        guard t.status == .running else { return t }
        let files = [t.outputPath]   // only the task's own output: log files named in the command are too ambiguous
        for f in files {
            guard let fh = FileHandle(forReadingAtPath: f) else { continue }
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            try? fh.seek(toOffset: size > 8192 ? size - 8192 : 0)
            guard let d = try? fh.readToEnd(), let text = String(data: d, encoding: .utf8) else { continue }
            if let (frac, label) = Self.lastProgress(in: text) {
                t.progress = frac; t.progressText = label
                let now = Date()
                if let s0 = samples[t.id] {
                    let dt = now.timeIntervalSince(s0.t), df = frac - s0.f
                    if dt > 30, df > 0 { t.eta = (1 - frac) * dt / df }
                } else { samples[t.id] = (now, frac) }
                break
            }
        }
        return t
    }

    static func lastProgress(in text: String) -> (Double, String)? {
        let patterns: [(String, (NSTextCheckingResult, String) -> (Double, String)?)] = [
            ("(\\d+)\\s*/\\s*(\\d+)", { m, s in
                guard let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s),
                      let x = Double(s[a]), let y = Double(s[b]), y > 0, x <= y else { return nil }
                return (x / y, "\(s[a]) / \(s[b])") }),
            ("(\\d{1,3}(?:\\.\\d+)?)\\s*%", { m, s in
                guard let a = Range(m.range(at: 1), in: s), let x = Double(s[a]), x <= 100 else { return nil }
                return (x / 100, "\(s[a])%") }),
        ]
        var best: (Int, Double, String)?
        for (pat, f) in patterns {
            guard let re = try? NSRegularExpression(pattern: pat) else { continue }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = f(m, text), m.range.location >= (best?.0 ?? -1) { best = (m.range.location, r.0, r.1) }
            }
        }
        return best.map { ($0.1, $0.2) }
    }

    /// Re-reads appended transcript bytes and returns the current rows, newest activity first.
    public func refresh() -> [SessionInfo] {
        var result: [String: SessionInfo] = [:]
        var liveIDs = Set<String>()
        let feeds = readFeeds()
        let hookEvents = readHookEvents()
        for e in registry() where Self.isAlive(e) {
            liveIDs.insert(e.sessionId)
            guard let path = transcriptPath(e) else { continue }
            let t = tail(path)
            t.advance()
            guard !t.missing, let first = t.firstTimestamp else { continue }
            let last = t.lastTimestamp ?? first
            let cwd = t.cwd ?? e.cwd
            let title = t.customTitle ?? e.name ?? t.agentName ?? t.firstPrompt ?? (cwd as NSString).lastPathComponent
            var info = SessionInfo(
                id: e.sessionId, pid: e.pid, cwd: cwd, branch: t.gitBranch, title: title,
                start: first, lastActivity: last, busySince: t.busySince,
                stateSince: t.stateSince ?? first, workedClosed: t.workedClosed,
                alive: true, subagents: subagents(for: path, descriptions: t.agentDescriptions, launchNames: t.agentNames, finished: t.finishedIDs, waiting: t.waitingIDs))
            info.tasks = t.backgroundTasks.values.sorted { $0.start > $1.start }.prefix(8).map(withProgress)
            info.plan = t.plan; info.planStart = t.planStart; info.promptAt = t.promptAt; info.activity = t.activity; info.activityAt = t.activityAt; info.statusText = t.statusText; info.statusAt = t.statusAt
            info.feeds = feeds.filter { !$0.cwd.isEmpty && $0.cwd == cwd }
            // Only pay for ps/lsof when this session is doing something.
            if info.state(at: Date()) == .working || info.hasPendingWork(at: Date()) {
                info.procs = scanner.subprocesses(sessionPid: e.pid, cwd: cwd).prefix(12).map { sp in
                    var sp = sp
                    // Match "name  frame a/b" lines from a feed to a process whose command mentions the name's first part.
                    let cmd = scanner.commandLine(sp.id)?.lowercased().replacingOccurrences(of: " ", with: "-") ?? ""
                    outer: for f in info.feeds { for line in f.now {
                        let name = line.split(separator: " ").first.map(String.init) ?? ""
                        let key = name.split(separator: "_").first.map { $0.lowercased() } ?? ""
                        if !key.isEmpty, cmd.contains(key), let (frac, txt) = Self.lastProgress(in: String(line.dropFirst(name.count))) {
                            sp.progress = frac; sp.progressText = txt; break outer
                        }
                    } }
                    return sp
                }
            }
            info.feeds = withRates(info.feeds, active: !info.procs.isEmpty)   // rate counts only time workers were alive
            if let h = hookEvents[e.sessionId] { info.hookEvent = h.event; info.hookAt = h.at }
            result[e.sessionId] = info
        }
        // Desktop-app SSH sessions: no local process, so "alive" means the transcript was written recently.
        let root = claudeDir + "/projects"
        let cutoff = Date().addingTimeInterval(-Self.remoteWindow)
        for d in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where d.hasPrefix("ssh-") {
            let dir = root + "/" + d
            for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".jsonl") && !n.hasPrefix("agent-") {
                let path = dir + "/" + n
                guard let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date, mtime > cutoff else { continue }
                let sid = String(n.dropLast(6))
                if result[sid] != nil { continue }
                let t = tail(path); t.advance()
                guard !t.missing, let first = t.firstTimestamp else { continue }
                let cwd = t.cwd ?? ""
                let title = t.customTitle ?? t.agentName ?? t.firstPrompt ?? (cwd as NSString).lastPathComponent
                var info = SessionInfo(id: sid, pid: 0, cwd: cwd, branch: t.gitBranch, title: title, start: first,
                                       lastActivity: t.lastTimestamp ?? first, busySince: t.busySince,
                                       stateSince: t.stateSince ?? first, workedClosed: t.workedClosed,
                                       alive: true, subagents: subagents(for: path, descriptions: t.agentDescriptions, launchNames: t.agentNames, finished: t.finishedIDs, waiting: t.waitingIDs))
                info.tasks = t.backgroundTasks.values.sorted { $0.start > $1.start }.prefix(8).map(withProgress)
                info.remote = true
                info.plan = t.plan; info.planStart = t.planStart; info.promptAt = t.promptAt; info.activity = t.activity; info.activityAt = t.activityAt; info.statusText = t.statusText; info.statusAt = t.statusAt
                if let h = hookEvents[sid] { info.hookEvent = h.event; info.hookAt = h.at }
                result[sid] = info; liveIDs.insert(sid)
            }
        }
        // Sessions that were alive earlier in this run and have now exited.
        let gone = known.filter { !liveIDs.contains($0.key) }
        for (id, s) in gone {
            if Date().timeIntervalSince(s.lastActivity) > 3600 { known[id] = nil; continue }
            let f = SessionInfo(id: s.id, pid: s.pid, cwd: s.cwd, branch: s.branch, title: s.title, start: s.start,
                                lastActivity: s.lastActivity, busySince: nil, stateSince: s.lastActivity,
                                workedClosed: s.worked(at: s.lastActivity), alive: false, subagents: s.subagents)
            known[id] = f; result[id] = f
        }
        for (id, s) in result where s.alive && !s.remote { known[id] = s }
        return result.values.sorted { $0.lastActivity > $1.lastActivity }
    }
}
