import Foundation

/// Offload buttons run the user's own commands (argv, no shell).
struct OffloadConfig: Codable, Equatable {
    var light: [String]?
    var deep: [String]?
    var restore: [String]?
    /// While this file exists, the assistant is treated as offloaded (JSON with optional "mode"/"purpose").
    var stateFile: String?
    /// Optional hover hints for the Light / Deep buttons.
    var lightLabel: String?
    var deepLabel: String?

    var isEmpty: Bool { light == nil && deep == nil && restore == nil && stateFile == nil && lightLabel == nil && deepLabel == nil }
}

/// Settings stored in ~/.config/jarvis-switch/config.json. Edited from the Settings window; every field is
/// optional and detected when left empty, so the file also stays easy to edit by hand or by an agent.
struct AppConfig: Codable, Equatable {
    var schema: String?
    var name: String?
    var refreshSeconds: Double?
    var menuBarText: Bool?
    var checkForUpdates: Bool?
    var gatewayURL: String?
    var openclawCLI: String?
    var openclawConfig: String?
    var modelBaseURL: String?
    var dashboardCommand: [String]?
    var offload: OffloadConfig?

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case name, refreshSeconds, menuBarText, checkForUpdates, gatewayURL, openclawCLI, openclawConfig,
             modelBaseURL, dashboardCommand, offload
    }

    static let path = expandPath("~/.config/jarvis-switch/config.json")
    static let schemaURL = "https://raw.githubusercontent.com/mertegemencaliskan/jarvis-switch/main/config.schema.json"

    /// Whether the file exists, and whether it parses. A broken file falls back to defaults (and --doctor says so).
    static func fileState() -> (exists: Bool, valid: Bool, error: String?) {
        guard let d = FileManager.default.contents(atPath: path) else { return (false, true, nil) }
        do {
            _ = try JSONDecoder().decode(AppConfig.self, from: d)
            return (true, true, nil)
        } catch {
            return (true, false, String(describing: error).prefix(200).description)
        }
    }

    static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func load() -> AppConfig {
        if let d = FileManager.default.contents(atPath: path),
           let c = try? JSONDecoder().decode(AppConfig.self, from: d) { return c }
        return AppConfig()
    }

    func save() {
        var c = self
        if c.schema == nil { c.schema = AppConfig.schemaURL }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(c) else { return }
        let dir = (AppConfig.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: AppConfig.path), options: .atomic)
    }

    static func writeStarterIfMissing() {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        AppConfig(schema: schemaURL, name: "Jarvis").save()
    }
}

/// Kept by the app when the user's pause commands do not maintain a marker file of their own.
let appPauseMarker = expandPath("~/.config/jarvis-switch/paused.json")

/// Settings after auto-detection.
struct Resolved {
    let name: String
    let refreshSeconds: Double
    let menuBarText: Bool
    let checkForUpdates: Bool
    let gatewayURL: String
    let cli: String?
    let openclawConfigPath: String?
    let primaryModel: String?        // "provider/model"
    let providerBaseURL: String?     // e.g. http://127.0.0.1:8000/v1
    let dashboard: [String]?
    let offload: OffloadConfig?

    var offloadConfigured: Bool { offload?.light != nil || offload?.deep != nil || offload?.restore != nil }

    /// The file whose presence means "paused": the user's own marker, or one the app keeps itself.
    var pauseMarker: String? {
        guard offloadConfigured else { return nil }
        return offload?.stateFile ?? appPauseMarker
    }

    static func resolve(_ c: AppConfig) -> Resolved {
        let fm = FileManager.default
        let blank: (String?) -> String? = { s in
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        let envConfig = ProcessInfo.processInfo.environment["OPENCLAW_CONFIG_PATH"]
        let cfgCandidates = [blank(c.openclawConfig).map(expandPath), envConfig, expandPath("~/.openclaw/openclaw.json")].compactMap { $0 }
        let cfgPath = cfgCandidates.first { fm.fileExists(atPath: $0) }
        let oc = cfgPath.flatMap { parseJSON(fm.contents(atPath: $0)) }

        var gateway = blank(c.gatewayURL)
        if gateway == nil, let port = num(j(oc, "gateway", "port")) { gateway = "http://127.0.0.1:\(Int(port))" }

        // agents.defaults.model is either "provider/model" or {"primary": "provider/model"}.
        let modelField = j(oc, "agents", "defaults", "model")
        let primary = (modelField as? String) ?? (j(modelField, "primary") as? String)
        var base = blank(c.modelBaseURL)
        if base == nil, let p = primary, let provider = p.split(separator: "/").first.map(String.init) {
            base = j(oc, "models", "providers", provider, "baseUrl") as? String
        }

        let cliCandidates = [blank(c.openclawCLI).map(expandPath), expandPath("~/.openclaw/bin/openclaw"),
                             "/opt/homebrew/bin/openclaw", "/usr/local/bin/openclaw"].compactMap { $0 }
        let cli = cliCandidates.first { fm.isExecutableFile(atPath: $0) }
        let dashboard = (c.dashboardCommand?.isEmpty == false ? c.dashboardCommand : nil) ?? cli.map { [$0, "dashboard"] }

        return Resolved(name: blank(c.name) ?? "Jarvis",
                        refreshSeconds: min(max(c.refreshSeconds ?? 1, 1), 3600),
                        menuBarText: c.menuBarText ?? false,
                        checkForUpdates: c.checkForUpdates ?? true,
                        gatewayURL: (gateway ?? "http://127.0.0.1:18789").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                        cli: cli, openclawConfigPath: cfgPath, primaryModel: primary, providerBaseURL: base,
                        dashboard: dashboard, offload: c.offload)
    }

    /// Environment for CLI calls, so a non-default OpenClaw config is honoured.
    var cliEnv: [String: String] {
        guard let p = openclawConfigPath, p != expandPath("~/.openclaw/openclaw.json") else { return [:] }
        return ["OPENCLAW_CONFIG_PATH": p]
    }
}

/// Commands are stored as argv arrays and edited as one line with shell-style quoting.
enum ShellWords {
    static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", inWord = false
        var quote: Character? = nil
        var escaped = false
        for ch in s {
            if escaped { cur.append(ch); escaped = false; inWord = true; continue }
            if ch == "\\" && quote != "'" { escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; inWord = true; continue }
            if ch == " " || ch == "\t" || ch == "\n" {
                if inWord { out.append(cur); cur = ""; inWord = false }
                continue
            }
            cur.append(ch); inWord = true
        }
        if inWord { out.append(cur) }
        return out
    }

    static func join(_ argv: [String]?) -> String {
        (argv ?? []).map { a in
            if a.isEmpty { return "\"\"" }
            if a.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\"'\\$`")) == nil { return a }
            return "\"" + a.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: " ")
    }
}
