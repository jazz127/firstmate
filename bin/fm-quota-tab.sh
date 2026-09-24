#!/usr/bin/env bash
# fm-quota-tab.sh - read-only terminal view of the quota-axi fleet house line.
#
# Usage: bin/fm-quota-tab.sh [once|loop]
# FM_QUOTA_CLONE defaults to "$FM_HOME/projects/quota-axi".
# FM_QUOTA_TAB_INTERVAL defaults to 300 seconds and must be a positive integer.
# Reads jazz127/house after a quiet fetch attempt, resolves quota-axi from PATH,
# and runs quota-axi once per frame. It never writes to the quota-axi clone.
set -u

usage() {
  printf 'usage: fm-quota-tab.sh [once|loop]\n' >&2
}

mode=${1:-loop}
if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi
case "$mode" in
  once|loop) ;;
  *) usage; exit 2 ;;
esac

interval=${FM_QUOTA_TAB_INTERVAL:-300}
case "$interval" in
  ''|*[!0-9]*|0)
    printf 'fm-quota-tab.sh: FM_QUOTA_TAB_INTERVAL must be a positive integer\n' >&2
    exit 2
    ;;
esac

quota_clone=${FM_QUOTA_CLONE:-${FM_HOME:-}/projects/quota-axi}

frame() {
  local executable short subject
  clear 2>/dev/null || true
  printf '%s\n\n' 'quota-axi view of the fleet house line'
  if [ ! -d "$quota_clone/.git" ] && [ ! -f "$quota_clone/.git" ]; then
    printf 'House tip: quota-axi clone is absent (%s)\n' "$quota_clone"
  else
    git -C "$quota_clone" fetch --quiet jazz127 house:refs/remotes/jazz127/house >/dev/null 2>&1 || true
    short=$(git -C "$quota_clone" rev-parse --short jazz127/house 2>/dev/null) || short='unavailable'
    subject=$(git -C "$quota_clone" show -s --format=%s jazz127/house 2>/dev/null) || subject='unavailable'
    printf 'House tip: %s %s\n' "$short" "${subject%%$'\n'*}"
  fi

  executable=$(command -v quota-axi 2>/dev/null) || executable='unavailable'
  printf 'quota-axi executable: %s\n\n' "$executable"
  printf '%s\n' 'quota-axi account headroom:'
  if command -v quota-axi >/dev/null 2>&1; then
    quota-axi 2>&1 || true
  else
    printf '%s\n' 'quota-axi is not installed.'
  fi
  printf '\nRefreshed: %s | interval: %s seconds | refreshes while running\n' \
    "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$interval"
}

if [ "$mode" = once ]; then
  frame
  exit 0
fi

while :; do
  frame
  sleep "$interval"
done
