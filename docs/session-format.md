# Session format

zharness keeps these artifacts per session under `.zharness/sessions/`:

| File | Role |
|------|------|
| `<id>.json` | Legacy single-array transcript (`[{role,content,tool_call_id,tool_calls_json}, …]`). Still written so existing GUI readers keep working. |
| `<id>.jsonl` | Append-only, seq-numbered event log (**preferred** on load). |
| `<id>.json.projections` | Durable goal/todo sidecar (unchanged). |

## JSONL event log

One JSON object per line, newline-terminated. The first line is a version header:

```json
{"v":1,"kind":"header","id":"<session id>"}
```

Every later line is one message event:

```json
{"v":1,"kind":"message","seq":1,"role":"user","content":"…","tool_call_id":null,"tool_calls_json":null}
```

- `v` is the format version (`format_version` in `src/session/log.zig`).
  Readers reject unknown versions with `error.UnsupportedFormatVersion`.
- `seq` is 1-based and monotonic per session.
- Unknown line kinds and malformed lines are skipped (forward tolerance).

## Migration seam

`Session.load` reads `<id>.jsonl` first; when it is absent it reads the legacy
`<id>.json` array and sets the log cursor to 0, so the next `save` writes a fresh
log. Cleared sessions rewrite the log; ordinary saves append only the new
messages.
