# Changelog

## 0.5.1 (2026-11-22)
- Added the native **Learning & Hygiene** section directly to the macOS menu-bar panel (and `--status` / `--status --json`), matching the iOS/mobile companion: shows 24h clean-run rate, friction/failure counts, offline RSI benchmark pass rate, tracked projects, and latest auto-cleanup quarantine receipt.
- Auto-detects `logs/run_metrics.jsonl` inside the configured `openclawConfig` directory (with an optional `metricsDir` override in `~/.config/jarvis-switch/config.json`) and stays hidden automatically on standard OpenClaw setups.
- Refreshed light/dark and hero screenshots to include the Learning & Hygiene card.

## 0.5.0 (2026-11-22)
- Read-only **Mobile companion** (`mobile/` + `--companion-stream`): view live status, context, model metrics, and full schedule from your phone on your local LAN or Tailnet, protected by a per-install viewer key / HttpOnly cookie or Tailscale identity header (`mobile/install.sh`).
- Shared menu-bar model sample (`CompanionModelSample`) so the mobile companion reuses the menu bar's live reading without double-probing your model server.
- Optional **Learning & Hygiene** card (`--metrics-dir`, `GET /api/learning`): displays 24h clean-run rate, offline benchmark score, and auto-cleanup receipts when configured; stays hidden automatically otherwise.
- Quiet client-disconnect handling in `mobile/server.py` (suppresses harmless `ConnectionResetError`, `BrokenPipeError`, and `TimeoutError` tracebacks when mobile browsers drop keep-alive sockets).
- Refreshed light/dark screenshots and improved model/probe reporting.

## 0.4.0 (2026-11-19)
- Shows the model actually in use and its thinking effort (Thinking off, Low, Medium, High, XHigh).
  Both come from the running OpenClaw session (its provider, model alias and thinking level), so setups
  with several local models behind one router, such as a dense model plus a Flash model, show the right one.
- A model that loads on demand says so instead of looking broken.
- `--status --json` adds `model.requestedAs`, `model.effort` and `model.activeFromSession`.

## 0.3.0 (2026-11-19)
- Live by default: the status refreshes every second (adjustable from 1 second to 15 minutes).
- New Context section: tokens in use out of the context window for the conversation the assistant is
  working in (or the main chat), reading or writing, and whether it has been compacted.
- Live tokens per second while the model writes, next to the typical speed and time to first token.
- Mac memory bar: the assistant, other apps and free memory, out of total RAM.
- "Offload" is now "Pause" / "Resume". Without a marker file of your own, the app keeps one.
- For agents and scripts: `--status --json`, `--doctor [--json]` (with a hint for every problem),
  `config.schema.json`, `AGENTS.md` and `llms.txt`. Settings edited outside the app apply live.
- Settings → Connection → Test connection runs the same checks as `--doctor`.
- New README with a hero image, light and dark screenshots, a states picture and a how-it-works diagram.
- Fixed: the looping "working" animation kept the open panel redrawing (about a quarter of a CPU core);
  it is now a single bounce when the state changes. The app idles at under 1% CPU, even refreshing every second.
- Probes share one network session instead of opening one per request.

## 0.2.0 (2026-11-19)
- New panel: a native, minimal popover in place of the plain menu. Status header with a coloured pill,
  Activity card, Model card with memory / KV cache / speed tiles and a quality-kept bar, collapsible
  details, Offload buttons, and Settings / Quit.
- Real Settings window (General, Connection, Offload, About): assistant name, how often the status
  refreshes (2 s to 15 min), icon or icon and status in the menu bar, update check, connection paths
  with Test connection, and the offload commands. No more editing JSON by hand.
- A job that is being re-run is no longer also listed as failed.
- Shorter KV-cache description and compact uptime.
- `--render` produces screenshots (with `--demo` sample data) for docs and design checks.
- Builds with the Command Line Tools alone (no @State macro).

## 0.1.0 (2026-11-19)
- First public release.
- Live status: OpenClaw gateway (version, uptime, readiness, failing channels), running/next/failed scheduled jobs, model generating or idle.
- Model details for Splash (MLX), LM Studio, Ollama and any OpenAI-compatible server: model id, runtime, weight quantization, size on disk, KV-cache format and memory, context window, memory use and pressure, speed, prompt-cache hit rate, speculative decoding.
- Rough quality-retained estimates versus BF16 for weights, KV cache and combined.
- Optional offload / restore buttons that run your own commands.
- `--status` prints the same information in a terminal; daily update check against GitHub releases.
