#!/usr/bin/env bash
# Non-T3 inbox steering retains the recorded metadata's activity verdict,
# including partial records that still identify a terminal but lack a target.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-inbox-meta)
mkdir -p "$TMP_ROOT/state" "$TMP_ROOT/config"

FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state" \
  FM_BUSY_REGEX=BUSYTOKEN bash -eu -c '
  . "$1/bin/fm-watch.sh"
  meta="$STATE/worker.meta"
  printf "terminal=lab:fm-worker\nharness=grok\nkind=ship\n" > "$meta"

  verdict=$(fm_busy_classify_meta "$meta" worker "$STATE" "BUSYTOKEN active")
  [ "$verdict" = "unknown no-target" ]
  # The terminal and rendered busy token alone would classify busy.
  fm_busy_is_busy tmux lab:fm-worker grok worker "$STATE" "BUSYTOKEN active"
  if inbox_steer_busy lab:fm-worker tmux worker "BUSYTOKEN active"; then
    echo "missing metadata target incorrectly deferred non-T3 steering" >&2
    exit 1
  fi

  printf "window=lab:fm-worker\n" >> "$meta"
  inbox_steer_busy lab:fm-worker tmux worker "BUSYTOKEN active"
  if inbox_steer_busy lab:fm-worker tmux worker "quiet output"; then
    echo "idle non-T3 metadata incorrectly deferred steering" >&2
    exit 1
  fi
' _ "$ROOT"

pass "non-T3 inbox guard preserves no-target uncertainty and recorded busy/idle verdicts"

FM_HOME="$TMP_ROOT/pause" FM_STATE_OVERRIDE="$TMP_ROOT/pause/state" \
  FM_CONFIG_OVERRIDE="$TMP_ROOT/pause/config" \
  FM_TASK_INBOX_GRACE_SECS=1 FM_SECONDMATE_WAKE_STALL_SECS=1 \
  bash -eu -s -- "$ROOT" <<'SH'
. "$1/bin/fm-watch.sh"
mkdir -p "$CONFIG"
touch "$CONFIG/wait-no-turns"

fm_backend_agent_state() { printf '%s\n' "$TEST_AGENT"; }
fm_backend_busy_state() { printf 'idle\n'; }
fm_backend_capture() { printf 'quiet\n'; }
fm_backend_composer_state() { printf 'empty\n'; }
fm_backend_send_text_submit() {
  if fm_secondmate_liveness_lock "$TEST_TASK"; then
    printf 'unlocked\n' >> "$FM_HOME/sends"
    fm_secondmate_liveness_unlock "$TEST_TASK"
    return 2
  fi
  printf '%s\n' "$TEST_TASK" >> "$FM_HOME/sends"
}
wake() { printf '%s\n' "$1" >> "$FM_HOME/alerts"; }

fixture() {
  TEST_TASK=$1
  mkdir -p "$FM_HOME/$TEST_TASK/state"
  printf '%s\n' "$TEST_TASK" > "$FM_HOME/$TEST_TASK/.fm-secondmate-home"
  printf 'kind=secondmate\nbackend=t3code\nwindow=%s\nharness=claude\nhome=%s\n' \
    "$TEST_TASK" "$FM_HOME/$TEST_TASK" > "$STATE/$TEST_TASK.meta"
}

unchanged() {
  cmp "$FM_HOME/before" "$1"
  [ ! -s "$FM_HOME/sends" ]
  [ ! -s "$FM_HOME/alerts" ]
  [ ! -s "$STATE/.wake-queue" ]
}

for location in local remote; do
  for TEST_AGENT in dead missing alive; do
    fixture "$location-$TEST_AGENT"
    [ "$location" != remote ] || printf 'remote_host=synthetic\n' >> "$STATE/$TEST_TASK.meta"
    rec=$(fm_task_inbox_write "$STATE" "$TEST_TASK" 'ordinary pending steer')
    touch -t 202001010000 "$rec"
    inbox=${rec%/*}
    printf '%s\t2\t1\n' "${rec##*/}" > "$inbox/.ring-state"
    printf '%s\t1\n' "${rec##*/}" > "$inbox/.busy-state"
    cp -R "$inbox" "$FM_HOME/inbox-before"
    touch "$STATE/.secondmate-paused-$TEST_TASK"
    inbox_steer_check "$TEST_TASK" "$TEST_TASK"
    diff -r "$FM_HOME/inbox-before" "$inbox"
    [ ! -s "$FM_HOME/sends" ]
    [ ! -s "$FM_HOME/alerts" ]
    [ ! -s "$STATE/.wake-queue" ]
    rm -rf "$FM_HOME/inbox-before"
    rm "$rec"
    rec=$(fm_task_inbox_write "$STATE" "$TEST_TASK" 'pending retry' fire-and-forget)
    fm_task_inbox_mark_retry "$STATE" "$TEST_TASK" "$rec"
    touch -t 202001010000 "$inbox/.retry-ring"
    cp -R "$inbox" "$FM_HOME/inbox-before"
    inbox_steer_check "$TEST_TASK" "$TEST_TASK"
    diff -r "$FM_HOME/inbox-before" "$inbox"
    rm -rf "$FM_HOME/inbox-before"
    TEST_AGENT=alive
    rm "$STATE/.secondmate-paused-$TEST_TASK"
    inbox_steer_check "$TEST_TASK" "$TEST_TASK"
    [ -f "$rec" ]
    [ ! -e "$inbox/.retry-ring" ]
    [ "$(cat "$FM_HOME/sends")" = "$TEST_TASK" ]
    [ ! -e "$STATE/.secondmate-liveness-$TEST_TASK.lock" ]
    rm "$FM_HOME/sends"
    rm "$STATE/$TEST_TASK.meta"
  done
done

fixture empty
mkdir -p "$STATE/.secondmate-wake-stall-receipts/empty"
fm_wake_secondmate_progress_marker_write empty 1 100-7
fm_wake_secondmate_ring_marker_write empty 100-7
fm_wake_secondmate_stall_marker_write empty 100-7
fm_wake_secondmate_stall_receipt_write empty 100-7
for record in progress ring stall; do
  cp "$STATE/.secondmate-wake-$record-empty" "$FM_HOME/$record-before"
done
cp "$STATE/.secondmate-wake-stall-receipts/empty/100-7" "$FM_HOME/receipt-before"
touch "$STATE/.secondmate-paused-empty"
secondmate_wake_stall_tick
for record in progress ring stall; do
  cmp "$FM_HOME/$record-before" "$STATE/.secondmate-wake-$record-empty"
done
cmp "$FM_HOME/receipt-before" "$STATE/.secondmate-wake-stall-receipts/empty/100-7"
rm "$STATE/empty.meta"

fixture unseen
printf '100\t7\tcheck\trouted\tcheck: routed work\n' > "$FM_HOME/unseen/state/.wake-queue"
touch "$STATE/.secondmate-paused-unseen"
secondmate_wake_stall_tick
[ ! -e "$STATE/.secondmate-wake-progress-unseen" ]
rm "$STATE/unseen.meta"

fixture mate
TEST_AGENT=alive
rec=$(fm_task_inbox_write "$STATE" mate 'pending ordinary steer')
touch -t 202001010000 "$rec"
printf '%s\t1\t1\n' "${rec##*/}" > "$STATE/mate.inbox/.ring-state"
cp -R "$STATE/mate.inbox" "$FM_HOME/inbox-before"
printf '100\t7\tcheck\trouted\tcheck: routed work\n' > "$FM_HOME/mate/state/.wake-queue"
cp "$FM_HOME/mate/state/.wake-queue" "$FM_HOME/foreign-before"
fm_wake_secondmate_progress_marker_write mate 1 100-7
cp "$STATE/.secondmate-wake-progress-mate" "$FM_HOME/before"
touch "$STATE/.secondmate-paused-mate"
inbox_steer_check mate mate
secondmate_wake_stall_tick
unchanged "$STATE/.secondmate-wake-progress-mate"
diff -r "$FM_HOME/inbox-before" "$STATE/mate.inbox"
cmp "$FM_HOME/foreign-before" "$FM_HOME/mate/state/.wake-queue"
[ ! -e "$STATE/.secondmate-wake-ring-mate" ]
[ ! -e "$STATE/.secondmate-wake-stall-mate" ]
[ ! -e "$STATE/.secondmate-wake-stall-receipts/mate" ]

rm "$STATE/.secondmate-paused-mate"
(
  fm_secondmate_liveness_lock mate
  touch "$FM_HOME/locked"
  for ((i=0; i<300; i++)); do
    [ ! -f "$FM_HOME/release" ] || break
    sleep 0.01
  done
  fm_secondmate_liveness_unlock mate
) &
holder=$!
for ((i=0; i<300; i++)); do
  [ ! -f "$FM_HOME/locked" ] || break
  sleep 0.01
done
[ -f "$FM_HOME/locked" ]
inbox_steer_check mate mate
secondmate_wake_stall_tick
unchanged "$STATE/.secondmate-wake-progress-mate"
diff -r "$FM_HOME/inbox-before" "$STATE/mate.inbox"
touch "$FM_HOME/release"
wait "$holder"

inbox_steer_check mate mate
[ "$(cat "$FM_HOME/sends")" = mate ]
IFS=$'\t' read -r base count epoch < "$STATE/mate.inbox/.ring-state"
[ "$base" = "${rec##*/}" ] && [ "$count" = 2 ]
[ -f "$rec" ]
[ ! -e "$STATE/.secondmate-liveness-mate.lock" ]
rm "$FM_HOME/sends"
secondmate_wake_stall_tick
[ "$(cat "$FM_HOME/sends")" = mate ]
[ "$(cat "$STATE/.secondmate-wake-ring-mate")" = 100-7 ]
[ ! -e "$STATE/.secondmate-liveness-mate.lock" ]
[ ! -s "$FM_HOME/alerts" ]
[ ! -s "$STATE/.wake-queue" ]
cmp "$FM_HOME/foreign-before" "$FM_HOME/mate/state/.wake-queue"
fm_wake_secondmate_progress_marker_write mate 1 100-7
secondmate_wake_stall_tick
grep -F 'secondmate wake-loop stalled: mate=mate row=7' "$FM_HOME/alerts"
[ -f "$STATE/.secondmate-wake-stall-mate" ]
[ -f "$STATE/.secondmate-wake-stall-receipts/mate/100-7" ]
[ ! -e "$STATE/.secondmate-liveness-mate.lock" ]
printf 'complete\n' > "$FM_HOME/complete"
SH
[ -f "$TMP_ROOT/pause/complete" ] || fail 'pause watcher scenarios did not finish'
pass "paused watcher inboxes and home queues defer without spending records or counters"
