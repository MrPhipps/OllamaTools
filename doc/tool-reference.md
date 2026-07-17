# Tool Reference — fcis_tools.json

All 13 tools available to the models during a tool-calling session. Definitions
live in `tools/fcis_tools.json` and are loaded once per invocation in `run_agent()`.
Disabled entirely with `--no-tools`.

**Source:** `tools/fcis_tools.json`, handler functions in `fcis-agent.py`.

---

## General notes

- **Path expansion:** All `path` and `cwd` parameters pass through
  `os.path.expanduser` + `Path.resolve()`. `~/` paths are always safe.
- **Output caps:** Most tools cap output at 6–8 KB to stay within the model's
  effective context window for a single tool result.
- **Error format:** On failure, tools return a string starting with `"ERROR:"`.
  The harness logs this to stderr and passes it to the model as the tool result
  so the model can recover (e.g. try a different path or tool).
- **Timeout behaviour:** Subprocess tools raise `subprocess.TimeoutExpired` on
  timeout; this is caught and returned as `"ERROR: timed out after Ns"`.

---

## File system

### `read_file`

Read a file from disk.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `path` | string | yes | Absolute or `~/` path |
| `lines` | string | no | Line range e.g. `"10-50"` (1-indexed, inclusive both ends) |

**Returns:** File text, optionally sliced to the given range.
`"ERROR: not found: /path"` if missing.

**Notes:**
- Line slicing uses `text.splitlines()[lo-1 : hi]` — both ends inclusive.
- No output cap — large files returned in full. The model may follow up with a
  `lines` range on a second call if the first result overwhelms context.

---

### `write_file`

Write or overwrite a file.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `path` | string | yes | Absolute or `~/` path |
| `content` | string | yes | Full file content to write |

**Returns:** `"Written N bytes to /path"` on success.

**Notes:**
- Parent directories are created automatically (`mkdir -p` equivalent via
  `path.parent.mkdir(parents=True, exist_ok=True)`).
- Always overwrites — no append mode.
- No confirmation prompt. Run from a project root to scope the model's write
  access to relevant directories.

---

### `list_directory`

List files in a directory.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `path` | string | yes | Directory to list |
| `extension` | string | no | Extension filter without dot, e.g. `"swift"` |
| `recursive` | boolean | no | Recurse via `rglob`. Default `false` |

**Returns:** Newline-separated file paths relative to `path`. Directories are
excluded — files only. `"ERROR: not found"` if the path doesn't exist.

---

### `grep_codebase`

Search for a pattern across files using `grep -rn`.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `pattern` | string | yes | Regex or literal string |
| `path` | string | no | Search root. Defaults to invocation `cwd` |
| `extension` | string | no | Restrict to this extension, e.g. `"swift"` |

**Returns:** `grep -rn` output capped at 6 000 characters. `"No matches."` if
nothing found (this is not an `ERROR:` string — the model continues normally).

**Notes:**
- Uses `shell=True`; pattern is Python-`repr()`-quoted to handle spaces and
  special chars, but avoid shell metacharacters in `path`.
- 15-second timeout.

---

## Swift toolchain

These tools invoke the local Xcode toolchain via `xcrun`. Requires Xcode Command
Line Tools (`xcode-select --install`).

### `swift_diagnostics`

Type-check a single `.swift` file without a full build.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `path` | string | yes | Path to the `.swift` file |
| `extra_flags` | string | no | Additional `swiftc` flags, e.g. `"-strict-concurrency=complete"` |

**Returns:** Compiler errors and warnings, or
`"No diagnostics — file type-checks cleanly."` Capped at 8 KB.

**Underlying command:**
```bash
xcrun swiftc -typecheck <path> -sdk $(xcrun --show-sdk-path) \
  -target arm64-apple-macosx14.0 -swift-version 6 [extra_flags]
```

**Notes:**
- Faster than `swift_build` — only type-checks, no code generation or linking.
- Target is hardcoded to `arm64-apple-macosx14.0` on Apple Silicon. Files
  importing iOS-only APIs will fail — use `swift_build` (which uses Package.swift
  platform targets) for cross-platform packages.
- Swift version is hardcoded to 6. Pre-Swift-6 concurrency patterns produce
  errors intentionally (FC/IS invariant: strict concurrency is always on).
- Does not resolve Package.swift dependencies. Files importing library targets
  (e.g. `import MIDISpec`) will fail unless that module is in the system SDK.
  Use `swift_build` for cross-module verification.
- 60-second timeout.

---

### `swift_build`

Run `swift build` in a package directory.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `cwd` | string | no | Project root containing `Package.swift`. Defaults to invocation `cwd` |
| `configuration` | string | no | `"debug"` (default) or `"release"` |

**Returns:** Full compiler output (stdout + stderr) capped at 8 KB.

**Underlying command:**
```bash
xcrun swift build -c debug 2>&1
```

**Notes:**
- 120-second timeout. Large projects may exceed this on a cold build (no `.build/`
  cache). Incremental builds are much faster.
- Does not run tests. Use `swift_test` for that.

---

### `swift_test`

Run Swift package tests.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `filter` | string | no | Test name or suite, e.g. `"NRPNParserTests"` or `"testReceiveComplete"` |
| `cwd` | string | no | Project root. Defaults to invocation `cwd` |

**Returns:** Test output (stdout + stderr) capped at 8 KB.

**Underlying command:**
```bash
xcrun swift test [--filter "<filter>"] 2>&1
```

**Notes:**
- 120-second timeout.
- Filter uses XCTest-style matching: `TestSuite/testMethod` or a name substring.
  Omit for the full test suite.

---

## Git

### `git_diff`

Show working tree or staged diff.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `path` | string | no | Scope diff to a specific file |
| `staged` | boolean | no | Show staged (`--cached`) diff. Default `false` |
| `cwd` | string | no | Git repo root. Defaults to invocation `cwd` |

**Returns:** `git diff` output capped at 8 KB. `"No diff."` if clean.

---

### `git_status`

Show modified, staged, and untracked files.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `cwd` | string | no | Git repo root. Defaults to invocation `cwd` |

**Returns:** `git status` output (not capped — status output is always short).

---

## SDK search

### `sdk_search`

Search Apple platform SDK `.swiftinterface` and `.h` headers for types, functions,
protocols, and conformances. Provides **ground-truth API signatures** from the
installed Xcode SDK — more reliable than web search for API existence checks.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `pattern` | string | yes | Regex or literal string |
| `framework` | string | no | Framework name, e.g. `"CoreMIDI"`, `"SwiftUI"` |
| `max_results` | integer | no | Max lines returned. Default 40 |

**Returns:** Matching lines with file paths and line numbers.
`"ERROR: framework not found in SDK: X"` if the named framework doesn't exist
in the SDK — the model should retry with a corrected framework name.

**Underlying command:**
```bash
grep -rn --include="*.swiftinterface" --include="*.h" \
  '<pattern>' $(xcrun --show-sdk-path)/System/Library/Frameworks[/<Framework>.framework]
```

**File types searched:**
- `.swiftinterface` — Swift overlay for each framework. Shows Swift-native types,
  `@available` annotations, protocol conformances, and generic constraints.
- `.h` — Objective-C headers. Use for C-level APIs like `MIDIClientCreate`,
  `MIDISendEventList`, and CoreFoundation types.

**Notes:**
- Scoping to a framework is significantly faster than a full-SDK search.
- 20-second timeout.

**Common query patterns:**
```
pattern: "MIDIClientCreate"              → find the exact C function signature
pattern: "protocol Sendable"             → confirm Sendable exists in stdlib
pattern: "CABTMidiCentralViewController" → verify BLE MIDI class is in SDK
pattern: "ViewModifier"  framework: "SwiftUI"
pattern: "@Observable"   framework: "Observation"
```

---

## Web

### `web_search`

DuckDuckGo Instant Answer API search.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `query` | string | yes | Search query |
| `max_results` | integer | no | Results to return. Default 8 |

**Returns:** Abstract (if any), then up to `max_results` related topics and result
entries with text snippets and URLs.

**Notes:**
- Uses `api.duckduckgo.com/?format=json` (Instant Answer API), not full web
  search. No API key required. Returns curated results, not ranked web pages.
- Best for: Swift Evolution proposals, Apple developer docs, Stack Overflow
  canonical answers, package READMEs.
- Not reliable for: very recent API changes, niche error messages, content behind
  login walls.
- Prefer `sdk_search` for API existence checks — `web_search` for conceptual
  questions and docs.
- 10-second timeout.

---

### `web_fetch`

Fetch and strip a URL to plain text.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `url` | string | yes | URL to fetch |
| `max_chars` | integer | no | Character cap on returned text. Default 8 000 |

**Returns:** Plain text — HTML tags stripped with regex `<[^>]+>`, entities
unescaped, whitespace normalised. Capped at `max_chars`.

**Notes:**
- Sends `User-Agent: fcis-agent/1.0`. Some sites block non-browser agents.
- HTML stripping is a simple regex, not a full parser. JavaScript-rendered pages
  return only the static HTML skeleton.
- 15-second timeout.
- Best for: raw GitHub Markdown files, Swift Evolution proposals
  (`https://github.com/swiftlang/swift-evolution/blob/main/proposals/XXXX-name.md`),
  Apple documentation pages.

---

## Tool availability by model

Both models receive the same tool list. In practice:

- **`qwen3-coder-30b-fcis`** uses tools aggressively — reads files, runs
  `swift_diagnostics`, and iterates on code across multiple turns before answering.
- **`qwen3-8b-fcis`** uses tools conservatively — mostly `read_file` and
  `web_search` to gather context before giving architectural advice.

Use `--no-tools` with the 8b model for pure planning/review sessions where you
want a fast single-shot response without file access.
