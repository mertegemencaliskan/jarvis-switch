import Darwin
import Foundation
import SQLite3

// MARK: - OpenClaw sessions (context size and compactions)

/// One OpenClaw conversation session, as stored by the gateway.
struct SessionInfo {
    let key: String
    let label: String
    let running: Bool
    let totalTokens: Double?     // context used at the end of the last model call
    let contextTokens: Double?   // the session's context window
    let compactions: Int
    let updatedAt: Date
}

/// Where OpenClaw keeps the agent's session store. Asked once from `openclaw sessions --json` (its "path"),
/// so it follows whatever state directory the user's OpenClaw runs with.
func sessionStorePath(cli: String?, env: [String: String]) -> String? {
    guard let cli = cli else { return nil }
    let r = runCommand([cli, "sessions", "--json", "--limit", "1"], timeout: 20, env: env)
    guard let o = lastJSONObject(r.output), let p = o["path"] as? String, FileManager.default.fileExists(atPath: p) else { return nil }
    return p
}

/// Reads recent sessions straight from the store, read-only (fast enough for a 1-second refresh).
/// Returns nil when the store layout is not one this version understands; the panel then hides the details.
func readSessions(_ path: String, limit: Int = 30) -> [SessionInfo]? {
    var db: OpaquePointer?
    let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?mode=ro"
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        sqlite3_close(db); return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 200)
    var stmt: OpaquePointer?
    let sql = "SELECT session_key, status, entry_json, updated_at FROM session_nodes ORDER BY updated_at DESC LIMIT \(limit)"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    var out: [SessionInfo] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let status = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
        let entry = sqlite3_column_text(stmt, 2).map { parseJSON(Data(String(cString: $0).utf8)) } ?? nil
        let updated = Double(sqlite3_column_int64(stmt, 3)) / 1000
        let entryStatus = (j(entry, "status") as? String) ?? status
        let finished = ["done", "failed", "killed", "timeout"].contains(entryStatus ?? "")
        let running = !finished && (j(entry, "activeWriterRunId") as? String) != nil
        var label = (j(entry, "label") as? String) ?? ""
        if label.hasPrefix("Automation: ") { label = String(label.dropFirst("Automation: ".count)) }
        if label.isEmpty { label = key.hasSuffix(":main") ? "Main chat" : (key.split(separator: ":").dropFirst(2).first.map(String.init) ?? key) }
        let fresh = (j(entry, "totalTokensFresh") as? Bool) ?? true
        out.append(SessionInfo(key: key, label: label, running: running,
                               totalTokens: fresh ? num(j(entry, "totalTokens")) : nil,
                               contextTokens: num(j(entry, "contextTokens")),
                               compactions: Int(num(j(entry, "compactionCount")) ?? 0),
                               updatedAt: Date(timeIntervalSince1970: updated)))
    }
    return out
}

/// What the Context card shows: the session that is running now, otherwise the main chat.
struct ContextNow {
    let label: String
    let tokens: Double?
    let window: Double?
    let compactions: Int?
    let phase: String          // "Reading prompt 61%", "Writing · 85 tokens", "Between steps", "Idle"
    let live: Bool
}

func contextNow(_ s: Snapshot, lastLive: [String: Double]) -> ContextNow? {
    let running = s.sessions.first { $0.running }
    let target = running ?? s.sessions.first { $0.key.hasSuffix(":main") } ?? s.sessions.first
    let req = s.model.requests.max { $0.contextTokens < $1.contextTokens }
    if target == nil && req == nil { return nil }
    let window = target?.contextTokens ?? s.model.contextTokens
    var phase = running != nil ? "Between steps" : "Idle"
    var tokens = target?.totalTokens
    if let key = target?.key, running != nil, tokens == nil { tokens = lastLive[key] }
    if let r = req {
        tokens = r.contextTokens
        if r.phase == "prefill", r.promptTokens > 0 {
            phase = "Reading prompt \(Int(min(100, r.promptProcessed / r.promptTokens * 100)))%"
        } else {
            phase = "Writing · \(formatInt(r.generatedTokens)) tokens"
        }
    }
    return ContextNow(label: target?.label ?? "Model", tokens: tokens, window: window,
                      compactions: target?.compactions, phase: phase, live: req != nil)
}

func formatTokens(_ t: Double) -> String {
    if t >= 100_000 { return String(format: "%.0fK", t / 1000) }
    if t >= 1000 { return String(format: "%.1fK", t / 1000) }
    return String(Int(t))
}

// MARK: - Mac memory

struct SystemMemory {
    let total: Double
    let used: Double
    var free: Double { max(0, total - used) }
}

/// Memory in use the way Activity Monitor counts it: app memory + wired + compressed.
func systemMemory() -> SystemMemory? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return nil }
    let page = Double(vm_kernel_page_size)
    let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
    let used = (max(0, app) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    return SystemMemory(total: Double(ProcessInfo.processInfo.physicalMemory), used: used)
}
