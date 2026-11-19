import Foundation

/// Self-checks shared by `jarvis-switch --doctor` and Settings > Connection > Test connection.
/// Each check says what was found and, when something is off, exactly what to change.
struct Check {
    enum Status: String { case ok, warn, fail }
    let name: String
    let status: Status
    let detail: String
    var hint: String? = nil

    var json: [String: Any] {
        var o: [String: Any] = ["name": name, "status": status.rawValue, "detail": detail]
        if let h = hint { o["hint"] = h }
        return o
    }
}

func runDoctor(_ r: Resolved) -> [Check] {
    var out: [Check] = []
    let fm = FileManager.default

    // Settings file
    let file = AppConfig.fileState()
    if !file.exists {
        out.append(Check(name: "settings", status: .ok, detail: "No settings file yet; using detected defaults",
                         hint: "Optional: create \(AppConfig.path) (see config.schema.json)"))
    } else if !file.valid {
        out.append(Check(name: "settings", status: .fail, detail: "\(AppConfig.path) is not valid: \(file.error ?? "parse error")",
                         hint: "Fix the JSON or delete the file; the app falls back to defaults while it is broken"))
    } else {
        out.append(Check(name: "settings", status: .ok, detail: AppConfig.path))
    }

    // OpenClaw config
    if let p = r.openclawConfigPath {
        out.append(Check(name: "openclaw-config", status: .ok, detail: p))
    } else {
        out.append(Check(name: "openclaw-config", status: .warn, detail: "No openclaw.json found",
                         hint: "Set \"openclawConfig\" to your OpenClaw config file (default ~/.openclaw/openclaw.json or $OPENCLAW_CONFIG_PATH)"))
    }

    // Gateway
    let g = probeGateway(r.gatewayURL, withReadiness: true)
    if !g.live {
        out.append(Check(name: "gateway", status: .fail, detail: "No OpenClaw gateway at \(r.gatewayURL)",
                         hint: "Start the OpenClaw gateway, or set \"gatewayURL\" (it comes from gateway.port in openclaw.json)"))
    } else if g.ready == false {
        out.append(Check(name: "gateway", status: .warn,
                         detail: "OpenClaw \(g.version ?? "") at \(r.gatewayURL) is live but not ready" +
                            (g.failing.isEmpty ? "" : " (failing: \(g.failing.joined(separator: ", ")))"),
                         hint: "Check the failing channels with `openclaw channels status`"))
    } else {
        out.append(Check(name: "gateway", status: .ok, detail: "OpenClaw \(g.version ?? "") at \(r.gatewayURL)"))
    }

    // Scheduler via CLI
    if r.cli == nil {
        out.append(Check(name: "scheduler", status: .warn, detail: "openclaw command not found, so scheduled jobs are not shown",
                         hint: "Set \"openclawCLI\" to the full path of the openclaw command"))
    } else if g.live {
        let a = probeActivity(cli: r.cli, env: r.cliEnv)
        out.append(a.known
            ? Check(name: "scheduler", status: .ok, detail: "\(a.jobs.count) scheduled jobs via \(r.cli!)")
            : Check(name: "scheduler", status: .warn, detail: "\(r.cli!) cron list: \(a.error ?? "no answer")",
                    hint: "Run `openclaw cron list --json` yourself; if it needs a different config, set \"openclawConfig\""))
    }

    // Model server
    let m = probeModel(baseURL: r.providerBaseURL, configuredModel: r.primaryModel)
    if m.reachable {
        var d = "\(m.modelID ?? "model") on \(m.runtime)"
        if let b = m.weightsBits { d += ", \(Int(b))-bit weights" }
        if let k = m.kvBits { d += ", \(Int(k))-bit KV cache" }
        out.append(Check(name: "model", status: .ok, detail: d))
    } else if r.providerBaseURL == nil {
        out.append(Check(name: "model", status: .warn,
                         detail: r.primaryModel.map { "\($0) has no local baseUrl (cloud model?)" } ?? "No default model found in openclaw.json",
                         hint: "For a local model, set \"modelBaseURL\" (e.g. http://127.0.0.1:8000/v1)"))
    } else {
        out.append(Check(name: "model", status: .fail, detail: "Model server \(m.runtime)",
                         hint: "Start the model server, or set \"modelBaseURL\""))
    }

    // Offload commands (optional)
    if let off = r.offload {
        for (label, argv) in [("light", off.light), ("deep", off.deep), ("restore", off.restore)] {
            guard let argv = argv, let exe = argv.first.map(expandPath) else { continue }
            let scriptArg = argv.dropFirst().first.map(expandPath)
            let interpreter = ["/bin/bash", "/bin/sh", "/bin/zsh", "/usr/bin/python3", "/usr/bin/env"].contains(exe)
            if !fm.isExecutableFile(atPath: exe) {
                out.append(Check(name: "offload-\(label)", status: .fail, detail: "\(exe) is not an executable file",
                                 hint: "Fix offload.\(label) (argv list, first item is the program)"))
            } else if interpreter, let script = scriptArg, script.hasPrefix("/"), !fm.fileExists(atPath: script) {
                out.append(Check(name: "offload-\(label)", status: .fail, detail: "\(script) does not exist",
                                 hint: "Fix the script path in offload.\(label)"))
            } else {
                out.append(Check(name: "offload-\(label)", status: .ok, detail: ShellWords.join(argv)))
            }
        }
        if let marker = off.stateFile.map(expandPath) {
            let dir = (marker as NSString).deletingLastPathComponent
            out.append(fm.fileExists(atPath: dir)
                ? Check(name: "offload-marker", status: .ok, detail: marker + (fm.fileExists(atPath: marker) ? " (offloaded now)" : ""))
                : Check(name: "offload-marker", status: .warn, detail: "Folder \(dir) does not exist",
                        hint: "offload.stateFile should be the file your offload command writes while offloaded"))
        }
    }
    return out
}

func doctorText(_ checks: [Check]) -> String {
    checks.map { c in
        let mark = c.status == .ok ? "✓" : c.status == .warn ? "!" : "✗"
        return "\(mark) \(c.name): \(c.detail)" + (c.hint.map { "\n    → \($0)" } ?? "")
    }.joined(separator: "\n")
}
