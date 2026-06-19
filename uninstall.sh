#!/usr/bin/env bash
# uninstall.sh — reverse install/install_shell.sh (and optionally remove models).
# Removes only the managed block (between markers); leaves the rest of your rc
# untouched. Homebrew / Node / Ollama / Claude Code are never removed.
#
# Usage: ./uninstall.sh [--shell zsh|bash] [--restore] [--purge-models]
#   --restore        restore the most recent rc backup instead of stripping the block
#   --purge-models   also remove the 3 tuned tags (qwen3-cc/-local/-air); keeps base model
set -euo pipefail

TARGET_SHELL=""
RESTORE=0
PURGE_MODELS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --shell) TARGET_SHELL="${2:-}"; shift 2 ;;
    --shell=*) TARGET_SHELL="${1#*=}"; shift ;;
    --restore) RESTORE=1; shift ;;
    --purge-models) PURGE_MODELS=1; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_0=''
fi
log()  { printf '%s\n' "${C_G}[uninstall]${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}[uninstall] warn:${C_0} $*" >&2; }
die()  { printf '%s\n' "${C_R}[uninstall] error:${C_0} $*" >&2; exit 1; }

if [ -z "$TARGET_SHELL" ]; then TARGET_SHELL="$(basename "${SHELL:-zsh}")"; fi
case "$TARGET_SHELL" in
  zsh)  RC="$HOME/.zshrc" ;;
  bash) RC="$HOME/.bashrc" ;;
  *)    die "Unknown --shell '$TARGET_SHELL' (expected zsh or bash)" ;;
esac

BEGIN="# >>> claude-local-fast >>>"
END="# <<< claude-local-fast <<<"

if [ "$RESTORE" = 1 ]; then
  # newest backup: rely on the sortable UTC timestamp in the suffix.
  # shellcheck disable=SC2012  # our own timestamped backups; ls+sort is fine here
  BACKUP="$(ls -1 "$RC".claude-local-fast.bak.* 2>/dev/null | sort | tail -1 || true)"
  [ -n "$BACKUP" ] || die "No backup found matching $RC.claude-local-fast.bak.*"
  cp "$BACKUP" "$RC"
  log "Restored $RC from $BACKUP"
else
  if [ -f "$RC" ]; then
    TMP="$(mktemp "${TMPDIR:-/tmp}/clf_unrc.XXXXXX")"
    trap 'rm -f "$TMP"' EXIT
    awk -v b="$BEGIN" -v e="$END" '
      $0 == b {skip=1; next}
      skip && $0 == e {skip=0; next}
      skip {next}
      {print}
    ' "$RC" > "$TMP"
    if cmp -s "$TMP" "$RC"; then
      log "No managed block found in $RC (nothing to remove)."
      rm -f "$TMP"; trap - EXIT
    else
      mv "$TMP" "$RC"; trap - EXIT
      log "Removed managed block from $RC"
    fi
  else
    warn "$RC does not exist — nothing to remove."
  fi
fi

if [ "$PURGE_MODELS" = 1 ]; then
  if command -v ollama >/dev/null 2>&1; then
    for tag in qwen3-cc qwen3-local qwen3-air; do
      if ollama list 2>/dev/null | awk '{print $1}' | sed 's/:latest$//' | grep -qx "$tag"; then
        log "Removing model $tag…"
        ollama rm "$tag" >/dev/null 2>&1 || warn "Could not remove $tag"
      fi
    done
    log "Tuned tags removed (base model qwen3:4b-instruct-2507-q4_K_M kept)."
  else
    warn "ollama not found — skipping model purge."
  fi
fi

printf '\nDone. Open a new shell (or: source %s) to drop the launchers.\n' "$RC"
