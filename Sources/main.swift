// Jarvis Switch — a menu-bar status light and offload switch for a local OpenClaw assistant.
// https://github.com/mertegemencaliskan/jarvis-switch  (MIT)
import Cocoa

let repoSlug = "mertegemencaliskan/jarvis-switch"

struct Snapshot {
    var gateway = GatewayStatus()
    var activity = ActivityStatus()
    var model = ModelStatus()
    var offload = OffloadState()
    var updatedAt = Date.distantPast
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    var cfg = Resolved.resolve(AppConfig.load())
    var snap = Snapshot()
    var working = false            // an offload/restore command is running
    var resultText: String?
    var resultAt = Date.distantPast
    var latestVersion: String?
    var lastReadiness = Date.distantPast
    var lastCron = Date.distantPast
    var lastUpdateCheck = Date.distantPast
    let probeQueue = DispatchQueue(label: "probe", qos: .utility)
    var probing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppConfig.writeStarterIfMissing()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        setIcon("brain.head.profile", "J")
        render()
        refresh(full: true)
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh(full: false) }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh(full: true) }

    // MARK: probing

    func refresh(full: Bool) {
        guard !probing else { return }
        probing = true
        let cfg = self.cfg
        let now = Date()
        let wantReady = full || now.timeIntervalSince(lastReadiness) > 30
        let wantCron = full || now.timeIntervalSince(lastCron) > 30
        let wantUpdate = cfg.checkForUpdates && now.timeIntervalSince(lastUpdateCheck) > 86_400
        probeQueue.async {
            var s = self.snap
            s.gateway = probeGateway(cfg.gatewayURL, withReadiness: wantReady)
            if !wantReady { s.gateway.ready = self.snap.gateway.ready; s.gateway.failing = self.snap.gateway.failing }
            if wantCron { s.activity = s.gateway.live ? probeActivity(cli: cfg.cli, env: cfg.cliEnv) : ActivityStatus() }
            s.model = probeModel(baseURL: cfg.providerBaseURL, configuredModel: cfg.primaryModel)
            s.offload = readOffloadState(cfg.offload?.stateFile)
            s.updatedAt = Date()
            let latest = wantUpdate ? latestReleaseTag(repo: repoSlug) : nil
            DispatchQueue.main.async {
                self.snap = s
                if wantReady { self.lastReadiness = now }
                if wantCron { self.lastCron = now }
                if wantUpdate { self.lastUpdateCheck = now; if let l = latest { self.latestVersion = l } }
                self.probing = false
                self.render()
            }
        }
    }

    // MARK: rendering

    func setIcon(_ symbol: String, _ fallback: String) {
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: cfg.name) {
            img.isTemplate = true
            item.button?.image = img
            item.button?.title = ""
        } else {
            item.button?.image = nil
            item.button?.title = fallback
        }
    }

    func headline() -> (String, String, String) {
        let s = snap, n = cfg.name
        if working { return ("\(n): working on your request…", "hourglass", "J…") }
        if s.updatedAt == .distantPast { return ("\(n): checking…", "brain.head.profile", "J") }
        if s.offload.active {
            let mode = s.offload.mode.map { " (\($0))" } ?? ""
            let why = s.offload.purpose.map { ": \($0)" } ?? ""
            return ("\(n) offloaded\(mode)\(why)", s.offload.mode == "deep" ? "moon.zzz.fill" : "moon.zzz", "J○")
        }
        if !s.gateway.live { return ("\(n): gateway not running", "exclamationmark.triangle", "J!") }
        let busy = !s.activity.running.isEmpty || s.model.activeRequests > 0
        if busy { return ("\(n): working", "brain.head.profile.fill", "J●") }
        if s.model.weightsReleased { return ("\(n): idle, model weights released", "moon.zzz", "J○") }
        return ("\(n): idle", "brain.head.profile", "J")
    }

    var textLines: [String]? = nil   // when set, render() records lines instead of building the menu

    func info(_ text: String, indent: Int = 0, copy: Bool = true) -> NSMenuItem {
        textLines?.append(String(repeating: "  ", count: indent) + text)
        let it = NSMenuItem(title: text, action: copy ? #selector(copyLine(_:)) : nil, keyEquivalent: "")
        it.target = self
        it.indentationLevel = indent
        it.isEnabled = copy
        it.toolTip = copy ? "Click to copy" : nil
        return it
    }

    func header(_ text: String) -> NSMenuItem {
        textLines?.append(text)
        let it = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        it.isEnabled = false
        it.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        return it
    }

    func render() {
        let (title, symbol, fallback) = headline()
        if item != nil {
            setIcon(symbol, fallback)
            item.button?.toolTip = title
        }
        menu.removeAllItems()
        let s = snap
        menu.addItem(header(title))

        // OpenClaw
        if s.gateway.live {
            var g = "OpenClaw \(s.gateway.version ?? "")"
            if let up = s.gateway.uptimeSeconds { g += " · up \(formatDuration(up))" }
            if let ready = s.gateway.ready { g += ready ? " · ready" : " · NOT ready" }
            menu.addItem(info(g, indent: 1))
            if !s.gateway.failing.isEmpty { menu.addItem(info("Failing: \(s.gateway.failing.joined(separator: ", "))", indent: 1)) }
        } else if s.updatedAt != .distantPast {
            menu.addItem(info("OpenClaw gateway unreachable at \(cfg.gatewayURL)", indent: 1))
        }

        // Activity
        if s.activity.known {
            if s.activity.running.isEmpty {
                menu.addItem(info("No scheduled job running", indent: 1))
            }
            for jb in s.activity.running {
                menu.addItem(info("Running: \(jb.name) (\(formatDuration(Date().timeIntervalSince(jb.runningSince!))))", indent: 1))
            }
            if let nx = s.activity.next, let at = nx.nextRun {
                menu.addItem(info("Next: \(nx.name) at \(formatClock(at))", indent: 1))
            }
            let failed = s.activity.failed
            if !failed.isEmpty {
                menu.addItem(info("Last run failed: \(failed.map(\.name).joined(separator: ", "))", indent: 1))
            }
        } else if let e = s.activity.error, s.gateway.live {
            menu.addItem(info("Jobs: \(e)", indent: 1))
        }
        if s.model.reachable {
            let gen = s.model.activeRequests > 0 ? "generating (\(s.model.activeRequests) request\(s.model.activeRequests == 1 ? "" : "s"))" : "idle"
            menu.addItem(info("Model: \(gen)", indent: 1))
        }

        // Model details
        menu.addItem(.separator())
        menu.addItem(header("Model"))
        addModelLines(s.model)

        // Offload
        if let off = cfg.offload, off.light != nil || off.deep != nil || off.restore != nil {
            menu.addItem(.separator())
            menu.addItem(header("Offload"))
            let offloaded = s.offload.active
            if let _ = off.light {
                menu.addItem(action(off.lightLabel ?? "Offload: light (release model memory)", #selector(light), enabled: !working && !offloaded))
            }
            if let _ = off.deep {
                menu.addItem(action(off.deepLabel ?? "Offload: deep (stop the model server)", #selector(deep), enabled: !working && !offloaded))
            }
            if let _ = off.restore {
                menu.addItem(action("Bring \(cfg.name) back", #selector(back), enabled: !working && offloaded))
            }
        }
        if let r = resultText, Date().timeIntervalSince(resultAt) < 600 { menu.addItem(info(r, indent: 1)) }

        // Footer
        menu.addItem(.separator())
        if cfg.dashboard != nil { menu.addItem(action("Open OpenClaw", #selector(openDashboard), enabled: true)) }
        menu.addItem(action("Refresh now", #selector(refreshNow), enabled: true, key: "r"))
        menu.addItem(action("Edit settings…", #selector(editSettings), enabled: true, key: ","))
        let version = appVersion
        if let l = latestVersion, isNewer(l, than: version) {
            menu.addItem(action("Update available: \(l) (copy brew command)", #selector(copyUpgrade), enabled: true))
        }
        menu.addItem(action("About Jarvis Switch \(version)", #selector(openRepo), enabled: true))
        menu.addItem(action("Quit", #selector(NSApplication.terminate(_:)), enabled: true, key: "q", target: NSApp))
    }

    func addModelLines(_ m: ModelStatus) {
        guard m.reachable else {
            menu.addItem(info(m.modelID.map { "\($0) · \(m.runtime)" } ?? "Model server: \(m.runtime)", indent: 1))
            return
        }
        menu.addItem(info("Runtime: \(m.runtime)", indent: 1))
        if let id = m.modelID { menu.addItem(info("Model: \(id)", indent: 1)) }
        if !m.servedNames.isEmpty { menu.addItem(info("Served as: \(m.servedNames.joined(separator: ", "))", indent: 1)) }
        if let note = m.note { menu.addItem(info(note, indent: 1)) }

        var w = "Weights: \(m.weightsLabel ?? "quantization unknown")"
        if let d = m.weightsOnDisk { w += " · \(formatBytes(d)) on disk" }
        menu.addItem(info(w, indent: 1))
        if let b = m.weightsBits {
            menu.addItem(info("Est. quality vs BF16: \(Quality.percent(Quality.weights(bits: b))) (rough estimate)", indent: 2))
        }

        var kv = "KV cache: \(m.kvLabel ?? "not reported")"
        if let a = m.kvAllocated { kv += " · \(formatBytes(a)) reserved" }
        if let act = m.kvActive { kv += ", \(formatBytes(act)) in use" }
        menu.addItem(info(kv, indent: 1))
        if let b = m.kvBits {
            menu.addItem(info("Est. KV quality vs BF16 cache: \(Quality.percent(Quality.kv(bits: b))) (rough estimate)", indent: 2))
        }
        if let w = m.weightsBits, let k = m.kvBits {
            let combined = Quality.weights(bits: w) * Quality.kv(bits: k) / 100
            menu.addItem(info("Combined estimate: \(Quality.percent(combined)) of full-precision quality", indent: 2))
        }
        if let c = m.contextTokens { menu.addItem(info("Context window: \(formatInt(c)) tokens", indent: 1)) }

        var mem = "Memory: "
        if let u = m.memoryInUse { mem += "\(formatBytes(u)) in use" } else { mem += "not reported" }
        if let p = m.memoryPeak { mem += " (peak \(formatBytes(p)))" }
        if let pr = m.memoryPressure { mem += " · system pressure \(pr)" }
        menu.addItem(info(mem, indent: 1))
        if m.weightsReleased { menu.addItem(info("Weights released from memory (light offload)", indent: 1)) }

        var speed: [String] = []
        if let t = m.ttftSeconds { speed.append(String(format: "first token %.1f s", t)) }
        if let tps = m.decodeTokensPerSecond { speed.append(String(format: "%.0f tok/s", tps)) }
        if !speed.isEmpty { menu.addItem(info("Speed (median): " + speed.joined(separator: " · "), indent: 1)) }
        var extra: [String] = []
        if let h = m.cacheHitRate { extra.append(String(format: "prompt cache hit rate %.0f%%", h * 100)) }
        if let sp = m.speculative { extra.append(sp ? "speculative decoding on" : "speculative decoding off") }
        if !extra.isEmpty { menu.addItem(info(extra.joined(separator: " · ").capitalizedFirst, indent: 1)) }
    }

    func action(_ title: String, _ sel: Selector, enabled: Bool, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        if textLines != nil && sel != #selector(openDashboard) && sel != #selector(refreshNow) && sel != #selector(editSettings) && sel != #selector(openRepo) && sel != #selector(NSApplication.terminate(_:)) {
            textLines?.append("  [\(enabled ? "x" : " ")] " + title)
        }
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = target ?? self
        it.isEnabled = enabled
        return it
    }

    // MARK: actions

    @objc func copyLine(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.title, forType: .string)
    }

    @objc func refreshNow() { refresh(full: true) }

    @objc func editSettings() {
        AppConfig.writeStarterIfMissing()
        NSWorkspace.shared.open(URL(fileURLWithPath: AppConfig.path))
        // Settings are re-read on the next refresh after the editor saves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.cfg = Resolved.resolve(AppConfig.load()) }
    }

    @objc func openDashboard() {
        guard let cmd = cfg.dashboard else { return }
        let env = cfg.cliEnv
        DispatchQueue.global().async { _ = runCommand(cmd, timeout: 30, env: env) }
    }

    @objc func openRepo() { NSWorkspace.shared.open(URL(string: "https://github.com/\(repoSlug)")!) }

    @objc func copyUpgrade() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew upgrade jarvis-switch && brew services restart jarvis-switch", forType: .string)
    }

    @objc func light() { runOffload(cfg.offload?.light, busy: "Offloading (light)…") }
    @objc func deep() { runOffload(cfg.offload?.deep, busy: "Offloading (deep)…") }
    @objc func back() { runOffload(cfg.offload?.restore, busy: "Bringing \(cfg.name) back…") }

    func runOffload(_ argv: [String]?, busy: String) {
        guard let argv = argv, !argv.isEmpty, !working else { return }
        working = true
        resultText = busy
        resultAt = Date()
        render()
        let env = cfg.cliEnv
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runCommand(argv.map(expandPath), timeout: 900, env: env)
            let o = lastJSONObject(r.output)
            let summary = AppDelegate.summarize(o, code: r.code, raw: r.output)
            DispatchQueue.main.async {
                self.working = false
                self.resultText = summary
                self.resultAt = Date()
                self.refresh(full: true)
            }
        }
    }

    static func summarize(_ o: [String: Any]?, code: Int32, raw: String) -> String {
        guard let o = o else {
            let tail = raw.split(separator: "\n").last.map(String.init) ?? ""
            return code == 0 ? "Done" : "Failed (exit \(code)): \(tail.prefix(120))"
        }
        if (o["restored"] as? Bool) == true {
            var t = "Back"
            if let s = num(o["restore_seconds"]) { t += String(format: " in %.0f s", s) }
            if let same = o["identical_to_before"] as? Bool { t += same ? ", identical to before" : ", CHANGED (check logs)" }
            return t
        }
        if (o["offloaded"] as? Bool) == true { return "Offloaded" + ((o["restore_by"] as? String).map { "; returns by \($0) at the latest" } ?? "") }
        if let e = o["error"] ?? o["reason"] { return "Not done: \(e)" }
        return code == 0 ? "Done" : "Failed (exit \(code))"
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

if CommandLine.arguments.contains("--version") { print(appVersion); exit(0) }
if CommandLine.arguments.contains("--status") {
    // Print the menu contents once and exit: handy over SSH and for bug reports.
    let d = AppDelegate()
    var s = Snapshot()
    s.gateway = probeGateway(d.cfg.gatewayURL, withReadiness: true)
    s.activity = s.gateway.live ? probeActivity(cli: d.cfg.cli, env: d.cfg.cliEnv) : ActivityStatus()
    s.model = probeModel(baseURL: d.cfg.providerBaseURL, configuredModel: d.cfg.primaryModel)
    s.offload = readOffloadState(d.cfg.offload?.stateFile)
    s.updatedAt = Date()
    d.snap = s
    d.textLines = []
    d.render()
    let footer = ["Open OpenClaw", "Refresh now", "Edit settings…", "Quit"]
    print(d.textLines!.filter { line in !footer.contains(where: { line.hasPrefix($0) }) }.joined(separator: "\n"))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
