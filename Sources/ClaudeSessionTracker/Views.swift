import SwiftUI
import TrackerCore

// MARK: layout grid
// Everything below a session title shares one indent and one right-hand value column, so bars and numbers line up.
private enum Grid {
    static let width: CGFloat = 380
    static let indent: CGFloat = 22        // aligns with the title text
    static let label: CGFloat = 120        // label column for sub-bars
    static let value: CGFloat = 124        // right-hand value column
    static let gap: CGFloat = 8
}

private func n(_ v: Int) -> String { v.formatted(.number.grouping(.automatic)) }
private let clockFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
private let dayClockFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f }()
/// Finish time as "22:15", or "Mon 06:14" when it falls on another day.
private func clock(_ eta: TimeInterval, from now: Date) -> String {
    let d = now.addingTimeInterval(eta)
    return (Calendar.current.isDate(d, inSameDayAs: now) ? clockFormatter : dayClockFormatter).string(from: d)
}

struct ContentView: View {
    @ObservedObject var model: TrackerModel
    @AppStorage("notifyOnWaiting") private var notifyOnWaiting = true
    @AppStorage("longRunMinutes") private var longRunMinutes = 0
    @AppStorage("showIdle") private var showIdle = false
    @State private var showPrefs = false

    private var active: [SessionInfo] {
        model.sessions.filter {
            let st = $0.state(at: model.now)
            return [.working, .background, .paused].contains(st) || (st == .waiting && $0.needsInput(at: model.now))
        }
    }
    private var idle: [SessionInfo] {
        let ids = Set(active.map(\.id))
        return model.sessions.filter { !ids.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if active.isEmpty {
                    Text("Nothing running").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                ForEach(active) { ActiveRow(session: $0, now: model.now) }
                if !idle.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Button { showIdle.toggle() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showIdle ? "chevron.down" : "chevron.right").font(.caption2.weight(.bold)).frame(width: 14)
                                Text("Idle (\(idle.count))").font(.callout)
                                Spacer()
                            }.foregroundStyle(.secondary).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if showIdle { ForEach(idle) { IdleRow(session: $0, now: model.now) } }
                    }
                }
            }.padding(12)
            Divider()
            if showPrefs {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Notify when a session starts waiting for me", isOn: $notifyOnWaiting)
                    Stepper(value: $longRunMinutes, in: 0...600, step: 5) {
                        Text(longRunMinutes == 0 ? "Long-run alert: off" : "Alert when a run exceeds \(longRunMinutes) min")
                    }
                }.padding(12).font(.callout)
                Divider()
            }
            HStack {
                Button { showPrefs.toggle() } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless)
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: Grid.width)
        .background(WindowTopAnchor())
        .onAppear { model.popoverVisible = true; model.requestNotificationAuth() }
        .onDisappear { model.popoverVisible = false }
    }
}

// MARK: reusable rows

/// `[label] [bar] [value]`; with no label the bar starts at the indent. Value column is right-aligned and fixed-width.
private struct BarRow: View {
    var label: String?
    let fraction: Double
    let value: String
    var valueColor: Color = .primary
    var body: some View {
        HStack(spacing: Grid.gap) {
            if let label { Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(width: Grid.label, alignment: .leading) }
            ProgressView(value: fraction).progressViewStyle(.linear)
            Text(value).font(.caption).monospacedDigit().foregroundStyle(valueColor).lineLimit(1).frame(width: Grid.value, alignment: .trailing)
        }
    }
}

/// `left ............ right`, right in the shared value column.
private struct ListRow: View {
    var icon: String?
    var iconColor: Color = .secondary
    let left: String
    var leftColor: Color = .secondary
    var right: String?
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 9)).foregroundStyle(iconColor).frame(width: 10) }
            Text(left).lineLimit(1).truncationMode(.middle).foregroundStyle(leftColor)
            Spacer(minLength: Grid.gap)
            if let right { Text(right).monospacedDigit().frame(width: Grid.value, alignment: .trailing) }
        }
    }
}

private struct Header: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.6)
            .foregroundStyle(.tertiary).padding(.top, 5)
    }
}

// MARK: session rows

struct ActiveRow: View {
    let session: SessionInfo
    let now: Date

    var body: some View {
        let state = session.state(at: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                marker(state).frame(width: 14)
                Text(session.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if session.remote { Image(systemName: "server.rack").font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                Text(state == .waiting ? "needs you" : topRight(state))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(state == .waiting ? Color.orange : (state == .paused ? Color.yellow : Color.primary))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.project).font(.caption).foregroundStyle(.secondary)
                if state != .waiting { body(state) }
            }.padding(.leading, Grid.indent)
        }
    }

    @ViewBuilder private func marker(_ state: RunState) -> some View {
        switch state {
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(Color.yellow).font(.system(size: 12))
        case .waiting: Circle().fill(Color.orange).frame(width: 8, height: 8)
        default: Circle().fill(Color.green).frame(width: 8, height: 8)
        }
    }

    /// Time left with the clock time it finishes, e.g. "45m (22:00)"; paused time, or elapsed when there is no estimate.
    private func topRight(_ state: RunState) -> String {
        if state == .paused { return "paused \(formatDuration(session.timeInState(at: now), compact: true))" }
        if let eta = session.progress(at: now)?.eta { return "\(formatDuration(eta, compact: true)) (\(clock(eta, from: now)))" }
        return formatDuration(session.timeInState(at: now), compact: true)
    }

    @ViewBuilder private func body(_ state: RunState) -> some View {
        let prog = session.progress(at: now)
        let reported = Array(session.reported(at: now))
        let feed = session.feeds.first { $0.isFresh(at: now) }
        let running = session.runningTasks
        let agents = session.subagents.filter { $0.isRunning(at: now) }
        let workers = Array(session.procs.prefix(6))

        // Main bar
        if let p = prog {
            BarRow(fraction: p.fraction, value: [p.detail ?? "", "\(Int(p.fraction * 100))%"].filter { !$0.isEmpty }.joined(separator: " · "))
        }

        VStack(alignment: .leading, spacing: 2) {
            if state == .working, let act = session.activity {
                ListRow(left: "Now · \(act)", leftColor: Color.primary.opacity(0.85),
                        right: session.activityAt.map { formatDuration(now.timeIntervalSince($0), compact: true) })
            }
            // Split jobs (feed stages)
            if let f = feed, f.stages.count > 1 {
                Header(text: "Stages")
                ForEach(f.stages) { st in
                    BarRow(label: st.name, fraction: st.fraction, value: stageValue(st, f, state))
                }
            }
            // Further counts the session reported (the first one is the main bar)
            if reported.count > 1 {
                Header(text: "Progress")
                ForEach(Array(reported.dropFirst().prefix(3))) { r in
                    BarRow(label: r.label, fraction: r.fraction, value: "\(n(r.done))/\(n(r.total)) · \(Int(r.fraction * 100))%")
                }
            }
            // Steps
            if session.plan.count >= 2 {
                let pending = session.plan.filter { !$0.isDone }
                Header(text: "Steps · \(session.plan.count - pending.count) of \(session.plan.count) done")
                ForEach(Array(pending.prefix(6).enumerated()), id: \.offset) { _, step in
                    let current = step.status == "in_progress"
                    ListRow(icon: current ? "play.circle.fill" : "circle", iconColor: current ? .green : .secondary,
                            left: step.content, leftColor: current ? .primary : .secondary)
                }
                if pending.count > 6 { ListRow(left: "+\(pending.count - 6) more steps") }
            }
            // Workers
            if !workers.isEmpty {
                let script = workers.first.flatMap { $0.label.split(separator: " ").first.map(String.init) } ?? ""
                let shared = workers.count > 1 && workers.allSatisfy { $0.label.hasPrefix(script) }
                Header(text: shared ? "Workers · \(script)" : "Workers")
                ForEach(workers) { sp in
                    let name = shared ? shortWorker(sp.label, script) : sp.label
                    if let f = sp.progress {
                        BarRow(label: name, fraction: f, value: "\(Int(f * 100))% · \(formatDuration(sp.elapsed, compact: true))")
                    } else {
                        ListRow(left: name, right: formatDuration(sp.elapsed, compact: true))
                    }
                }
                if session.procs.count > workers.count { ListRow(left: "+\(session.procs.count - workers.count) more") }
            }
            if !running.isEmpty {
                Header(text: "Background tasks")
                ForEach(running.prefix(4)) { t in
                    ListRow(left: t.label, right: formatDuration(t.elapsed(at: now), compact: true))
                }
            }
            if !agents.isEmpty {
                Header(text: "Agents · \(agents.count) running")
                let groups = Dictionary(grouping: agents, by: { $0.description })
                    .sorted { ($0.value.map { $0.duration(at: now) }.max() ?? 0) > ($1.value.map { $0.duration(at: now) }.max() ?? 0) }
                ForEach(Array(groups.prefix(4)), id: \.key) { g in
                    ListRow(left: g.value.count > 1 ? "\(g.value.count)× \(g.key)" : g.key,
                            right: formatDuration(g.value.map { $0.duration(at: now) }.max() ?? 0, compact: true))
                }
            }
        }.font(.caption).foregroundStyle(.secondary)
    }

    /// "record-arrival.js --station Oxford Circus" -> "Oxford Circus" once the script is shown in the header.
    private func shortWorker(_ label: String, _ script: String) -> String {
        var rest = String(label.dropFirst(script.count)).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("--"), let sp = rest.firstIndex(of: " ") { rest = String(rest[rest.index(after: sp)...]) }
        return rest.isEmpty ? label : rest
    }

    private func stageValue(_ st: ProgressFeed.Stage, _ f: ProgressFeed, _ state: RunState) -> String {
        let base = "\(st.done)/\(st.total) · \(Int(st.fraction * 100))%"
        if st.done >= st.total { return base }
        if st.id == f.currentStage?.id {
            if state == .paused { return base }
            if let e = f.stageETA(st) { return "\(base) · \(clock(e, from: now))" }
        }
        return base
    }
}

struct IdleRow: View {
    let session: SessionInfo
    let now: Date
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if session.remote { Image(systemName: "server.rack").font(.caption2) } else { Color.clear }
            }.frame(width: 14)
            Text(session.title).lineLimit(1)
            Spacer(minLength: 8)
            Text(formatDuration(session.timeInState(at: now), compact: true)).monospacedDigit()
        }.font(.caption).foregroundStyle(.secondary)
    }
}

/// Keeps the menu-bar popover pinned just under the menu bar. AppKit resizes a window from its bottom-left corner, so
/// when the content shrinks while the popover is open (a job finishes) the top edge would otherwise drop and the
/// popover "hangs" below the bar. Re-pinned on every SwiftUI refresh (each second while open), on resize/show, and
/// shortly after appearing, because relying on resize notifications alone proved unreliable.
struct WindowTopAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { AnchorView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in AnchorView.pin(view?.window) }
    }

    final class AnchorView: NSView {
        private var observers: [NSObjectProtocol] = []
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            guard let w = window else { return }
            let nc = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification,
                         NSWindow.didUpdateNotification] {
                observers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak w] _ in Self.pin(w) })
            }
            for delay in [0.0, 0.05, 0.3] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak w] in Self.pin(w) }
            }
        }

        /// Top edge goes 2 pt under the menu bar (visibleFrame ends at the bottom of the menu bar / notch area).
        static func pin(_ w: NSWindow?) {
            guard let w, w.isVisible, let screen = w.screen ?? NSScreen.main else { return }
            let top = screen.visibleFrame.maxY - 2
            if abs(w.frame.maxY - top) > 0.5 { w.setFrameTopLeftPoint(NSPoint(x: w.frame.minX, y: top)) }
        }
    }
}
