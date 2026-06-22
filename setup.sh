#!/usr/bin/env bash
# setup.sh — one-command installer for claude-local-fast.
# Installs deps → builds tuned models → wires the launchers into your shell.
# Everything is idempotent and safe to re-run.
#
# Usage: ./setup.sh [--yes] [--no-shell] [--shell zsh|bash] [--dir <path>] [--skip-models]
set -euo pipefail

ASSUME_YES=0
DO_SHELL=1
DO_MODELS=1
TARGET_SHELL=""
DIR_OVERRIDE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y)      ASSUME_YES=1; shift ;;
    --no-shell)    DO_SHELL=0; shift ;;
    --skip-models) DO_MODELS=0; shift ;;
    --shell)       TARGET_SHELL="${2:-}"; shift 2 ;;
    --shell=*)     TARGET_SHELL="${1#*=}"; shift ;;
    --dir)         DIR_OVERRIDE="${2:-}"; shift 2 ;;
    --dir=*)       DIR_OVERRIDE="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi
log()  { printf '%s\n' "${C_G}[setup]${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}[setup] warn:${C_0} $*" >&2; }
die()  { printf '%s\n' "${C_R}[setup] error:${C_0} $*" >&2; exit 1; }

# Resolve repo root = directory of this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_LOCAL_FAST_DIR="${DIR_OVERRIDE:-$SCRIPT_DIR}"
CLAUDE_LOCAL_FAST_DIR="$(cd "$CLAUDE_LOCAL_FAST_DIR" && pwd)"
export CLAUDE_LOCAL_FAST_DIR

printf '%s\n' "${C_B}claude-local-fast setup${C_0}  (dir: $CLAUDE_LOCAL_FAST_DIR)"

# ---- Preflight ----
[ "$(uname -s)" = "Darwin" ] || warn "Not macOS — the launchers target macOS/Apple Silicon; continuing anyway."
if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" != "arm64" ]; then
  warn "Not Apple Silicon (uname -m = $(uname -m)). Intel Macs run the local model on CPU — expect it to be slow."
fi
if [ "$(uname -s)" = "Darwin" ]; then
  MEM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  MEM_GB=$(( MEM_BYTES / 1024 / 1024 / 1024 ))
  if [ "$MEM_GB" -gt 0 ] && [ "$MEM_GB" -lt 8 ]; then
    warn "Detected ${MEM_GB} GB RAM — below the 8 GB target. The model may swap; prefer claude-local (medium)."
  else
    log "RAM: ${MEM_GB} GB"
  fi
fi
command -v git  >/dev/null 2>&1 || die "git is required."
command -v curl >/dev/null 2>&1 || die "curl is required."

# ---- Steps ----
log "1/3 dependencies…"
if [ "$ASSUME_YES" = 1 ]; then
  bash "$CLAUDE_LOCAL_FAST_DIR/install/deps.sh" --yes
else
  bash "$CLAUDE_LOCAL_FAST_DIR/install/deps.sh"
fi

if [ "$DO_MODELS" = 1 ]; then
  log "2/3 models…"
  bash "$CLAUDE_LOCAL_FAST_DIR/install/build_models.sh"
else
  warn "2/3 models… skipped (--skip-models)"
fi

if [ "$DO_SHELL" = 1 ]; then
  log "3/3 shell wiring…"
  if [ -n "$TARGET_SHELL" ]; then
    bash "$CLAUDE_LOCAL_FAST_DIR/install/install_shell.sh" --dir "$CLAUDE_LOCAL_FAST_DIR" --shell "$TARGET_SHELL"
  else
    bash "$CLAUDE_LOCAL_FAST_DIR/install/install_shell.sh" --dir "$CLAUDE_LOCAL_FAST_DIR"
  fi
else
  warn "3/3 shell wiring… skipped (--no-shell)"
fi

printf '\n%s\n' "${C_B}✅ Done.${C_0}"
if [ "$DO_SHELL" = 1 ] && [ "$TARGET_SHELL" != "bash" ]; then
  # Shell wiring ran for zsh (explicit --shell zsh or auto-detected).
  printf 'Next:\n  source ~/.zshrc\n  claude-local --help\n'
elif [ "$DO_SHELL" = 1 ]; then
  # --shell bash: install_shell.sh made no changes (launchers are zsh-only).
  printf 'Next:\n  The launchers are zsh-only. Start zsh, then run:\n    install/install_shell.sh --shell zsh\n'
else
  # --no-shell: wiring was skipped entirely.
  printf 'Next:\n  Wire the launchers when ready:\n    install/install_shell.sh --shell zsh\n'
fi
