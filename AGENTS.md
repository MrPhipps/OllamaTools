# AGENTS.md — ollama-fcis

Local harness that routes a prompt to one of two FCIS-tuned Ollama models, runs a tool-calling loop against the Ollama API, and injects the nearest `AGENTS.md` (found by walking up from the current directory) as system context. Python (`fcis-agent.py`) and Swift (`fcis-agent.swift`) implementations.

This file is itself injected as system context for runs started inside this repo. Keep it short: the 30b Modelfile sets `num_ctx 16384`.

## Repo
- Remote: https://github.com/MrPhipps/OllamaTools.git (`origin`), branch `main`
- Backs the `ollama-fcis` Claude agent and skill: `.claude/agents/ollama-fcis.md`, `.claude/skills/ollama-fcis.md` (`~/.claude/agents/ollama-fcis.md` is a symlink to the agent file)

## Commands
Taken from `install.sh` and the `fcis-agent.py` usage text; not executed in the 2026-10-27 review.
- Create the models: `./install.sh` (runs `ollama create` for `qwen3-coder-30b-fcis` and `qwen3-8b-fcis` from `modelfiles/`)
- Run: `python fcis-agent.py [--model coder|general] [--no-tools] [--no-think] [--agents PATH] [--log] [--show-model] "prompt"`
- Swift harness: `swift fcis-agent.swift --show-model "prompt"`
- Env: `FCIS_AGENTS_MD` (absolute path override), `OLLAMA_HOST` (default `http://localhost:11434`)

## Layout
- `fcis-agent.py`, `fcis-agent.swift` — harness (routing, AGENTS.md discovery, tool loop capped at 10 iterations, 300 s request timeout)
- `tools/fcis_tools.json` — 18 tool definitions
- `modelfiles/` — `qwen3-coder-30b-fcis.Modelfile` (FROM `qwen3-coder:30b`, ctx 16384), `qwen3-8b-fcis.Modelfile` (FROM `qwen3:8b`, ctx 32768)
- `doc/` — `architecture-internals.md`, `tool-reference.md`, `ollama-api-tool-calling.md`, `ollama-fcis-Swift.md`
- `install.sh`; `.claude/` (agent, skill, project memory)

## Routing
Bag-of-words heuristic: any of 35 coding keywords in the prompt routes to the coder model, otherwise to the general model. Use `--show-model` to check, and `--model` to override.

## Boundaries
- Never open, list, or modify anything named `heretic`. Treat `modelfiles/*abliterated*` as off-limits until James says otherwise.
- Do not commit, discard, or tidy the uncommitted files without asking: modified `modelfiles/qwen3-8b-fcis.Modelfile`; untracked `fcis-agent-fixed.swift`, `artifacts/`, `js`, `modelfiles/qwen3-coder-30b-fcis-abliterated.Modelfile`, a `.pyc`.
- Restart Ollama only with `brew services restart ollama --file=/Users/jphipps/Library/LaunchAgents/homebrew.mxcl.ollama.plist.backup --verbose` (source: `.claude/memory/feedback_ollama_plist.md`; Homebrew upgrades overwrite the live plist).
- Swift written here follows `~/.claude/CLAUDE.md`: no `default` on enum switches, no `init?` on domain types, typed error enums, two tabs per indent level.

## Verified status, 2026-10-27 (observed, not fixed)
- Ollama on this Mac: 0.40.11 (released 2026-10-24).
- **Decided 2026-10-27 (James):** `fcis-coder` and `fcis-general` are canonical. Both are built on the abliterated Qwen 3.8 base `hf.co/Ryn1998/Qwen3.8-27B-Heretic-Abliterated-Uncensored-GGUF` (17 GB each; capabilities tools, thinking, completion, vision; `num_ctx 32768`). Qwen 3.8 replaced `qwen3-coder-30b-fcis` and `qwen3-8b-fcis`, which are retired and no longer installed. The harness constants now point at the `fcis-*` names (branch `fix/fcis-model-names`). `install.sh` and the Modelfiles in `modelfiles/` still describe the retired models.
- Ollama API drift against the harness (official docs, github.com/ollama/ollama `docs/`):
	- Current docs show tool results as `{"role": "tool", "tool_name": ..., "content": ...}`. Both harnesses send `{"role": "tool", "content": ...}` (`fcis-agent.py:625`, `fcis-agent.swift:592`).
	- `think` also accepts level strings, and `/api/show` returns a top-level `thinking` object (`values`, `default`). The harness sends only boolean `true`.
	- Since 0.40.0 (2026-09-25), Apple Silicon runs MLX-supported architectures on MLX by default. The official Modelfile docs do not mention `num_gpu`, so whether `num_gpu` is honored for MLX-run models is unverified.
	- Ollama's hosted `web_search` API needs an API key. The harness's `web_search` uses DuckDuckGo instead (`fcis-agent.py:300`).
- Doc drift: `tool-reference.md` says 13 tools (18 exist); `architecture-internals.md` says 40 routing keywords (35 exist); `doc/ollama-fcis-Swift.md` reads as a model-generated conversion transcript with non-idiomatic Swift, not a spec (not compiled); `install.sh` repeats one `curl` line; `qwen3-8b-fcis.Modelfile` sets `repeat_penalty` twice (1.0, then 1.05).

## ai-sync results, 2026-10-27
Initial `doctor`: AGENTS.md missing, no state file, `claude-code` detected (no `.github/`, so no Copilot target). `apply --dry-run` would have written `.claude/rules/project-context.md` with empty content, so AGENTS.md was written first. Approved sequence: AGENTS.md, `ai-sync init`, `ai-sync apply`, `.ai-sync/` added to `.gitignore`.
