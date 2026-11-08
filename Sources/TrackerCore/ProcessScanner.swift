import Foundation

public struct SubProcess: Identifiable {
    public let id: Int          // pid
    public let label: String
    public let elapsed: TimeInterval
    public var progress: Double?
    public var progressText: String?
}

struct ProcInfo { let pid: Int; let ppid: Int; let elapsed: TimeInterval; let command: String; var cwd: String? }

/// Finds the work a session has running, even when it was started detached (nohup/caffeinate re-parent
/// it to launchd): processes whose working directory is inside the session's folder, plus descendants of
/// the session's own pid. Read-only (`ps` and `lsof`).
final class ProcessScanner {
    private var cache: [ProcInfo] = []
    private var cachedAt = Date.distantPast

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func parseEtime(_ s: String) -> TimeInterval {
        let dayParts = s.split(separator: "-", maxSplits: 1).map(String.init)
        let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
        let hms = (dayParts.last ?? "").split(separator: ":").compactMap { Double($0) }
        var secs = 0.0
        for v in hms { secs = secs * 60 + v }
        return days * 86400 + secs
    }

    /// Cached for `ttl` seconds: lsof is the expensive part.
    func all(ttl: TimeInterval = 10) -> [ProcInfo] {
        if Date().timeIntervalSince(cachedAt) < ttl { return cache }
        var procs: [Int: ProcInfo] = [:]
        for line in Self.run("/bin/ps", ["-axo", "pid=,ppid=,etime=,command="]).split(separator: "\n") {
            let p = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard p.count == 4, let pid = Int(p[0]), let ppid = Int(p[1]) else { continue }
            procs[pid] = ProcInfo(pid: pid, ppid: ppid, elapsed: Self.parseEtime(String(p[2])), command: String(p[3]), cwd: nil)
        }
        var cur = -1
        for line in Self.run("/usr/sbin/lsof", ["-a", "-u", String(getuid()), "-d", "cwd", "-Fpn"]).split(separator: "\n") {
            if line.hasPrefix("p") { cur = Int(line.dropFirst()) ?? -1 }
            else if line.hasPrefix("n"), var pi = procs[cur] { pi.cwd = String(line.dropFirst()); procs[cur] = pi }
        }
        cache = Array(procs.values); cachedAt = Date()
        return cache
    }

    func commandLine(_ pid: Int) -> String? { cache.first { $0.pid == pid }?.command }

    private static let ignore = ["sleep", "caffeinate", "tail", "grep", "ugrep", "ps", "lsof", "head", "cat", "claude", "ClaudeSessionTracker", "watch", "disclaimer", "swift-build", "swift-frontend", "swiftc"]
    private static let shells = ["bash", "sh", "zsh"]

    static func label(_ command: String) -> String {
        let toks = command.split(separator: " ").map(String.init)
        guard let first = toks.first else { return command }
        let exe = (first as NSString).lastPathComponent
        // Interpreter + script: show the script.
        var i = 0
        if ["node", "python", "python3", "bash", "sh", "zsh", "ruby", "tsx", "bun", "deno"].contains(exe) {
            i = 1
            while i < toks.count, toks[i].hasPrefix("-") { i += 1 }
        }
        guard i < toks.count else { return exe }
        var parts = [(toks[i] as NSString).lastPathComponent]
        var flags = 0
        for t in toks.dropFirst(i + 1) {
            if t.hasPrefix("--") { flags += 1; if flags > 1 { break } }
            parts.append(t)
        }
        let s = parts.joined(separator: " ")
        return s.count > 56 ? String(s.prefix(56)) + "…" : s
    }

    /// Sub-processes for a session: leaves (not shells that merely wait on a child), no helpers.
    func subprocesses(sessionPid: Int, cwd: String, now: Date = Date()) -> [SubProcess] {
        let procs = all()
        let byParent = Dictionary(grouping: procs, by: \.ppid)
        func descendants(_ pid: Int) -> [Int] { (byParent[pid] ?? []).flatMap { [$0.pid] + descendants($0.pid) } }
        let desc = Set(descendants(sessionPid))
        let mine = procs.filter { p in
            p.pid != sessionPid && !p.command.contains("shell-snapshots") &&
            (desc.contains(p.pid) || (p.cwd.map { $0 == cwd || $0.hasPrefix(cwd + "/") } ?? false))
        }
        let ids = Set(mine.map(\.pid))
        func exe(_ p: ProcInfo) -> String { (p.command.split(separator: " ").first.map(String.init) ?? "" as String as String).split(separator: "/").last.map(String.init) ?? "" }
        let kept = mine.filter { p in
            let e = exe(p)
            if Self.label(p.command).hasPrefix("progress") { return false }   // dashboards/feed writers are not work
            if e.hasPrefix("(") || Self.ignore.contains(e) || p.command.contains(".app/Contents/") { return false }
            // A shell whose children include another kept-candidate is just a wrapper.
            let hasWorkChild = (byParent[p.pid] ?? []).contains { c in ids.contains(c.pid) && !Self.ignore.contains(exe(c)) }
            return !(Self.shells.contains(e) && hasWorkChild)
        }
        // Keep only roots of work: drop Chrome helpers etc. that hang off another kept process, and bare shells.
        let keptIDs = Set(kept.map(\.pid))
        let parent = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0.ppid) })
        func hasKeptAncestor(_ pid: Int) -> Bool {
            var p = parent[pid] ?? 0, hops = 0
            while p > 1, hops < 20 { if keptIDs.contains(p) { return true }; p = parent[p] ?? 0; hops += 1 }
            return false
        }
        let roots = kept.filter { p in
            !hasKeptAncestor(p.pid) && !(Self.shells.contains(exe(p)) && Self.label(p.command) == exe(p))
        }
        return roots.sorted { $0.elapsed > $1.elapsed }.map {
            SubProcess(id: $0.pid, label: Self.label($0.command), elapsed: $0.elapsed, progress: nil, progressText: nil)
        }
    }
}
