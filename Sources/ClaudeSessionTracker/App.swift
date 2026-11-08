import SwiftUI
import TrackerCore

@main
struct ClaudeSessionTrackerApp: App {
    @StateObject private var model: TrackerModel

    init() {
        // `ClaudeSessionTracker --dump` prints the current picture and exits (for verification).
        if CommandLine.arguments.contains("--dump") {
            let t0 = Date()
            let rows = SessionStore().refresh()
            let now = Date()
            for s in rows {
                print("\(s.state(at: now).rawValue)\t\(s.title)\t\(s.project)\t\(s.branch ?? "-")\tstart \(s.start.formatted())\tinState \(formatDuration(s.timeInState(at: now)))\ttotal \(formatDuration(s.total(at: now)))\tworked \(formatDuration(s.worked(at: now)))")
                for a in s.subagents.prefix(5) {
                    print("   sub\t\(a.description)\t\(a.statusLabel(at: now))\t\(formatDuration(a.duration(at: now)))")
                }
            }
            print(String(format: "scan %.2fs", Date().timeIntervalSince(t0)))
            exit(0)
        }
        _model = StateObject(wrappedValue: TrackerModel())
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            Text(model.title).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
