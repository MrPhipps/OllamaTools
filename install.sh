#!/usr/bin/env bash
# Install FCIS Ollama models from Modelfiles
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MF_DIR="$SCRIPT_DIR/modelfiles"

echo "==> Installing qwen3-coder-30b-fcis..."
ollama create qwen3-coder-30b-fcis -f "$MF_DIR/qwen3-coder-30b-fcis.Modelfile"

echo "==> Installing qwen3-8b-fcis..."
ollama create qwen3-8b-fcis -f "$MF_DIR/qwen3-8b-fcis.Modelfile"

echo ""
echo "==> Installed models:"
ollama list | grep fcis

echo ""
echo "==> Verify (shows parameters):"
echo "    curl -s localhost:11434/api/show -d '{\"model\":\"qwen3-coder-30b-fcis\"}' | jq .parameters "
echo "    curl -s localhost:11434/api/show -d '{\"model\":\"qwen3-coder-30b-fcis\"}' | jq .parameters "
echo ""
echo "==> Test routing:"
echo "    swift $SCRIPT_DIR/fcis-agent.swift --show-model 'write a Swift enum for MIDIMessage'"
echo "    swift $SCRIPT_DIR/fcis-agent.swift --show-model 'what is the FCIS architecture?'"
echo "    python $SCRIPT_DIR/fcis-agent.py --show-model 'write a Swift enum for MIDIMessage'"
echo "    python $SCRIPT_DIR/fcis-agent.py --show-model 'what is the FCIS architecture?'"
