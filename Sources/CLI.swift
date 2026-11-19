import Foundation

/// One-shot synchronous probe for the command-line modes. With sampleSpeed, a second model sample one
/// second later gives a live tokens-per-second figure while the model is writing.
func probeOnce(_ r: Resolved, sampleSpeed: Bool = true) -> Snapshot {
    var s = Snapshot()
    s.gateway = probeGateway(r.gatewayURL, withReadiness: true)
    s.activity = s.gateway.live ? probeActivity(cli: r.cli, env: r.cliEnv) : ActivityStatus()
    s.model = probeModel(baseURL: r.providerBaseURL, configuredModel: r.primaryModel)
    s.offload = readOffloadState(r.pauseMarker)
    s.memory = systemMemory()
    if s.gateway.live, let path = sessionStorePath(cli: r.cli, env: r.cliEnv) { s.sessions = readSessions(path) ?? [] }
    s.updatedAt = Date()
    if sampleSpeed && s.model.requests.contains(where: { $0.phase == "decode" }) {
        Thread.sleep(forTimeInterval: 1)
        var next = s
        next.model = probeModel(baseURL: r.providerBaseURL, configuredModel: r.primaryModel)
        next.updatedAt = Date()
        next.liveTokensPerSecond = liveSpeed(previous: s, current: next)
        s = next
    }
    return s
}

private let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// Machine-readable status (`jarvis-switch --status --json`). Missing values are left out, never guessed.
func statusJSON(name: String, kind: Kind, _ s: Snapshot, offloadConfigured: Bool, gatewayURL: String) -> [String: Any] {
    var out: [String: Any] = [
        "name": name,
        "state": kind.title.lowercased(),
        "checkedAt": iso.string(from: s.updatedAt),
        "app": ["name": "jarvis-switch", "version": appVersion],
    ]
    var g: [String: Any] = ["url": gatewayURL, "live": s.gateway.live]
    if let v = s.gateway.version { g["version"] = v }
    if let r = s.gateway.ready { g["ready"] = r }
    if let u = s.gateway.uptimeSeconds { g["uptimeSeconds"] = Int(u) }
    if !s.gateway.failing.isEmpty { g["failing"] = s.gateway.failing }
    out["gateway"] = g

    var jobs: [String: Any] = ["known": s.activity.known]
    let now = Date()
    jobs["running"] = s.activity.running.map { ["name": $0.name, "runningSeconds": Int(now.timeIntervalSince($0.runningSince ?? now))] }
    if let n = s.activity.next, let at = n.nextRun { jobs["next"] = ["name": n.name, "at": iso.string(from: at)] }
    jobs["lastRunFailed"] = s.activity.failed.map(\.name)
    if let e = s.activity.error { jobs["error"] = e }
    out["jobs"] = jobs

    let m = s.model
    var model: [String: Any] = ["reachable": m.reachable, "runtime": m.runtime, "activeRequests": m.activeRequests]
    if let id = m.modelID { model["id"] = id }
    if !m.servedNames.isEmpty { model["servedAs"] = m.servedNames }
    var weights: [String: Any] = [:]
    if let l = m.weightsLabel { weights["label"] = l }
    if let b = m.weightsBits { weights["bits"] = b; weights["estimatedQualityPercent"] = Quality.weights(bits: b) }
    if let d = m.weightsOnDisk { weights["bytesOnDisk"] = Int(d) }
    if !weights.isEmpty { model["weights"] = weights }
    var kv: [String: Any] = [:]
    if let l = m.kvLabel { kv["label"] = l }
    if let b = m.kvBits { kv["bits"] = b; kv["estimatedQualityPercent"] = Quality.kv(bits: b) }
    if let a = m.kvAllocated { kv["reservedBytes"] = Int(a) }
    if let u = m.kvActive { kv["usedBytes"] = Int(u) }
    if !kv.isEmpty { model["kvCache"] = kv }
    if let w = m.weightsBits {
        let combined = Quality.weights(bits: w) * (m.kvBits.map { Quality.kv(bits: $0) } ?? 100) / 100
        model["estimatedQualityPercent"] = (combined * 10).rounded() / 10
        model["qualityNote"] = "Rough estimate versus BF16 from published quantization studies; not measured on this model."
    }
    if let c = m.contextTokens { model["contextTokens"] = Int(c) }
    if let v = m.memoryInUse { model["memoryBytes"] = Int(v) }
    if let v = m.memoryPeak { model["peakMemoryBytes"] = Int(v) }
    if let v = m.memoryPressure { model["memoryPressure"] = v }
    if let v = m.decodeTokensPerSecond { model["decodeTokensPerSecond"] = (v * 10).rounded() / 10 }
    if let v = m.ttftSeconds { model["timeToFirstTokenSeconds"] = (v * 100).rounded() / 100 }
    if let v = m.cacheHitRate { model["promptCacheHitRate"] = (v * 1000).rounded() / 1000 }
    if let v = m.speculative { model["speculativeDecoding"] = v }
    if m.weightsReleased { model["weightsReleased"] = true }
    if let live = s.liveTokensPerSecond { model["liveTokensPerSecond"] = (live * 10).rounded() / 10 }
    if let f = m.processFootprint { model["processMemoryBytes"] = Int(f) }
    out["model"] = model

    if let c = contextNow(s, lastLive: [:]) {
        var ctx: [String: Any] = ["session": c.label, "phase": c.phase, "live": c.live]
        if let t = c.tokens { ctx["tokens"] = Int(t) }
        if let w = c.window { ctx["windowTokens"] = Int(w) }
        if let t = c.tokens, let w = c.window, w > 0 { ctx["percent"] = (t / w * 1000).rounded() / 10 }
        if let n = c.compactions { ctx["compactions"] = n; ctx["compacted"] = n > 0 }
        out["context"] = ctx
    }
    if let mem = s.memory {
        var mm: [String: Any] = ["totalBytes": Int(mem.total), "usedBytes": Int(mem.used), "freeBytes": Int(mem.free)]
        if let j = m.processFootprint ?? m.memoryInUse { mm["assistantBytes"] = Int(min(j, mem.used)) }
        out["memory"] = mm
    }

    var off: [String: Any] = ["configured": offloadConfigured, "active": s.offload.active]
    if let v = s.offload.mode { off["mode"] = v }
    if let v = s.offload.purpose { off["purpose"] = v }
    out["offload"] = off
    return out
}

func jsonString(_ o: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
    return String(data: d, encoding: .utf8) ?? "{}"
}

/// Human-readable status (`jarvis-switch --status`).
func statusText(name: String, kind: Kind, _ s: Snapshot, offloadConfigured: Bool, gatewayURL: String) -> String {
    var out: [String] = []
    out.append("\(name): \(kind.title)")
    if s.gateway.live {
        var g = "  OpenClaw \(s.gateway.version ?? "")"
        if let up = s.gateway.uptimeSeconds { g += " · up \(formatDuration(up))" }
        if let ready = s.gateway.ready { g += ready ? " · ready" : " · NOT ready" }
        out.append(g)
    } else {
        out.append("  OpenClaw gateway not running at \(gatewayURL)")
    }
    for jb in s.activity.running { out.append("  Running: \(jb.name) (\(formatDuration(Date().timeIntervalSince(jb.runningSince!))))") }
    if s.activity.known && s.activity.running.isEmpty { out.append("  Nothing running") }
    if let nx = s.activity.next, let at = nx.nextRun { out.append("  Next: \(nx.name) at \(formatClock(at))") }
    if !s.activity.failed.isEmpty { out.append("  Last run failed: \(s.activity.failed.map(\.name).joined(separator: ", "))") }
    if let e = s.activity.error { out.append("  Jobs: \(e)") }
    if let c = contextNow(s, lastLive: [:]) {
        var line = "Context (\(c.label)): "
        if let t = c.tokens, let w = c.window { line += "\(formatTokens(t)) of \(formatTokens(w)) tokens (\(Int((t / max(w, 1) * 100).rounded()))%)" }
        else if let t = c.tokens { line += "\(formatTokens(t)) tokens" } else { line += "size unknown until the next model call" }
        line += " · \(c.phase)"
        if let n = c.compactions { line += n == 0 ? " · not compacted" : " · compacted \(n)×" }
        out.append(line)
    }
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
        if let p = m.memoryPressure { out.append("  Memory pressure: \(p)") }
        if let live = s.liveTokensPerSecond {
            out.append(String(format: "  Speed: %.0f tok/s live", live))
        } else if let tps = m.decodeTokensPerSecond {
            out.append(String(format: "  Speed: %.0f tok/s typical", tps) + (m.ttftSeconds.map { String(format: " · %.1f s to first token", $0) } ?? ""))
        }
    } else {
        out.append("  \(m.modelID.map { "\($0) · " } ?? "")\(m.runtime)")
    }
    if let mem = s.memory {
        var line = "Memory: \(formatBytes(mem.free)) free of \(formatBytes(mem.total))"
        if let j = m.processFootprint ?? m.memoryInUse { line += " · \(name) \(formatBytes(min(j, mem.used))) · other \(formatBytes(max(0, mem.used - min(j, mem.used))))" }
        out.append(line)
    }
    if offloadConfigured {
        out.append("Pause: " + (s.offload.active ? "paused" + (s.offload.mode.map { " (\($0))" } ?? "") : "available"))
    }
    return out.joined(separator: "\n")
}
