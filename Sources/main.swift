// Jarvis Switch — menu-bar status, model details and an offload switch for a local OpenClaw assistant.
// https://github.com/mertegemencaliskan/jarvis-switch  (MIT)
import AppKit
import Combine
import SwiftUI

let repoSlug = "mertegemencaliskan/jarvis-switch"

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = Store.shared
    var item: NSStatusItem!
    let popover = NSPopover()
    var watchers = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppConfig.writeStarterIfMissing()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        item.button?.imagePosition = .imageLeading

        let host = NSHostingController(rootView: PanelView().environmentObject(store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        store.openSettings = { [weak self] in
            self?.popover.performClose(nil)
            if let s = self?.store { SettingsWindow.show(store: s) }
        }
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateButton() } }
            .store(in: &watchers)
        updateButton()
        store.start()
        // Hidden test hooks: open the panel or Settings right after launch.
        if CommandLine.arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.togglePanel(nil) }
        }
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.store.openSettings() }
        }
    }

    @objc func togglePanel(_ sender: Any?) {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refresh(full: true)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func updateButton() {
        guard let button = item?.button else { return }
        let kind = store.kind
        let img = NSImage(systemSymbolName: kind.menuSymbol, accessibilityDescription: store.resolved.name)
        img?.isTemplate = true
        button.image = img
        button.title = store.resolved.menuBarText ? " \(kind.title)" : ""
        button.toolTip = "\(store.resolved.name): \(kind.title)"
    }
}

// MARK: - Command line: --version, --status, --render

/// One-shot synchronous probe for the command-line modes.
func probeOnce(_ store: Store) -> Snapshot {
    let r = store.resolved
    var s = Snapshot()
    s.gateway = probeGateway(r.gatewayURL, withReadiness: true)
    s.activity = s.gateway.live ? probeActivity(cli: r.cli, env: r.cliEnv) : ActivityStatus()
    s.model = probeModel(baseURL: r.providerBaseURL, configuredModel: r.primaryModel)
    s.offload = readOffloadState(r.offload?.stateFile)
    s.updatedAt = Date()
    return s
}

func statusText(_ store: Store, _ s: Snapshot) -> String {
    var out: [String] = []
    let r = store.resolved
    out.append("\(r.name): \(store.kind.title)")
    if s.gateway.live {
        var g = "  OpenClaw \(s.gateway.version ?? "")"
        if let up = s.gateway.uptimeSeconds { g += " · up \(formatDuration(up))" }
        if let ready = s.gateway.ready { g += ready ? " · ready" : " · NOT ready" }
        out.append(g)
    } else {
        out.append("  OpenClaw gateway not running at \(r.gatewayURL)")
    }
    for jb in s.activity.running { out.append("  Running: \(jb.name) (\(formatDuration(Date().timeIntervalSince(jb.runningSince!))))") }
    if s.activity.known && s.activity.running.isEmpty { out.append("  Nothing running") }
    if let nx = s.activity.next, let at = nx.nextRun { out.append("  Next: \(nx.name) at \(formatClock(at))") }
    if !s.activity.failed.isEmpty { out.append("  Last run failed: \(s.activity.failed.map(\.name).joined(separator: ", "))") }
    if let e = s.activity.error { out.append("  Jobs: \(e)") }
    let m = s.model
    out.append("Model")
    if m.reachable {
        out.append("  \(m.modelID ?? "unknown") · \(m.runtime)\(m.activeRequests > 0 ? " · generating" : "")")
        var w = "  Weights: \(m.weightsLabel ?? "quantization unknown")"
        if let d = m.weightsOnDisk { w += " · \(formatBytes(d)) on disk" }
        out.append(w)
        var kv = "  KV cache: \(m.kvLabel ?? "not reported")"
        if let a = m.kvAllocated { kv += " · \(formatBytes(a)) reserved" }
        out.append(kv)
        if let b = m.weightsBits {
            let weights = Quality.weights(bits: b), kvq = m.kvBits.map { Quality.kv(bits: $0) }
            var q = "  Quality kept vs BF16 (estimate): \(Quality.percent(weights * (kvq ?? 100) / 100))"
            q += " (weights \(Quality.percent(weights))" + (kvq.map { ", KV \(Quality.percent($0))" } ?? "") + ")"
            out.append(q)
        }
        var mem = "  Memory: \(m.memoryInUse.map(formatBytes) ?? "not reported")"
        if let p = m.memoryPressure { mem += " · pressure \(p)" }
        out.append(mem)
        if let tps = m.decodeTokensPerSecond { out.append(String(format: "  Speed: %.0f tok/s", tps) + (m.ttftSeconds.map { String(format: " · %.1f s to first token", $0) } ?? "")) }
    } else {
        out.append("  \(m.modelID.map { "\($0) · " } ?? "")\(m.runtime)")
    }
    if r.offloadConfigured {
        out.append("Offload: " + (s.offload.active ? "offloaded" + (s.offload.mode.map { " (\($0))" } ?? "") : "available"))
    }
    return out.joined(separator: "\n")
}

/// Sample data for screenshots, so no real job names or paths end up in public images.
func demoSnapshot() -> Snapshot {
    var s = Snapshot()
    s.gateway = GatewayStatus(live: true, ready: true, failing: [], version: "2026.11.5", uptimeSeconds: 3 * 3600 + 1200)
    let now = Date()
    s.activity.known = true
    s.activity.jobs = [
        Job(name: "Morning briefing", runningSince: now.addingTimeInterval(-252), nextRun: nil, lastFailed: false, enabled: true),
        Job(name: "Inbox triage", runningSince: nil, nextRun: now.addingTimeInterval(1260), lastFailed: false, enabled: true),
    ]
    var m = ModelStatus()
    m.reachable = true
    m.runtime = "Splash (MLX)"
    m.modelID = "mlx-community/Qwen3.8-27B-4bit"
    m.servedNames = ["assistant", "assistant_fast"]
    m.weightsLabel = "4-bit affine, group size 64"
    m.weightsBits = 4
    m.weightsOnDisk = 15.4e9
    m.kvLabel = "int8 (symmetric, f32 scales)"
    m.kvBits = 8
    m.kvAllocated = 4.8e9
    m.kvActive = 1.3e9
    m.contextTokens = 262_144
    m.memoryInUse = 23.6e9
    m.memoryPeak = 28.1e9
    m.memoryPressure = "normal"
    m.activeRequests = 1
    m.ttftSeconds = 1.9
    m.decodeTokensPerSecond = 44
    m.cacheHitRate = 0.99
    m.speculative = true
    s.model = m
    s.updatedAt = now
    return s
}

/// Render a SwiftUI view to PNG (used for README screenshots and design checks).
func renderPNG<V: View>(_ view: V, appearance: NSAppearance.Name, to path: String) {
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: appearance)
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: expandPath(path)))
    window.orderOut(nil)
}

/// Panel and Settings framed like they appear on screen.
struct PreviewFrame<Content: View>: View {
    let content: Content
    var body: some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .padding(18)
    }
}

let args = CommandLine.arguments
func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("--version") { print(appVersion); exit(0) }

if args.contains("--status") {
    let store = Store.shared
    store.setSnapshotForCLI(probeOnce(store))
    print(statusText(store, store.snap))
    exit(0)
}

if let target = argValue("--render") {
    // --render out.png [--dark] [--settings general|connection|offload|about] [--details]
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let store = Store.shared
    store.setSnapshotForCLI(args.contains("--demo") ? demoSnapshot() : probeOnce(store))
    let appearance: NSAppearance.Name = args.contains("--dark") ? .darkAqua : .aqua
    UserDefaults.standard.set(args.contains("--details"), forKey: "showModelDetails")
    if let tabName = argValue("--settings"), let tab = SettingsTab.allCases.first(where: { $0.rawValue.lowercased() == tabName.lowercased() }) {
        SettingsUI.shared.tab = tab
        renderPNG(PreviewFrame(content: SettingsView().environmentObject(store)), appearance: appearance, to: target)
    } else {
        renderPNG(PreviewFrame(content: PanelView().environmentObject(store)), appearance: appearance, to: target)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
