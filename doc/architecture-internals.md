# fcis-agent.py — Architecture & Internals

Detailed technical reference for how the harness works internally. Read this
before modifying `fcis-agent.py` or `tools/fcis_tools.json`.

**Sources:**
- `fcis-agent.py` (all section references are to this file)
- Ollama API: https://github.com/ollama/ollama/blob/main/docs/api.md
- Qwen3 model card: https://huggingface.co/Qwen/Qwen3-30B-A3B
- Python subprocess docs: https://docs.python.org/3/library/subprocess.html

---

## High-level flow

```
CLI args / stdin
      │
      ▼
  route_model()          ← keyword scoring → MODEL_CODER or MODEL_GENERAL
      │
      ▼
  find_agents_md()       ← walk cwd upward for AGENTS.md (git-style discovery)
      │
      ▼
  load_system_context()  ← prepend "# Project Context (AGENTS.md)\n\n" + file text
      │
      ▼
  run_agent()            ← tool loop (while iteration_count < 10)
      │
      ├── ollama_chat()  ← POST /api/chat with full messages + tools list
      │       │
      │       ├── tool_calls present?
      │       │     yes → execute_tool() for each call
      │       │           append assistant msg + tool results to messages
      │       │           loop (POST again with updated messages)
      │       │
      │       └── no tool_calls → return content (final answer)
      │
      ▼
  print(response)        ← to stdout
  log_session()          ← if --log: write logs/TIMESTAMP_MODEL.json
```

---

## Model routing

**`route_model(prompt: str) → str`**

Tokenises the prompt with `re.findall(r"\b\w+\b", prompt.lower())`, intersects
with `CODER_SIGNALS` (40 coding-task keywords):

```python
CODER_SIGNALS = {
    "implement", "write", "fix", "generate", "refactor", "code", "snippet",
    "func", "struct", "enum", "class", "protocol", "actor", "extension",
    "async", "await", "throws", "init", "type", "generic", "conform",
    "method", "property", "closure", "build", "compile", "error", "crash",
    "parse", "encode", "decode", "test", "spec", "assert", "mock",
}
```

Any intersection → `MODEL_CODER` (`qwen3-coder-30b-fcis`).
Empty intersection → `MODEL_GENERAL` (`qwen3-8b-fcis`).

This is a **bag-of-words heuristic**, not semantic routing. Known misclassifications:
- `"write a design doc for the parser"` → routes to coder (has `"write"`) —
  use `--model general` explicitly for design/review tasks.
- `"what's wrong with this enum switch?"` → routes to coder (has `"enum"`) —
  usually correct.

Use `--show-model "your prompt"` to verify routing before a long run.

---

## AGENTS.md discovery

**`find_agents_md(start: Path | None) → Path | None`**

Mimics git's `.git` discovery: walks from `start` (default: `Path.cwd()`) upward
through all parent directories, checking for `AGENTS.md` at each level. Returns
the first match or `None`.

```
Running from: /Users/jphipps/Developer/src/SMILE/Sources/SMILE/MIDI/

  → /Users/jphipps/Developer/src/SMILE/Sources/SMILE/MIDI/AGENTS.md  (not found)
  → /Users/jphipps/Developer/src/SMILE/Sources/SMILE/AGENTS.md       (not found)
  → /Users/jphipps/Developer/src/SMILE/Sources/AGENTS.md              (not found)
  → /Users/jphipps/Developer/src/SMILE/AGENTS.md                      ✓ FOUND
```

**Override priority (highest → lowest):**
1. `FCIS_AGENTS_MD` environment variable (absolute path, checked first in `find_agents_md`)
2. `--agents PATH` CLI flag (passed as `override` to `load_system_context`)
3. Auto-discovery from `cwd`

**`load_system_context(override: str | None) → str`**

Wraps the AGENTS.md content:

```
# Project Context (AGENTS.md)

<full file contents>
```

This header signals to the model that what follows is project-specific invariants
layered on top of its Modelfile SYSTEM prompt. Returns `""` if no AGENTS.md is
found (model operates on its baked-in FC/IS invariants only — prints a WARNING
to stderr).

---

## Tool loop

**`run_agent(model, prompt, system, use_tools, think) → str`**

Manages the `messages` list and drives `ollama_chat()` until the model produces
a response with no `tool_calls`.

```python
messages = []
if system:
    messages.append({"role": "system", "content": system})
messages.append({"role": "user", "content": prompt})

iteration_count = 0
while iteration_count < 10:
    iteration_count += 1
    response = ollama_chat(model, messages, tools, think)
    msg = response.get("message", {})
    calls = msg.get("tool_calls", [])

    if not calls:
        if thinking := msg.get("thinking", ""):
            print(f"\n<think>\n{thinking}\n</think>\n", file=sys.stderr)
        return msg.get("content", "")           # ← final answer

    # Echo the assistant message back (preserving tool_calls, content, thinking)
    messages.append({"role": "assistant", **{k: v for k, v in msg.items() if k != "role"}})

    for call in calls:
        fn = call.get("function", {})
        result = execute_tool(fn.get("name", ""), fn.get("arguments", {}))
        if result.startswith("ERROR:"):
            print(f"[fcis-agent] Tool error (passing to model): {result}", file=sys.stderr)
        messages.append({"role": "tool", "content": result})

return "ERROR: tool loop exceeded 10 iterations. ..."
```

**Why echo the assistant message verbatim?**
Ollama requires the assistant's `tool_calls` message to be present in history so
the model can match results to calls. The dict comprehension
`{k: v for k, v in msg.items() if k != "role"}` copies `content`, `tool_calls`,
and `thinking` while letting `messages.append` set the `"role"` key to
`"assistant"`.

**Tool error handling:**
Tool results starting with `"ERROR:"` are logged to stderr, then appended to
`messages` as a normal `tool` role result. The model sees the error and can:
retry with a corrected argument, use a different tool, or acknowledge failure.
The loop is NOT aborted on tool errors — only the 10-iteration cap or an Ollama
connection failure terminates early.

**Iteration cap (10):**
Prevents runaway loops. Well-formed tasks complete in 2–5 iterations. Tasks
hitting the cap usually have an ambiguous prompt, a tool producing unexpected
output, or the model entering a search loop that isn't converging.

---

## Ollama HTTP layer

**`_post(payload: dict, timeout: int = 300) → dict`**

Uses Python's stdlib `urllib.request` — no third-party HTTP dependency. The 300s
(5 minute) timeout accommodates the 30b model's generation time on long responses.
Does not stream; waits for the full JSON blob.

```python
req = urllib.request.Request(
    f"{OLLAMA_BASE}/api/chat", data=data,
    headers={"Content-Type": "application/json"}, method="POST",
)
with urllib.request.urlopen(req, timeout=timeout) as resp:
    return json.loads(resp.read())
```

**Error handling:**
- `HTTPError` (4xx/5xx) → raises `RuntimeError(f"HTTP {e.code}: {body}")`
- `URLError` (connection refused, DNS failure) → prints diagnostic
  (`brew services start ollama`) and calls `sys.exit(1)`

---

## Thinking mode detection

**`supports_thinking(model: str) → bool`**

Probes `POST /api/show` once per model per session. Result cached in
`_think_support_cache` (module-level dict).

Check order:
1. `"thinking" in info.get("capabilities", [])` — Ollama 0.19+ explicit
2. `"thinking" in (modelfile + template).lower()` — older Ollama fallback

Failed probe (any exception) → `False`. Better to skip thinking than crash with
a 400 on a model that doesn't support it.

**Why `"<think>" in template` was removed:**
Qwen3 prompt templates use `<think>` as a literal formatting token even when not
in thinking mode. This caused false positives — models that didn't support
`think: true` received it anyway and returned 400. Removed in the "Fixed 10 tool
call cap" commit (63e3dbc).

---

## Path expansion

**`expand(raw: str) → Path`**

```python
Path(os.path.expanduser(raw)).resolve()
```

- `expanduser`: resolves `~` and `~user` to absolute home directory path
- `resolve`: follows symlinks, collapses `.` and `..`

All tool `path` and `cwd` parameters pass through `expand()` before any
filesystem operation. This means `~/` paths always work regardless of the
invocation context.

---

## Tool execution dispatch

**`execute_tool(name: str, args: dict) → str`**

1. Looks up `name` in `TOOL_HANDLERS` dict
2. Logs a 120-char preview of the call to stderr:
   `  [tool] read_file({"path": "~/Developer/src/SMILE/...`
3. Calls the handler inside `try/except Exception` as a safety net
4. Returns `"ERROR: tool <name> failed: <exception>"` if the handler raises
   unexpectedly (individual handlers also have their own try/except for known
   failure modes)

`args` is always a Python dict — Ollama parses tool call arguments before
returning them. Never call `json.loads()` on `args`.

---

## Logging

**`log_session(model, prompt, response)`**

When `--log` is passed, writes to `logs/` directory adjacent to `fcis-agent.py`:

```json
{
  "timestamp": "20260716_143022",
  "model": "qwen3-coder-30b-fcis",
  "prompt": "...",
  "response": "..."
}
```

Filename: `YYYYMMDD_HHMMSS_<model>.json` (colons replaced with `-`).

**What is NOT logged:** individual tool call turns, thinking traces, stderr
output. The log captures only the final prompt→response pair.

For full session inspection including tool calls and thinking, redirect stderr:

```bash
python fcis-agent.py "prompt" 2>full-session.log
```

---

## stdin support

If no positional `prompt` argument is given and `sys.stdin.isatty()` is `False`,
the prompt is read from stdin in full:

```bash
git diff | python fcis-agent.py --model general "review this diff for FC/IS compliance"
# ^ prompt is the arg; the diff could be piped as additional context
# or:
cat long-prompt.txt | python fcis-agent.py
```

If stdin is a TTY and no prompt is given, argparse prints help and exits 1.

---

## Modifying tool definitions

Tools are defined in two places that must stay in sync:

| File | Role |
|---|---|
| `tools/fcis_tools.json` | JSON Schema sent to the model. Controls what it thinks it can call, parameter names, types, and descriptions. |
| `TOOL_HANDLERS` in `fcis-agent.py` | Python functions that actually execute the calls. Keys must exactly match JSON Schema `name` fields. |

**Adding a tool:**
1. Add a JSON Schema entry to `fcis_tools.json` following the existing pattern
2. Implement `tool_<name>(args: dict) → str` in `fcis-agent.py`
3. Add `"<name>": tool_<name>` to `TOOL_HANDLERS`

**Tool handler contract:**
- Accept `args: dict` (pre-parsed by Ollama — never a JSON string)
- Always return `str` — never raise
- Prefix failure strings with `"ERROR:"` for harness logging
- Cap large outputs to 6–8 KB to stay within effective context per tool result
- Have their own `try/except` for known failure modes (the outer
  `execute_tool` catch is a safety net, not a substitute)

---

## Environment variables

| Variable | Constant / Usage | Effect |
|---|---|---|
| `OLLAMA_HOST` | `OLLAMA_BASE` | Override base URL. Default `http://localhost:11434` |
| `FCIS_AGENTS_MD` | `find_agents_md()` | Override AGENTS.md path. Takes precedence over auto-discovery |

---

## Known limitations

**DuckDuckGo `web_search` returns sparse results.**
The DDG Instant Answer API is optimised for direct answers, not full web search.
For detailed research, use `web_search` to get a URL, then `web_fetch` to read it.

**`swift_diagnostics` does not resolve Package.swift dependencies.**
Type-checking a file that imports a local library target (e.g. `import MIDISpec`)
fails unless that module is in the system SDK. Use `swift_build` for cross-module
verification.

**`bash_exec` timeout is 30 seconds.**
Long-running commands should use the dedicated Swift tools (`swift_build`,
`swift_test`) which have 120-second timeouts. Very long operations should run
outside the harness.

**Tool loop cap is 10 iterations.**
Tasks requiring more than 10 tool calls will be cut off with an error. For
file-heavy tasks, prompt the model to batch reads or summarise earlier results
before continuing.

**No streaming output during generation.**
Each iteration waits for the full model response before executing tools. The CLI
produces no output during generation — this is by design.

**`write_file` has no confirmation prompt.**
The model can write to any path accessible to the running user. Always invoke the
harness from a project root to give the model a natural scope, and review any
`write_file` calls in the stderr log before running in sensitive directories.
