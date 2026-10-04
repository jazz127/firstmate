#!/usr/bin/env bash
# Wrapper-owned supervision across one opted-in Claude context handoff.
# Usage: fm-context-restart-supervise.sh <wrapper-pid> <private-token>
# Internal child of fm-primary.sh, outside Claude's hook process tree.
# Wait for this generation's reset-safe ready record; when supervision is
# needed, take over the current arm through fm-watch-arm.sh before terminating
# Claude. Keep cycling until a successor session's auto-arm owns delivery.
# No wake is drained or acknowledged here. Queue rows survive the handoff.
# Failure to establish supervision leaves Claude running and reports the error.
# The wrapper owns this child's lifetime and terminates it on an ordinary exit.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
WRAPPER_PID=${1:-}
TOKEN=${2:-}
[ "$#" -eq 2 ] || exit 2
case "$WRAPPER_PID:$TOKEN" in *[!0-9a-fA-F:]*|:*|*:) exit 2 ;; esac
# shellcheck source=bin/fm-context-restart-lib.sh
. "$SCRIPT_DIR/fm-context-restart-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
RECORD="$STATE/.context-restart-crossing"
ARM_PID=
ARM_OUT=
LAST_ARM_PID=
# shellcheck disable=SC2329 # Trap handler.
cleanup() {
  trap - EXIT HUP INT TERM
  if [ -n "$ARM_PID" ]; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  [ -z "$ARM_OUT" ] || rm -f "$ARM_OUT"
}
trap cleanup EXIT
trap 'exit 143' HUP INT TERM
ready() {
  [ -f "$RECORD" ] && fm_context_restart_budget_read "$CONFIG" >/dev/null 2>&1 \
    && fm_context_restart_record_read "$RECORD" >/dev/null 2>&1 \
    && [ "$FM_CONTEXT_RESTART_RECORD_PHASE" = ready ] \
    && [ "$FM_CONTEXT_RESTART_RECORD_MODE" = automatic ] \
    && [ "$FM_CONTEXT_RESTART_RECORD_TOKEN" = "$TOKEN" ]
}
while kill -0 "$WRAPPER_PID" 2>/dev/null; do
  ready && break
  sleep 0.2
done
ready || exit 0
OLD_PID=$FM_CONTEXT_RESTART_RECORD_LOCK_PID
[ "$(cat "$STATE/.lock" 2>/dev/null)" = "$OLD_PID" ] || exit 1
fm_harness_pid_alive "$OLD_PID" || exit 0

# The away daemon is independent of Claude and remains the supervision owner.
needs_bridge() {
  fm_supervision_needed "$STATE" "$GRACE" || return 1
  fm_afk_daemon_owns_supervision "$STATE" && return 1
  return 0
}
start_arm_once() {
  local parent='' i=0
  ARM_OUT=$(mktemp "$STATE/.context-restart-arm.XXXXXX") || return 1
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    parent=$(ps -o ppid= -p "$FM_WATCHER_HEALTHY_PID" 2>/dev/null | tr -d ' ')
  fi
  # Treat queued rows as being handled by the durable handoff, so they do not
  # drive a hot rearm-resurface loop during startup. The successor's native
  # auto-arm takes this cycle over and restores ordinary queue delivery.
  export FM_WATCH_PREDECESSOR_ARM_PID="${LAST_ARM_PID:-${parent:-$WRAPPER_PID}}"
  case "$parent" in
    ''|*[!0-9]*) "$SCRIPT_DIR/fm-watch-arm.sh" >"$ARM_OUT" 2>&1 & ;;
    *) "$SCRIPT_DIR/fm-watch-arm.sh" --take-over "$parent" >"$ARM_OUT" 2>&1 & ;;
  esac
  ARM_PID=$!
  while [ "$i" -lt 100 ]; do
    if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME" \
      && [ "$(ps -o ppid= -p "$FM_WATCHER_HEALTHY_PID" 2>/dev/null | tr -d ' ')" = "$ARM_PID" ]; then
      return 0
    fi
    fm_pid_alive "$ARM_PID" || break
    sleep 0.1
    i=$((i + 1))
  done
  kill -TERM "$ARM_PID" 2>/dev/null || true
  LAST_ARM_PID=$ARM_PID
  wait "$ARM_PID" 2>/dev/null || true
  ARM_PID=
  rm -f "$ARM_OUT"
  ARM_OUT=
  return 1
}
start_arm() {
  local attempt=0
  # An old auto-arm may have concurrently detached a handling successor.
  # Take over that now-current peer once rather than mistaking a safe attach
  # for a bridge-owned child, or terminating Claude over an unowned watcher.
  while [ "$attempt" -lt 2 ]; do
    start_arm_once && return 0
    attempt=$((attempt + 1))
  done
  return 1
}
if needs_bridge; then
  if ! start_arm; then
    echo 'context-restart: watcher handoff failed; leaving the prepared Claude session running' >&2
    exit 1
  fi
fi
# Recheck the generation and exact owner after the arm handover.
ready && [ "$(cat "$STATE/.lock" 2>/dev/null)" = "$OLD_PID" ] \
  && fm_harness_pid_alive "$OLD_PID" || exit 1
# Only a completed transfer authorizes the wrapper's automatic relaunch.
# Ready preparation alone must not turn a later ordinary exit into a restart
# after a failed bridge, so commit the replacing phase under the crossing lock.
fm_lock_try_acquire "$STATE/.context-restart.lock" || exit 1
if ! ready || [ "$(cat "$STATE/.lock" 2>/dev/null)" != "$OLD_PID" ] \
  || ! fm_context_restart_record_publish "$STATE" "$FM_CONTEXT_RESTART_RECORD_SESSION" \
    "$FM_CONTEXT_RESTART_RECORD_CONTEXT" "$FM_CONTEXT_RESTART_RECORD_BUDGET" \
    "$FM_CONTEXT_RESTART_RECORD_DETECTED_AT" replacing automatic "$TOKEN" "$OLD_PID"; then
  fm_lock_release "$STATE/.context-restart.lock"
  exit 1
fi
fm_lock_release "$STATE/.context-restart.lock"
kill -TERM "$OLD_PID" 2>/dev/null || exit 1

# A close only enqueues durable notifications. Keep a successor cycle until the
# new session's Stop hook takes delivery responsibility. Once it does, wait for
# the arm it follows to close naturally rather than stopping its live watcher.
while [ -n "$ARM_PID" ]; do
  LAST_ARM_PID=$ARM_PID
  wait "$ARM_PID" 2>/dev/null || true
  ARM_PID=
  rm -f "$ARM_OUT"
  ARM_OUT=
  kill -0 "$WRAPPER_PID" 2>/dev/null || exit 0
  needs_bridge || exit 0
  if [ "$(cat "$STATE/.lock" 2>/dev/null)" != "$OLD_PID" ] \
    && fm_autoarm_claim_open "$STATE" "$GRACE"; then
    exit 0
  fi
  start_arm || {
    echo 'context-restart: watcher bridge lost supervision during successor startup' >&2
    exit 1
  }
done
