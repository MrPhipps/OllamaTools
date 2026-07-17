---
name: feedback_ollama_plist
description: Ollama plist management — always use .backup file to restart; brew and Homebrew upgrades overwrite the live plist
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 58c45637-d1d9-4343-8dac-c4b1b3e14838
---

Always restart ollama using the backup plist, not the live one:

```bash
brew services restart ollama --file=/Users/jphipps/Library/LaunchAgents/homebrew.mxcl.ollama.plist.backup --verbose
```

**Why:** `brew services` and Homebrew upgrades silently overwrite `homebrew.mxcl.ollama.plist`, discarding custom env vars (`OLLAMA_KV_CACHE_TYPE=f16`, `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_MAX_LOADED_MODELS=1`, etc.). The `.plist.backup` file is the durable source of truth for the FCIS model config.

**How to apply:** Any time ollama needs a restart (after model rebuilds, config changes, or troubleshooting), always use `--file=...plist.backup`. After restart, verify with `launchctl print gui/501/homebrew.mxcl.ollama | grep -A 20 environment`.
