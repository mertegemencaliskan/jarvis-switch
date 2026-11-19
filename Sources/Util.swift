import Foundation

/// Read a nested value from decoded JSON: j(obj, "a", "b", 0, "c").
func j(_ value: Any?, _ path: Any...) -> Any? {
    var cur = value
    for key in path {
        if let k = key as? String { cur = (cur as? [String: Any])?[k] }
        else if let i = key as? Int, let arr = cur as? [Any], i >= 0, i < arr.count { cur = arr[i] }
        else { return nil }
    }
    return cur
}

func num(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

func parseJSON(_ data: Data?) -> Any? {
    guard let data = data, !data.isEmpty else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

/// Small synchronous GET with a short timeout. Called from background queues only.
func httpGET(_ url: String, timeout: TimeInterval = 3) -> (status: Int, data: Data?) {
    guard let u = URL(string: url) else { return (0, nil) }
    var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    req.httpMethod = "GET"
    let sem = DispatchSemaphore(value: 0)
    var result: (Int, Data?) = (0, nil)
    let cfg = URLSessionConfiguration.ephemeral
    cfg.connectionProxyDictionary = [:]   // local services only; never through a proxy
    cfg.timeoutIntervalForRequest = timeout
    let session = URLSession(configuration: cfg)
    session.dataTask(with: req) { data, resp, _ in
        result = ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    session.invalidateAndCancel()
    return result
}

/// Run a command (argv, no shell) with a timeout; returns (exit code, stdout+stderr).
func runCommand(_ argv: [String], timeout: TimeInterval = 20, env: [String: String] = [:]) -> (code: Int32, output: String) {
    guard let exe = argv.first else { return (-1, "empty command") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = Array(argv.dropFirst())
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    var collected = Data()
    let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        lock.lock(); collected.append(d); lock.unlock()
    }
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning { p.terminate(); usleep(200_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
    p.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil
    let rest = pipe.fileHandleForReading.readDataToEndOfFile()
    lock.lock(); collected.append(rest); lock.unlock()
    return (p.terminationStatus, String(data: collected, encoding: .utf8) ?? "")
}

/// The last JSON object printed by a command (tools often log lines before it).
func lastJSONObject(_ text: String) -> [String: Any]? {
    if let whole = parseJSON(Data(text.utf8)) as? [String: Any] { return whole }
    for line in text.split(separator: "\n").reversed() {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("{"), let o = parseJSON(Data(t.utf8)) as? [String: Any] { return o }
    }
    return nil
}

func expandPath(_ p: String) -> String { (p as NSString).expandingTildeInPath }

func formatBytes(_ b: Double?) -> String {
    guard let b = b, b >= 0 else { return "?" }
    let gb = b / 1_073_741_824
    if gb >= 1 { return String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb) }
    let mb = b / 1_048_576
    return String(format: "%.0f MB", mb)
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(s / 60) min" }
    if s < 86400 { return "\(s / 3600) h \(s % 3600 / 60) min" }
    return "\(s / 86400) d \(s % 86400 / 3600) h"
}

/// Compact form for tight spots: "45 s", "12 min", "18 h", "3 d".
func formatDurationShort(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(s / 60) min" }
    if s < 86400 { return "\(s / 3600) h" }
    return "\(s / 86400) d"
}

func formatClock(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
    return f.string(from: date)
}

func formatInt(_ n: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: Int(n))) ?? "\(Int(n))"
}
