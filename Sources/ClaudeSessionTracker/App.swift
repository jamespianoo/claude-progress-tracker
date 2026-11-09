import SwiftUI
import Combine
import TrackerCore

@main
struct ClaudeSessionTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // `ClaudeSessionTracker --dump` prints the current picture and exits (for verification).
        // `--probe file.jsonl` prints how one transcript is parsed (debugging).
        if let i = CommandLine.arguments.firstIndex(of: "--probe"), i + 1 < CommandLine.arguments.count {
            let t = TranscriptTail(path: CommandLine.arguments[i + 1]); t.advance()
            print("first \(String(describing: t.firstTimestamp))\nlast \(String(describing: t.lastTimestamp))\nbusySince \(String(describing: t.busySince))\nstateSince \(String(describing: t.stateSince))\nactivity \(t.activity ?? "-")\nplan \(t.plan.count)\nhistory \(t.reportedHistory.map { "\($0.key): \($0.value.map { "\($0.done)/\($0.total)@\($0.t.formatted(date: .omitted, time: .shortened))" })" })\nstatusAt \(String(describing: t.statusAt))\nSTATUS: \(t.statusText ?? "-")\nreported \(ReportedProgress.parse(t.statusText ?? "").map { "\($0.label) \($0.done)/\($0.total)" })\nestimate \(ReportedProgress.sessionEstimate(t.statusText ?? "") ?? "nil")\nseconds \(String(describing: ReportedProgress.estimateSeconds(ReportedProgress.sessionEstimate(t.statusText ?? "") ?? "")))")
            exit(0)
        }
        if CommandLine.arguments.contains("--dump") {
            let t0 = Date()
            let rows = SessionStore().refresh()
            let now = Date()
            for s in rows {
                print("\(s.state(at: now).rawValue)\t\(s.title)\t[ETA \(s.eta(at: now).map { ($0.approximate ? "~" : "") + formatDuration($0.seconds, compact: true) } ?? "none")]\t\(s.project)\t\(s.remote ? "remote:" : "")\(s.progress(at: now).map { "[\(Int($0.fraction*100))% \($0.detail ?? "")] " } ?? "")\(s.branch ?? "-")\tstart \(s.start.formatted())\tinState \(formatDuration(s.timeInState(at: now)))\ttotal \(formatDuration(s.total(at: now)))\tworked \(formatDuration(s.worked(at: now)))")
                for t in s.runningTasks { print("   task\t\(t.label)\t\(formatDuration(t.elapsed(at: now)))\t\(t.progressText ?? "-")\toutput \(t.outputPath)") }
                if !s.plan.isEmpty { print("   plan\t\(s.plan.filter(\.isDone).count)/\(s.plan.count) marks \(s.planMarks.count) start \(s.planStart.map { $0.formatted() } ?? "-")") }
                for sp in s.procs { print("   proc\t\(sp.label)\t\(formatDuration(sp.elapsed))\t\(sp.progressText ?? "-")") }
                for a in s.subagents.filter({ $0.isRunning(at: now) || !$0.runningTasks.isEmpty }).prefix(12) {
                    print("   sub\t\(a.description)\t\(a.statusLabel(at: now))\t\(formatDuration(a.duration(at: now)))\ttasks \(a.runningTasks.count)/\(a.tasks.count)\tfinished \(a.finished)")
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
    }

    // The UI is a native NSStatusItem + NSPopover (see AppDelegate): AppKit keeps a popover anchored under the
    // menu bar when its content changes size, which SwiftUI's MenuBarExtra window does not.
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var model: TrackerModel!
    private var titleSink: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = TrackerModel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = Logo.menuBar
            b.imagePosition = .imageLeft
            b.target = self
            b.action = #selector(toggle)
        }
        setTitle(model.title)
        titleSink = model.$title.sink { [weak self] in self?.setTitle($0) }

        let host = NSHostingController(rootView: ContentView(model: model))
        host.sizingOptions = [.preferredContentSize]      // popover follows the content's size
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
    }

    private func setTitle(_ t: String) {
        statusItem.button?.attributedTitle = NSAttributedString(
            string: " " + t, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)])
    }

    @objc private func toggle() {
        guard let b = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        model.popoverVisible = true
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) { model.popoverVisible = false }
}
