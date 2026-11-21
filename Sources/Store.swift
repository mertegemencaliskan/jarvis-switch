import AppKit
import SwiftUI

struct Snapshot {
    var gateway = GatewayStatus()
    var activity = ActivityStatus()
    var model = ModelStatus()
    var offload = OffloadState()
    var sessions: [SessionInfo] = []
    var active: ActiveModel?
    var memory: SystemMemory?
    var learning: LearningStatus?
    /// Tokens per second measured between the last two refreshes while the model was writing.
    var liveTokensPerSecond: Double?
    var updatedAt = Date.distantPast
}

/// What the assistant is doing, as one word, with a colour and symbols.
enum Kind: Equatable {
    case checking, offline, offloaded, working, idle, resting

    var title: String {
        switch self {
        case .checking: return "Checking"
        case .offline: return "Offline"
        case .offloaded: return "Paused"
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
        case .offline: return "exclamationmark.triangle.fill"
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

extension Kind {
    static func from(_ s: Snapshot, busy: Bool) -> Kind {
        if busy { return .working }
        if s.updatedAt == .distantPast { return .checking }
        if s.offload.active { return .offloaded }
        if !s.gateway.live { return .offline }
        if !s.activity.running.isEmpty || s.model.activeRequests > 0 { return .working }
        if s.model.weightsReleased { return .resting }
        return .idle
    }
}

func symbol(_ name: String, or fallback: String) -> String {
    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
}

/// Generated tokens since the previous refresh, per second; smoothed a little so the number is readable.
func liveSpeed(previous: Snapshot, current: Snapshot) -> Double? {
    guard previous.model.modelID == current.model.modelID,
          previous.active?.baseURL == current.active?.baseURL else { return nil }
    let dt = current.updatedAt.timeIntervalSince(previous.updatedAt)
    guard dt > 0.3, dt < 120 else { return nil }
    let before = Dictionary(previous.model.requests.map { ($0.id, $0.generatedTokens) }, uniquingKeysWith: { a, _ in a })
    var delta = 0.0
    var writing = false
    for r in current.model.requests where r.phase == "decode" {
        writing = true
        if let b = before[r.id] { delta += max(0, r.generatedTokens - b) } else { delta += r.generatedTokens }
    }
    guard writing, delta > 0 else { return nil }
    let now = delta / dt
    if let last = previous.liveTokensPerSecond { return 0.5 * now + 0.5 * last }
    return now
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
    private var configDate = AppConfig.modificationDate()
    private var sessionStore: String?
    private var lastSessionLookup = Date.distantPast
    /// Last live context size per running session, shown while the agent is between model calls.
    private(set) var lastLiveContext: [String: Double] = [:]
    private let queue = DispatchQueue(label: "jarvis-switch.probe", qos: .utility)

    init(config: AppConfig? = nil) {
        let c = config ?? AppConfig.load()
        self.config = c
        resolved = Resolved.resolve(c)
    }

    /// Command-line modes probe synchronously and hand the result over.
    func setSnapshotForCLI(_ s: Snapshot) { snap = s }

    // MARK: derived state

    var kind: Kind { Kind.from(snap, busy: offloadBusy != nil) }

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
        configDate = AppConfig.modificationDate()
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

    /// Settings edited outside the app (by hand, a script or an agent) apply on the next refresh.
    private func reloadIfChangedOnDisk() {
        let d = AppConfig.modificationDate()
        guard d != configDate else { return }
        configDate = d
        let c = AppConfig.load()
        guard c != config else { return }
        let intervalChanged = c.refreshSeconds != config.refreshSeconds
        config = c
        resolved = Resolved.resolve(c)
        if intervalChanged { scheduleTimer() }
    }

    /// full: also re-read scheduled jobs and readiness now (used when the panel opens).
    func refresh(full: Bool) {
        reloadIfChangedOnDisk()
        guard !probing else { return }
        probing = true
        let cfg = resolved
        let now = Date()
        // Cheap HTTP and file reads run every refresh (as often as every second). The `openclaw` CLI costs
        // about a second of CPU, so scheduled jobs are read at most every 30 s (and when the panel opens).
        let wantReady = full || now.timeIntervalSince(lastReadiness) >= max(15, cfg.refreshSeconds)
        let wantJobs = full || now.timeIntervalSince(lastJobs) >= max(30, cfg.refreshSeconds)
        let wantStore = sessionStore == nil && now.timeIntervalSince(lastSessionLookup) >= 600
        let wantUpdate = cfg.checkForUpdates && now.timeIntervalSince(lastUpdateCheck) > 86_400
        let previous = snap
        var storePath = sessionStore
        queue.async {
            var s = previous
            s.gateway = probeGateway(cfg.gatewayURL, withReadiness: wantReady)
            if !wantReady { s.gateway.ready = previous.gateway.ready; s.gateway.failing = previous.gateway.failing }
            if wantJobs {
                s.activity = s.gateway.live ? probeActivity(cli: cfg.cli, env: cfg.cliEnv) : ActivityStatus()
                s.learning = probeLearning(metricsDir: cfg.metricsDir)
            }
            if wantStore, s.gateway.live { storePath = sessionStorePath(cli: cfg.cli, env: cfg.cliEnv) }
            s.sessions = storePath.flatMap { readSessions($0) } ?? []
            let active = activeModel(s.sessions, cfg)
            s.active = active
            s.model = probeModel(baseURL: active.baseURL, configuredModel: active.alias)
            s.offload = readOffloadState(cfg.pauseMarker)
            s.memory = systemMemory()
            s.updatedAt = Date()
            s.liveTokensPerSecond = liveSpeed(previous: previous, current: s)
            CompanionModelSample.publish(s)
            let latest = wantUpdate ? latestReleaseTag(repo: repoSlug) : nil
            DispatchQueue.main.async {
                if wantStore { self.lastSessionLookup = now; self.sessionStore = storePath }
                if let running = s.sessions.filter({ $0.running }).first, s.sessions.filter({ $0.running }).count == 1,
                   let req = s.model.requests.max(by: { $0.contextTokens < $1.contextTokens }) {
                    self.lastLiveContext[running.key] = req.contextTokens
                }
                self.snap = s
                if wantReady { self.lastReadiness = now }
                if wantJobs { self.lastJobs = now }
                if wantUpdate { self.lastUpdateCheck = now; if let l = latest { self.latestVersion = l } }
                self.probing = false
            }
        }
    }

    var context: ContextNow? { contextNow(snap, lastLive: lastLiveContext) }

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

    func offloadLight() { runOffload(resolved.offload?.light, busy: "Pausing (light)…", marker: .pause("light")) }
    func offloadDeep() { runOffload(resolved.offload?.deep, busy: "Pausing (deep)…", marker: .pause("deep")) }
    func restore() { runOffload(resolved.offload?.restore, busy: "Resuming \(resolved.name)…", marker: .resume) }

    enum MarkerChange { case pause(String), resume }

    private func runOffload(_ argv: [String]?, busy: String, marker: MarkerChange) {
        guard let argv = argv, !argv.isEmpty, offloadBusy == nil else { return }
        offloadBusy = busy
        let env = resolved.cliEnv
        // Without a marker file of the user's own, the app keeps one so the panel knows it is paused.
        let ownMarker = resolved.offload?.stateFile == nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runCommand(argv.map(expandPath), timeout: 900, env: env)
            let o = lastJSONObject(r.output)
            let text = Store.summarize(o, code: r.code, raw: r.output)
            let ok = r.code == 0 && o?["error"] == nil && (o?["offloaded"] as? Bool) != false && (o?["restored"] as? Bool) != false
            if ownMarker && ok {
                switch marker {
                case .pause(let mode):
                    let body: [String: Any] = ["mode": mode, "purpose": "paused from the menu bar",
                                               "since": ISO8601DateFormatter().string(from: Date())]
                    try? FileManager.default.createDirectory(atPath: (appPauseMarker as NSString).deletingLastPathComponent,
                                                             withIntermediateDirectories: true)
                    try? JSONSerialization.data(withJSONObject: body).write(to: URL(fileURLWithPath: appPauseMarker))
                case .resume:
                    try? FileManager.default.removeItem(atPath: appPauseMarker)
                }
            }
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
