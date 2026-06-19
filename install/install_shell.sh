#!/usr/bin/env bash
# install/install_shell.sh — idempotently wire the launchers into your shell rc.
#
# Adds ONLY a 3-line managed block (between markers) that exports
# CLAUDE_LOCAL_FAST_DIR and sources shell/claude-local-fast.zsh. Re-running
# replaces the block in place; uninstall.sh removes exactly that block. The rc
# is backed up first and never edited outside the markers.
#
# Usage: install/install_shell.sh [--shell zsh|bash] [--dir <repo path>]
set -euo pipefail

TARGET_SHELL=""
DIR_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --shell) TARGET_SHELL="${2:-}"; shift 2 ;;
    --shell=*) TARGET_SHELL="${1#*=}"; shift ;;
    --dir) DIR_OVERRIDE="${2:-}"; shift 2 ;;
    --dir=*) DIR_OVERRIDE="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

if [ -t 1 ]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_0=''
fi
log()  { printf '%s\n' "${C_G}[shell]${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}[shell] warn:${C_0} $*" >&2; }
die()  { printf '%s\n' "${C_R}[shell] error:${C_0} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${DIR_OVERRIDE:-${CLAUDE_LOCAL_FAST_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
[ -d "$REPO_DIR" ] || die "Repo dir not found: $REPO_DIR"
REPO_DIR="$(cd "$REPO_DIR" && pwd)"
[ -f "$REPO_DIR/shell/claude-local-fast.zsh" ] || die "Missing $REPO_DIR/shell/claude-local-fast.zsh"

# Resolve target shell + rc file.
if [ -z "$TARGET_SHELL" ]; then
  TARGET_SHELL="$(basename "${SHELL:-zsh}")"
fi
case "$TARGET_SHELL" in
  zsh)  RC="$HOME/.zshrc" ;;
  bash)
    warn "The launchers are zsh-syntax; bash is not supported yet (see plans/IMPLEMENTATION_PLAN.md §10)."
    warn "No changes made to ~/.bashrc. To use them now, run zsh and re-run with: --shell zsh"
    exit 0 ;;
  *) die "Unknown --shell '$TARGET_SHELL' (expected zsh or bash)" ;;
esac

BEGIN="# >>> claude-local-fast >>>"
END="# <<< claude-local-fast <<<"

touch "$RC"

# Back up before touching it.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$RC.claude-local-fast.bak.$STAMP"
cp "$RC" "$BACKUP"
log "Backed up $RC → $BACKUP"

TMP="$(mktemp "${TMPDIR:-/tmp}/clf_rc.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# Strip any existing managed block (markers inclusive), keep everything else.
awk -v b="$BEGIN" -v e="$END" '
  $0 == b {skip=1; next}
  skip && $0 == e {skip=0; next}
  skip {next}
  {print}
' "$RC" > "$TMP"

# Append a fresh managed block.
{
  printf '%s\n' "$BEGIN"
  printf 'export CLAUDE_LOCAL_FAST_DIR="%s"\n' "$REPO_DIR"
  # Single-quoted on purpose: write the literal $CLAUDE_LOCAL_FAST_DIR into the rc.
  # shellcheck disable=SC2016
  printf '%s\n' '[ -f "$CLAUDE_LOCAL_FAST_DIR/shell/claude-local-fast.zsh" ] && source "$CLAUDE_LOCAL_FAST_DIR/shell/claude-local-fast.zsh"'
  printf '%s\n' "$END"
} >> "$TMP"

mv "$TMP" "$RC"
trap - EXIT

# Validate (zsh target only).
if command -v zsh >/dev/null 2>&1; then
  if zsh -n "$RC"; then
    log "Validated: zsh -n $RC OK"
  else
    warn "zsh -n reported a problem; restoring backup."
    cp "$BACKUP" "$RC"
    die "Restored $RC from backup. No changes applied."
  fi
fi

log "Installed managed block into $RC"
printf '\nNext:\n  source %s\n  claude-local --help\n' "$RC"
