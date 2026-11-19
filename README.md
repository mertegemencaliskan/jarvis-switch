# Jarvis Switch

A small macOS menu-bar app for people who run their own AI assistant on a Mac with
[OpenClaw](https://docs.openclaw.ai) and a local model. One glance tells you whether your
assistant is idle or working, what it is running, and exactly which model is loaded: its quantization,
KV cache, memory and speed, plus a rough estimate of how much quality the quantization keeps compared
with the full-precision (BF16) model.

If you also need your RAM and GPU back for something heavy (a render, a 3D model, a big training job),
it can offload the model with your own commands and bring it back afterwards.

```
Jarvis: working
  OpenClaw 2026.11.5 · up 18 h 31 min · ready
  Running: Daily planner (12 min)
  Next: Morning brief at 08:30
  Model: generating (1 request)
Model
  Runtime: Splash (MLX)
  Model: mlx-community/Qwen3.8-27B-4bit
  Served as: jarvis_local, jarvis_low, jarvis_medium, jarvis_high
  Weights: 4-bit affine, group size 64 · 15 GB on disk
    Est. quality vs BF16: ≈97.5% (rough estimate)
  KV cache: symmetric int8, float32 scales · 4.6 GB reserved, 1.2 GB in use
    Est. KV quality vs BF16 cache: ≈99.9% (rough estimate)
    Combined estimate: ≈97.4% of full-precision quality
  Context window: 262,144 tokens
  Memory: 22 GB in use (peak 28 GB) · system pressure normal
  Speed (median): first token 2.0 s · 44 tok/s
  Prompt cache hit rate 99% · speculative decoding on
Offload
  [x] Offload: light (release model memory)
  [x] Offload: deep (stop the model server)
  [ ] Bring Jarvis back
```

The icon changes too: a head while idle, a filled head while working, a moon while offloaded and a
warning triangle when the OpenClaw gateway is down. Click any line to copy it.

## Install

```bash
brew install mertegemencaliskan/jarvis/jarvis-switch
brew services start jarvis-switch
```

It is built from source on your Mac, so it needs the Xcode Command Line Tools (`xcode-select --install`).
`brew services` starts it at login and restarts it if it crashes.

Update:

```bash
brew upgrade jarvis-switch && brew services restart jarvis-switch
```

The menu shows **Update available** when a newer release exists (checked once a day against GitHub
releases; turn it off with `"checkForUpdates": false`).

Without Homebrew: `git clone`, then `scripts/build.sh` builds `build/JarvisSwitch.app`.

## What it reads

| Source | What | How |
|---|---|---|
| OpenClaw gateway | version, uptime, readiness, failing channels | `GET /startupz`, `/healthz`, `/readyz` (no token needed) |
| OpenClaw scheduler | running jobs and for how long, next job, last failures | `openclaw cron list --json` every 30 s and when you open the menu |
| Model server | everything in the Model section | the provider `baseUrl` of your default model in `openclaw.json` |

Model servers it understands:

- **Splash (MLX)**: `/status`, plus the model folder's `config.json` for weight quantization. Gives the
  richest detail: KV format and memory, memory pressure, speed, cache hit rate, speculative decoding.
- **LM Studio**: `/api/v0/models` (model id, quantization, context). LM Studio does not report its KV cache.
- **Ollama**: `/api/ps` (model, quantization level, VRAM, context). The KV type is read from `OLLAMA_KV_CACHE_TYPE` (default f16).
- **Anything OpenAI-compatible**: `/v1/models`; the bit width is guessed from the model name.

Cloud models (no local `baseUrl`) show the model name only.

Nothing leaves your Mac except the daily update check to `api.github.com`. The app never reads or sends
your OpenClaw token or API keys.

## About the quality estimates

These numbers are **rough, literature-based estimates, not measurements of your model**. They follow the
typical size of the quality loss reported for modern 7B–70B models:

| Weights | Est. quality kept | | KV cache | Est. quality kept |
|---|---|---|---|---|
| 16-bit (BF16/FP16) | 100% | | 16-bit | 100% |
| 8-bit | ≈99.7% | | 8-bit | ≈99.9% |
| 6-bit | ≈99.2% | | 4-bit | ≈99.0% |
| 5-bit | ≈98.6% | | lower | ≈96% |
| 4-bit | ≈97.5% | | | |
| 3-bit | ≈93% | | | |
| 2-bit | ≈82% | | | |

The real loss depends on the task. 4-bit models often match BF16 on reasoning and coding benchmarks, but
can lose much more on OCR-style and exact-transcription work. An 8-bit KV cache is close to lossless; a
4-bit one costs a little more at very long contexts. Treat the figures as a guide, and test your own workload.

## Settings

`~/.config/jarvis-switch/config.json` (menu → **Edit settings…**). Everything is optional and detected
when left out:

| Key | Default | Meaning |
|---|---|---|
| `name` | `Jarvis` | Your assistant's name in the menu |
| `openclawConfig` | `$OPENCLAW_CONFIG_PATH` or `~/.openclaw/openclaw.json` | Where to find the gateway port and default model |
| `openclawCLI` | `~/.openclaw/bin/openclaw`, then Homebrew paths | The `openclaw` command |
| `gatewayURL` | `http://127.0.0.1:<gateway.port>` | Gateway address |
| `modelBaseURL` | provider `baseUrl` of the default model | Override the model server address |
| `dashboardCommand` | `openclaw dashboard` | What **Open OpenClaw** runs, e.g. `["/usr/bin/open", "-a", "OpenClaw"]` |
| `checkForUpdates` | `true` | Daily GitHub release check |
| `offload` | none | Offload buttons, see below |

See [`examples/config.example.json`](examples/config.example.json).

### Offload buttons

Jarvis Switch does not decide how to unload your model; it runs commands you provide (an argv list, no
shell):

```json
"offload": {
  "light": ["/path/to/script", "--light"],
  "deep": ["/path/to/script", "--deep"],
  "restore": ["/path/to/script", "--restore"],
  "stateFile": "~/.local/state/my-assistant/offloaded.json"
}
```

- While `stateFile` exists, the menu shows the assistant as offloaded and enables **Bring back**. Its
  optional JSON fields `mode` and `purpose` are shown.
- If a command prints a JSON object as its last line, the result line uses it: `{"offloaded": true}`,
  `{"restored": true, "restore_seconds": 12, "identical_to_before": true}`, or `{"error": "…"}`.

A simple light offload for Splash is `POST /v1/memory/release`. A deep one stops the server's LaunchAgent.

## Terminal

```bash
jarvis-switch --status     # print the menu once (good for SSH and bug reports)
jarvis-switch --version
```

## Development

```bash
scripts/build.sh                                   # build/JarvisSwitch.app
build/JarvisSwitch.app/Contents/MacOS/JarvisSwitch --status
```

Releases: `scripts/release.sh 0.2.0` bumps `VERSION`, tags, publishes a GitHub release and updates the
Homebrew formula in [`homebrew-jarvis`](https://github.com/mertegemencaliskan/homebrew-jarvis).

Not affiliated with OpenClaw, Splash, LM Studio or Ollama. MIT licensed.
