import XCTest
@testable import TrackerCore

final class TranscriptTailTests: XCTestCase {
    var path = ""
    override func setUp() { path = NSTemporaryDirectory() + "t-\(UUID().uuidString).jsonl" }
    override func tearDown() { try? FileManager.default.removeItem(atPath: path) }

    func line(_ type: String, _ t: String, content: String, stop: String? = nil) -> String {
        let stopJSON = stop.map { "\"\($0)\"" } ?? "null"
        if type == "user" {
            return #"{"type":"user","timestamp":"2026-01-01T\#(t)Z","cwd":"/a/b","gitBranch":"main","message":{"role":"user","content":\#(content)}}"# + "\n"
        }
        return #"{"type":"assistant","timestamp":"2026-01-01T\#(t)Z","message":{"role":"assistant","stop_reason":\#(stopJSON),"content":[]}}"# + "\n"
    }
    func append(_ s: String) {
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(s.utf8)); try? h.close() }
        else { try? s.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    func testBusyIdleIntervalsAndIncrementalRead() {
        append(#"{"type":"queue-operation","timestamp":"2026-01-01T10:00:00.000Z"}"# + "\n")
        append(line("user", "10:00:05.000", content: "\"do thing\""))
        let t = TranscriptTail(path: path); t.advance()
        XCTAssertTrue(t.isBusy)
        XCTAssertEqual(t.firstPrompt, "do thing")
        append(line("assistant", "10:00:10.000", content: "", stop: "tool_use"))
        append(line("user", "10:00:20.000", content: #"[{"type":"tool_result","content":"ok"}]"#))
        append(line("assistant", "10:01:05.000", content: "", stop: "end_turn"))
        t.advance()
        XCTAssertFalse(t.isBusy)
        XCTAssertEqual(t.workedClosed, 60, accuracy: 0.01)          // 10:00:05 -> 10:01:05
        append(line("user", "10:30:00.000", content: "\"again\""))   // long idle gap not counted
        t.advance()
        XCTAssertTrue(t.isBusy)
        XCTAssertEqual(t.workedClosed, 60, accuracy: 0.01)
        XCTAssertEqual(t.firstTimestamp!.timeIntervalSince(t.lastTimestamp!), -1800, accuracy: 0.01 + 5)
    }

    func testPartialLineAndInterrupt() {
        append(line("user", "10:00:00.000", content: "\"go\""))
        let half = line("assistant", "10:00:30.000", content: "", stop: "end_turn")
        append(String(half.prefix(20)))
        let t = TranscriptTail(path: path); t.advance()
        XCTAssertTrue(t.isBusy)                       // partial line ignored
        append(String(half.dropFirst(20)))
        t.advance()
        XCTAssertFalse(t.isBusy)
        append(line("user", "10:01:00.000", content: "\"x\""))
        append(line("user", "10:01:10.000", content: #"[{"type":"text","text":"[Request interrupted by user]"}]"#))
        t.advance()
        XCTAssertFalse(t.isBusy)
        XCTAssertEqual(t.workedClosed, 40, accuracy: 0.01)
    }

    func testTruncationResets() {
        append(line("user", "10:00:00.000", content: "\"go\""))
        let t = TranscriptTail(path: path); t.advance()
        try? FileManager.default.removeItem(atPath: path)
        t.advance(); XCTAssertTrue(t.missing)
        append(line("user", "11:00:00.000", content: "\"new\""))
        t.advance()
        XCTAssertFalse(t.missing)
        XCTAssertEqual(t.firstPrompt, "new")
    }

    func planLine(_ t: String, _ input: String) -> String {
        #"{"type":"assistant","timestamp":"2026-01-01T\#(t)Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"x","name":"mcp__ccd_turn__update_plan","input":\#(input)}]}}"# + "\n"
    }

    func testPlanProgressAndReset() {
        append(line("user", "10:00:00.000", content: "\"go\""))
        append(planLine("10:00:01.000", #"{"items":[{"content":"a","status":"in_progress"},{"content":"b","status":"pending"},{"content":"c","status":"pending"}]}"#))
        append(planLine("10:00:30.000", #"{"advance":true}"#))
        append(planLine("10:00:40.000", #"{"done":[3]}"#))
        let t = TranscriptTail(path: path); t.advance()
        XCTAssertEqual(t.plan.map(\.status), ["completed", "in_progress", "completed"])
        append(line("user", "10:05:00.000", content: "\"next thing\""))
        t.advance()
        XCTAssertEqual(t.plan.count, 3)                 // unfinished plan carries over
        append(planLine("10:06:00.000", #"{"done":[2]}"#))
        append(line("user", "10:07:00.000", content: "\"another\""))
        t.advance()
        XCTAssertTrue(t.plan.isEmpty)                   // finished plan is cleared by the next prompt
    }

    func testRateCountsOnlyActiveTime() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var h: [(t: Date, done: Int, active: Bool)] = []
        // 20 min running at 1 item/min, then 60 min paused (no progress, not active), then 15 min running at 1 item/min.
        for m in 0...20 { h.append((t0.addingTimeInterval(Double(m) * 60), m, true)) }
        for m in 21...80 { h.append((t0.addingTimeInterval(Double(m) * 60), 20, false)) }
        for m in 81...95 { h.append((t0.addingTimeInterval(Double(m) * 60), 20 + (m - 80), true)) }
        let r = SessionStore.recentRate(h)!
        XCTAssertEqual(r, 1.0 / 60.0, accuracy: 0.002)            // 1 item/min; the pause is not counted
        XCTAssertNil(SessionStore.recentRate(Array(h.prefix(5))))  // under 10 min of active time: no estimate
        XCTAssertNil(SessionStore.recentRate(h.map { ($0.t, $0.done, false) }))  // never active: no estimate
    }

    func testLargeFileOnlyReadsRecentWindow() {
        for i in 0..<200 { append(line("user", "10:00:\(String(format: "%02d", i % 60)).000", content: "\"old prompt \(i)\"")) }
        append(line("assistant", "11:00:00.000", content: "", stop: "end_turn"))
        append(line("user", "11:30:00.000", content: "\"recent\""))
        let t = TranscriptTail(path: path, initialWindow: 400); t.advance()
        XCTAssertTrue(t.isBusy)                                   // state from the tail
        XCTAssertNotEqual(t.firstPrompt, "old prompt 0")          // early history was skipped
        append(line("assistant", "11:31:00.000", content: "", stop: "end_turn"))
        t.advance()
        XCTAssertFalse(t.isBusy)                                  // and it keeps tailing normally
    }

    func testReportedProgressParsing() {
        let text = "Batches 31-34 are all in. 1,292 of the 3,232 Zone 1 squares are reviewed (40%).\nThe pictures are being taken at about 3 a minute. About 1,930 squares are still to photograph, which is roughly 10½ hours, so about 5am tomorrow."
        let r = ReportedProgress.parse(text)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].done, 1292); XCTAssertEqual(r[0].total, 3232)
        XCTAssertEqual(r[0].label, "Zone 1 squares")
        XCTAssertTrue(ReportedProgress.sessionEstimate(text)!.contains("10½ hours"))
        XCTAssertTrue(ReportedProgress.sessionEstimate("- **ETA:** about 4½–5 hours for cab, so roughly 01:00–01:30 if nothing fails.")!.hasPrefix("ETA: about 4½–5 hours"))
        XCTAssertTrue(ReportedProgress.parse("saw 2 of 3 agents on 11/08").isEmpty)   // noise ignored
    }

    func testEstimateSeconds() {
        XCTAssertEqual(ReportedProgress.estimateSeconds("which is roughly 10½ hours, so about 5am"), 10.5 * 3600)
        XCTAssertEqual(ReportedProgress.estimateSeconds("ETA: about 4½–5 hours for cab"), 4.75 * 3600)
        XCTAssertEqual(ReportedProgress.estimateSeconds("about 45 minutes left"), 45 * 60)
        XCTAssertNil(ReportedProgress.estimateSeconds("finishing around 20:40"))
    }

    func testSessionWaitingOnAgentsCountsAsBackground() {
        let now = Date()
        func session(agentRunning: Bool) -> SessionInfo {
            let a = SubagentInfo(id: "a", description: "fix", agentType: "x", start: now.addingTimeInterval(-600),
                                 lastActivity: now.addingTimeInterval(agentRunning ? -60 : -7200), busy: true, workedClosed: 0)
            var s = SessionInfo(id: "s", pid: 0, cwd: "/x", branch: nil, title: "t", start: now.addingTimeInterval(-9000),
                                lastActivity: now.addingTimeInterval(-30), busySince: nil, stateSince: now.addingTimeInterval(-30),
                                workedClosed: 0, alive: true, subagents: [a])
            s.remote = true
            return s
        }
        XCTAssertEqual(session(agentRunning: true).state(at: now), .background)   // turn ended, agents still working
        XCTAssertNotEqual(session(agentRunning: false).state(at: now), .background)
    }

    func testBackgroundTaskLifecycleFromAttachments() {
        let launch = #"{"type":"assistant","timestamp":"2026-01-01T10:00:00.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"sleep 99","description":"Wait for portal","run_in_background":true}}]}}"# + "\n"
        let result = #"{"type":"user","timestamp":"2026-01-01T10:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"Command running in background with ID: bt1. Output is being written to: /tmp/x/bt1.output. You will be notified"}]}}"# + "\n"
        append(launch); append(result)
        // A command the harness moved to the background on its own (no run_in_background flag).
        append(#"{"type":"assistant","timestamp":"2026-01-01T10:00:05.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"until grep -q DONE x; do sleep 5; done","description":"Wait for portal check"}}]}}"# + "\n")
        append(#"{"type":"user","timestamp":"2026-01-01T10:02:05.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu2","content":"Command was moved to the background (ID: bt2). Output is being written to: /tmp/x/bt2.output. You will be notified when it completes."}]}}"# + "\n")
        // A command whose OUTPUT merely quotes the harness wording is not a background task.
        append(#"{"type":"assistant","timestamp":"2026-01-01T10:03:00.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"tu3","name":"Bash","input":{"command":"grep background transcript","description":"Search transcript"}}]}}"# + "\n")
        append(#"{"type":"user","timestamp":"2026-01-01T10:03:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu3","content":"found: Command running in background with ID: bt9. Output is being written to: /tmp/y/bt9.output"}]}}"# + "\n")
        let t = TranscriptTail(path: path); t.advance()
        XCTAssertEqual(t.backgroundTasks["bt1"]?.status, .running)
        XCTAssertEqual(t.backgroundTasks["bt2"]?.status, .running)
        XCTAssertNil(t.backgroundTasks["bt9"])
        XCTAssertEqual(t.backgroundTasks["bt2"]?.label, "Wait for portal check")
        XCTAssertEqual(t.backgroundTasks["bt2"]?.outputPath, "/tmp/x/bt2.output")
        append(#"{"type":"attachment","timestamp":"2026-01-01T10:30:00.000Z","attachment":{"type":"queued_command","prompt":"<task-notification>\n<task-id>bt1</task-id>\n<status>completed</status>\n</task-notification>"}}"# + "\n")
        // An agent paused for its own background work is not finished.
        append(#"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-01T10:31:00.000Z","content":"<task-notification><task-id>agentA</task-id><status>completed</status><summary>Agent x is waiting on its own background work</summary></task-notification>"}"# + "\n")
        append(#"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-01T10:32:00.000Z","content":"<task-notification><task-id>agentB</task-id><status>completed</status><summary>Agent y finished</summary></task-notification>"}"# + "\n")
        t.advance()
        XCTAssertEqual(t.backgroundTasks["bt1"]?.status, .completed)
        XCTAssertFalse(t.finishedIDs.contains("agentA"))
        XCTAssertTrue(t.finishedIDs.contains("agentB"))
    }

    func testFormat() {
        XCTAssertEqual(formatDuration(4320, compact: true), "1h12m")
        XCTAssertEqual(formatDuration(192), "3m12s")
    }
}
