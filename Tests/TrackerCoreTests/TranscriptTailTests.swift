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

    func testFormat() {
        XCTAssertEqual(formatDuration(4320, compact: true), "1h12")
        XCTAssertEqual(formatDuration(192), "3m12s")
    }
}
