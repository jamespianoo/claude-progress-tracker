import Foundation
import SwiftUI
import UserNotifications
@preconcurrency import TrackerCore

@MainActor
final class TrackerModel: ObservableObject {
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var now = Date()
    @Published private(set) var title = "Claude"
    var popoverVisible = false { didSet { if popoverVisible { now = Date() }; updateTimer() } }

    private let store = SessionStore()
    private let queue = DispatchQueue(label: "tracker.store", qos: .utility)
    private var watcher: FSWatcher?
    private var tickTimer: Timer?
    private var slowTimer: Timer?
    private var refreshPending = false
    private var refreshing = false
    private var lastStates: [String: RunState] = [:]
    private var longRunNotified: Set<String> = []

    init() {
        UserDefaults.standard.register(defaults: ["notifyOnWaiting": true, "longRunMinutes": 0])
        let home = NSHomeDirectory() + "/.claude"
        let feedDir = NSHomeDirectory() + "/.claude-progress"
        try? FileManager.default.createDirectory(atPath: feedDir, withIntermediateDirectories: true)
        watcher = FSWatcher(paths: [home + "/projects", home + "/sessions", feedDir]) { [weak self] in
            Task { @MainActor in self?.requestRefresh() }
        }
        // Liveness (process exit) produces no file event, so poll cheaply.
        slowTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestRefresh() }
        }
        requestRefresh()
    }

    func requestNotificationAuth() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func requestRefresh() {
        if refreshing { refreshPending = true; return }
        refreshing = true
        queue.async { [store] in
            let result = store.refresh()
            Task { @MainActor in
                self.apply(result)
                self.refreshing = false
                if self.refreshPending { self.refreshPending = false; self.requestRefresh() }
            }
        }
    }

    private func apply(_ result: [SessionInfo]) {
        now = Date()
        sessions = result
        evaluateNotifications()
        updateTitle()
        updateTimer()
    }

    var runningCount: Int { sessions.filter { [.working, .background].contains($0.state(at: now)) }.count }

    private func updateTitle() {
        let working = sessions.filter { [.working, .background].contains($0.state(at: now)) }
        let new = "\(working.count)"
        if new != title { title = new }
    }

    /// 1 s tick only while something is running or the popover is open; otherwise no timer at all.
    private func updateTimer() {
        let needed = popoverVisible || runningCount > 0
        if needed, tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } else if !needed, let t = tickTimer {
            t.invalidate(); tickTimer = nil
        }
    }

    private func tick() {
        let d = Date()
        if popoverVisible { now = d } else { now = d }
        updateTitle()
        evaluateNotifications()
        if !popoverVisible && runningCount == 0 { updateTimer() }
    }

    // MARK: notifications
    private func evaluateNotifications() {
        let defaults = UserDefaults.standard
        let notifyWaiting = defaults.bool(forKey: "notifyOnWaiting")
        let threshold = defaults.integer(forKey: "longRunMinutes")
        var states: [String: RunState] = [:]
        for s in sessions {
            let st = s.state(at: now)
            states[s.id] = st
            if notifyWaiting, lastStates[s.id] == .working, st == .waiting {
                post("Claude is waiting", "\(s.title) · \(s.project) finished after \(formatDuration(now.timeIntervalSince(s.stateSince), compact: true))", id: "wait-\(s.id)-\(Int(now.timeIntervalSince1970))")
            }
            let key = "\(s.id)-\(Int(s.stateSince.timeIntervalSince1970))"
            if threshold > 0, st == .working, s.timeInState(at: now) >= Double(threshold * 60), !longRunNotified.contains(key) {
                longRunNotified.insert(key)
                post("Long run", "\(s.title) has been working for \(formatDuration(s.timeInState(at: now), compact: true))", id: "long-\(key)")
            }
        }
        lastStates = states
    }

    private func post(_ title: String, _ body: String, id: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}
