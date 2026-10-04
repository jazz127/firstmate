#!/usr/bin/env bash
# Complete or inspect a deliberate primary-session context handoff.
# Usage:
#   fm-context-restart.sh read-budget
#   fm-context-restart.sh handoff --session <session-id> --reset-safe
#
# `read-budget` validates and prints config/context-restart-budget.
# `handoff` is called only after the internal /stow pass reports reset-safe. It
# verifies the durable threshold crossing and current session-lock ownership,
# advances the record to ready when bin/fm-primary.sh supplied a private wrapper
# token. Its supervisor transfers any needed watcher, publishes replacing, and
# terminates Claude. Automatic handoff waits for that replacing commit before
# reporting success. The wrapper requires that token-matching replacing sentinel
# after its child exits, releases only the exact dead owner's session lock, and
# starts a fresh session.
#
# Without the wrapper token, durable preparation still succeeds but this command
# returns 3 with the manual exit-and-relaunch fallback. Repeating the same exact
# handoff is idempotent, so interruption after ready publication can retry it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECORD="$STATE/.context-restart-crossing"
CLAIM="$STATE/.context-restart.lock"

# shellcheck source=bin/fm-context-restart-lib.sh
. "$SCRIPT_DIR/fm-context-restart-lib.sh"

usage() {
  sed -n '2,5{s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-}" in
  read-budget)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    if ! fm_context_restart_budget_read "$CONFIG"; then
      printf 'context-restart-budget: invalid config/%s - %s\n' \
        "$FM_CONTEXT_RESTART_BUDGET_FILE" "$FM_CONTEXT_RESTART_BUDGET_ERROR" >&2
      exit 1
    fi
    exit 0
    ;;
  handoff) ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
shift

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"


SESSION_ID=
RESET_SAFE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      SESSION_ID=$2
      shift 2
      ;;
    --reset-safe)
      RESET_SAFE=1
      shift
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done
if [ "$RESET_SAFE" -ne 1 ] || ! fm_context_restart_safe_atom "$SESSION_ID"; then
  usage >&2
  exit 2
fi

fm_context_restart_budget_read "$CONFIG" >/dev/null || {
  echo "context-restart: refresh is disabled or its budget is invalid" >&2
  exit 1
}
fm_primary_scope_matches "$FM_ROOT" "$STATE" || {
  echo "context-restart: not a genuine primary Firstmate home" >&2
  exit 1
}
fm_session_lock_owned_by_self "$STATE" || {
  echo "context-restart: current session does not own this home's session lock" >&2
  exit 1
}
LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
case "$LOCK_PID" in
  ''|*[!0-9]*)
    echo "context-restart: current session lock is malformed" >&2
    exit 1
    ;;
esac
fm_harness_pid_alive "$LOCK_PID" || {
  echo "context-restart: current session-lock owner is not a live verified harness" >&2
  exit 1
}

fm_lock_try_acquire "$CLAIM" || {
  echo "context-restart: another handoff step is already active; retry this command" >&2
  exit 1
}
trap 'fm_lock_release "$CLAIM"' EXIT

fm_context_restart_record_read "$RECORD" >/dev/null 2>&1 || {
  echo "context-restart: durable threshold crossing is missing or invalid" >&2
  exit 1
}
[ "$FM_CONTEXT_RESTART_RECORD_SESSION" = "$SESSION_ID" ] || {
  echo "context-restart: crossing belongs to a different Claude session" >&2
  exit 1
}

case "$FM_CONTEXT_RESTART_RECORD_PHASE" in
  detected|ready|replacing) ;;
  *) echo "context-restart: this session has no threshold crossing to hand off" >&2; exit 1 ;;
esac

TOKEN=${FM_CONTEXT_RESTART_WRAPPER_TOKEN:-}
MODE=manual
if [ -n "$TOKEN" ]; then
  case "$TOKEN" in *[!A-Fa-f0-9]*)
    echo "context-restart: wrapper token is malformed" >&2
    exit 1
    ;;
  esac
  [ "${#TOKEN}" -ge 16 ] && [ "${#TOKEN}" -le 128 ] || {
    echo "context-restart: wrapper token is malformed" >&2
    exit 1
  }
  MODE=automatic
fi

if [ "$MODE" = automatic ]; then
  BRIDGE_PID=${FM_CONTEXT_RESTART_BRIDGE_PID:-}
  case "$BRIDGE_PID" in ''|*[!0-9]*)
    echo "context-restart: no wrapper-owned supervision handoff process" >&2
    exit 1 ;;
  esac
  kill -0 "$BRIDGE_PID" 2>/dev/null || {
    echo "context-restart: wrapper-owned supervision handoff process exited; keep this session running" >&2
    exit 1
  }
fi

if [ "$FM_CONTEXT_RESTART_RECORD_PHASE" = ready ] || [ "$FM_CONTEXT_RESTART_RECORD_PHASE" = replacing ]; then
  [ "$FM_CONTEXT_RESTART_RECORD_LOCK_PID" = "$LOCK_PID" ] || {
    echo "context-restart: ready crossing names a different session-lock owner" >&2
    exit 1
  }
  [ "$FM_CONTEXT_RESTART_RECORD_MODE" = "$MODE" ] || {
    echo "context-restart: ready crossing uses a different relaunch mode" >&2
    exit 1
  }
  if [ "$MODE" = automatic ] \
    && [ "$FM_CONTEXT_RESTART_RECORD_TOKEN" != "$TOKEN" ]; then
    echo "context-restart: ready crossing belongs to a different relaunch wrapper" >&2
    exit 1
  fi
else
  fm_context_restart_record_publish \
    "$STATE" "$FM_CONTEXT_RESTART_RECORD_SESSION" \
    "$FM_CONTEXT_RESTART_RECORD_CONTEXT" "$FM_CONTEXT_RESTART_RECORD_BUDGET" \
    "$FM_CONTEXT_RESTART_RECORD_DETECTED_AT" ready "$MODE" "$TOKEN" "$LOCK_PID" || {
      echo "context-restart: could not publish the reset-safe handoff" >&2
      exit 1
    }
fi

if [ "$MODE" = manual ]; then
  echo "context-restart: handoff is durable, but this session was not launched by bin/fm-primary.sh; exit Claude and relaunch with bin/fm-primary.sh so the fresh session can resume from its session-start digest" >&2
  exit 3
fi

# Let the bridge acquire the publication lock, then keep the tool call pending
# until supervision transfer commits. A print-mode Claude can otherwise finish
# its final turn and exit while the record is only ready, before the wrapper is
# authorized to launch a successor.
fm_lock_release "$CLAIM"
trap - EXIT
while fm_context_restart_record_read "$RECORD" >/dev/null 2>&1 \
  && [ "$FM_CONTEXT_RESTART_RECORD_SESSION" = "$SESSION_ID" ] \
  && [ "$FM_CONTEXT_RESTART_RECORD_MODE" = automatic ] \
  && [ "$FM_CONTEXT_RESTART_RECORD_TOKEN" = "$TOKEN" ] \
  && [ "$FM_CONTEXT_RESTART_RECORD_LOCK_PID" = "$LOCK_PID" ]; do
  if [ "$FM_CONTEXT_RESTART_RECORD_PHASE" = replacing ]; then
    printf 'context-restart: reset-safe handoff committed; wrapper will end this Claude session\n'
    exit 0
  fi
  [ "$FM_CONTEXT_RESTART_RECORD_PHASE" = ready ] && fm_pid_alive "$BRIDGE_PID" || break
  sleep 0.1
done
echo 'context-restart: supervision transfer did not commit; keep this session running' >&2
exit 1
