# Quick Start

Get zharness running in under 5 minutes.

## Prerequisites

- **Zig 0.17.0** (stable) — install via [zigup](https://github.com/marler8997/zigup)
- **curl** on PATH
- **zcordis** at `../zcordis`:

```bash
git clone https://github.com/chy3xyz/zcordis.git ../zcordis
```

## Build & Run

```bash
git clone https://github.com/chy3xyz/zharness.git zharness
cd zharness
zig build                      # -> ./zig-out/bin/zh

export ZHARNESS_API_KEY="sk-..."
./zig-out/bin/zh run "list files and summarize this repo"
```

## Common Commands

```bash
# Single task
zh run "fix the failing tests"

# Interactive chat
zh chat

# Persist a session
zh run "remember: blue is my favorite color" --session notes
zh run "what is my favorite color?" --session notes

# Web UI
zh serve --port 3080
open http://127.0.0.1:3080

# Override model
zh run "explain src/main.zig" --model deepseek-v4-flash

# Disable streaming (for piping)
zh run "summarize git log" --no-stream
```

## Common Flags

| Flag | Effect |
|------|--------|
| `--model X` | Override the model |
| `--provider Y` | Override the provider (`deepseek`, `openai`, `ollama`) |
| `--no-stream` | Disable streaming |
| `--session ID` | Resume / persist a named session |
| `--preset P` | Use a preset (`standard`, `minimal`, `ptc`, `creative`) |
| `--sandbox S` | Sandbox mode (`off`, `process`) |

## Next Steps

- [README.md](README.md) — full documentation
- [docs/architecture.md](docs/architecture.md) — how zharness works
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to contribute
