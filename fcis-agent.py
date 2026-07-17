#!/usr/bin/env python3
"""
FCIS Agent — routes coding tasks to qwen3-coder-30b-fcis and general queries
to qwen3-8b-fcis via the Ollama API. Injects the nearest AGENTS.md as system
context. Runs the tool loop for tool-calling responses.

Usage:
    python fcis-agent.py "your prompt"
    python fcis-agent.py --model coder "implement a Result-typed parser"
    python fcis-agent.py --model general "review this architecture decision"
    python fcis-agent.py --no-tools "quick question"
    python fcis-agent.py --no-think "skip thinking mode"
    python fcis-agent.py --agents /path/to/AGENTS.md "..."
    echo "prompt" | python fcis-agent.py

Environment:
    FCIS_AGENTS_MD   Override AGENTS.md path (absolute)
    OLLAMA_HOST      Override Ollama base URL (default http://localhost:11434)
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path

# ── Configuration ─────────────────────────────────────────────────────────────

OLLAMA_BASE   = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
TOOLS_FILE    = Path(__file__).parent / "tools/fcis_tools.json"
LOG_DIR       = Path(__file__).parent / ".logs"

MODEL_CODER   = "qwen3-coder-30b-fcis"
MODEL_GENERAL = "qwen3-8b-fcis"

# Keywords that signal a coding task → route to coder model
CODER_SIGNALS = {
    "implement", "write", "fix", "generate", "refactor", "code", "snippet",
    "func", "struct", "enum", "class", "protocol", "actor", "extension",
    "async", "await", "throws", "init", "type", "generic", "conform",
    "method", "property", "closure", "build", "compile", "error", "crash",
    "parse", "encode", "decode", "test", "spec", "assert", "mock",
}

# ── AGENTS.md discovery ───────────────────────────────────────────────────────

def find_agents_md(start: Path | None = None) -> Path | None:
    """Walk up from start (default: cwd) looking for AGENTS.md, like git does for .git."""
    if env := os.environ.get("FCIS_AGENTS_MD"):
        p = Path(env)
        return p if p.exists() else None
    root = start or Path.cwd()
    for directory in [root, *root.parents]:
        candidate = directory / "AGENTS.md"
        if candidate.exists():
            return candidate
    return None


def load_system_context(override: str | None = None) -> str:
    if override:
        p = Path(override)
        if p.exists():
            return f"# Project Context (AGENTS.md)\n\n{p.read_text()}"
        print(f"[fcis-agent] WARNING: --agents path not found: {p}", file=sys.stderr)

    agents_md = find_agents_md()
    if agents_md:
        print(f"[fcis-agent] context={agents_md}", file=sys.stderr)
        return f"# Project Context ({agents_md.name})\n\n{agents_md.read_text()}"

    print("[fcis-agent] WARNING: no AGENTS.md found — using built-in FCIS invariants only", file=sys.stderr)
    return ""


# ── Routing ───────────────────────────────────────────────────────────────────

def route_model(prompt: str) -> str:
    words = set(re.findall(r"\b\w+\b", prompt.lower()))
    return MODEL_CODER if (words & CODER_SIGNALS) else MODEL_GENERAL


# ── Tool execution ────────────────────────────────────────────────────────────

def expand(raw: str) -> Path:
    return Path(os.path.expanduser(raw)).resolve()


def default_cwd() -> Path:
    return Path.cwd()


def tool_read_file(args: dict) -> str:
    path = expand(args["path"])
    if not path.exists():
        return f"ERROR: not found: {path}"
    try:
        text = path.read_text()
        if line_range := args.get("lines"):
            lo, hi = (int(x) for x in line_range.split("-"))
            text = "\n".join(text.splitlines()[lo - 1 : hi])
        return text
    except Exception as e:
        return f"ERROR: {e}"


def tool_write_file(args: dict) -> str:
    path = expand(args["path"])
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.write_text(args["content"])
        return f"Written {len(args['content'])} bytes to {path}"
    except Exception as e:
        return f"ERROR: {e}"


# Patterns that would destroy source files or irreversibly remove data.
# The model must use explicit file-level write_file / git operations instead.
_BASH_BLOCKLIST = re.compile(
    r"rm\s+(-[a-zA-Z]*r[a-zA-Z]*f?|-[a-zA-Z]*f[a-zA-Z]*r?|--recursive)\s"  # rm -rf / rm -fr
    r"|rm\s+--recursive"
    r"|rmdir\s"
    r"|git\s+clean\s"          # git clean -fdx wipes untracked files
    r"|tuist\s+clean"        # tuist clean removes derived data
    r"|xcodebuild\s+clean"   # same for xcodebuild
    r"|mkfs|dd\s+if="      # disk-level operations
    r"|chmod\s+-R\s+000"       # permission wipe
    r"|:\s*>\s*/",               # truncate files under root
    re.IGNORECASE,
)

def tool_bash_exec(args: dict) -> str:
    command = args.get("command", "")
    cwd     = expand(args["cwd"]) if "cwd" in args else default_cwd()

    print(f"  [bash_exec] {command!r}", file=sys.stderr)

    if _BASH_BLOCKLIST.search(command):
        return (
            f"ERROR: command blocked — contains a potentially destructive operation: {command!r}. "
            "Use write_file, git operations, or a more targeted command instead."
        )

    try:
        result = subprocess.run(
            command, shell=True, cwd=cwd,
            capture_output=True, text=True, timeout=30,
        )
        out = result.stdout + result.stderr
        return out[:8000] if len(out) > 8000 else out
    except subprocess.TimeoutExpired:
        return "ERROR: timed out after 30s"
    except Exception as e:
        return f"ERROR: {e}"


def tool_list_directory(args: dict) -> str:
    path = expand(args["path"])
    ext  = args.get("extension", "")
    if not path.exists():
        return f"ERROR: not found: {path}"
    try:
        if args.get("recursive"):
            files = sorted(path.rglob(f"*.{ext}" if ext else "*"))
        else:
            files = sorted(path.glob(f"*.{ext}" if ext else "*"))
        return "\n".join(str(f.relative_to(path)) for f in files if f.is_file())
    except Exception as e:
        return f"ERROR: {e}"


def tool_grep_codebase(args: dict) -> str:
    base = expand(args["path"]) if "path" in args else default_cwd()
    ext  = args.get("extension", "")
    pat  = args["pattern"]
    cmd  = f'grep -rn --include="*.{ext}" {repr(pat)} {base}' if ext else \
           f'grep -rn {repr(pat)} {base}'
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
        out = result.stdout[:6000]
        return out if out else "No matches."
    except Exception as e:
        return f"ERROR: {e}"


def _sdk_path() -> str:
    r = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True)
    return r.stdout.strip()


def _swift_target() -> str:
    import platform
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    return f"{arch}-apple-macosx14.0"


def tool_swift_diagnostics(args: dict) -> str:
    path  = expand(args["path"])
    sdk   = _sdk_path()
    flags = args.get("extra_flags", "")
    cmd   = (f'xcrun swiftc -typecheck {path} -sdk {sdk} '
             f'-target {_swift_target()} -swift-version 6 {flags}')
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
        out = (r.stdout + r.stderr).strip()
        return out if out else "No diagnostics — file type-checks cleanly."
    except subprocess.TimeoutExpired:
        return "ERROR: type-check timed out after 60s"
    except Exception as e:
        return f"ERROR: {e}"


def tool_swift_build(args: dict) -> str:
    cwd    = expand(args["cwd"]) if "cwd" in args else default_cwd()
    config = args.get("configuration", "debug")
    cmd    = f"xcrun swift build -c {config} 2>&1"
    try:
        r = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True, timeout=120)
        out = (r.stdout + r.stderr)[:8000]
        return out if out else "Build produced no output."
    except subprocess.TimeoutExpired:
        return "ERROR: build timed out after 120s"
    except Exception as e:
        return f"ERROR: {e}"


def tool_swift_test(args: dict) -> str:
    cwd    = expand(args["cwd"]) if "cwd" in args else default_cwd()
    filter_ = args.get("filter", "")
    cmd    = f'xcrun swift test{f" --filter {repr(filter_)}" if filter_ else ""} 2>&1'
    try:
        r = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True, timeout=120)
        out = (r.stdout + r.stderr)[:8000]
        return out if out else "Tests produced no output."
    except subprocess.TimeoutExpired:
        return "ERROR: tests timed out after 120s"
    except Exception as e:
        return f"ERROR: {e}"


def tool_git_diff(args: dict) -> str:
    cwd    = expand(args["cwd"]) if "cwd" in args else default_cwd()
    staged = "--cached " if args.get("staged") else ""
    path   = str(expand(args["path"])) if "path" in args else ""
    cmd    = f"git diff {staged}{path}".strip()
    try:
        r = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True, timeout=15)
        out = (r.stdout + r.stderr)[:8000]
        return out if out else "No diff."
    except Exception as e:
        return f"ERROR: {e}"


def tool_git_status(args: dict) -> str:
    cwd = expand(args["cwd"]) if "cwd" in args else default_cwd()
    try:
        r = subprocess.run("git status", shell=True, cwd=cwd, capture_output=True, text=True, timeout=10)
        return (r.stdout + r.stderr).strip()
    except Exception as e:
        return f"ERROR: {e}"


def tool_sdk_search(args: dict) -> str:
    sdk       = _sdk_path()
    pattern   = args["pattern"]
    framework = args.get("framework", "")
    max_res   = int(args.get("max_results", 40))

    # Framework-scoped search uses the full framework dir (grep -r recurses into Versions/A/Headers/)
    if framework:
        search_root = f"{sdk}/System/Library/Frameworks/{framework}.framework"
        if not Path(search_root).exists():
            return f"ERROR: framework not found in SDK: {framework}"
    else:
        search_root = f"{sdk}/System/Library/Frameworks"

    # Search both .swiftinterface (Swift overlays) and .h (ObjC headers)
    cmd = (f'grep -rn --include="*.swiftinterface" --include="*.h" '
           f'{repr(pattern)} {repr(search_root)} 2>/dev/null | head -n {max_res}')
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=20)
        out = r.stdout.strip()
        return out if out else f"No SDK matches for '{pattern}'" + (f" in {framework}" if framework else "")
    except subprocess.TimeoutExpired:
        return "ERROR: SDK search timed out after 20s"
    except Exception as e:
        return f"ERROR: {e}"


def tool_web_search(args: dict) -> str:
    import urllib.parse
    query   = args["query"]
    max_res = int(args.get("max_results", 8))
    url     = f"https://api.duckduckgo.com/?q={urllib.parse.quote(query)}&format=json&no_html=1&skip_disambig=1"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "fcis-agent/1.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())

        results = []
        # Abstract (instant answer)
        if data.get("Abstract"):
            results.append(f"[Abstract] {data['Abstract']}\n  {data.get('AbstractURL','')}")
        # Related topics
        for topic in data.get("RelatedTopics", [])[:max_res]:
            if isinstance(topic, dict) and topic.get("Text"):
                url_link = topic.get("FirstURL", "")
                results.append(f"• {topic['Text'][:200]}\n  {url_link}")
        # Results
        for r in data.get("Results", [])[:max_res]:
            results.append(f"• {r.get('Text','')[:200]}\n  {r.get('FirstURL','')}")

        return "\n\n".join(results[:max_res]) if results else f"No results for '{query}'"
    except Exception as e:
        return f"ERROR: {e}"


def tool_web_fetch(args: dict) -> str:
    import html
    import re as _re
    url      = args["url"]
    max_chars = int(args.get("max_chars", 8000))
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "fcis-agent/1.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read().decode(errors="replace")
        # Strip HTML tags
        text = _re.sub(r"<[^>]+>", " ", raw)
        text = html.unescape(text)
        text = _re.sub(r"\s+", " ", text).strip()
        return text[:max_chars]
    except Exception as e:
        return f"ERROR: {e}"



def tool_tuist_generate(args: dict) -> str:
    cwd = expand(args["path"]) if "path" in args else default_cwd()
    try:
        r = subprocess.run("tuist generate", shell=True, cwd=cwd,
                           capture_output=True, text=True, timeout=120)
        out = (r.stdout + r.stderr)[:8000]
        return out if out else "tuist generate produced no output."
    except subprocess.TimeoutExpired:
        return "ERROR: tuist generate timed out after 120s"
    except Exception as e:
        return f"ERROR: {e}"


def tool_tuist_install(args: dict) -> str:
    cwd = expand(args["path"]) if "path" in args else default_cwd()
    try:
        r = subprocess.run("tuist install", shell=True, cwd=cwd,
                           capture_output=True, text=True, timeout=120)
        out = (r.stdout + r.stderr)[:8000]
        return out if out else "tuist install produced no output."
    except subprocess.TimeoutExpired:
        return "ERROR: tuist install timed out after 120s"
    except Exception as e:
        return f"ERROR: {e}"


def tool_tuist_lint(args: dict) -> str:
    cwd = expand(args["path"]) if "path" in args else default_cwd()
    try:
        r = subprocess.run("tuist lint project", shell=True, cwd=cwd,
                           capture_output=True, text=True, timeout=60)
        out = (r.stdout + r.stderr)[:8000]
        return out if out else "No lint issues found."
    except subprocess.TimeoutExpired:
        return "ERROR: tuist lint timed out after 60s"
    except Exception as e:
        return f"ERROR: {e}"


def tool_tuist_graph(args: dict) -> str:
    cwd    = expand(args["path"]) if "path" in args else default_cwd()
    fmt    = args.get("format", "json")
    try:
        r = subprocess.run(f"tuist graph --format {fmt}", shell=True, cwd=cwd,
                           capture_output=True, text=True, timeout=60)
        out = (r.stdout + r.stderr)[:8000]
        return out if out else "tuist graph produced no output."
    except subprocess.TimeoutExpired:
        return "ERROR: tuist graph timed out after 60s"
    except Exception as e:
        return f"ERROR: {e}"


def _http_get(url: str, timeout: int = 15) -> str:
    """Minimal GET helper shared by web_fetch and api_docs_fetch."""
    import html as _html
    req = urllib.request.Request(url, headers={"User-Agent": "fcis-agent/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode(errors="replace")
    return raw


def _strip_html(text: str) -> str:
    import re as _re, html as _html
    text = _re.sub(r"<[^>]+>", " ", text)
    text = _html.unescape(text)
    return _re.sub(r"\s+", " ", text).strip()


def _base_url(spec: dict) -> str:
    """Extract base URL from OpenAPI 2 (host+basePath) or OpenAPI 3 (servers)."""
    if servers := spec.get("servers"):
        return servers[0].get("url", "")
    host = spec.get("host", "")
    base = spec.get("basePath", "/")
    schemes = spec.get("schemes", ["https"])
    return f"{schemes[0]}://{host}{base}" if host else ""


def _format_openapi(spec: dict, endpoint_filter: str | None, max_chars: int) -> str:
    lines: list[str] = []
    info = spec.get("info", {})
    lines.append(f"API: {info.get('title', '?')} v{info.get('version', '?')}")
    base = _base_url(spec)
    if base:
        lines.append(f"Base URL: {base}")
    lines.append("")

    for path, methods in sorted(spec.get("paths", {}).items()):
        if endpoint_filter and endpoint_filter not in path:
            continue
        for method, op in methods.items():
            if method == "parameters":
                continue
            if not isinstance(op, dict):
                continue
            summary = op.get("summary", op.get("operationId", ""))
            lines.append(f"{method.upper()} {path}" + (f" — {summary}" if summary else ""))
            for p in op.get("parameters", []):
                req_tag = " (required)" if p.get("required") else ""
                ptype = p.get("schema", {}).get("type", p.get("type", "?"))
                lines.append(f"  param [{p.get('in','?')}] {p.get('name','?')}: {ptype}{req_tag}")
            if rb := op.get("requestBody"):
                for ct, media in rb.get("content", {}).items():
                    schema_str = json.dumps(media.get("schema", {}))[:200]
                    lines.append(f"  body ({ct}): {schema_str}")
            for code, resp in op.get("responses", {}).items():
                desc = resp.get("description", "") if isinstance(resp, dict) else ""
                lines.append(f"  → {code}: {desc}")
            lines.append("")

    return "\n".join(lines)[:max_chars]


def tool_api_docs_fetch(args: dict) -> str:
    url       = args.get("url", "")
    endpoint  = args.get("endpoint")
    max_chars = int(args.get("max_chars", 12000))

    if not url:
        return "ERROR: url is required"

    # Attempt 1: fetch the provided URL directly
    try:
        raw = _http_get(url)
    except Exception as e:
        return f"ERROR: could not fetch {url}: {e}"

    stripped = raw.lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        try:
            spec = json.loads(raw)
            if any(k in spec for k in ("paths", "openapi", "swagger")):
                return _format_openapi(spec, endpoint, max_chars)
        except json.JSONDecodeError:
            pass

    # Attempt 2: probe common OpenAPI spec paths from the root URL
    root = url.rstrip("/")
    for suffix in ["/openapi.json", "/swagger.json", "/api-docs",
                   "/v3/api-docs", "/swagger/v1/swagger.json", "/api/openapi.json"]:
        try:
            raw2 = _http_get(root + suffix, timeout=8)
            spec = json.loads(raw2)
            if "paths" in spec:
                return _format_openapi(spec, endpoint, max_chars)
        except Exception:
            continue

    # Fallback: return plain text
    return _strip_html(raw)[:max_chars]


TOOL_HANDLERS = {
    "read_file":          tool_read_file,
    "write_file":         tool_write_file,
    "bash_exec":          tool_bash_exec,
    "list_directory":     tool_list_directory,
    "grep_codebase":      tool_grep_codebase,
    "swift_diagnostics":  tool_swift_diagnostics,
    "swift_build":        tool_swift_build,
    "swift_test":         tool_swift_test,
    "git_diff":           tool_git_diff,
    "git_status":         tool_git_status,
    "sdk_search":         tool_sdk_search,
    "web_search":         tool_web_search,
    "web_fetch":          tool_web_fetch,
    "tuist_generate":     tool_tuist_generate,
    "tuist_install":      tool_tuist_install,
    "tuist_lint":         tool_tuist_lint,
    "tuist_graph":        tool_tuist_graph,
    "api_docs_fetch":     tool_api_docs_fetch,
}


def execute_tool(name: str, args: dict) -> str:
    handler = TOOL_HANDLERS.get(name)
    if not handler:
        return f"ERROR: unknown tool '{name}'"
    preview = json.dumps(args, ensure_ascii=False)[:120]
    print(f"  [tool] {name}({preview})", file=sys.stderr)
    try:
        return handler(args)
    except Exception as e:
        return f"ERROR: tool {name} failed: {e}"


# ── Ollama API ────────────────────────────────────────────────────────────────

def _post(payload: dict, timeout: int = 300) -> dict:
    data = json.dumps(payload).encode()
    req  = urllib.request.Request(
        f"{OLLAMA_BASE}/api/chat", data=data,
        headers={"Content-Type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        raise RuntimeError(f"HTTP {e.code}: {body}") from e
    except urllib.error.URLError as e:
        print(f"\nERROR: Ollama unreachable — {e}", file=sys.stderr)
        print("Is Ollama running?  brew services start ollama", file=sys.stderr)
        sys.exit(1)


_think_support_cache: dict[str, bool] = {}


def ollama_chat(model: str, messages: list, tools: list | None, think: bool) -> dict:
    payload: dict = {"model": model, "messages": messages, "stream": False}
    if tools:
        payload["tools"] = tools
    # Skip think=True if we already learned this model rejects it (HTTP 400).
    want_think = think and _think_support_cache.get(model, True)
    if want_think:
        payload["think"] = True
    try:
        return _post(payload)
    except RuntimeError as e:
        if want_think and "does not support thinking" in str(e):
            _think_support_cache[model] = False
            print(f"[fcis-agent] {model} does not support thinking — retrying without", file=sys.stderr)
            payload.pop("think")
            return _post(payload)
        raise


# ── Tool loop ─────────────────────────────────────────────────────────────────

MAX_ITERATIONS = 10

def run_agent(model: str, prompt: str, system: str, use_tools: bool, think: bool):
    """Returns (response_text, tool_trace, iterations_used, hit_cap, prompt_tokens, eval_tokens)."""
    tools    = json.loads(TOOLS_FILE.read_text()) if (use_tools and TOOLS_FILE.exists()) else None
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    tool_trace = []
    iteration  = 0

    while iteration < MAX_ITERATIONS:
        response = ollama_chat(model, messages, tools, think)
        msg      = response.get("message", {})
        calls    = msg.get("tool_calls", [])

        if not calls:
            if thinking := msg.get("thinking", ""):
                print(f"\n<think>\n{thinking}\n</think>\n", file=sys.stderr)
            return (
                msg.get("content", ""),
                tool_trace,
                iteration,
                False,
                response.get("prompt_eval_count", 0),
                response.get("eval_count", 0),
            )

        messages.append({"role": "assistant", **{k: v for k, v in msg.items() if k != "role"}})
        for call in calls:
            fn      = call.get("function", {})
            name    = fn.get("name", "")
            args    = fn.get("arguments", {})
            args_summary = ", ".join(f"{k}={str(v)[:60]}" for k, v in args.items())
            print(f"[fcis-agent] ⟳ {name}({args_summary})", file=sys.stderr, flush=True)
            t0      = time.monotonic()
            result  = execute_tool(name, args)
            ms      = int((time.monotonic() - t0) * 1000)
            if result.startswith("ERROR:"):
                print(f"[fcis-agent] ✗ Tool error (passing to model): {result}", file=sys.stderr)
            else:
                print(f"[fcis-agent] ✓ {name} → {len(result)}b in {ms}ms", file=sys.stderr)
            tool_trace.append({
                "tool":        name,
                "args":        args_summary,
                "result_len":  len(result),
                "duration_ms": ms,
                "is_error":    result.startswith("ERROR:"),
            })
            messages.append({"role": "tool", "content": result})
        iteration += 1

    return ("ERROR: tool loop exceeded iteration cap", tool_trace, MAX_ITERATIONS, True, 0, 0)


# ── Logging ───────────────────────────────────────────────────────────────────

def log_session(model: str, prompt: str, response: str, tool_trace: list,
                iterations: int, hit_cap: bool, prompt_tokens: int, eval_tokens: int):
    LOG_DIR.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    entry = {
        "timestamp":         stamp,
        "model":             model,
        "prompt":            prompt,
        "response":          response,
        "iterations_used":   iterations,
        "hit_iteration_cap": hit_cap,
        "prompt_tokens":     prompt_tokens,
        "eval_tokens":       eval_tokens,
        "tool_trace":        tool_trace,
    }
    (LOG_DIR / f"{stamp}_{model.replace(':', '-')}.json").write_text(json.dumps(entry, indent=2))


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="FCIS Ollama agent")
    parser.add_argument("prompt", nargs="?")
    parser.add_argument("--model", choices=["coder", "general", "auto"], default="auto")
    parser.add_argument("--agents", metavar="PATH", help="Explicit path to AGENTS.md")
    parser.add_argument("--no-tools", action="store_true")
    parser.add_argument("--no-think", action="store_true")
    parser.add_argument("--log",      action="store_true")
    parser.add_argument("--show-model", action="store_true")
    args = parser.parse_args()

    prompt = args.prompt
    if not prompt:
        if not sys.stdin.isatty():
            prompt = sys.stdin.read().strip()
        else:
            parser.print_help()
            sys.exit(1)

    model = (
        MODEL_CODER   if args.model == "coder"   else
        MODEL_GENERAL if args.model == "general" else
        route_model(prompt)
    )

    if args.show_model:
        print(f"Routed to: {model}")
        sys.exit(0)

    system = load_system_context(args.agents)

    print(f"[fcis-agent] model={model} tools={'off' if args.no_tools else 'on'} "
          f"think={'off' if args.no_think else 'on'}", file=sys.stderr)

    response, tool_trace, iterations, hit_cap, prompt_tokens, eval_tokens = run_agent(
        model=model, prompt=prompt, system=system,
        use_tools=not args.no_tools, think=not args.no_think,
    )
    print(response)
    if hit_cap:
        print(f"[fcis-agent] WARNING: tool loop hit {MAX_ITERATIONS}-iteration cap — response may be incomplete", file=sys.stderr)
    if eval_tokens:
        print(f"[fcis-agent] tokens: prompt={prompt_tokens} eval={eval_tokens} total={prompt_tokens + eval_tokens}", file=sys.stderr)
    if args.log:
        log_session(model, prompt, response, tool_trace, iterations, hit_cap, prompt_tokens, eval_tokens)


if __name__ == "__main__":
    main()