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

    public init(path: String) { self.path = path }

    /// Worked time as of `now`. A stale open interval is capped at last activity.
    public func worked(at now: Date, staleAfter: TimeInterval) -> TimeInterval {
        guard let b = busySince else { return workedClosed }
        var end = now
        if let last = lastTimestamp, now.timeIntervalSince(last) > staleAfter { end = last }
        return workedClosed + max(0, end.timeIntervalSince(b))
    }

    private func reset() {
        offset = 0; partial = Data(); sawFirstLine = false
        firstTimestamp = nil; lastTimestamp = nil; busySince = nil; stateSince = nil
        workedClosed = 0; customTitle = nil; agentName = nil; firstPrompt = nil
        cwd = nil; gitBranch = nil
    }

    /// Reads any bytes appended since the last call.
    public func advance() {
        var st = stat()
        guard stat(path, &st) == 0 else { missing = true; return }
        missing = false
        if UInt64(st.st_ino) != fileID || UInt64(st.st_size) < offset {
            reset(); fileID = UInt64(st.st_ino)
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
                                 "\"type\":\"custom-title\"", "\"type\":\"agent-name\""].map { Data($0.utf8) }

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
        default: break
        }
    }

    private func handleUser(_ obj: [String: Any], _ ts: Date) {
        if obj["isMeta"] as? Bool == true { return }
        let content = (obj["message"] as? [String: Any])?["content"]
        var text: String?
        var onlyToolResults = false
        if let s = content as? String {
            text = s
        } else if let arr = content as? [[String: Any]] {
            onlyToolResults = !arr.isEmpty && arr.allSatisfy { $0["type"] as? String == "tool_result" }
            text = arr.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        if let t = text, t.hasPrefix("[Request interrupted") { goIdle(ts); return }
        if !onlyToolResults, firstPrompt == nil, let t = text {
            firstPrompt = Self.summarise(t)
        }
        goBusy(ts)
    }

    private func handleAssistant(_ obj: [String: Any], _ ts: Date) {
        let reason = (obj["message"] as? [String: Any])?["stop_reason"] as? String
        if let reason, reason != "tool_use" { goIdle(ts) } else { goBusy(ts) }
    }

    private func goBusy(_ ts: Date) {
        if busySince == nil { busySince = ts; stateSince = ts }
    }
    private func goIdle(_ ts: Date) {
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
