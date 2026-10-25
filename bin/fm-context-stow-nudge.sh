#!/usr/bin/env bash
# Context-threshold nudge owner. Usage: --claude-hook | --pi
# Claude UserPromptSubmit/PreToolUse supply session_id and transcript_path;
# the latest main-session assistant usage after the last compact boundary is
# sampled and a crossing is delivered as additionalContext. Pi supplies
# session_id and a nonnegative, uncapped percent and receives the envelope.
# config/context-stow-threshold (FM_CONFIG_OVERRIDE supported) is an integer
# 1..100, default 70; 0 disables nudges. Invalid configuration stands down.
# Claude's config/context-stow-window-tokens is the positive token capacity
# used for the transcript estimate, default 200000; set it for a larger window.
# Usage counts input, cache creation, cache reads, and output of one response.
# state/.context-stow-<session_id>.json stores above, under the shared wake
# mutex. A below-threshold observation rearms the next upward crossing.
# Only the lock-owning primary/secondmate may observe. Always exits 0.
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
case "${1:-}" in --claude-hook|--pi) mode=$1 ;; *) exit 0 ;; esac
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
case "$mode" in
  --claude-hook)
    event=$(printf '%s' "$payload" | jq -er '.hook_event_name') || exit 0
    case "$event" in UserPromptSubmit|PreToolUse) ;; *) exit 0 ;; esac
    transcript=$(printf '%s' "$payload" | jq -er '.transcript_path | strings | select(startswith("/") and (contains("\n") | not))') || exit 0
    [ -f "$transcript" ] && [ -r "$transcript" ] && [ ! -L "$transcript" ] || exit 0
    window=200000
    config="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/context-stow-window-tokens"
    if [ -f "$config" ]; then window=$(cat "$config") || exit 0; fi
    case "$window" in ''|0*|*[!0-9]*) exit 0 ;; esac
    percent=$(jq -Rne --arg session "$session" --argjson window "$window" '
      reduce inputs as $line (null;
        (try ($line | fromjson) catch null) as $entry |
        if ($entry | type) != "object" then .
        elif $entry.sessionId != $session or $entry.isSidechain == true then .
        elif $entry.type == "system" and $entry.subtype == "compact_boundary" then null
        elif $entry.type == "assistant" then $entry.message.usage
        else . end) |
      select(type == "object") |
      select(.input_tokens | type == "number") |
      [.input_tokens, (.cache_creation_input_tokens // 0), (.cache_read_input_tokens // 0), (.output_tokens // 0)] |
      select(all(.[]; type == "number" and . >= 0)) |
      add * 100 / $window
    ' "$transcript" 2>/dev/null) || exit 0
    ;;
  --pi)
    percent=$(printf '%s' "$payload" | jq -er '.percent | numbers | select(. >= 0)') || exit 0
    ;;
esac
above=false
if [ -f "$record" ]; then
  above=$(jq -r '.above == true' "$record") || exit 0
fi
high=$(jq -n --argjson percent "$percent" --argjson threshold "$threshold" '$percent >= $threshold') || exit 0
nudge=
if [ "$high" = true ] && [ "$above" = false ]; then
  fm_operational_input_encode context-stow 'Context usage crossed the configured stow threshold. Run /stow now to persist established knowledge and open work before compaction.' nudge || exit 0
fi
umask 077
tmp=$(mktemp "$STATE/.context-stow.XXXXXX") || exit 0
if ! jq -n --argjson above "$high" '{above:$above}' > "$tmp" || ! mv -f "$tmp" "$record"; then
  rm -f "$tmp"
  exit 0
fi
[ -n "$nudge" ] || exit 0
case "$mode" in
  --claude-hook)
    jq -n --arg event "$event" --arg content "$nudge" '{hookSpecificOutput:{hookEventName:$event,additionalContext:$content}}'
    ;;
  --pi) printf '%s\n' "$nudge" ;;
esac
exit 0
