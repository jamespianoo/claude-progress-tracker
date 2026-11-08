import SwiftUI
import TrackerCore

struct ContentView: View {
    @ObservedObject var model: TrackerModel
    @AppStorage("notifyOnWaiting") private var notifyOnWaiting = true
    @AppStorage("longRunMinutes") private var longRunMinutes = 0
    @State private var showPrefs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.sessions.isEmpty {
                Text("No running Claude Code sessions")
                    .foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.sessions) { SessionRow(session: $0, now: model.now) }
                    }.padding(12)
                }.frame(maxHeight: 520)
            }
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
        .frame(width: 400)
        .onAppear { model.popoverVisible = true; model.requestNotificationAuth() }
        .onDisappear { model.popoverVisible = false }
    }
}

struct SessionRow: View {
    let session: SessionInfo
    let now: Date

    var body: some View {
        let state = session.state(at: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color(state)).frame(width: 9, height: 9)
                Text(session.title).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(label(state)) \(formatDuration(session.timeInState(at: now)))")
                    .font(.callout.monospacedDigit()).foregroundStyle(color(state))
            }
            HStack {
                Text([session.project, session.branch].compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text("total \(formatDuration(session.total(at: now))) · worked \(formatDuration(session.worked(at: now)))")
                    .monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            if !session.subagents.isEmpty { subagents }
        }
        .opacity(state == .finished ? 0.55 : 1)
    }

    private var subagents: some View {
        let shown = session.subagents.filter { $0.isRunning(at: now) } +
            session.subagents.filter { !$0.isRunning(at: now) }.prefix(4)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(shown) { a in
                let running = a.isRunning(at: now)
                HStack(spacing: 6) {
                    Image(systemName: running ? "play.circle.fill" : (a.busy ? "exclamationmark.circle" : "checkmark.circle"))
                        .foregroundStyle(running ? Color.green : .secondary)
                    Text(a.description).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(a.start.formatted(date: .omitted, time: .shortened)) · \(formatDuration(a.duration(at: now))) · \(a.statusLabel(at: now))")
                        .monospacedDigit().foregroundStyle(.secondary)
                }.font(.caption)
            }
        }.padding(.leading, 15).padding(.top, 2)
    }

    private func color(_ s: RunState) -> Color {
        switch s { case .working: .green; case .waiting: .orange; case .idle: .gray; case .finished: .secondary }
    }
    private func label(_ s: RunState) -> String {
        switch s { case .working: "working"; case .waiting: "waiting"; case .idle: "idle"; case .finished: "finished" }
    }
}
