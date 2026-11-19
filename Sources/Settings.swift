import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", connection = "Connection", offload = "Offload", about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .connection: return "point.3.connected.trianglepath.dotted"
        case .offload: return "moon.zzz"
        case .about: return "info.circle"
        }
    }
}

/// View state for the Settings window. Kept in an ObservableObject rather than @State so the app builds
/// with the Command Line Tools alone (they ship without the SwiftUI macro plugin that @State now needs).
final class SettingsUI: ObservableObject {
    static let shared = SettingsUI()
    @Published var tab: SettingsTab = .general
    @Published var testing = false
    @Published var results: [TestLine] = []
}

struct TestLine {
    let ok: Bool?
    let text: String
}

/// The Settings window: an icon tab bar over grouped forms, like System Settings panes.
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var ui = SettingsUI.shared

    private var tab: SettingsTab { ui.tab }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { t in
                    Button { ui.tab = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: symbol(t.icon, or: "network")).font(.system(size: 17, weight: .medium)).frame(height: 20)
                            Text(t.rawValue).font(.system(size: 11, weight: .medium))
                        }
                        .frame(width: 84, height: 50)
                        .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(tab == t ? Color.accentColor.opacity(0.14) : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
            Divider()
            Group {
                switch tab {
                case .general: GeneralPane()
                case .connection: ConnectionPane()
                case .offload: OffloadPane()
                case .about: AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 560, height: 500)
    }
}

// MARK: - Bindings into the stored config

extension Store {
    func text(_ get: @escaping (AppConfig) -> String?, _ set: @escaping (inout AppConfig, String?) -> Void) -> Binding<String> {
        Binding(get: { get(self.config) ?? "" },
                set: { v in
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.update { set(&$0, t.isEmpty ? nil : v) }
                })
    }

    func command(_ get: @escaping (AppConfig) -> [String]?, _ set: @escaping (inout AppConfig, [String]?) -> Void) -> Binding<String> {
        Binding(get: { ShellWords.join(get(self.config)) },
                set: { v in
                    let argv = ShellWords.split(v)
                    self.update { set(&$0, argv.isEmpty ? nil : argv) }
                })
    }

    func offloadText(_ kp: WritableKeyPath<OffloadConfig, String?>) -> Binding<String> {
        text({ $0.offload?[keyPath: kp] }, { c, v in var o = c.offload ?? OffloadConfig(); o[keyPath: kp] = v; c.offload = o })
    }

    func offloadCommand(_ kp: WritableKeyPath<OffloadConfig, [String]?>) -> Binding<String> {
        command({ $0.offload?[keyPath: kp] }, { c, v in var o = c.offload ?? OffloadConfig(); o[keyPath: kp] = v; c.offload = o })
    }
}

/// Text field with a "Choose…" button for files.
struct PathField: View {
    let title: String
    @Binding var value: String
    let prompt: String
    var directory = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: $value, prompt: Text(prompt))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseFiles = !directory
                    p.canChooseDirectories = directory
                    p.allowsMultipleSelection = false
                    p.showsHiddenFiles = true
                    p.treatsFilePackagesAsDirectories = true
                    if p.runModal() == .OK, let url = p.url {
                        value = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

struct FieldRow: View {
    let title: String
    @Binding var value: String
    let prompt: String
    var monospaced = false
    var width: CGFloat? = nil

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $value, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .font(monospaced ? .system(size: 11.5, design: .monospaced) : .body)
                .frame(width: width)
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @EnvironmentObject var store: Store
    static let intervals: [(Double, String)] = [(2, "2 seconds"), (5, "5 seconds"), (10, "10 seconds"), (30, "30 seconds"),
                                                (60, "1 minute"), (300, "5 minutes"), (900, "15 minutes")]

    var body: some View {
        Form {
            Section {
                FieldRow(title: "Assistant name", value: store.text({ $0.name }, { $0.name = $1 }), prompt: "Jarvis", width: 200)
                Picker("Refresh status every", selection: Binding(
                    get: { store.resolved.refreshSeconds },
                    set: { v in store.update { $0.refreshSeconds = v } })) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Menu bar shows", selection: Binding(
                    get: { store.resolved.menuBarText },
                    set: { v in store.update { $0.menuBarText = v } })) {
                    Text("Icon only").tag(false)
                    Text("Icon and status").tag(true)
                }
            } header: {
                Text("Status")
            } footer: {
                Text("Opening the panel always refreshes right away. Scheduled jobs are read at most every 15 seconds, because asking OpenClaw for them takes about a second.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Check for new versions once a day", isOn: Binding(
                    get: { store.resolved.checkForUpdates },
                    set: { v in store.update { $0.checkForUpdates = v } }))
                LabeledContent("Start at login") {
                    Text("brew services start jarvis-switch")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Settings file") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: AppConfig.path)])
                    }
                    .controlSize(.small)
                }
            } footer: {
                Text("Settings are saved as you type to ~/.config/jarvis-switch/config.json, so scripts and agents can change them too.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var options: [(Double, String)] {
        let current = store.resolved.refreshSeconds
        var o = GeneralPane.intervals
        if !o.contains(where: { $0.0 == current }) { o.append((current, "\(formatInt(current)) seconds")); o.sort { $0.0 < $1.0 } }
        return o
    }
}

// MARK: - Connection

struct ConnectionPane: View {
    @EnvironmentObject var store: Store
    @ObservedObject var ui = SettingsUI.shared

    var body: some View {
        let r = store.resolved
        Form {
            Section {
                PathField(title: "OpenClaw config", value: store.text({ $0.openclawConfig }, { $0.openclawConfig = $1 }),
                          prompt: tilde(r.openclawConfigPath) ?? "~/.openclaw/openclaw.json")
                PathField(title: "openclaw command", value: store.text({ $0.openclawCLI }, { $0.openclawCLI = $1 }),
                          prompt: tilde(r.cli) ?? "openclaw")
                FieldRow(title: "Gateway address", value: store.text({ $0.gatewayURL }, { $0.gatewayURL = $1 }),
                         prompt: r.gatewayURL)
                FieldRow(title: "Model server", value: store.text({ $0.modelBaseURL }, { $0.modelBaseURL = $1 }),
                         prompt: r.providerBaseURL ?? "detected from OpenClaw")
                FieldRow(title: "“Open OpenClaw” runs", value: store.command({ $0.dashboardCommand }, { $0.dashboardCommand = $1 }),
                         prompt: "openclaw dashboard", monospaced: true)
            } header: {
                Text("OpenClaw")
            } footer: {
                Text("Leave a field empty to detect it. The model server is the one behind your default OpenClaw model; Splash, LM Studio, Ollama and OpenAI-compatible servers are recognised.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Test connection") { test() }.disabled(ui.testing)
                    if ui.testing { ProgressView().controlSize(.small).padding(.leading, 4) }
                    Spacer()
                }
                ForEach(Array(ui.results.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 8) {
                        Image(systemName: line.ok == true ? "checkmark.circle.fill" : line.ok == false ? "xmark.circle.fill" : "minus.circle")
                            .foregroundStyle(line.ok == true ? Color.green : line.ok == false ? Color.red : Color.secondary)
                        Text(line.text).font(.system(size: 12)).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        let ui = self.ui, store = self.store
        ui.testing = true
        ui.results = []
        let r = store.resolved
        DispatchQueue.global(qos: .userInitiated).async {
            let g = probeGateway(r.gatewayURL, withReadiness: true)
            var out: [(Bool?, String)] = []
            out.append((g.live, g.live ? "Gateway \(g.version ?? "") at \(r.gatewayURL)\(g.ready == false ? " (not ready)" : "")"
                                       : "No gateway at \(r.gatewayURL)"))
            if g.live {
                let a = probeActivity(cli: r.cli, env: r.cliEnv)
                out.append((a.known, a.known ? "Scheduler: \(a.jobs.count) jobs" : "Scheduler: \(a.error ?? "unavailable")"))
            }
            let m = probeModel(baseURL: r.providerBaseURL, configuredModel: r.primaryModel)
            out.append((m.reachable ? true : (r.providerBaseURL == nil ? nil : false),
                        m.reachable ? "Model: \(m.modelID ?? "?") on \(m.runtime)" : "Model: \(m.runtime)"))
            DispatchQueue.main.async {
                ui.results = out.map { TestLine(ok: $0.0, text: $0.1) }
                ui.testing = false
                store.refresh(full: true)
            }
        }
    }

    private func tilde(_ p: String?) -> String? { p?.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

// MARK: - Offload

struct OffloadPane: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Form {
            Section {
                FieldRow(title: "Light offload", value: store.offloadCommand(\.light), prompt: "/path/to/script --light", monospaced: true)
                FieldRow(title: "Deep offload", value: store.offloadCommand(\.deep), prompt: "/path/to/script --deep", monospaced: true)
                FieldRow(title: "Bring back", value: store.offloadCommand(\.restore), prompt: "/path/to/script --restore", monospaced: true)
                PathField(title: "Offloaded marker", value: store.offloadText(\.stateFile), prompt: "~/…/offloaded.json")
            } header: {
                Text("Commands")
            } footer: {
                Text("Commands run directly, without a shell; quote arguments that contain spaces. While the marker file exists, \(store.resolved.name) shows as offloaded. A command may print a JSON line such as {\"offloaded\": true}, {\"restored\": true, \"restore_seconds\": 12} or {\"error\": \"…\"}. Leave all three empty to hide the Offload section.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Button hints") {
                FieldRow(title: "Light", value: store.offloadText(\.lightLabel), prompt: "Release model memory; back in seconds")
                FieldRow(title: "Deep", value: store.offloadText(\.deepLabel), prompt: "Stop the model server; frees the most")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutPane: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color.blue, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "brain.head.profile").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 72, height: 72)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            VStack(spacing: 4) {
                Text("Jarvis Switch").font(.system(size: 20, weight: .semibold))
                Text("Version \(appVersion)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Check for Updates") { store.checkForUpdatesNow() }
                if store.updateAvailable != nil {
                    Button("Copy brew command") { store.copyUpgradeCommand() }
                }
            }
            if let msg = store.updateMessage {
                Text(msg).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                Link("GitHub", destination: URL(string: "https://github.com/\(repoSlug)")!)
                Link("Release notes", destination: URL(string: "https://github.com/\(repoSlug)/releases")!)
                Link("Report an issue", destination: URL(string: "https://github.com/\(repoSlug)/issues/new")!)
            }
            .font(.system(size: 12))
            Spacer(minLength: 4)
            Text("Quality figures are rough estimates from published quantization studies, not measurements of your model. Not affiliated with OpenClaw, Splash, LM Studio or Ollama. MIT licensed.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Window

enum SettingsWindow {
    private static var window: NSWindow?

    static func show(store: Store) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(store))
            let w = NSWindow(contentViewController: host)
            w.title = "Jarvis Switch Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
