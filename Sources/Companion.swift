import Foundation
import SQLite3

/// The companion uses the menu bar's actual model sample while that app is publishing.
struct CompanionModelSample: Codable {
    let sampledAt: Date
    let model: ModelStatus
    let active: ActiveModel?
    let speed: Double?

    private static let installed = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/jarvis_switch_mobile", isDirectory: true)
    private static let directory = installed.appendingPathComponent("state", isDirectory: true)
    private static let file = directory.appendingPathComponent("menubar_sample.json")

    static func publish(_ snapshot: Snapshot) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: installed.appendingPathComponent("server.py").path),
              snapshot.updatedAt != .distantPast else { return }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let sample = CompanionModelSample(sampledAt: snapshot.updatedAt, model: snapshot.model,
                                             active: snapshot.active, speed: snapshot.liveTokensPerSecond)
            try JSONEncoder().encode(sample).write(to: file, options: .atomic)
        } catch {
            // The companion can probe the same local model directly if the shared sample is unavailable.
        }
    }

    static func latest(at now: Date) -> CompanionModelSample? {
        guard let data = try? Data(contentsOf: file),
              let sample = try? JSONDecoder().decode(Self.self, from: data),
              (0...3).contains(now.timeIntervalSince(sample.sampledAt)) else { return nil }
        return sample
    }
}

private struct CompanionSchedule {
    var activity = ActivityStatus()
    var rows: [[String: Any]] = []
}

/// Read the scheduler's saved definition and runtime state in one SQLite snapshot.
/// The projection omits job payloads, destinations, diagnostics and identifiers.
private func companionSchedule(_ path: String) -> CompanionSchedule? {
    var db: OpaquePointer?
    let url = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(url, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }
    sqlite3_busy_timeout(db, 100)

    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let sql = """
        SELECT name, enabled,
               json_extract(job_json, '$.schedule.kind'),
               json_extract(job_json, '$.schedule.expr'),
               json_extract(job_json, '$.schedule.tz'),
               json_extract(job_json, '$.schedule.everyMs'),
               json_extract(state_json, '$.nextRunAtMs') AS nextRunAtMs,
               json_extract(state_json, '$.runningAtMs'),
               json_extract(state_json, '$.lastRunAtMs'),
               coalesce(json_extract(state_json, '$.lastRunStatus'), json_extract(state_json, '$.lastStatus'))
        FROM cron_jobs
        WHERE store_key = ?
        ORDER BY nextRunAtMs IS NULL, nextRunAtMs, name COLLATE NOCASE
        """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    let stateDir = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
    let key = stateDir.appendingPathComponent("cron/jobs.json").path
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard sqlite3_bind_text(stmt, 1, key, -1, transient) == SQLITE_OK else { return nil }

    func string(_ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }
    func milliseconds(_ index: Int32) -> Int64? {
        let value = sqlite3_column_int64(stmt, index)
        return value > 0 ? value : nil
    }
    func date(_ ms: Int64?) -> Date? {
        ms.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    var schedule = CompanionSchedule()
    let runStates = Set(["ok", "error", "failed", "skipped", "cancelled", "timeout"])
    var result = sqlite3_step(stmt)
    while result == SQLITE_ROW {
        let name = String((string(0) ?? "Scheduled task").prefix(160))
        let enabled = sqlite3_column_int(stmt, 1) != 0
        let kind = string(2) ?? "unknown"
        let next = milliseconds(6), running = milliseconds(7)
        let lastStatus = string(9)
        schedule.activity.jobs.append(Job(name: name, runningSince: date(running), nextRun: date(next),
                                          lastFailed: lastStatus == "error" || lastStatus == "failed", enabled: enabled))
        // Completed or disabled one-offs aren't part of the current schedule.
        if kind != "at" || (enabled && (next != nil || running != nil)) {
            var row: [String: Any] = ["name": name, "enabled": enabled, "kind": kind]
            if let expr = string(3) { row["expression"] = expr }
            if let timezone = string(4) { row["timezone"] = timezone }
            if let every = milliseconds(5) { row["everyMs"] = every }
            if let next, enabled { row["nextRunAtMs"] = next }
            if let running { row["runningAtMs"] = running }
            if let last = milliseconds(8) { row["lastRunAtMs"] = last }
            if let lastStatus, runStates.contains(lastStatus) { row["lastRunStatus"] = lastStatus }
            schedule.rows.append(row)
        }
        result = sqlite3_step(stmt)
    }
    guard result == SQLITE_DONE else { return nil }
    schedule.activity.known = true
    return schedule
}

/// One line per second for the companion's local web server. This path performs only passive probes.
func streamCompanionStatus(cronDB: String, sessionDB: String) {
    var resolved = Resolved.resolve(AppConfig.load())
    var configDate = AppConfig.modificationDate()
    var previous = Snapshot()
    var readinessAt = -Double.infinity
    var lastLive: [String: Double] = [:]
    let process = ProcessInfo.processInfo
    var nextTick = process.systemUptime

    while true {
        let tick = process.systemUptime
        let modified = AppConfig.modificationDate()
        if modified != configDate {
            configDate = modified
            resolved = Resolved.resolve(AppConfig.load())
        }
        let withReadiness = !previous.gateway.live || tick - readinessAt >= 15
        let schedule = companionSchedule(cronDB)
        var snapshot = Snapshot()
        snapshot.gateway = probeGateway(resolved.gatewayURL, withReadiness: withReadiness)
        if withReadiness {
            readinessAt = tick
        } else if snapshot.gateway.live {
            snapshot.gateway.ready = previous.gateway.ready
            snapshot.gateway.failing = previous.gateway.failing
        }
        if snapshot.gateway.live {
            snapshot.activity = schedule?.activity ?? ActivityStatus()
            snapshot.sessions = readSessions(sessionDB) ?? []
        }
        let menuBar = CompanionModelSample.latest(at: Date())
        if let menuBar {
            snapshot.active = menuBar.active
            snapshot.model = menuBar.model
        } else {
            let active = activeModel(snapshot.sessions, resolved)
            snapshot.active = active
            snapshot.model = probeModel(baseURL: active.baseURL, configuredModel: active.alias)
        }
        snapshot.offload = readOffloadState(resolved.pauseMarker)
        snapshot.memory = systemMemory()
        snapshot.updatedAt = Date()
        if let menuBar {
            snapshot.liveTokensPerSecond = menuBar.speed
        } else {
            snapshot.liveTokensPerSecond = liveSpeed(previous: previous, current: snapshot)
        }
        let running = snapshot.sessions.filter(\.running)
        lastLive = lastLive.filter { key, _ in running.contains { $0.key == key } }
        if running.count == 1, let request = snapshot.model.requests.max(by: { $0.contextTokens < $1.contextTokens }) {
            lastLive[running[0].key] = request.contextTokens
        }

        let kind = Kind.from(snapshot, busy: false)
        var status = statusJSON(name: resolved.name, kind: kind, snapshot, offloadConfigured: false,
                                gatewayURL: "", lastLive: lastLive)
        if var gateway = status["gateway"] as? [String: Any] {
            gateway.removeValue(forKey: "url")
            gateway.removeValue(forKey: "failing")
            status["gateway"] = gateway
        }
        if var context = status["context"] as? [String: Any] {
            context["session"] = running.first.map { activeSession in
                snapshot.activity.running.first { $0.name == activeSession.label }?.name ?? "Active session"
            } ?? "Main chat"
            status["context"] = context
        }
        status.removeValue(forKey: "offload")
        status["schedule"] = schedule?.rows
        status["timezone"] = TimeZone.current.identifier
        status["sampledAtMs"] = Int64(snapshot.updatedAt.timeIntervalSince1970 * 1000)
        status["modelSampledAtMs"] = Int64((menuBar?.sampledAt ?? snapshot.updatedAt).timeIntervalSince1970 * 1000)
        if var data = try? JSONSerialization.data(withJSONObject: status) {
            data.append(0x0a)
            FileHandle.standardOutput.write(data)
        }
        previous = snapshot
        let finished = process.systemUptime
        nextTick = max(nextTick + 1, finished)
        Thread.sleep(forTimeInterval: nextTick - finished)
    }
}
