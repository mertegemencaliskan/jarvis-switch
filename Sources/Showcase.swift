import AppKit
import SwiftUI

// Screenshots for the README and design checks. Everything here uses sample data, so no real
// job names, paths or ids end up in public images.

let demoConfig = AppConfig(name: "Jarvis", dashboardCommand: ["/usr/bin/true"],
                           offload: OffloadConfig(light: ["/usr/bin/true"], deep: ["/usr/bin/true"], restore: ["/usr/bin/true"]))

func demoSnapshot() -> Snapshot {
    var s = Snapshot()
    let now = Date()
    s.gateway = GatewayStatus(live: true, ready: true, failing: [], version: "2026.11.5", uptimeSeconds: 3 * 3600 + 1200)
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
    m.memoryInUse = 22.1e9
    m.memoryPeak = 28.1e9
    m.processFootprint = 24.2e9
    m.memoryPressure = "normal"
    m.activeRequests = 1
    m.requests = [LiveRequest(id: 7, phase: "decode", promptTokens: 38_420, promptProcessed: 38_420, generatedTokens: 612)]
    m.ttftSeconds = 1.9
    m.decodeTokensPerSecond = 44
    m.cacheHitRate = 0.99
    m.speculative = true
    s.model = m
    s.liveTokensPerSecond = 47
    s.sessions = [
        SessionInfo(key: "agent:main:cron:demo:run:1", label: "Morning briefing", running: true, totalTokens: nil,
                    contextTokens: 262_144, compactions: 0, updatedAt: now),
        SessionInfo(key: "agent:main:main", label: "Main chat", running: false, totalTokens: 162_908,
                    contextTokens: 262_144, compactions: 1, updatedAt: now.addingTimeInterval(-600)),
    ]
    s.memory = SystemMemory(total: 51_539_607_552, used: 36.4e9)
    s.updatedAt = now
    return s
}

/// Variants for the states picture.
func demoStates() -> [Snapshot] {
    let base = demoSnapshot()
    var idle = base
    idle.activity.jobs = [Job(name: "Inbox triage", runningSince: nil, nextRun: Date().addingTimeInterval(1260), lastFailed: false, enabled: true)]
    idle.model.activeRequests = 0
    idle.model.requests = []
    idle.liveTokensPerSecond = nil
    var resting = idle
    resting.model.weightsReleased = true
    var paused = idle
    paused.offload = OffloadState(active: true, mode: "deep", purpose: "3D render")
    var offline = idle
    offline.gateway = GatewayStatus()
    return [idle, base, resting, paused, offline]
}

// MARK: - Views

struct AppGlyph: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(LinearGradient(colors: [Color.blue, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "brain.head.profile").font(.system(size: size * 0.47, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.18), radius: size * 0.08, y: size * 0.04)
    }
}

/// How the state looks in the menu bar (icon and the optional status word).
struct MenuBarChip: View {
    let kind: Kind

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.menuSymbol).font(.system(size: 13, weight: .medium))
            Text(kind.title).font(.system(size: 12.5, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08)))
    }
}

struct StatesView: View {
    let stores: [Store]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(stores.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 14) {
                    MenuBarChip(kind: s.kind).frame(width: 128, alignment: .leading)
                    StatusHeader().environmentObject(s)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
                        .frame(width: 330)
                }
            }
        }
        .padding(16)
    }
}

struct HeroView: View {
    let store: Store

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.11), Color(red: 0.12, green: 0.11, blue: 0.27)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.blue.opacity(0.32), .clear], center: UnitPoint(x: 0.78, y: 0.18), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color.purple.opacity(0.22), .clear], center: UnitPoint(x: 0.12, y: 0.9), startRadius: 0, endRadius: 460)
            HStack(alignment: .center, spacing: 60) {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 16) {
                        AppGlyph(size: 62)
                        Text("Jarvis Switch").font(.system(size: 46, weight: .bold, design: .rounded))
                    }
                    Text("Know what your local AI assistant is doing,\nright from the menu bar.")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 11) {
                        feature("waveform", "Live: idle or working, jobs, tokens per second")
                        feature("text.alignleft", "Context window in use, and whether it was compacted")
                        feature("cpu", "Model, quantization, KV cache, memory")
                        feature("checkmark.seal", "Estimated quality kept vs BF16")
                        feature("pause.circle", "Pause it to free RAM and GPU for other work")
                    }
                    Text("brew install mertegemencaliskan/jarvis/jarvis-switch")
                        .font(.system(size: 14.5, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.09)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    Text("For OpenClaw · Splash · LM Studio · Ollama · macOS 13+")
                        .font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.55))
                }
                .frame(width: 600, alignment: .leading)
                PanelView(scrollable: false).environmentObject(store)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .scaleEffect(0.72)
                    .frame(width: 245, height: 600)
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
            }
            .padding(.horizontal, 70)
        }
        .frame(width: 1280, height: 640)
        .environment(\.colorScheme, .dark)
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(icon, or: "circle")).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.55, green: 0.7, blue: 1)).frame(width: 22)
            Text(text).font(.system(size: 17)).foregroundStyle(.white.opacity(0.9))
        }
    }
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

// MARK: - Rendering

/// Render a SwiftUI view to PNG at the screen's backing scale.
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

/// `--render FILE.png [--dark] [--demo] [--details] [--settings TAB | --hero | --states]`
func renderFromCommandLine(_ target: String) {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let demo = args.contains("--demo") || args.contains("--hero") || args.contains("--states")
    let store = demo ? Store(config: demoConfig) : Store.shared
    store.setSnapshotForCLI(demo ? demoSnapshot() : probeOnce(store.resolved, sampleSpeed: false))
    let appearance: NSAppearance.Name = args.contains("--dark") ? .darkAqua : .aqua
    UserDefaults.standard.set(args.contains("--details"), forKey: "showModelDetails")
    if args.contains("--hero") {
        renderPNG(HeroView(store: store), appearance: .darkAqua, to: target)
    } else if args.contains("--states") {
        let stores = demoStates().map { snap -> Store in
            let s = Store(config: demoConfig)
            s.setSnapshotForCLI(snap)
            return s
        }
        renderPNG(PreviewFrame(content: StatesView(stores: stores)), appearance: appearance, to: target)
    } else if let tabName = argValue("--settings"),
              let tab = SettingsTab.allCases.first(where: { $0.rawValue.lowercased() == tabName.lowercased() }) {
        SettingsUI.shared.tab = tab
        renderPNG(PreviewFrame(content: SettingsView().environmentObject(store)), appearance: appearance, to: target)
    } else {
        renderPNG(PreviewFrame(content: PanelView(scrollable: false).environmentObject(store)), appearance: appearance, to: target)
    }
}
