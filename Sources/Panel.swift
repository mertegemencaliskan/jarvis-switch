import SwiftUI

/// Measured height of the panel content, so the popover can scroll on short screens.
/// (An ObservableObject rather than @State, so the app builds with the Command Line Tools alone.)
final class PanelLayout: ObservableObject {
    static let shared = PanelLayout()
    @Published var contentHeight: CGFloat = 600
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The panel that opens from the menu-bar icon.
struct PanelView: View {
    @EnvironmentObject var store: Store
    @AppStorage("showModelDetails") private var showDetails = false
    @ObservedObject private var layout = PanelLayout.shared
    var scrollable = true

    var body: some View {
        if scrollable {
            let maxHeight = max(400, (NSScreen.main?.visibleFrame.height ?? 900) - 40)
            ScrollView(.vertical, showsIndicators: layout.contentHeight > maxHeight) {
                content
                    .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .onPreferenceChange(HeightKey.self) { h in if h > 0 && abs(h - layout.contentHeight) > 0.5 { layout.contentHeight = h } }
            .frame(width: 340, height: min(layout.contentHeight, maxHeight))
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeader()
            SectionHeader(title: "Activity")
            activityCard
            if let ctx = store.context, store.snap.gateway.live || ctx.live {
                SectionHeader(title: "Context", trailing: ctx.label)
                contextCard(ctx)
            }
            SectionHeader(title: "Model", trailing: store.snap.model.reachable ? runtimeShort(store.snap.model.runtime) : nil)
            modelCard
            if store.resolved.offloadConfigured {
                SectionHeader(title: "Pause")
                pauseCard
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: activity

    private var activityCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Card {
                activityRows(now: ctx.date)
            }
        }
    }

    @ViewBuilder private func activityRows(now: Date) -> some View {
        let s = store.snap
        if s.updatedAt == .distantPast {
            InfoRow(icon: "ellipsis.circle", title: "Checking…")
        } else if !s.gateway.live {
            InfoRow(icon: "bolt.horizontal.circle", title: "Gateway not running", tint: .red)
            Text("Expected at \(store.resolved.gatewayURL). Start OpenClaw, or set the address in Settings.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            if let busy = store.offloadBusy {
                InfoRow(icon: "hourglass", title: busy, tint: .blue)
            }
            ForEach(Array(s.activity.running.enumerated()), id: \.offset) { _, job in
                InfoRow(icon: "play.circle.fill", title: job.name, tint: .blue,
                        trailing: formatDuration(now.timeIntervalSince(job.runningSince ?? now)))
            }
            if s.model.activeRequests > 0 {
                InfoRow(icon: "waveform", title: "Model is generating", tint: .blue,
                        trailing: s.model.activeRequests == 1 ? "1 request" : "\(s.model.activeRequests) requests")
            }
            if s.activity.running.isEmpty && s.model.activeRequests == 0 && store.offloadBusy == nil {
                InfoRow(icon: "checkmark.circle.fill", title: "Nothing running", tint: .green)
            }
            if let next = s.activity.next, let at = next.nextRun {
                InfoRow(icon: "clock", title: next.name, trailing: nextLabel(at, now: now))
            }
            ForEach(Array(s.activity.failed.enumerated()), id: \.offset) { _, job in
                InfoRow(icon: "exclamationmark.triangle.fill", title: job.name, tint: .orange,
                        trailing: "last run failed", trailingColor: .orange)
            }
            if !s.gateway.failing.isEmpty {
                InfoRow(icon: "exclamationmark.circle.fill", title: "Not ready: " + s.gateway.failing.joined(separator: ", "), tint: .orange)
            }
            if let e = s.activity.error {
                InfoRow(icon: "questionmark.circle", title: e)
            }
        }
    }

    private func nextLabel(_ at: Date, now: Date) -> String {
        let delta = at.timeIntervalSince(now)
        if delta < 60 { return "now" }
        if delta < 3600 * 3 { return "in \(formatDuration(delta))" }
        return formatClock(at)
    }

    // MARK: context

    private func contextCard(_ c: ContextNow) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    if let t = c.tokens, let w = c.window {
                        Text(formatTokens(t)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("of \(formatTokens(w)) tokens").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if let t = c.tokens {
                        Text("\(formatTokens(t)) tokens").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    } else {
                        Text("Size shows at the next model call").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let t = c.tokens, let w = c.window, w > 0 {
                        Text("\(Int((t / w * 100).rounded()))%").font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    }
                }
                Meter(fraction: c.tokens.flatMap { t in c.window.map { t / max($0, 1) } } ?? 0, color: contextColor(c))
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: c.live ? "waveform" : (c.phase == "Idle" ? "pause.circle" : "ellipsis"))
                            .foregroundStyle(c.live ? Color.blue : Color.secondary)
                        Text(c.phase)
                    }
                    Spacer()
                    if let n = c.compactions {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(n > 0 ? Color.purple : Color.secondary)
                            Text(n == 0 ? "Not compacted" : n == 1 ? "Compacted once" : "Compacted \(n)×")
                        }
                        .help("How many times OpenClaw summarised this conversation to fit the context window")
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func contextColor(_ c: ContextNow) -> Color {
        guard let t = c.tokens, let w = c.window, w > 0 else { return .blue }
        let f = t / w
        return f > 0.9 ? .red : f > 0.75 ? .orange : .blue
    }

    // MARK: model

    @ViewBuilder private var modelCard: some View {
        let m = store.snap.model
        Card {
            if !m.reachable {
                InfoRow(icon: m.modelID == nil ? "questionmark.circle" : "cloud",
                        title: m.modelID.map(shortModelName) ?? "No local model found")
                Text(m.modelID == nil ? "Looking for the model server of your default OpenClaw model."
                     : (store.snap.active?.fromSession == true ? "Not loaded right now; it loads when the next request arrives."
                                                               : "Model server: \(m.runtime)"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                memoryRow(m)
            } else {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.modelID.map(shortModelName) ?? "Unknown model")
                            .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if let id = m.modelID, shortModelName(id) != id {
                            Text(id).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    if let badge = m.weightBadge { Badge(text: badge) }
                    if let e = store.snap.active?.effort { Badge(text: effortLabel(e)).help("Thinking effort of the model in use") }
                    if let note = m.note { Badge(text: note) }
                }
                HStack(spacing: 7) {
                    let live = store.snap.liveTokensPerSecond
                    Tile(icon: "speedometer", label: "Speed",
                         value: (live ?? m.decodeTokensPerSecond).map { String(format: "%.0f tok/s", $0) } ?? "—",
                         note: live != nil ? "live" : (m.decodeTokensPerSecond != nil ? "typical" : nil),
                         noteColor: live != nil ? .blue : nil)
                    Tile(icon: "timer", label: "First token",
                         value: m.ttftSeconds.map { String(format: "%.1f s", $0) } ?? "—",
                         note: m.ttftSeconds != nil ? "typical" : nil)
                    Tile(icon: "square.stack.3d.up", label: "KV cache", value: m.kvAllocated.map(formatBytes) ?? "—",
                         note: m.kvBits.map { $0 >= 16 ? "16-bit" : "\(Int($0))-bit" })
                }
                memoryRow(m)
                qualityRow(m)
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 5) { detailRows(m) }
                        .padding(.top, 6)
                } label: {
                    Text("Details").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Mac memory as one stacked bar: Jarvis, everything else, free.
    @ViewBuilder private func memoryRow(_ m: ModelStatus) -> some View {
        if let mem = store.snap.memory, mem.total > 0 {
            let jarvis = min(m.processFootprint ?? m.memoryInUse ?? 0, mem.used)
            let other = max(0, mem.used - jarvis)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Memory").font(.system(size: 12)).foregroundStyle(.secondary)
                    if let p = m.memoryPressure, p.lowercased() != "normal" && p.lowercased() != "nominal" {
                        Pill(text: pressureLabel(p), color: pressureColor(p), small: true)
                    }
                    Spacer()
                    Text("\(formatBytes(mem.free)) free of \(formatBytes(mem.total))")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
                StackedBar(parts: [(jarvis / mem.total, Color.accentColor), (other / mem.total, Color.secondary.opacity(0.55))])
                HStack(spacing: 12) {
                    if jarvis > 0 { LegendDot(color: .accentColor, text: "\(store.resolved.name) \(formatBytes(jarvis))") }
                    LegendDot(color: Color.secondary.opacity(0.55), text: "Other \(formatBytes(other))")
                    LegendDot(color: Color.primary.opacity(0.12), text: "Free \(formatBytes(mem.free))")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func qualityRow(_ m: ModelStatus) -> some View {
        if let w = m.weightsBits, let weights = m.weightQuality {
            let kv = m.kvBits.map { Quality.kv(bits: $0) }
            let combined = weights * (kv ?? 100) / 100
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Quality kept vs BF16").font(.system(size: 12)).foregroundStyle(.secondary)
                    Image(systemName: "info.circle").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    Spacer()
                    Text(Quality.percent(combined)).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                }
                Meter(fraction: combined / 100, color: qualityColor(combined))
            }
            .help(qualityHelp(weightsBits: w, weights: weights, kv: kv))
        }
    }

    @ViewBuilder private func detailRows(_ m: ModelStatus) -> some View {
        DetailRow(label: "Runtime", value: m.runtime)
        if let a = store.snap.active?.alias {
            DetailRow(label: "In use", value: a + (store.snap.active?.fromSession == true ? " (running session)" : " (default)"))
        }
        if !m.servedNames.isEmpty { DetailRow(label: "Served as", value: m.servedNames.joined(separator: ", ")) }
        DetailRow(label: "Weights", value: m.weightsLabel ?? "unknown")
        if let d = m.weightsOnDisk { DetailRow(label: "On disk", value: formatBytes(d)) }
        if let kept = m.weightQuality { DetailRow(label: "Weights keep", value: "\(Quality.percent(kept)) of BF16 (estimate)") }
        DetailRow(label: "KV cache", value: m.kvLabel ?? "not reported")
        if let a = m.kvAllocated {
            DetailRow(label: "KV memory", value: (m.kvActive.map { "\(formatBytes($0)) used of " } ?? "") + "\(formatBytes(a)) reserved")
        }
        if let b = m.kvBits { DetailRow(label: "KV keeps", value: "\(Quality.percent(Quality.kv(bits: b))) of BF16 (estimate)") }
        if let c = m.contextTokens { DetailRow(label: "Max context", value: "\(formatInt(c)) tokens") }
        if let u = m.memoryInUse { DetailRow(label: "GPU memory", value: formatBytes(u) + (m.memoryPeak.map { ", peak \(formatBytes($0))" } ?? "")) }
        if let t = m.decodeTokensPerSecond { DetailRow(label: "Typical speed", value: String(format: "%.0f tok/s", t)) }
        if let h = m.cacheHitRate { DetailRow(label: "Prompt cache", value: String(format: "%.0f%% hits", h * 100)) }
        if let sp = m.speculative { DetailRow(label: "Speculative", value: sp ? "On (draft model)" : "Off") }
        if m.weightsReleased { DetailRow(label: "Weights", value: "Released from memory") }
    }

    // MARK: pause

    private var pauseCard: some View {
        let s = store.snap, r = store.resolved
        return Card {
            if let busy = store.offloadBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.system(size: 13))
                }
            } else if s.offload.active {
                InfoRow(icon: "pause.circle.fill", title: "Paused" + (s.offload.mode.map { " (\($0))" } ?? ""), tint: .indigo,
                        trailing: s.offload.purpose)
                if r.offload?.restore != nil {
                    Button { store.restore() } label: {
                        Label("Resume \(r.name)", systemImage: "play.fill")
                    }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                }
            } else {
                HStack(spacing: 8) {
                    if r.offload?.light != nil {
                        Button { store.offloadLight() } label: { Label("Light", systemImage: "pause") }
                            .help(r.offload?.lightLabel ?? "Release the model's memory; resumes in seconds")
                    }
                    if r.offload?.deep != nil {
                        Button { store.offloadDeep() } label: { Label("Deep", systemImage: "moon.zzz") }
                            .help(r.offload?.deepLabel ?? "Stop the model server; frees the most memory")
                    }
                }
                .buttonStyle(PanelButtonStyle())
                Text("Pause \(r.name) and free its memory for another task. Resume with one click.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let res = store.result, Date().timeIntervalSince(res.at) < 600 {
                Text(res.text).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 9) {
            if let v = store.updateAvailable {
                Button { store.copyUpgradeCommand() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                        Text("Version \(v) is available").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("Copy brew command").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Button { store.openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
                Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(PanelButtonStyle())
            HStack(spacing: 6) {
                if store.resolved.dashboard != nil {
                    Button { store.openDashboard() } label: {
                        HStack(spacing: 3) { Text("Open OpenClaw"); Image(systemName: "arrow.up.right") }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(updatedLabel(now: ctx.date)).monospacedDigit()
                }
                .foregroundStyle(.tertiary)
                Button { store.refresh(full: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh now")
                    .keyboardShortcut("r", modifiers: .command)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 2)
        }
    }

    private func updatedLabel(now: Date) -> String {
        let t = store.snap.updatedAt
        if t == .distantPast { return "Updating…" }
        let s = max(0, now.timeIntervalSince(t))
        if s < 2 { return store.resolved.refreshSeconds <= 2 ? "Live" : "Updated just now" }
        return "Updated \(formatDuration(s)) ago"
    }
}

/// Assistant name, OpenClaw version and uptime, and the status pill.
struct StatusHeader: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let kind = store.kind
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [kind.color.opacity(0.95), kind.color.opacity(0.62)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: kind.glyph)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .bounce(on: kind.title)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.resolved.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            Pill(text: kind.title, color: kind.color)
        }
        .padding(.horizontal, 2)
    }

    private var subtitle: String {
        let g = store.snap.gateway
        if store.snap.updatedAt == .distantPast { return "Connecting to OpenClaw…" }
        guard g.live else { return "OpenClaw gateway not running" }
        var parts = ["OpenClaw \(g.version ?? "")".trimmingCharacters(in: .whitespaces)]
        if let up = g.uptimeSeconds { parts.append("up \(formatDurationShort(up))") }
        if g.ready == false { parts.append("not ready") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - helpers

/// "mlx-community/Qwen3.8-27B-4bit" -> "Qwen3.8-27B".
func shortModelName(_ id: String) -> String {
    var s = String(id.split(separator: "/").last ?? Substring(id))
    if Quality.ggufWeightFormat(from: s) != nil, let separator = s.lastIndex(of: ":") {
        s.removeSubrange(separator...)
    }
    let suffix = "[-_.](\\d+[-_]?bits?|mlx|gguf|q\\d[\\w]*|iq\\d[\\w]*|int\\d+|fp16|bf16|f16|awq|gptq|mxfp4|instruct-mlx)$"
    while let r = s.range(of: suffix, options: [.regularExpression, .caseInsensitive]), r.lowerBound > s.startIndex {
        s.removeSubrange(r)
    }
    return s.isEmpty ? id : s
}

func runtimeShort(_ r: String) -> String {
    if r.hasPrefix("Splash") { return "Splash · MLX" }
    if r.hasPrefix("OpenAI") { return "OpenAI API" }
    return r
}

func pressureLabel(_ p: String) -> String {
    switch p.lowercased() {
    case "normal", "nominal": return "normal"
    case "warning", "warn": return "pressure"
    case "critical", "urgent": return "critical"
    default: return p
    }
}

func pressureColor(_ p: String) -> Color {
    switch p.lowercased() {
    case "normal", "nominal": return .green
    case "warning", "warn": return .orange
    case "critical", "urgent": return .red
    default: return .secondary
    }
}

func qualityColor(_ pct: Double) -> Color {
    if pct >= 97 { return .green }
    if pct >= 93 { return .yellow }
    if pct >= 85 { return .orange }
    return .red
}

func qualityHelp(weightsBits: Double, weights: Double, kv: Double?) -> String {
    var t = "Rough estimate from published quantization studies, not a measurement of this model. "
    t += "Weights at \(weightsBits >= 16 ? "16" : String(Int(weightsBits)))-bit keep \(Quality.percent(weights))"
    if let kv = kv { t += "; the KV cache keeps \(Quality.percent(kv))" }
    t += ". 4-bit models usually match BF16 on reasoning and coding, but can lose more on OCR-style or exact transcription work."
    return t
}
