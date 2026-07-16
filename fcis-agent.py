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
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path

# ── Configuration ─────────────────────────────────────────────────────────────

OLLAMA_BASE   = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
TOOLS_FILE    = Path(__file__).parent / "tools/fcis_tools.json"
LOG_DIR       = Path(__file__).parent / "logs"

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


def tool_bash_exec(args: dict) -> str:
    cwd = expand(args["cwd"]) if "cwd" in args else default_cwd()
    try:
        result = subprocess.run(
            args["command"], shell=True, cwd=cwd,
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
    pattern  = f"**/*.{ext}" if ext and args.get("recursive") else (f"*.{ext}" if ext else "*")
    glob_fn  = path.glob if not args.get("recursive") else path.rglob
    pattern  = f"*.{ext}" if ext else "*"
    if args.get("recursive"):
        files = sorted(path.rglob(f"*.{ext}" if ext else "*"))
    else:
        files = sorted(path.glob(f"*.{ext}" if ext else "*"))
    return "\n".join(str(f.relative_to(path)) for f in files if f.is_file())


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
}


def execute_tool(name: str, args: dict) -> str:
    handler = TOOL_HANDLERS.get(name)
    if not handler:
        return f"ERROR: unknown tool '{name}'"
    preview = json.dumps(args, ensure_ascii=False)[:120]
    print(f"  [tool] {name}({preview})", file=sys.stderr)
    return handler(args)


# ── Ollama API ────────────────────────────────────────────────────────────────

_think_support_cache: dict[str, bool] = {}


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


def supports_thinking(model: str) -> bool:
    """Check whether the model supports think:true via /api/show. Cached per session."""
    if model not in _think_support_cache:
        try:
            data = json.dumps({"model": model}).encode()
            req  = urllib.request.Request(
                f"{OLLAMA_BASE}/api/show", data=data,
                headers={"Content-Type": "application/json"}, method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                info = json.loads(resp.read())
            # Ollama 0.19+ lists capabilities in model info
            caps = info.get("capabilities", [])
            template = info.get("modelfile", "") + info.get("template", "")
            _think_support_cache[model] = (
                "thinking" in caps or
                "<think>" in template or
                "thinking" in template.lower()
            )
        except Exception:
            # On any error, assume no thinking support rather than crashing
            _think_support_cache[model] = False
        print(f"[fcis-agent] {model} thinking={'yes' if _think_support_cache[model] else 'no'}",
              file=sys.stderr)
    return _think_support_cache[model]


def ollama_chat(model: str, messages: list, tools: list | None, think: bool) -> dict:
    payload: dict = {"model": model, "messages": messages, "stream": False}
    if think and supports_thinking(model):
        payload["think"] = True
    if tools:
        payload["tools"] = tools
    return _post(payload)


# ── Tool loop ─────────────────────────────────────────────────────────────────

def run_agent(model: str, prompt: str, system: str, use_tools: bool, think: bool) -> str:
    tools    = json.loads(TOOLS_FILE.read_text()) if (use_tools and TOOLS_FILE.exists()) else None
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    for _ in range(10):
        response = ollama_chat(model, messages, tools, think)
        msg      = response.get("message", {})
        calls    = msg.get("tool_calls", [])

        if not calls:
            if thinking := msg.get("thinking", ""):
                print(f"\n<think>\n{thinking}\n</think>\n", file=sys.stderr)
            return msg.get("content", "")

        messages.append({"role": "assistant", **{k: v for k, v in msg.items() if k != "role"}})
        for call in calls:
            fn     = call.get("function", {})
            result = execute_tool(fn.get("name", ""), fn.get("arguments", {}))
            messages.append({"role": "tool", "content": result})

    return "ERROR: tool loop exceeded 10 iterations."


# ── Logging ───────────────────────────────────────────────────────────────────

def log_session(model: str, prompt: str, response: str):
    LOG_DIR.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    (LOG_DIR / f"{stamp}_{model.replace(':', '-')}.json").write_text(
        json.dumps({"timestamp": stamp, "model": model, "prompt": prompt, "response": response}, indent=2)
    )


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

    response = run_agent(
        model=model, prompt=prompt, system=system,
        use_tools=not args.no_tools, think=not args.no_think,
    )
    print(response)
    if args.log:
        log_session(model, prompt, response)


if __name__ == "__main__":
    main()
