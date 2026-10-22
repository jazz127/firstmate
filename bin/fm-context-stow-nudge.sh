#!/usr/bin/env bash
# Context-threshold nudge owner. Usage: --claude-status | --claude-hook | --pi
# Claude statusLine supplies session_id and context_window.used_percentage;
# its hooks consume the pending nudge as additionalContext. Pi supplies
# session_id and percent and receives the operational envelope directly.
# config/context-stow-threshold (FM_CONFIG_OVERRIDE supported) is an integer
# 1..100, default 70; 0 disables nudges. Invalid configuration stands down.
# state/.context-stow-<session_id>.json stores above/pending, under the shared
# wake mutex. A below-threshold observation rearms the next upward crossing.
# Only the lock-owning primary/secondmate may observe or consume. Always exits 0.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
case "${1:-}" in --claude-status|--claude-hook|--pi) mode=$1 ;; *) exit 0 ;; esac
[ "${FM_PRECOMPACT_STOW_ACTIVE:-0}" != 1 ] || exit 0
[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0
fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_session_lock_owned_by_self "$STATE" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat) || exit 0
fm_hook_payload_is_foreign_host "$payload" && exit 0
session=$(printf '%s' "$payload" | jq -er '.session_id | strings | select(length > 0 and length <= 128)') || exit 0
case "$session" in *[!a-zA-Z0-9_-]*) exit 0 ;; esac
printf '%s' "$payload" | jq -e '.agent_id? == null' >/dev/null 2>&1 || exit 0
threshold=70
config="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/context-stow-threshold"
if [ -f "$config" ]; then threshold=$(cat "$config") || exit 0; fi
case "$threshold" in 0) exit 0 ;; ''|0*|*[!0-9]*) exit 0 ;; esac
[ "${#threshold}" -le 3 ] && [ "$threshold" -le 100 ] || exit 0
record="$STATE/.context-stow-$session.json"
[ ! -L "$record" ] || exit 0
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
lock="$STATE/.context-stow-nudge.lock"
fm_lock_try_acquire "$lock" || exit 0
trap 'fm_lock_release "$lock"' EXIT
above=false
pending=false
if [ -f "$record" ]; then
  above=$(jq -r '.above == true' "$record") || exit 0
  pending=$(jq -r '.pending == true' "$record") || exit 0
fi
if [ "$mode" != --claude-hook ]; then
  percent=$(printf '%s' "$payload" | jq -er --arg mode "$mode" '
    (if $mode == "--pi" then .percent else .context_window.used_percentage end)
    | numbers | select(. >= 0 and . <= 100)') || exit 0
  high=$(jq -n --argjson percent "$percent" --argjson threshold "$threshold" '$percent >= $threshold') || exit 0
  if [ "$high" = true ] && [ "$above" = false ]; then pending=true; fi
  if [ "$high" = false ]; then pending=false; fi
  above=$high
else
  event=$(printf '%s' "$payload" | jq -er '.hook_event_name') || exit 0
  case "$event" in UserPromptSubmit|PreToolUse) ;; *) exit 0 ;; esac
fi
nudge=
if [ "$mode" != --claude-status ] && [ "$pending" = true ]; then
  fm_operational_input_encode context-stow 'Context usage crossed the configured stow threshold. Run /stow now to persist established knowledge and open work before compaction.' nudge || exit 0
  pending=false
fi
umask 077
tmp=$(mktemp "$STATE/.context-stow.XXXXXX") || exit 0
if ! jq -n --argjson above "$above" --argjson pending "$pending" '{above:$above,pending:$pending}' > "$tmp" || ! mv -f "$tmp" "$record"; then
  rm -f "$tmp"
  exit 0
fi
case "$mode" in
  --claude-status) printf 'Context: %s%%\n' "$percent" ;;
  --claude-hook)
    [ -n "$nudge" ] || exit 0
    jq -n --arg event "$event" --arg content "$nudge" '{hookSpecificOutput:{hookEventName:$event,additionalContext:$content}}'
    ;;
  --pi) [ -z "$nudge" ] || printf '%s\n' "$nudge" ;;
esac
exit 0
