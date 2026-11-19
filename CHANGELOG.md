# Changelog

## 0.1.0 (2026-11-19)
- First public release.
- Live status: OpenClaw gateway (version, uptime, readiness, failing channels), running/next/failed scheduled jobs, model generating or idle.
- Model details for Splash (MLX), LM Studio, Ollama and any OpenAI-compatible server: model id, runtime, weight quantization, size on disk, KV-cache format and memory, context window, memory use and pressure, speed, prompt-cache hit rate, speculative decoding.
- Rough quality-retained estimates versus BF16 for weights, KV cache and combined.
- Optional offload / restore buttons that run your own commands.
- `--status` prints the same information in a terminal; daily update check against GitHub releases.
