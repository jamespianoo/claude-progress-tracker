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

    func testRecentRateIgnoresPausedTime() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // 600 items in the first 10 min, then paused for 50 min with no progress.
        var h: [(t: Date, done: Int)] = []
        for m in 0...60 { h.append((t0.addingTimeInterval(Double(m) * 60), min(m, 10) * 60)) }
        XCTAssertNil(SessionStore.recentRate(h))                     // stalled in the last 30 min: no ETA
        // Resumes at 6 items/min for 10 min: the since-start average would be ~0.16/s, the recent rate is ~0.03/s.
        for m in 61...70 { h.append((t0.addingTimeInterval(Double(m) * 60), 600 + (m - 60) * 6)) }
        let r = SessionStore.recentRate(h)!
        XCTAssertGreaterThan(r, 0.03)
        XCTAssertLessThan(r, 0.04)
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

    func testFormat() {
        XCTAssertEqual(formatDuration(4320, compact: true), "1h12m")
        XCTAssertEqual(formatDuration(192), "3m12s")
    }
}
