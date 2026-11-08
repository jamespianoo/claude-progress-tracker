import SwiftUI
import TrackerCore

struct ContentView: View {
    @ObservedObject var model: TrackerModel
    @AppStorage("notifyOnWaiting") private var notifyOnWaiting = true
    @AppStorage("longRunMinutes") private var longRunMinutes = 0
    @State private var showPrefs = false
    @AppStorage("showIdle") private var showIdle = false

    private var active: [SessionInfo] {
        model.sessions.filter { [.working, .background, .paused, .waiting].contains($0.state(at: model.now)) && ($0.state(at: model.now) != .waiting || $0.needsInput(at: model.now)) }
    }
    private var idle: [SessionInfo] {
        let ids = Set(active.map(\.id))
        return model.sessions.filter { !ids.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if active.isEmpty {
                    Text("Nothing running").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                ForEach(active) { ActiveRow(session: $0, now: model.now) }
                if !idle.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Button { showIdle.toggle() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showIdle ? "chevron.down" : "chevron.right").font(.caption2.weight(.bold))
                                Text("Idle (\(idle.count))").font(.callout)
                                Spacer()
                            }.foregroundStyle(.secondary).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if showIdle {
                            ForEach(idle) { IdleRow(session: $0, now: model.now) }
                        }
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
        .frame(width: 380)
        .onAppear { model.popoverVisible = true; model.requestNotificationAuth() }
        .onDisappear { model.popoverVisible = false }
    }
}

/// One active session: name + repo, elapsed, a percentage bar with ETA, then the details (current step, workers, agents).
struct ActiveRow: View {
    let session: SessionInfo
    let now: Date

    var body: some View {
        let state = session.state(at: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if state == .paused { Image(systemName: "pause.circle.fill").foregroundStyle(Color.yellow).font(.system(size: 10)) }
                else { Circle().fill(state == .waiting ? Color.orange : Color.green).frame(width: 8, height: 8) }
                if session.remote { Image(systemName: "server.rack").font(.caption).foregroundStyle(.secondary) }
                Text(session.title).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 8)
                Text(state == .waiting ? "needs you" : topRight(state))
                    .font(.callout.monospacedDigit()).foregroundStyle(state == .waiting ? Color.orange : (state == .paused ? Color.yellow : Color.primary))
            }
            Text(session.project).font(.caption).foregroundStyle(.secondary).padding(.leading, 14)
            if state != .waiting {
                if let p = session.progress(at: now) {
                    HStack(spacing: 8) {
                        ProgressView(value: p.fraction).progressViewStyle(.linear)
                        Text([p.detail, "\(Int(p.fraction * 100))%"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption.monospacedDigit()).foregroundStyle(Color.primary).fixedSize()
                    }.padding(.leading, 14)
                }
                if let f = session.feeds.first(where: { $0.isFresh(at: now) }), f.stages.count > 1 {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(f.stages) { st in
                            HStack(spacing: 8) {
                                Text(st.name).frame(width: 64, alignment: .leading)
                                ProgressView(value: st.fraction).progressViewStyle(.linear)
                                Text([ "\(st.done)/\(st.total)", "\(Int(st.fraction * 100))%",
                                       (state == .paused ? nil : f.stageETA(st)).map { "ETA \(now.addingTimeInterval($0).formatted(date: .omitted, time: .shortened))" } ?? (st.done >= st.total ? "done" : nil)]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .monospacedDigit().foregroundStyle(Color.primary).fixedSize()
                            }
                        }
                    }.font(.caption).padding(.leading, 14)
                }
                details
            }
        }
    }

    /// Time left with the clock time it finishes, e.g. "45m (22:00)"; elapsed time when there is no estimate.
    private func topRight(_ state: RunState) -> String {
        if state == .paused { return "paused \(formatDuration(session.timeInState(at: now), compact: true))" }
        if let eta = session.progress(at: now)?.eta {
            return "\(formatDuration(eta, compact: true)) (\(now.addingTimeInterval(eta).formatted(date: .omitted, time: .shortened)))"
        }
        return formatDuration(session.timeInState(at: now), compact: true)
    }

    private func header(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary).padding(.top, 2)
    }

    /// Detailed sub-sections: now, steps, workers, tasks, agents. Only sections with content are shown.
    @ViewBuilder private var details: some View {
        let running = session.runningTasks
        let agents = session.subagents.filter { $0.isRunning(at: now) }
        let workers = Array(session.procs.prefix(6))
        VStack(alignment: .leading, spacing: 2) {
            if session.state(at: now) == .working, let act = session.activity {
                HStack {
                    Text("Now · \(act)").lineLimit(1).truncationMode(.tail).foregroundStyle(Color.primary.opacity(0.85))
                    Spacer(minLength: 4)
                    if let at = session.activityAt { Text(formatDuration(now.timeIntervalSince(at), compact: true)).monospacedDigit() }
                }
            }
            if session.plan.count >= 2 {
                let done = session.plan.filter(\.isDone).count
                header("Steps · \(done) of \(session.plan.count) done")
                let pending = session.plan.filter { !$0.isDone }
                ForEach(Array(pending.prefix(6).enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 5) {
                        Image(systemName: step.status == "in_progress" ? "play.circle.fill" : "circle").font(.system(size: 9))
                            .foregroundStyle(step.status == "in_progress" ? Color.green : Color.secondary)
                        Text(step.content).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(step.status == "in_progress" ? Color.primary : Color.secondary)
                    }
                }
                if pending.count > 6 { Text("+\(pending.count - 6) more steps") }
            } else if let step = session.currentStep {
                Text("▸ \(step)").lineLimit(1)
            }
            if !workers.isEmpty {
                header("Workers")
                ForEach(workers) { sp in
                    HStack(spacing: 8) {
                        Text(sp.label).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        Spacer(minLength: 4)
                        if let f = sp.progress {
                            ProgressView(value: f).progressViewStyle(.linear).frame(width: 48)
                            Text("\(Int(f * 100))%").monospacedDigit().frame(width: 36, alignment: .trailing)
                        }
                        Text(formatDuration(sp.elapsed, compact: true)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                if session.procs.count > workers.count { Text("+\(session.procs.count - workers.count) more") }
            }
            if !running.isEmpty {
                header("Background tasks")
                ForEach(running.prefix(4)) { t in
                    HStack {
                        Text(t.label).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if let p = t.progressText { Text(p).monospacedDigit() }
                        Text(formatDuration(t.elapsed(at: now), compact: true)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
            }
            if !agents.isEmpty {
                header("Agents")
                ForEach(agents.prefix(5)) { a in
                    HStack {
                        Text(a.description).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(formatDuration(a.duration(at: now), compact: true)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }.font(.caption).foregroundStyle(.secondary).padding(.leading, 14)
    }
}

struct IdleRow: View {
    let session: SessionInfo
    let now: Date
    var body: some View {
        HStack {
            if session.remote { Image(systemName: "server.rack") }
            Text(session.title).lineLimit(1)
            Spacer(minLength: 8)
            Text(formatDuration(session.timeInState(at: now), compact: true)).monospacedDigit()
        }.font(.caption).foregroundStyle(.secondary)
    }
}

