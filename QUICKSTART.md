# Quick start

Get zharness running in under five minutes.

## 1. Prerequisites

- **Zig `0.17.0-dev`** — install via [zigup](https://github.com/marler8997/zigup)
  (or your package manager) and ensure `zig` is on `PATH`.
- **`curl`** on `PATH` (zharness posts chat requests through `curl`).
- A local **zcordis** checkout at `../zcordis` (referenced by relative path in
  `build.zig.zon`):

  ```bash
  git clone <zcordis-url> ../zcordis
  ```

## 2. Build

```bash
git clone <zharness-url> zharness
cd zharness
zig build                 # -> ./zig-out/bin/zharness
```

## 3. Set your API key

```bash
export ZHARNESS_API_KEY="sk-..."     # or DEEPSEEK_API_KEY
```

The default provider is `deepseek` with model `deepseek-v4-flash`.

## 4. Run your first task

```bash
./zig-out/bin/zharness run "list the files in this repo and summarize what it does"
```

The agent will read files, run shell/git tools as needed, and print a final
answer.

## 5. Chat interactively

```bash
./zig-out/bin/zharness chat
```

Type `exit` or `quit` to leave.

## 6. Persist a conversation

Sessions are stored under `.zharness/sessions/<id>.json` in the current
directory. Resume any time with the same `--session <id>`:

```bash
# Turn 1
./zig-out/bin/zharness run "My favorite color is cobalt blue. Remember this." --session live

# Turn 2 (later, even in another process)
./zig-out/bin/zharness run "What is my favorite color?" --session live
```

## 7. Common flags

| Flag | Effect |
|------|--------|
| `--model X` | Override the model (e.g. `deepseek-v4-flash`) |
| `--provider Y` | Override the provider (`deepseek`, `openai`, `ollama`, `openrouter`) |
| `--no-stream` | Disable streaming (handy when piping output) |
| `--session ID` | Resume / persist a named session |

Example:

```bash
./zig-out/bin/zharness run "explain src/agent/agent.zig" --model deepseek-v4-flash --no-stream
```

## 8. Run the tests

```bash
zig build test          # full suite (17 tests)
```

## Next steps

- [`README.md`](README.md) — full usage and configuration reference.
- [`docs/architecture.md`](docs/architecture.md) — how zharness is structured.
- [`docs/authoring-tools.md`](docs/authoring-tools.md) — add your own tool.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to contribute.
