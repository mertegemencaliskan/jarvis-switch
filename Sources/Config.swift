import Foundation

/// User settings: ~/.config/jarvis-switch/config.json. Every field is optional; sensible defaults are detected.
struct OffloadConfig: Codable {
    /// Commands (argv, no shell). Each may print a JSON object as its last line; see README.
    var light: [String]?
    var deep: [String]?
    var restore: [String]?
    /// While this file exists, the assistant is treated as offloaded (JSON with optional "mode"/"purpose").
    var stateFile: String?
    var lightLabel: String?
    var deepLabel: String?
}

struct AppConfig: Codable {
    var name: String?
    var gatewayURL: String?
    var openclawCLI: String?
    var openclawConfig: String?
    var dashboardCommand: [String]?
    var modelBaseURL: String?
    var offload: OffloadConfig?
    var checkForUpdates: Bool?

    static let path = expandPath("~/.config/jarvis-switch/config.json")

    static func load() -> AppConfig {
        if let d = FileManager.default.contents(atPath: path),
           let c = try? JSONDecoder().decode(AppConfig.self, from: d) { return c }
        return AppConfig()
    }

    /// First run: write a commented-by-example starter file so users can find and edit it.
    static func writeStarterIfMissing() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { return }
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let starter = """
        {
          "name": "Jarvis"
        }

        """
        fm.createFile(atPath: path, contents: Data(starter.utf8))
    }
}

/// Resolved settings after detection.
struct Resolved {
    let name: String
    let gatewayURL: String
    let cli: String?
    let openclawConfigPath: String?
    let primaryModel: String?        // "provider/model"
    let providerBaseURL: String?     // e.g. http://127.0.0.1:8000/v1
    let dashboard: [String]?
    let offload: OffloadConfig?
    let checkForUpdates: Bool

    static func resolve(_ c: AppConfig) -> Resolved {
        let fm = FileManager.default
        let envConfig = ProcessInfo.processInfo.environment["OPENCLAW_CONFIG_PATH"]
        let cfgCandidates = [c.openclawConfig.map(expandPath), envConfig, expandPath("~/.openclaw/openclaw.json")].compactMap { $0 }
        let cfgPath = cfgCandidates.first { fm.fileExists(atPath: $0) }
        let oc = cfgPath.flatMap { parseJSON(fm.contents(atPath: $0)) }

        var gateway = c.gatewayURL
        if gateway == nil, let port = num(j(oc, "gateway", "port")) { gateway = "http://127.0.0.1:\(Int(port))" }

        // agents.defaults.model is either "provider/model" or {"primary": "provider/model"}.
        let modelField = j(oc, "agents", "defaults", "model")
        let primary = (modelField as? String) ?? (j(modelField, "primary") as? String)
        var base = c.modelBaseURL
        if base == nil, let p = primary, let provider = p.split(separator: "/").first.map(String.init) {
            base = j(oc, "models", "providers", provider, "baseUrl") as? String
        }

        let cliCandidates = [c.openclawCLI.map(expandPath), expandPath("~/.openclaw/bin/openclaw"),
                             "/opt/homebrew/bin/openclaw", "/usr/local/bin/openclaw"].compactMap { $0 }
        let cli = cliCandidates.first { fm.isExecutableFile(atPath: $0) }

        return Resolved(name: c.name ?? "Jarvis",
                        gatewayURL: (gateway ?? "http://127.0.0.1:18789").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                        cli: cli, openclawConfigPath: cfgPath, primaryModel: primary, providerBaseURL: base,
                        dashboard: c.dashboardCommand ?? cli.map { [$0, "dashboard"] },
                        offload: c.offload, checkForUpdates: c.checkForUpdates ?? true)
    }

    /// Environment for CLI calls, so a non-default OpenClaw config is honoured.
    var cliEnv: [String: String] {
        guard let p = openclawConfigPath, p != expandPath("~/.openclaw/openclaw.json") else { return [:] }
        return ["OPENCLAW_CONFIG_PATH": p]
    }
}
