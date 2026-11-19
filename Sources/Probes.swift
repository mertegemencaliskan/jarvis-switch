import Foundation

// MARK: - OpenClaw gateway (unauthenticated health probes)

struct GatewayStatus {
    var live = false
    var ready: Bool?
    var failing: [String] = []
    var version: String?
    var uptimeSeconds: Double?
}

func probeGateway(_ base: String, withReadiness: Bool) -> GatewayStatus {
    var g = GatewayStatus()
    let start = httpGET(base + "/startupz", timeout: 2)
    if start.status == 200, let o = parseJSON(start.data) {
        g.live = true
        g.version = j(o, "version") as? String
        g.uptimeSeconds = num(j(o, "uptimeMs")).map { $0 / 1000 }
    } else {
        let h = httpGET(base + "/healthz", timeout: 2)
        g.live = h.status == 200 && (j(parseJSON(h.data), "ok") as? Bool) == true
    }
    if g.live && withReadiness {
        let r = httpGET(base + "/readyz", timeout: 3)
        if let o = parseJSON(r.data) {
            g.ready = (j(o, "ready") as? Bool) ?? (r.status == 200)
            g.failing = (j(o, "failing") as? [Any])?.compactMap { $0 as? String } ?? []
        }
    }
    return g
}

// MARK: - Scheduled jobs (openclaw cron list --json; ~1 s, polled slowly)

struct Job {
    let name: String
    let runningSince: Date?
    let nextRun: Date?
    let lastFailed: Bool
    let enabled: Bool
}

struct ActivityStatus {
    var known = false
    var error: String?
    var jobs: [Job] = []
    var running: [Job] { jobs.filter { $0.runningSince != nil } }
    /// Jobs whose last run failed and that are not being re-run right now.
    var failed: [Job] { jobs.filter { $0.enabled && $0.lastFailed && $0.runningSince == nil } }
    var next: Job? { jobs.filter { $0.enabled && $0.nextRun != nil }.min { $0.nextRun! < $1.nextRun! } }
}

func probeActivity(cli: String?, env: [String: String]) -> ActivityStatus {
    var a = ActivityStatus()
    guard let cli = cli else { a.error = "openclaw CLI not found (set openclawCLI in config)"; return a }
    let r = runCommand([cli, "cron", "list", "--json"], timeout: 20, env: env)
    guard let o = lastJSONObject(r.output), let jobs = o["jobs"] as? [[String: Any]] else {
        a.error = r.code == 0 ? "unexpected cron output" : "cron list failed"
        return a
    }
    a.known = true
    a.jobs = jobs.map { jb in
        let st = jb["state"] as? [String: Any]
        let date: (Any?) -> Date? = { v in num(v).map { Date(timeIntervalSince1970: $0 / 1000) } }
        let last = (st?["lastRunStatus"] as? String) ?? (st?["lastStatus"] as? String)
        return Job(name: (jb["name"] as? String) ?? (jb["id"] as? String) ?? "job",
                   runningSince: date(st?["runningAtMs"]), nextRun: date(st?["nextRunAtMs"]),
                   lastFailed: last == "error" || last == "failed", enabled: (jb["enabled"] as? Bool) ?? true)
    }
    return a
}

// MARK: - Model server (Splash, LM Studio, Ollama, or any OpenAI-compatible server)

struct ModelStatus {
    var reachable = false
    var runtime = "unknown"
    var modelID: String?
    var servedNames: [String] = []
    var weightsLabel: String?
    var weightsBits: Double?
    var weightsOnDisk: Double?
    var kvLabel: String?
    var kvBits: Double?
    var kvAllocated: Double?
    var kvActive: Double?
    var contextTokens: Double?
    var memoryInUse: Double?
    var memoryPeak: Double?
    var memoryPressure: String?
    var activeRequests = 0
    var ttftSeconds: Double?
    var decodeTokensPerSecond: Double?
    var cacheHitRate: Double?
    var speculative: Bool?
    var weightsReleased = false
    var note: String?
    /// In-flight requests (Splash reports these), for live context size and live speed.
    var requests: [LiveRequest] = []
    /// What the model server process takes in RAM (Activity Monitor's "Memory"), when known.
    var processFootprint: Double?
    var draftAcceptRate: Double?
}

struct LiveRequest {
    let id: Int
    let phase: String          // "prefill" (reading the prompt) or "decode" (writing)
    let promptTokens: Double
    let promptProcessed: Double
    let generatedTokens: Double
    var contextTokens: Double { promptTokens + generatedTokens }
}

/// Per-process facts that never change while the server runs (model folder, quantization, served names).
/// Cached by pid so a 1-second refresh does not spawn `ps` or re-read files every time.
private struct StaticModelFacts {
    var weightsLabel: String?
    var weightsBits: Double?
    var weightsOnDisk: Double?
    var speculative: Bool?
    var servedNames: [String] = []
}
private var staticFacts: [Int: StaticModelFacts] = [:]
private let staticFactsLock = NSLock()

func modelRoot(_ baseURL: String) -> String {
    var s = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if s.hasSuffix("/v1") { s.removeLast(3) }
    return s
}

func probeModel(baseURL: String?, configuredModel: String?) -> ModelStatus {
    var m = ModelStatus()
    guard let baseURL = baseURL else {
        m.runtime = "cloud or not configured"
        m.modelID = configuredModel
        return m
    }
    let root = modelRoot(baseURL)
    let wanted = configuredModel?.split(separator: "/", maxSplits: 1).last.map(String.init)

    // Splash (MLX server): rich /status document.
    let st = httpGET(root + "/status", timeout: 2)
    if st.status == 200, let o = parseJSON(st.data) as? [String: Any], o["instance"] != nil, o["schema_version"] != nil {
        fillSplash(&m, o, root: root)
        return m
    }
    // LM Studio native REST API.
    let lms = httpGET(root + "/api/v0/models", timeout: 2)
    if lms.status == 200, let arr = j(parseJSON(lms.data), "data") as? [[String: Any]], arr.contains(where: { $0["state"] != nil }) {
        m.reachable = true
        m.runtime = "LM Studio"
        let loaded = arr.filter { ($0["state"] as? String) == "loaded" && ($0["type"] as? String) != "embeddings" }
        let pick = loaded.first { ($0["id"] as? String) == wanted } ?? loaded.first
        m.modelID = (pick?["id"] as? String) ?? wanted
        if let q = pick?["quantization"] as? String { m.weightsLabel = q; m.weightsBits = Quality.bits(fromLabel: q) }
        m.contextTokens = num(pick?["loaded_context_length"]) ?? num(pick?["max_context_length"])
        m.kvLabel = "not reported by LM Studio"
        if pick == nil { m.note = "no model loaded" }
        return m
    }
    // Ollama.
    let ol = httpGET(root + "/api/ps", timeout: 2)
    if ol.status == 200, let models = j(parseJSON(ol.data), "models") as? [[String: Any]] {
        m.reachable = true
        m.runtime = "Ollama"
        let pick = models.first { ($0["name"] as? String) == wanted || ($0["model"] as? String) == wanted } ?? models.first
        m.modelID = (pick?["name"] as? String) ?? wanted
        if let q = j(pick, "details", "quantization_level") as? String { m.weightsLabel = q; m.weightsBits = Quality.bits(fromLabel: q) }
        m.memoryInUse = num(pick?["size_vram"]) ?? num(pick?["size"])
        m.processFootprint = num(pick?["size"])
        m.contextTokens = num(pick?["context_length"])
        m.kvLabel = ProcessInfo.processInfo.environment["OLLAMA_KV_CACHE_TYPE"] ?? "f16 (Ollama default unless OLLAMA_KV_CACHE_TYPE is set)"
        m.kvBits = Quality.bits(fromLabel: m.kvLabel!)
        if pick == nil { m.note = "no model loaded" }
        return m
    }
    // Generic OpenAI-compatible server.
    let v1 = httpGET(root + "/v1/models", timeout: 2)
    if v1.status == 200, let arr = j(parseJSON(v1.data), "data") as? [[String: Any]] {
        m.reachable = true
        m.runtime = "OpenAI-compatible server"
        m.servedNames = arr.compactMap { $0["id"] as? String }
        m.modelID = wanted ?? m.servedNames.first
        if let id = m.modelID { m.weightsBits = Quality.bits(fromLabel: id); m.weightsLabel = m.weightsBits.map { "\(Int($0))-bit (from model name)" } }
        return m
    }
    m.runtime = "not reachable at \(root)"
    return m
}

private func fillSplash(_ m: inout ModelStatus, _ o: [String: Any], root: String) {
    m.reachable = true
    m.runtime = "Splash (MLX)"
    m.modelID = j(o, "instance", "model") as? String
    m.contextTokens = num(j(o, "maximum_context_tokens"))
    m.activeRequests = (j(o, "active_requests") as? [Any])?.count ?? 0
    for k in ["prefilling", "decoding", "queued"] { m.activeRequests = max(m.activeRequests, Int(num(j(o, "scheduler", k)) ?? 0)) }
    let kvFormat = j(o, "identity", "kv", "format") as? String
    let kvQuant = j(o, "identity", "kv", "quantization") as? String
    if let f = kvFormat {
        // "symmetric_int8" + "float32" -> "int8 (symmetric, f32 scales)"
        let q = (kvQuant ?? f).lowercased()
        var parts: [String] = []
        if q.contains("symmetric") && !q.contains("asymmetric") { parts.append("symmetric") }
        if q.contains("asymmetric") { parts.append("asymmetric") }
        if let scale = j(o, "identity", "kv", "scale_type") as? String {
            parts.append(scale.replacingOccurrences(of: "float", with: "f") + " scales")
        }
        m.kvLabel = f + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))")
        m.kvBits = Quality.bits(fromLabel: f)
    }
    m.kvAllocated = num(j(o, "kv", "allocated_bytes"))
    m.kvActive = num(j(o, "kv", "active_bytes"))
    m.memoryInUse = num(j(o, "memory_actual", "current_bytes"))
    m.memoryPeak = num(j(o, "memory_actual", "peak_bytes"))
    m.memoryPressure = j(o, "memory_governor", "system_pressure") as? String ?? j(o, "memory_pressure") as? String
    m.ttftSeconds = num(j(o, "metrics", "ttft_ms", "p50")).map { $0 / 1000 }
    if let itl = num(j(o, "metrics", "itl_ms", "p50")), itl > 0 { m.decodeTokensPerSecond = 1000 / itl }
    m.cacheHitRate = num(j(o, "cache", "hit_rate"))
    m.weightsReleased = (j(o, "weights", "released") as? Bool) == true
    m.processFootprint = num(j(o, "memory_governor", "host_telemetry", "phys_footprint_bytes"))
    m.requests = ((j(o, "active_requests") as? [[String: Any]]) ?? []).map { r in
        LiveRequest(id: Int(num(r["id"]) ?? 0), phase: (r["phase"] as? String) ?? "",
                    promptTokens: num(r["prompt_tokens"]) ?? 0, promptProcessed: num(r["prompt_processed"]) ?? 0,
                    generatedTokens: num(r["generated_tokens"]) ?? 0)
    }
    guard let pid = num(j(o, "instance", "pid")).map(Int.init) else { return }
    staticFactsLock.lock()
    let cached = staticFacts[pid]
    staticFactsLock.unlock()
    let facts = cached ?? loadSplashFacts(pid: pid, root: root, modelID: m.modelID)
    if cached == nil {
        staticFactsLock.lock(); staticFacts = [pid: facts]; staticFactsLock.unlock()
    }
    m.weightsLabel = facts.weightsLabel
    m.weightsBits = facts.weightsBits ?? m.modelID.flatMap { Quality.bits(fromLabel: $0) }
    m.weightsOnDisk = facts.weightsOnDisk
    m.speculative = facts.speculative
    m.servedNames = facts.servedNames.filter { $0 != m.modelID }
}

private func loadSplashFacts(pid: Int, root: String, modelID: String?) -> StaticModelFacts {
    var f = StaticModelFacts()
    if let names = j(parseJSON(httpGET(root + "/v1/models", timeout: 2).data), "data") as? [[String: Any]] {
        f.servedNames = names.compactMap { $0["id"] as? String }
    }
    // Weight quantization comes from the model folder's config.json (MLX "quantization" block).
    // Splash runs `... -m server.server <resolved-model-dir> --flags`; `splash serve` itself takes --model-dir.
    let cmd = runCommand(["/bin/ps", "-o", "command=", "-p", String(pid)], timeout: 3).output
    var dir: String?
    for marker in ["server.server ", "--model-dir "] {
        if let r = cmd.range(of: marker) {
            var d = String(cmd[r.upperBound...])
            if let next = d.range(of: " --") { d = String(d[..<next.lowerBound]) }
            dir = d.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
    }
    var tmp = ModelStatus()
    if let dir = dir {
        fillWeightsFromDir(&tmp, dir)
        f.speculative = cmd.contains("--draft-model") || ((try? FileManager.default.contentsOfDirectory(atPath: dir + "/draft"))?.isEmpty == false)
    } else {
        f.speculative = cmd.contains("--draft-model") ? true : nil
    }
    f.weightsLabel = tmp.weightsLabel
    f.weightsBits = tmp.weightsBits
    f.weightsOnDisk = tmp.weightsOnDisk
    return f
}

/// Reads {"quantization": {"bits": 4, "group_size": 64, "mode": "affine"}} and sums the safetensors size.
func fillWeightsFromDir(_ m: inout ModelStatus, _ dir: String) {
    let fm = FileManager.default
    let cfg = parseJSON(fm.contents(atPath: dir + "/config.json"))
    let q = (j(cfg, "quantization") ?? j(cfg, "quantization_config")) as? [String: Any]
    if let bits = num(q?["bits"]) {
        m.weightsBits = bits
        var label = "\(Int(bits))-bit"
        if let mode = q?["mode"] as? String { label += " \(mode)" }
        if let g = num(q?["group_size"]) { label += ", group size \(Int(g))" }
        m.weightsLabel = label
    } else if q == nil, cfg != nil {
        m.weightsLabel = (j(cfg, "torch_dtype") as? String) ?? "unquantized"
        m.weightsBits = 16
    }
    // Weights may sit in the directory itself or in target/ (Splash), often as symlinks: measure the real files.
    var total = 0.0
    for sub in ["", "/target"] {
        let d = dir + sub
        guard let files = try? fm.contentsOfDirectory(atPath: d) else { continue }
        for f in files where f.hasSuffix(".safetensors") || f.hasSuffix(".gguf") {
            let real = (d + "/" + f as NSString).resolvingSymlinksInPath
            if let n = (try? fm.attributesOfItem(atPath: real)[.size]) as? NSNumber { total += n.doubleValue }
        }
        if total > 0 { break }
    }
    if total > 0 { m.weightsOnDisk = total }
}

// MARK: - Offload state file

struct OffloadState {
    var active = false
    var mode: String?
    var purpose: String?
}

func readOffloadState(_ path: String?) -> OffloadState {
    guard let p = path.map(expandPath), let d = FileManager.default.contents(atPath: p) else { return OffloadState() }
    let o = parseJSON(d)
    return OffloadState(active: true, mode: j(o, "mode") as? String, purpose: j(o, "purpose") as? String)
}

// MARK: - Update check (GitHub releases, at most daily)

func latestReleaseTag(repo: String) -> String? {
    let r = httpGET("https://api.github.com/repos/\(repo)/releases/latest", timeout: 6)
    guard r.status == 200 else { return nil }
    return (j(parseJSON(r.data), "tag_name") as? String).map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
}

func isNewer(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").compactMap { Int($0) }, pb = b.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}
