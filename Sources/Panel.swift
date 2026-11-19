import SwiftUI

/// The panel that opens from the menu-bar icon.
struct PanelView: View {
    @EnvironmentObject var store: Store
    @AppStorage("showModelDetails") private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            SectionHeader(title: "Activity")
            activityCard
            SectionHeader(title: "Model", trailing: store.snap.model.reachable ? runtimeShort(store.snap.model.runtime) : nil)
            modelCard
            if store.resolved.offloadConfigured {
                SectionHeader(title: "Offload")
                offloadCard
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: header

    private var header: some View {
        let kind = store.kind
        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [kind.color.opacity(0.95), kind.color.opacity(0.62)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: kind.glyph)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .pulsing(kind == .working)
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

    // MARK: model

    @ViewBuilder private var modelCard: some View {
        let m = store.snap.model
        Card {
            if !m.reachable {
                InfoRow(icon: m.modelID == nil ? "questionmark.circle" : "cloud",
                        title: m.modelID.map(shortModelName) ?? "No local model found")
                Text(m.modelID == nil ? "Looking for the model server of your default OpenClaw model."
                                      : "Model server: \(m.runtime)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    if let b = m.weightsBits { Badge(text: b >= 16 ? "BF16" : "\(Int(b))-bit") }
                    if let note = m.note { Badge(text: note) }
                }
                HStack(spacing: 7) {
                    Tile(icon: "memorychip", label: "Memory", value: m.memoryInUse.map(formatBytes) ?? "—",
                         note: m.memoryPressure.map(pressureLabel), noteColor: m.memoryPressure.map(pressureColor))
                    Tile(icon: "square.stack.3d.up", label: "KV cache", value: m.kvAllocated.map(formatBytes) ?? "—",
                         note: m.kvBits.map { $0 >= 16 ? "16-bit" : "\(Int($0))-bit" })
                    Tile(icon: "speedometer", label: "Speed",
                         value: m.decodeTokensPerSecond.map { String(format: "%.0f tok/s", $0) } ?? "—",
                         note: m.ttftSeconds.map { String(format: "%.1f s to start", $0) })
                }
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

    @ViewBuilder private func qualityRow(_ m: ModelStatus) -> some View {
        if let w = m.weightsBits {
            let weights = Quality.weights(bits: w)
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
        if !m.servedNames.isEmpty { DetailRow(label: "Served as", value: m.servedNames.joined(separator: ", ")) }
        DetailRow(label: "Weights", value: m.weightsLabel ?? "unknown")
        if let d = m.weightsOnDisk { DetailRow(label: "On disk", value: formatBytes(d)) }
        if let b = m.weightsBits { DetailRow(label: "Weights keep", value: "\(Quality.percent(Quality.weights(bits: b))) of BF16 (estimate)") }
        DetailRow(label: "KV cache", value: m.kvLabel ?? "not reported")
        if let a = m.kvAllocated {
            DetailRow(label: "KV memory", value: (m.kvActive.map { "\(formatBytes($0)) used of " } ?? "") + "\(formatBytes(a)) reserved")
        }
        if let b = m.kvBits { DetailRow(label: "KV keeps", value: "\(Quality.percent(Quality.kv(bits: b))) of BF16 (estimate)") }
        if let c = m.contextTokens { DetailRow(label: "Context", value: "\(formatInt(c)) tokens") }
        if let p = m.memoryPeak { DetailRow(label: "Peak memory", value: formatBytes(p)) }
        if let h = m.cacheHitRate { DetailRow(label: "Prompt cache", value: String(format: "%.0f%% hits", h * 100)) }
        if let sp = m.speculative { DetailRow(label: "Speculative", value: sp ? "On (draft model)" : "Off") }
        if m.weightsReleased { DetailRow(label: "Weights", value: "Released from memory") }
    }

    // MARK: offload

    private var offloadCard: some View {
        let s = store.snap, r = store.resolved
        return Card {
            if let busy = store.offloadBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.system(size: 13))
                }
            } else if s.offload.active {
                InfoRow(icon: "moon.zzz.fill", title: "Offloaded" + (s.offload.mode.map { " (\($0))" } ?? ""), tint: .indigo,
                        trailing: s.offload.purpose)
                if r.offload?.restore != nil {
                    Button { store.restore() } label: {
                        Label("Bring \(r.name) back", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                }
            } else {
                HStack(spacing: 8) {
                    if r.offload?.light != nil {
                        Button { store.offloadLight() } label: { Label("Light", systemImage: "moon") }
                            .help(r.offload?.lightLabel ?? "Release model memory; comes back in seconds")
                    }
                    if r.offload?.deep != nil {
                        Button { store.offloadDeep() } label: { Label("Deep", systemImage: "moon.zzz") }
                            .help(r.offload?.deepLabel ?? "Stop the model server; frees the most memory")
                    }
                }
                .buttonStyle(PanelButtonStyle())
                Text("Free RAM and GPU for heavy work, then bring \(r.name) back with one click.")
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
        return s < 2 ? "Updated just now" : "Updated \(formatDuration(s)) ago"
    }
}

// MARK: - helpers

/// "mlx-community/Qwen3.8-27B-4bit" -> "Qwen3.8-27B".
func shortModelName(_ id: String) -> String {
    var s = String(id.split(separator: "/").last ?? Substring(id))
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
