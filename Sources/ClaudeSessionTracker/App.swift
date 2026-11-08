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
                print("\(s.state(at: now).rawValue)\t\(s.title)\t\(s.project)\t\(s.remote ? "remote:" : "")\(s.progress(at: now).map { "[\(Int($0.fraction*100))% \($0.detail ?? "")] " } ?? "")\(s.branch ?? "-")\tstart \(s.start.formatted())\tinState \(formatDuration(s.timeInState(at: now)))\ttotal \(formatDuration(s.total(at: now)))\tworked \(formatDuration(s.worked(at: now)))")
                for t in s.runningTasks { print("   task\t\(t.label)\t\(formatDuration(t.elapsed(at: now)))\t\(t.progressText ?? "-")\toutput \(t.outputPath)") }
                for sp in s.procs { print("   proc\t\(sp.label)\t\(formatDuration(sp.elapsed))\t\(sp.progressText ?? "-")") }
                for a in s.subagents.prefix(5) {
                    print("   sub\t\(a.description)\t\(a.statusLabel(at: now))\t\(formatDuration(a.duration(at: now)))")
                }
            }
            print(String(format: "scan %.2fs", Date().timeIntervalSince(t0)))
            exit(0)
        }
        // `--snapshot out.png` renders the popover once the first scan has landed (for verification).
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            Task { @MainActor in
                let m = TrackerModel()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                let host = NSHostingView(rootView: ContentView(model: m).background(Color(white: 0.16)).environment(\.colorScheme, .dark))
                let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
                win.contentView = host
                win.appearance = NSAppearance(named: .darkAqua)
                win.orderFrontRegardless()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                for _ in 0..<3 {
                    host.frame.size = NSSize(width: 380, height: max(host.fittingSize.height, 100))
                    host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: out)) }
                }
                exit(0)
            }
        }
        _model = StateObject(wrappedValue: TrackerModel())
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            HStack(spacing: 4) { Image(nsImage: Logo.menuBar); Text(model.title).monospacedDigit() }
        }
        .menuBarExtraStyle(.window)
    }
}
