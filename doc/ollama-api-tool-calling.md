# Ollama Tool Calling — Wire Format & API Reference

This document covers the exact HTTP wire format for Ollama's tool calling API as
used by `fcis-agent.py`. All behaviour described here was verified against Ollama
≥ 0.3.0 with Qwen3 models.

**Sources:**
- Ollama API reference: https://github.com/ollama/ollama/blob/main/docs/api.md
- OpenAI tool calling spec (Ollama follows this schema): https://platform.openai.com/docs/guides/function-calling
- Qwen3 tool calling guide: https://qwen.readthedocs.io/en/latest/framework/function_call.html

---

## Endpoint

```
POST http://localhost:11434/api/chat
Content-Type: application/json
```

All chat and tool-calling traffic goes through this single endpoint. Ollama does
not expose separate endpoints for tool calls vs. plain chat.

---

## Request format

### Plain chat (no tools)

```json
{
  "model": "qwen3-coder-30b-fcis",
  "messages": [
    { "role": "system", "content": "You are ..." },
    { "role": "user",   "content": "your prompt" }
  ],
  "stream": false
}
```

### With tools

Add a `tools` array containing JSON Schema function definitions. Ollama passes
these to the model formatted according to the model's native tool-calling template
(Qwen3 uses XML-based `<tool_call>` tags internally, but you never see that — the
API normalises it).

```json
{
  "model": "qwen3-coder-30b-fcis",
  "messages": [...],
  "stream": false,
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "read_file",
        "description": "Read a file from disk.",
        "parameters": {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Absolute path." },
            "lines": { "type": "string", "description": "Optional range: '10-50'." }
          },
          "required": ["path"]
        }
      }
    }
  ]
}
```

### With thinking mode (Qwen3 only)

```json
{
  "model": "qwen3-coder-30b-fcis",
  "messages": [...],
  "stream": false,
  "think": true,
  "tools": [...]
}
```

`think: true` activates Qwen3's extended reasoning pass before it produces its
response. The reasoning trace is returned separately in the `thinking` field of
the response message. Ollama 0.5.1+ is required for `think` support; older
versions return a 400 if the parameter is sent to a model that doesn't support it.

**How `fcis-agent.py` detects thinking support:**
It probes `POST /api/show` for the model and checks `capabilities` for `"thinking"`
or `"thinking"` in the modelfile template string. Result is cached per session to
avoid repeated probes. (`<think>` tag was previously checked but removed — it
appears in non-thinking Qwen3 templates as a literal and caused false positives.)

---

## Response format

### No tool calls (final answer)

```json
{
  "model": "qwen3-coder-30b-fcis",
  "message": {
    "role": "assistant",
    "content": "Here is the implementation...",
    "thinking": "First I need to..."
  },
  "done": true
}
```

`"thinking"` is only present when `think: true` was sent and the model supports it.

### Tool call requested

When the model wants to call a tool, `content` is empty (or omitted) and
`tool_calls` is populated:

```json
{
  "model": "qwen3-coder-30b-fcis",
  "message": {
    "role": "assistant",
    "content": "",
    "tool_calls": [
      {
        "function": {
          "name": "read_file",
          "arguments": {
            "path": "~/Developer/src/SMILE/Sources/SMILE/MIDI/NRPNParser.swift"
          }
        }
      }
    ]
  },
  "done": true
}
```

Key points:
- A single response can contain **multiple** `tool_calls` entries. The harness
  executes all of them in sequence before sending results back.
- `arguments` is already a parsed JSON **object** (not a string). Ollama
  deserialises it for you, unlike the OpenAI API which returns it as a
  JSON-encoded string.
- There is **no `id` field** on Ollama tool calls (unlike OpenAI). Tool results
  do not need to reference a call ID.

---

## Tool result format

After executing the tool, append the assistant message (with its `tool_calls`)
and then a `tool` role message with the result:

```json
{ "role": "assistant", "content": "", "tool_calls": [...] }
{ "role": "tool",      "content": "file contents here..." }
```

If there were multiple tool calls in one response, append one `tool` message per
call in the same order as the calls:

```json
{ "role": "assistant", "content": "", "tool_calls": [call_A, call_B] }
{ "role": "tool", "content": "result of call_A" }
{ "role": "tool", "content": "result of call_B" }
```

Then send the entire updated `messages` array back to `/api/chat`. The model
reads the tool results and either calls more tools or produces its final answer.

**Error results:** There is no special error format — return the error string as
`content`. The model reads it and decides how to recover. Do NOT omit the `tool`
message on error; the message history must remain consistent (an assistant message
with `tool_calls` must always be followed by matching `tool` results).

---

## Full multi-turn tool loop (annotated)

```
Turn 1 — user prompt
────────────────────
POST /api/chat
  messages: [system, user]
  tools: [...]

  Response: { tool_calls: [{ function: { name: "read_file", arguments: { path: "..." } } }] }

Turn 2 — tool result
────────────────────
POST /api/chat
  messages: [
    system,
    user,
    { role: "assistant", content: "", tool_calls: [...] },   ← echo back verbatim
    { role: "tool", content: "file contents..." }            ← tool result
  ]
  tools: [...]   ← resend the full tools list every turn

  Response: { content: "Here is the analysis..." }   ← no tool_calls → final answer
```

**The tools array must be resent on every turn.** Ollama does not retain tool
definitions between requests; each POST is stateless.

---

## `POST /api/show` — model capability probe

Used by `supports_thinking()` to check if a model understands `think: true`:

```
POST http://localhost:11434/api/show
Content-Type: application/json

{ "model": "qwen3-coder-30b-fcis" }
```

Response fields of interest:

```json
{
  "capabilities": ["completion", "tools", "thinking"],
  "modelfile": "FROM qwen3-coder:30b\n...\nSYSTEM \"\"\"...",
  "template": "..."
}
```

- `capabilities` array (Ollama 0.19+): check for `"thinking"`.
- `modelfile` + `template` (fallback for older Ollama): check for `"thinking"` as substring.

---

## Streaming vs. non-streaming

`fcis-agent.py` uses `"stream": false` exclusively. With streaming (`"stream": true`):
- The response arrives as a sequence of NDJSON lines, each with a partial `message`
- Tool calls only appear in the *last* chunk where `"done": true`
- Streaming requires reassembling the full message before checking `tool_calls`

Non-streaming is simpler and sufficient for CLI use where latency-to-first-token
is not a concern.

---

## Known Ollama behaviour notes

- **400 on `think: true`** for models that don't support it. The harness probes
  first and only sends `think: true` when capability is confirmed.
- **Empty `content` on tool-call responses.** Some Ollama versions return `null`
  instead of `""` — always use `msg.get("content", "")`.
- **`arguments` is a dict, not a string.** Unlike OpenAI, Ollama parses tool
  call arguments before returning them. Never `json.loads()` on arguments.
- **No `tool_call_id`.** Ollama does not assign IDs to tool calls. Tool result
  messages are matched positionally, not by ID.
