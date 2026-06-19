#!/usr/bin/env bash
# install/build_models.sh — pull the base model + create the 3 tuned tags.
# Idempotent: existing tags are skipped unless --force is given.
# Usage: install/build_models.sh [--force]
set -euo pipefail

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${CLAUDE_LOCAL_FAST_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

BASE_MODEL="qwen3:4b-instruct-2507-q4_K_M"

if [ -t 1 ]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_0=''
fi
log()  { printf '%s\n' "${C_G}[models]${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}[models] warn:${C_0} $*" >&2; }
die()  { printf '%s\n' "${C_R}[models] error:${C_0} $*" >&2; exit 1; }

command -v ollama >/dev/null 2>&1 || die "ollama not found — run install/deps.sh first."

# Names from `ollama list` carry a ":latest" suffix on created tags; strip it.
model_present() { # $1 = tag/name
  ollama list 2>/dev/null | awk '{print $1}' | sed 's/:latest$//' | grep -qx "$1"
}

# Ensure the Ollama daemon is reachable (start it tuned/offline-safe if not).
if ! curl -s http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  log "Starting Ollama (8GB-tuned, offline-safe)…"
  export OLLAMA_HOST=127.0.0.1:11434 OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 \
         OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_KEEP_ALIVE=5m OLLAMA_NO_CLOUD=1
  nohup ollama serve >"${TMPDIR:-/tmp}/ollama_serve.log" 2>&1 &
  t=0
  until curl -s http://127.0.0.1:11434/api/version >/dev/null 2>&1; do
    sleep 1; t=$((t+1))
    [ "$t" -ge 20 ] && die "Ollama didn't start — see ${TMPDIR:-/tmp}/ollama_serve.log"
  done
fi

# ---- base model ----
if model_present "$BASE_MODEL"; then
  log "Base model present: $BASE_MODEL"
else
  warn "Pulling base model $BASE_MODEL (~2.5 GB download)…"
  ollama pull "$BASE_MODEL"
fi

# ---- tuned tags ----
for tag in qwen3-cc qwen3-local qwen3-air; do
  mf="$REPO_DIR/ollama/Modelfile.$tag"
  [ -f "$mf" ] || die "Missing Modelfile: $mf"
  if [ "$FORCE" = 0 ] && model_present "$tag"; then
    log "Tag present: $tag (use --force to rebuild)"
  else
    log "Creating $tag from $(basename "$mf")…"
    ollama create "$tag" -f "$mf"
  fi
done

log "Done. Current models:"
ollama list
