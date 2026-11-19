import AppKit
import SwiftUI

struct Snapshot {
    var gateway = GatewayStatus()
    var activity = ActivityStatus()
    var model = ModelStatus()
    var offload = OffloadState()
    var updatedAt = Date.distantPast
}

/// What the assistant is doing, as one word, with a colour and symbols.
enum Kind: Equatable {
    case checking, offline, offloaded, working, idle, resting

    var title: String {
        switch self {
        case .checking: return "Checking"
        case .offline: return "Offline"
        case .offloaded: return "Offloaded"
        case .working: return "Working"
        case .idle: return "Idle"
        case .resting: return "Resting"
        }
    }

    var color: Color {
        switch self {
        case .checking: return .gray
        case .offline: return .red
        case .offloaded: return .indigo
        case .working: return .blue
        case .idle: return .green
        case .resting: return .teal
        }
    }

    /// White glyph on the coloured tile in the panel header.
    var glyph: String {
        switch self {
        case .checking: return "brain.head.profile"
        case .offline: return "bolt.horizontal.circle"
        case .offloaded: return "moon.zzz.fill"
        case .working: return symbol("brain.head.profile.fill", or: "brain.head.profile")
        case .idle: return "brain.head.profile"
        case .resting: return "moon.fill"
        }
    }

    /// Template symbol in the menu bar.
    var menuSymbol: String {
        switch self {
        case .checking, .idle: return "brain.head.profile"
        case .offline: return "exclamationmark.triangle"
        case .offloaded: return "moon.zzz"
        case .working: return symbol("brain.head.profile.fill", or: "brain.head.profile")
        case .resting: return "moon"
        }
    }
}

func symbol(_ name: String, or fallback: String) -> String {
    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
}

final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var config: AppConfig
    @Published private(set) var resolved: Resolved
    @Published private(set) var snap = Snapshot()
    @Published private(set) var offloadBusy: String?
    @Published private(set) var result: (text: String, at: Date)?
    @Published private(set) var latestVersion: String?
    @Published private(set) var updateMessage: String?

    /// Set by the app delegate: closes the panel and opens the Settings window.
    var openSettings: () -> Void = {}

    private var timer: Timer?
    private var probing = false
    private var lastJobs = Date.distantPast
    private var lastReadiness = Date.distantPast
    private var lastUpdateCheck = Date.distantPast
    private var pendingRefresh: DispatchWorkItem?
    private let queue = DispatchQueue(label: "jarvis-switch.probe", qos: .utility)

    init() {
        let c = AppConfig.load()
        config = c
        resolved = Resolved.resolve(c)
    }

    /// Command-line modes probe synchronously and hand the result over.
    func setSnapshotForCLI(_ s: Snapshot) { snap = s }

    // MARK: derived state

    var kind: Kind {
        let s = snap
        if offloadBusy != nil { return .working }
        if s.updatedAt == .distantPast { return .checking }
        if s.offload.active { return .offloaded }
        if !s.gateway.live { return .offline }
        if !s.activity.running.isEmpty || s.model.activeRequests > 0 { return .working }
        if s.model.weightsReleased { return .resting }
        return .idle
    }

    var updateAvailable: String? {
        guard let l = latestVersion, isNewer(l, than: appVersion) else { return nil }
        return l
    }

    // MARK: settings

    func update(_ change: (inout AppConfig) -> Void) {
        var c = config
        change(&c)
        if c.offload?.isEmpty == true { c.offload = nil }
        guard c != config else { return }
        let intervalChanged = c.refreshSeconds != config.refreshSeconds
        config = c
        c.save()
        resolved = Resolved.resolve(c)
        if intervalChanged { scheduleTimer() }
        // Typing in a text field changes settings on every keystroke: probe once the user pauses.
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(full: true) }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: polling

    func start() {
        scheduleTimer()
        refresh(full: true)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = resolved.refreshSeconds
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh(full: false) }
        t.tolerance = interval * 0.15
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// full: also re-read scheduled jobs and readiness now (used when the panel opens).
    func refresh(full: Bool) {
        guard !probing else { return }
        probing = true
        let cfg = resolved
        let now = Date()
        let slowEvery = max(15, cfg.refreshSeconds)
        let wantReady = full || now.timeIntervalSince(lastReadiness) >= slowEvery
        let wantJobs = full || now.timeIntervalSince(lastJobs) >= slowEvery
        let wantUpdate = cfg.checkForUpdates && now.timeIntervalSince(lastUpdateCheck) > 86_400
        let previous = snap
        queue.async {
            var s = previous
            s.gateway = probeGateway(cfg.gatewayURL, withReadiness: wantReady)
            if !wantReady { s.gateway.ready = previous.gateway.ready; s.gateway.failing = previous.gateway.failing }
            if wantJobs { s.activity = s.gateway.live ? probeActivity(cli: cfg.cli, env: cfg.cliEnv) : ActivityStatus() }
            s.model = probeModel(baseURL: cfg.providerBaseURL, configuredModel: cfg.primaryModel)
            s.offload = readOffloadState(cfg.offload?.stateFile)
            s.updatedAt = Date()
            let latest = wantUpdate ? latestReleaseTag(repo: repoSlug) : nil
            DispatchQueue.main.async {
                self.snap = s
                if wantReady { self.lastReadiness = now }
                if wantJobs { self.lastJobs = now }
                if wantUpdate { self.lastUpdateCheck = now; if let l = latest { self.latestVersion = l } }
                self.probing = false
            }
        }
    }

    func checkForUpdatesNow() {
        updateMessage = "Checking…"
        DispatchQueue.global(qos: .utility).async {
            let latest = latestReleaseTag(repo: repoSlug)
            DispatchQueue.main.async {
                self.lastUpdateCheck = Date()
                if let l = latest {
                    self.latestVersion = l
                    self.updateMessage = isNewer(l, than: appVersion) ? "Version \(l) is available." : "You're up to date."
                } else {
                    self.updateMessage = "Couldn't reach GitHub."
                }
            }
        }
    }

    // MARK: actions

    func openDashboard() {
        guard let cmd = resolved.dashboard else { return }
        let env = resolved.cliEnv
        DispatchQueue.global().async { _ = runCommand(cmd, timeout: 30, env: env) }
    }

    func copyUpgradeCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew upgrade jarvis-switch && brew services restart jarvis-switch", forType: .string)
        result = ("Upgrade command copied. Paste it in Terminal.", Date())
    }

    func offloadLight() { runOffload(resolved.offload?.light, busy: "Offloading (light)…") }
    func offloadDeep() { runOffload(resolved.offload?.deep, busy: "Offloading (deep)…") }
    func restore() { runOffload(resolved.offload?.restore, busy: "Bringing \(resolved.name) back…") }

    private func runOffload(_ argv: [String]?, busy: String) {
        guard let argv = argv, !argv.isEmpty, offloadBusy == nil else { return }
        offloadBusy = busy
        let env = resolved.cliEnv
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runCommand(argv.map(expandPath), timeout: 900, env: env)
            let text = Store.summarize(lastJSONObject(r.output), code: r.code, raw: r.output)
            DispatchQueue.main.async {
                self.offloadBusy = nil
                self.result = (text, Date())
                self.refresh(full: true)
            }
        }
    }

    static func summarize(_ o: [String: Any]?, code: Int32, raw: String) -> String {
        guard let o = o else {
            let tail = raw.split(separator: "\n").last.map(String.init) ?? ""
            return code == 0 ? "Done." : "Failed (exit \(code)): \(tail.prefix(120))"
        }
        if (o["restored"] as? Bool) == true {
            var t = "Back"
            if let s = num(o["restore_seconds"]) { t += String(format: " in %.0f s", s) }
            if let same = o["identical_to_before"] as? Bool { t += same ? ", identical to before." : ", but something changed: check the logs." }
            return t
        }
        if (o["offloaded"] as? Bool) == true { return "Offloaded." }
        if let e = o["error"] ?? o["reason"] { return "Not done: \(e)" }
        return code == 0 ? "Done." : "Failed (exit \(code))."
    }
}
