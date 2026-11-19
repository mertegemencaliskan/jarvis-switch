# Changelog

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
