import Foundation

/// Reads the time estimate a session gives in its own words ("about 5 to 6 hours from now", "roughly 01:00–01:30")
/// and turns it into time remaining. Works on any session's latest estimate message.
///
/// Rules, in order of trust:
///  1. Explicit remaining time: "<n> hours from now / left / remaining / to go", "in <n> hours", "ETA <n> hours".
///  2. A clock time ("around 20:40", "01:00–01:30", "5am"), local sessions only (a server's clock zone is unknown).
///  3. Looser "about <n> hours" statements.
/// Within the highest class present, the LATEST finish is taken: an overall completion is later than its milestones.
public enum StatedEstimate {
    private static let dur = #"(\d+(?:\.\d+)?)(½)?(?:\s*(?:–|-|to)\s*(\d+(?:\.\d+)?)(½)?)?\s*(hours?|hrs?|minutes?|mins?)\b"#
    private static let negatives = ["after it", "after the", "overlap", " per ", "each ", "on its own", "takes ", "took ", " ago",
                                    "started", "since ", "clock reads", "so far", "elapsed", "running for", "has been", "in total", "under an hour", "less than"]

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: .caseInsensitive) }
    private static let explicitFromNow = re(dur + #"\s+(?:from now|left|remaining|to go|more)\b"#)
    private static let explicitIn = re(#"(?:\bin|\bETA:?|\bwithin)\s+(?:about |around |roughly |approximately |~)?"# + dur)
    private static let loose = re(#"(?:about|around|roughly|approximately|~)\s*"# + dur)
    private static let clock24 = re(#"\b(\d{1,2}):(\d{2})(?:\s*(?:–|-|to)\s*(\d{1,2}):(\d{2}))?\b"#)
    private static let clock12 = re(#"\b(\d{1,2})\s?(am|pm)\b"#)

    /// Midpoint of a duration match (groups 1...5 starting at `g`) in seconds.
    private static func seconds(_ m: NSTextCheckingResult, _ s: String, group g: Int) -> TimeInterval? {
        func grp(_ i: Int) -> String? { Range(m.range(at: g + i - 1), in: s).map { String(s[$0]) } }
        guard var lo = grp(1).flatMap(Double.init), let unit = grp(5)?.lowercased() else { return nil }
        if grp(2) != nil { lo += 0.5 }
        var v = lo
        if var hi = grp(3).flatMap(Double.init) { if grp(4) != nil { hi += 0.5 }; v = (lo + hi) / 2 }
        return v * (unit.hasPrefix("h") ? 3600 : 60)
    }

    private static func sentences(_ text: String) -> [String] {
        var clean = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        // Quoted text is someone else's words (a session quoting another session's estimate): ignore it.
        for q in [#""[^"\n]{8,400}""#, #"“[^”\n]{8,400}”"#] {
            clean = clean.replacingOccurrences(of: q, with: " ", options: .regularExpression)
        }
        var out: [String] = []
        for line in clean.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
            for p in line.components(separatedBy: ". ") { for q in p.components(separatedBy: "; ") { out.append(q) } }
        }
        return out.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -•*\t")) }.filter { $0.count >= 8 }
    }

    /// Cheap pre-check so the tail only keeps messages that could contain an estimate.
    public static func mayContainEstimate(_ text: String) -> Bool {
        let l = text.lowercased()
        guard l.contains(where: \.isNumber) else { return false }
        return ["hour", "minute", " min", "eta", "am ", "pm ", ":"].contains { l.contains($0) }
    }

    /// Finish time the session stated (as a date), or nil. `statusAt` anchors "from now" phrases.
    public static func finish(in text: String, statusAt: Date, remote: Bool, calendar: Calendar = .current) -> Date? {
        var strong: [Date] = [], weak: [Date] = []
        for s in sentences(text) {
            let l = s.lowercased()
            if negatives.contains(where: { l.contains($0) }) { continue }
            let r = NSRange(s.startIndex..., in: s)
            for m in explicitFromNow.matches(in: s, range: r) { if let d = seconds(m, s, group: 1) { strong.append(statusAt.addingTimeInterval(d)) } }
            for m in explicitIn.matches(in: s, range: r) { if let d = seconds(m, s, group: 1) { strong.append(statusAt.addingTimeInterval(d)) } }
            for m in loose.matches(in: s, range: r) { if let d = seconds(m, s, group: 1) { weak.append(statusAt.addingTimeInterval(d)) } }
            guard !remote, ["around", "about", "roughly", "by ", "until", "finish", "done", "ready", "eta", "puts", "complete", "should"].contains(where: { l.contains($0) }) else { continue }
            func target(_ h: Int, _ min: Int) -> Date? {
                guard h < 24, min < 60 else { return nil }
                var c = calendar.dateComponents([.year, .month, .day], from: statusAt)
                c.hour = h; c.minute = min
                guard var d = calendar.date(from: c) else { return nil }
                if d < statusAt.addingTimeInterval(-60) { d = calendar.date(byAdding: .day, value: 1, to: d) ?? d }   // "01:15" said at 19:44
                return d.timeIntervalSince(statusAt) < 18 * 3600 ? d : nil                                        // reject past times
            }
            for m in clock24.matches(in: s, range: r) {
                func g(_ i: Int) -> Int? { Range(m.range(at: i), in: s).flatMap { Int(s[$0]) } }
                guard let h1 = g(1), let m1 = g(2), let a = target(h1, m1) else { continue }
                if let h2 = g(3), let m2 = g(4), let b = target(h2, m2), b > a { strong.append(Date(timeIntervalSince1970: (a.timeIntervalSince1970 + b.timeIntervalSince1970) / 2)) }
                else { strong.append(a) }
            }
            for m in clock12.matches(in: s, range: r) {
                guard let hr = Range(m.range(at: 1), in: s).flatMap({ Int(s[$0]) }), (1...12).contains(hr),
                      let ap = Range(m.range(at: 2), in: s).map({ s[$0].lowercased() }) else { continue }
                let h24 = (hr % 12) + (ap == "pm" ? 12 : 0)
                if let d = target(h24, 0) { strong.append(d) }
            }
        }
        return (strong.max() ?? weak.max())
    }

    /// Seconds remaining at `now`, or nil if none stated, already passed, or implausibly far.
    public static func remaining(in text: String, statusAt: Date, now: Date, remote: Bool) -> TimeInterval? {
        guard let f = finish(in: text, statusAt: statusAt, remote: remote) else { return nil }
        let left = f.timeIntervalSince(now)
        return (left > 60 && left < 72 * 3600) ? left : nil
    }
}
