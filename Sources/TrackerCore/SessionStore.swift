import Foundation

/// Discovers live Claude Code sessions and keeps one TranscriptTail per transcript.
/// Read-only: only reads ~/.claude/sessions/*.json and ~/.claude/projects/**.
/// Not thread-safe; call `refresh()` from one queue.
public final class SessionStore {
    private let claudeDir: String
    private var tails: [String: TranscriptTail] = [:]       // by path
    private var pathCache: [String: String] = [:]            // sessionId -> transcript path
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

    func subagents(for transcript: String) -> [SubagentInfo] {
        let dir = (transcript as NSString).deletingPathExtension + "/subagents"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [SubagentInfo] = []
        for n in names where n.hasPrefix("agent-") && n.hasSuffix(".jsonl") {
            let t = tail(dir + "/" + n)
            t.advance()
            guard let start = t.firstTimestamp, let last = t.lastTimestamp else { continue }
            let id = String(n.dropFirst(6).dropLast(6))
            var desc = id, type = "agent"
            if let d = FileManager.default.contents(atPath: dir + "/agent-\(id).meta.json"),
               let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                desc = (m["description"] as? String) ?? desc
                type = (m["agentType"] as? String) ?? type
            }
            out.append(SubagentInfo(id: id, description: desc, agentType: type, start: start,
                                    lastActivity: last, busy: t.isBusy, workedClosed: t.workedClosed))
        }
        return out.sorted { $0.start > $1.start }
    }

    /// Re-reads appended transcript bytes and returns the current rows, newest activity first.
    public func refresh() -> [SessionInfo] {
        var result: [String: SessionInfo] = [:]
        var liveIDs = Set<String>()
        for e in registry() where Self.isAlive(e) {
            liveIDs.insert(e.sessionId)
            guard let path = transcriptPath(e) else { continue }
            let t = tail(path)
            t.advance()
            guard !t.missing, let first = t.firstTimestamp else { continue }
            let last = t.lastTimestamp ?? first
            let cwd = t.cwd ?? e.cwd
            let title = t.customTitle ?? e.name ?? t.agentName ?? t.firstPrompt ?? (cwd as NSString).lastPathComponent
            result[e.sessionId] = SessionInfo(
                id: e.sessionId, pid: e.pid, cwd: cwd, branch: t.gitBranch, title: title,
                start: first, lastActivity: last, busySince: t.busySince,
                stateSince: t.stateSince ?? first, workedClosed: t.workedClosed,
                alive: true, subagents: subagents(for: path))
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
        for (id, s) in result where s.alive { known[id] = s }
        return result.values.sorted { $0.lastActivity > $1.lastActivity }
    }
}
