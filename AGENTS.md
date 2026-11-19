# AGENTS.md: Jarvis Switch

Instructions for AI agents (Claude Code, Codex, Antigravity, OpenClaw agents and others) that install,
configure or change Jarvis Switch for a person. People can read the [README](README.md) instead.

## What it is

A native macOS menu-bar app (Swift, MIT) for someone running their own AI assistant with
[OpenClaw](https://docs.openclaw.ai) and a local model. It shows live, every second by default:

- whether the assistant is idle, working, resting, paused or offline
- the scheduled jobs running now, the next one, and failed ones
- the active context window (tokens used out of the window, reading or writing) and whether the
  conversation has been compacted
- the model: id, runtime, weight and KV-cache quantization, live tokens per second, time to first token,
  and an estimated quality kept versus BF16
- Mac memory: the assistant's share, other apps and free, out of total RAM

It can also pause the assistant to free RAM and GPU for another task, by running commands the person
chooses. It only reads local endpoints and never needs tokens or API keys.

## Install for a person (macOS 13 or later)

```bash
xcode-select -p || xcode-select --install     # Command Line Tools; installing them needs the person to click Install
brew install mertegemencaliskan/jarvis/jarvis-switch
jarvis-switch --doctor                         # fix every ✗ line; ! lines are optional
brew services start jarvis-switch              # starts now and at every login
jarvis-switch --status                         # confirm it sees the assistant
```

Homebrew builds from source, so there is no Gatekeeper prompt. Updating: `brew upgrade jarvis-switch &&
brew services restart jarvis-switch`.

## Configure

Settings live in `~/.config/jarvis-switch/config.json`, described by [`config.schema.json`](config.schema.json).
Every field is optional. The running app re-reads the file within one refresh; no restart needed. People
can change the same settings in the app (panel → Settings).

Work out values in this order, and only set what detection gets wrong:

1. Run `jarvis-switch --doctor --json`. Each check has `status` (`ok`, `warn`, `fail`), `detail` and a `hint`.
2. `openclawConfig`: the OpenClaw config the gateway really uses. If the person starts OpenClaw through a
   wrapper that exports `OPENCLAW_CONFIG_PATH` or `OPENCLAW_STATE_DIR`, use those values; otherwise the
   default `~/.openclaw/openclaw.json` is usually right.
3. `openclawCLI`: the command that talks to that gateway. With a non-default state directory, point it at
   the person's wrapper script (one that sets the same environment), not at a bare `openclaw`.
4. `gatewayURL` and `modelBaseURL` are normally detected from `openclaw.json` (`gateway.port`, and the
   `baseUrl` of the provider behind `agents.defaults.model`). Set them only if the doctor says so.
5. `refreshSeconds`: 1 (default) for live numbers; raise it on battery-sensitive machines.

Never write tokens, API keys or passwords into this file. Do not edit OpenClaw's own config for Jarvis Switch.

## Pause commands

`offload.light`, `offload.deep` and `offload.restore` are argv lists run without a shell. Use
`["/bin/sh", "-c", "…"]` when you need a shell. A command succeeds when it exits 0 and does not print
`{"error": …}` as its last line. Optional JSON last lines the panel understands:
`{"offloaded": true}`, `{"restored": true, "restore_seconds": 12, "identical_to_before": true}`,
`{"error": "…"}`.

`offload.stateFile` is a file that exists while paused. Leave it out and the app keeps its own marker at
`~/.config/jarvis-switch/paused.json` after a successful pause, removing it after a successful resume.

Examples (adjust the model names and paths to the person's setup, and test each command once):

| Runtime | Light pause | Resume |
|---|---|---|
| Splash | `["/usr/bin/curl", "-fsS", "-X", "POST", "http://127.0.0.1:8000/v1/memory/release"]` | a 1-token request to `/v1/chat/completions`, which loads the weights again |
| Ollama | `["/opt/homebrew/bin/ollama", "stop", "MODEL"]` | `["/usr/bin/curl", "-fsS", "http://127.0.0.1:11434/api/generate", "-d", "{\"model\": \"MODEL\"}"]` (an empty prompt loads the model) |
| LM Studio | `["~/.lmstudio/bin/lms", "unload", "--all"]` | `["~/.lmstudio/bin/lms", "load", "MODEL"]` |

A deep pause usually stops the model server's LaunchAgent, for example
`["/bin/sh", "-c", "launchctl bootout gui/$(id -u)/LABEL"]`, and resumes with
`["/bin/sh", "-c", "launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/LABEL.plist"]`.

## Read the status from scripts

```bash
jarvis-switch --status --json
```

Top-level keys: `name`, `state` (`idle`, `working`, `resting`, `paused`, `offline`), `checkedAt`, `app`,
`gateway`, `jobs` (`running`, `next`, `lastRunFailed`), `context` (`session`, `tokens`, `windowTokens`,
`percent`, `phase`, `compactions`, `compacted`, `live`), `model` (`id`, `runtime`, `weights`, `kvCache`,
`estimatedQualityPercent`, `liveTokensPerSecond`, `decodeTokensPerSecond`, `timeToFirstTokenSeconds`,
`processMemoryBytes`, …), `memory` (`totalBytes`, `usedBytes`, `freeBytes`, `assistantBytes`) and
`offload`. Values that are unknown are left out, never guessed. When the model is writing, `--status`
takes a second sample one second later to measure live speed.

Exit codes: `--status` always exits 0; `--doctor` exits 1 when any check fails.

## Change the code

- Build: `scripts/build.sh` → `build/JarvisSwitch.app`. It must build with the Command Line Tools alone
  (that is how Homebrew users build it), so do not use `@State` or other SwiftUI APIs that need Xcode's
  macro plugins; keep view state in `ObservableObject`s.
- Check designs without a screen: `build/JarvisSwitch.app/Contents/MacOS/JarvisSwitch --render out.png
  [--dark] [--demo] [--details] [--settings general] [--hero] [--states]`.
- Regenerate the README images with `scripts/screenshots.sh`. They use sample data only.
- Keep personal data out of the repository and the images: no real paths, job names, ids or account names.
- CI (`.github/workflows/build.yml`) builds on macOS and checks `--version`, `--status --json` and
  `--doctor --json`.
- Release: add a `## X.Y.Z` section to `CHANGELOG.md`, commit, then `scripts/release.sh X.Y.Z`. It tags,
  publishes the GitHub release and updates the formula in
  [`homebrew-jarvis`](https://github.com/mertegemencaliskan/homebrew-jarvis).

Source map: `main.swift` (app and command line), `Store.swift` (refresh loop and actions), `Probes.swift`
(gateway, scheduler, model servers), `Live.swift` (sessions, context, Mac memory), `Panel.swift` and
`Components.swift` (the panel), `Settings.swift` (settings window), `Doctor.swift`, `CLI.swift`,
`Quality.swift` (quality estimates), `Showcase.swift` (screenshots and sample data).
