import Foundation

/// Optional 24h learning, benchmark and auto-cleanup summary read from local assistant logs.
struct LearningStatus: Equatable {
    var windowHours: Int = 24
    var totalRuns: Int = 0
    var cleanPercent: Int = 100
    var frictionRuns: Int = 0
    var failedRuns: Int = 0
    var evalPassed: Int?
    var evalTotal: Int?
    var lastCleanupDate: String?
    var lastCleanupCount: Int = 0
    var projectsTracked: Int = 0
}

/// Read-only probe for local learning and hygiene telemetry. Returns nil when logs/run_metrics.jsonl
/// is absent so standard OpenClaw setups stay clean without extra configuration.
func probeLearning(metricsDir: String?) -> LearningStatus? {
    guard let base = metricsDir, !base.isEmpty else { return nil }
    let fm = FileManager.default
    let metricsPath = (base as NSString).appendingPathComponent("logs/run_metrics.jsonl")
    guard fm.fileExists(atPath: metricsPath) else { return nil }

    let cutoffMs = (Date().timeIntervalSince1970 - 24 * 3600) * 1000
    var total = 0
    var friction = 0
    var failed = 0

    if let text = try? String(contentsOfFile: metricsPath, encoding: .utf8) {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let rec = parseJSON(Data(trimmed.utf8)) as? [String: Any] else { continue }
            guard let endMs = num(rec["end_ms"]), endMs >= cutoffMs else { continue }
            total += 1
            if (num(rec["friction_score"]) ?? 0) > 0 { friction += 1 }
            if let reasons = rec["stop_reasons"] as? [String],
               reasons.contains(where: { $0 == "error" || $0 == "aborted" }) {
                failed += 1
            }
        }
    }

    var lastDate: String? = nil
    var lastCount = 0
    let receiptsPath = (base as NSString).appendingPathComponent("logs/cleanup_receipts.jsonl")
    if let text = try? String(contentsOfFile: receiptsPath, encoding: .utf8) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var byDate: [String: Int] = [:]
        for raw in lines.suffix(500) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let rec = parseJSON(Data(trimmed.utf8)) as? [String: Any],
                  let d = rec["date"] as? String, !d.isEmpty else { continue }
            byDate[d, default: 0] += 1
        }
        if let maxDate = byDate.keys.max() {
            lastDate = maxDate
            lastCount = byDate[maxDate] ?? 0
        }
    }

    var projectsTracked = 0
    let regPath = (base as NSString).appendingPathComponent("state/cleanup_registry.json")
    if let data = fm.contents(atPath: regPath),
       let reg = parseJSON(data) as? [String: Any],
       let projects = reg["projects"] as? [String: Any] {
        projectsTracked = projects.count
    }

    var evalPassed: Int? = nil
    var evalTotal: Int? = nil
    let evalPath = (base as NSString).appendingPathComponent("logs/eval_history.jsonl")
    if let text = try? String(contentsOfFile: evalPath, encoding: .utf8) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for raw in lines.suffix(50).reversed() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let rec = parseJSON(Data(trimmed.utf8)) as? [String: Any] else { continue }
            if (rec["mode"] as? String) == "full", (rec["note"] as? String) != "reverted" {
                evalPassed = num(rec["passed"]).map(Int.init)
                evalTotal = num(rec["total"]).map(Int.init)
                break
            }
        }
    }

    let cleanPercent = total > 0 ? Int((Double(total - friction) * 100.0 / Double(total)).rounded()) : 100
    return LearningStatus(
        windowHours: 24,
        totalRuns: total,
        cleanPercent: cleanPercent,
        frictionRuns: friction,
        failedRuns: failed,
        evalPassed: evalPassed,
        evalTotal: evalTotal,
        lastCleanupDate: lastDate,
        lastCleanupCount: lastCount,
        projectsTracked: projectsTracked
    )
}
