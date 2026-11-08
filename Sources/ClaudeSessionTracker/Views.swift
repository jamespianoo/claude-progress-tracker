import SwiftUI
import TrackerCore

struct ContentView: View {
    @ObservedObject var model: TrackerModel
    @AppStorage("notifyOnWaiting") private var notifyOnWaiting = true
    @AppStorage("longRunMinutes") private var longRunMinutes = 0
    @State private var showPrefs = false
    @State private var showIdle = false

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
                    DisclosureGroup(isExpanded: $showIdle) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(idle) { IdleRow(session: $0, now: model.now) }
                        }.padding(.top, 4)
                    } label: {
                        Text("Idle (\(idle.count))").font(.callout).foregroundStyle(.secondary)
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

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let step = session.currentStep {
                Text("▸ \(step)").lineLimit(1).truncationMode(.tail)
            }
            let shown = Array(session.procs.prefix(5))
            ForEach(shown) { sp in
                HStack(spacing: 8) {
                    Text(sp.label).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    Spacer(minLength: 4)
                    if let f = sp.progress {
                        ProgressView(value: f).progressViewStyle(.linear).frame(width: 48)
                        Text("\(Int(f * 100))%").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                    Text(formatDuration(sp.elapsed, compact: true)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            if session.procs.count > shown.count { Text("+\(session.procs.count - shown.count) more") }
            ForEach(session.subagents.filter { $0.isRunning(at: now) }.prefix(4)) { a in
                HStack {
                    Text("agent · \(a.description)").lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(formatDuration(a.duration(at: now), compact: true)).monospacedDigit()
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

