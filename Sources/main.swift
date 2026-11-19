// Jarvis Switch — menu-bar status, model details and an offload switch for a local OpenClaw assistant.
// https://github.com/mertegemencaliskan/jarvis-switch  (MIT)
import AppKit
import Combine
import SwiftUI

let repoSlug = "mertegemencaliskan/jarvis-switch"

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = Store.shared
    var item: NSStatusItem!
    let popover = NSPopover()
    var watchers = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppConfig.writeStarterIfMissing()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        item.button?.imagePosition = .imageLeading

        let host = NSHostingController(rootView: PanelView().environmentObject(store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        store.openSettings = { [weak self] in
            self?.popover.performClose(nil)
            if let s = self?.store { SettingsWindow.show(store: s) }
        }
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateButton() } }
            .store(in: &watchers)
        updateButton()
        store.start()
        // Hidden test hooks: open the panel or Settings right after launch.
        if CommandLine.arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.togglePanel(nil) }
        }
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.store.openSettings() }
        }
    }

    @objc func togglePanel(_ sender: Any?) {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refresh(full: true)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func updateButton() {
        guard let button = item?.button else { return }
        let kind = store.kind
        let img = NSImage(systemSymbolName: kind.menuSymbol, accessibilityDescription: store.resolved.name)
        img?.isTemplate = true
        button.image = img
        button.title = store.resolved.menuBarText ? " \(kind.title)" : ""
        button.toolTip = "\(store.resolved.name): \(kind.title)"
    }
}

// MARK: - Command line

let args = CommandLine.arguments
func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let usage = """
jarvis-switch: menu-bar status for a local OpenClaw assistant.

  jarvis-switch                     run the menu-bar app (normally started by `brew services`)
  jarvis-switch --status [--json]   print the current status once
  jarvis-switch --doctor [--json]   check settings, gateway, scheduler, model server and offload commands
  jarvis-switch --version
  jarvis-switch --render FILE.png [--dark] [--demo] [--details] [--settings TAB | --hero | --states]
                                    render screenshots (--demo uses sample data)

Settings: \(AppConfig.path)
Docs: https://github.com/\(repoSlug)
"""

if args.contains("--help") || args.contains("-h") { print(usage); exit(0) }
if args.contains("--version") { print(appVersion); exit(0) }

if args.contains("--status") {
    let r = Resolved.resolve(AppConfig.load())
    let snap = probeOnce(r)
    let kind = Kind.from(snap, busy: false)
    if args.contains("--json") {
        print(jsonString(statusJSON(name: r.name, kind: kind, snap, offloadConfigured: r.offloadConfigured, gatewayURL: r.gatewayURL)))
    } else {
        print(statusText(name: r.name, kind: kind, snap, offloadConfigured: r.offloadConfigured, gatewayURL: r.gatewayURL))
    }
    exit(0)
}

if args.contains("--doctor") {
    let checks = runDoctor(Resolved.resolve(AppConfig.load()))
    let ok = !checks.contains { $0.status == .fail }
    if args.contains("--json") {
        print(jsonString(["ok": ok, "version": appVersion, "checks": checks.map(\.json)]))
    } else {
        print(doctorText(checks))
        print(ok ? "\nAll required checks passed." : "\nSome checks failed; see the hints above.")
    }
    exit(ok ? 0 : 1)
}

if let target = argValue("--render") {
    renderFromCommandLine(target)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
