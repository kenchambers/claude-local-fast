#!/usr/bin/env bash
# install/deps.sh — detect/install Homebrew, Ollama, Node+npm, Claude Code, python3.
# Idempotent: every step is skipped if already present. Safe to re-run.
# Usage: install/deps.sh [--yes]
set -euo pipefail

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    *) ;;
  esac
done

if [ -t 1 ]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi
log()  { printf '%s\n' "${C_G}[deps]${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}[deps] warn:${C_0} $*" >&2; }
die()  { printf '%s\n' "${C_R}[deps] error:${C_0} $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

confirm() { # $1 = prompt; honors --yes
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  printf '%s [y/N] ' "$1"
  local reply
  read -r reply || return 1
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

SUMMARY=""
record() { SUMMARY="${SUMMARY}  $1"$'\n'; }

# ---- Homebrew ----
if have brew; then
  log "Homebrew present"
  record "Homebrew      | present"
else
  warn "Homebrew not found."
  if confirm "Install Homebrew now (runs the official install script)?"; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Apple-Silicon Homebrew installs to /opt/homebrew and isn't on PATH yet.
    if [ -x /opt/homebrew/bin/brew ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    record "Homebrew      | installed"
  else
    warn "Skipping Homebrew. Install it from https://brew.sh then re-run."
    record "Homebrew      | MISSING (skipped)"
  fi
fi

# ---- Ollama ----
if have ollama; then
  log "Ollama present"
  record "Ollama        | present"
elif have brew; then
  log "Installing Ollama via Homebrew…"
  brew install ollama
  record "Ollama        | installed"
else
  warn "Cannot install Ollama without Homebrew. See https://ollama.com/download"
  record "Ollama        | MISSING"
fi
if have ollama && ! ollama --version >/dev/null 2>&1; then
  warn "ollama present but 'ollama --version' failed"
fi

# ---- Node + npm ----
if have node && have npm; then
  log "Node present ($(node --version)), npm present ($(npm --version))"
  record "Node + npm    | present"
else
  warn "Node/npm not found. This project does NOT auto-install a system Node."
  warn "Recommended: install nvm (https://github.com/nvm-sh/nvm), then 'nvm install --lts'."
  # Load an existing nvm so a later 'claude' install lands on PATH.
  NVM_SH="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
  if [ -s "$NVM_SH" ]; then
    # shellcheck disable=SC1090
    . "$NVM_SH"
    if have node; then log "Loaded nvm; node now $(node --version)"; fi
  fi
  if have node && have npm; then
    record "Node + npm    | present (via nvm)"
  else
    record "Node + npm    | MISSING (install nvm)"
  fi
fi

# ---- Claude Code ----
if have claude; then
  log "Claude Code present"
  record "Claude Code   | present"
elif have npm; then
  log "Installing Claude Code (npm -g @anthropic-ai/claude-code)…"
  npm install -g @anthropic-ai/claude-code
  record "Claude Code   | installed"
else
  warn "Cannot install Claude Code without npm. Install Node first."
  record "Claude Code   | MISSING"
fi

# ---- python3 (probe only; no pip deps) ----
if have python3; then
  log "python3 present ($(python3 --version 2>&1))"
  record "python3       | present"
else
  warn "python3 not found (needed only for the prefix probe). Install via Homebrew or python.org."
  record "python3       | MISSING"
fi

printf '\n%s\n' "${C_B}=== dependency summary ===${C_0}"
printf '%s' "$SUMMARY"
