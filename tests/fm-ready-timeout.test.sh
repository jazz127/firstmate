#!/usr/bin/env bash
# tests/fm-ready-timeout.test.sh - the opt-in ready-session timeout
# (bin/fm-ready-timeout-lib.sh) driven through a real bin/fm-watch.sh.
#
# A ship worker whose `done` delivery names a pull request with an armed merge
# poll, whose agent is alive and exactly idle, and which has shown no activity
# for the configured timeout has its agent stopped through the control plane.
# The control plane itself is a recording stub here (FM_READY_TIMEOUT_CONTROL_BIN);
# tests/fm-control.test.sh pins the real exit verb. Covered: the knob's parsing,
# disabled by default, the enabled default duration, a custom duration, no stop
# for a busy, recently active, or unacknowledged-steer worker, no stop unless the
# authoritative crew state reads done, and no stale or dead-endpoint alarm for a
# worker the timeout stopped.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-ready-timeout-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-ready-timeout-tests)
WINDOW=test:fm-rt
KEY=test_fm-rt
PR=https://github.com/o/r/pull/3
DONE_CREW_STATE="state: done · source: status-log · PR $PR checks green"

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

set_mtime() {  # <epoch> <file>
  local stamp
  if stamp=$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$2"
  else
    touch -t "$(date -d "@$1" +%Y%m%d%H%M.%S)" "$2"
  fi
}

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

seen_sig() {  # <status-file>
  printf 'v2\t%s\t%s@%s' "$(status_observed_signature "$1")" "$(size_of "$1")" \
    "$(_fm_open_decisions_file_ident "$1")"
}

# Wait for one whole poll cycle of <pid> (the beacon is touched at each top).
wait_poll_cycle() {  # <state> <pid>
  local beat="$1/.last-watcher-beat" first='' now i=0
  rm -f "$beat"
  while [ "$i" -lt 300 ]; do
    kill -0 "$2" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1; i=$((i + 1))
  done
  while [ "$i" -lt 300 ]; do
    kill -0 "$2" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    [ -n "$now" ] && [ "$now" != "$first" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# A ready worker: `done` naming the pull request, its merge poll armed through
# the same private publication bin/fm-pr-check.sh performs, an idle Claude busy
# record, and every activity file aged <age> seconds.
ready_fixture() {  # <name> <age>
  local dir state gen now
  dir=$(make_case "$1"); state="$dir/state"
  mkdir -p "$dir/home" "$dir/config"
  now=$(date +%s)
  printf 'window=%s\nkind=ship\nharness=claude\nmode=no-mistakes\nspawn_gen=gen-1\npr=%s\n' \
    "$WINDOW" "$PR" > "$state/rt.meta"
  fm_pr_poll_prepare "$state" rt github "$PR" github.com o/r 3 "$ROOT/bin/fm-pr-poll.sh" \
    && fm_pr_poll_publish_prepared || return 1
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" rt) || return 1
  "$ROOT/bin/fm-busy-event.sh" apply "$state" rt idle --gen "$gen" \
    --source claude-hook --event stop >/dev/null || return 1
  printf 'done [at=%s]: PR %s checks green\n' "$(( now - $2 ))" "$PR" > "$state/rt.status"
  set_mtime "$(( now - $2 ))" "$state/rt.status"
  set_mtime "$(( now - $2 ))" "$state/rt.meta"
  set_mtime "$(( now - $2 ))" "$state/rt.pr-poll-registration"
  printf '%s' "$(seen_sig "$state/rt.status")" > "$state/.seen-rt_status"
  printf 'finished, awaiting review' > "$dir/pane.txt"
  touch "$state/.last-check" "$state/.last-heartbeat"
  cat > "$dir/fakebin/fm-control-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_RT_CONTROL_LOG"
printf 'stopped %s harness=claude backend=tmux\n' "$1"
SH
  chmod +x "$dir/fakebin/fm-control-stub"
  printf '%s\n' "$dir"
}

# Run the watcher over <dir> for three poll cycles (or until it exits) with the
# agent reading as <command> (claude = alive, zsh = no agent). Extra
# environment assignments follow.
watch_rounds() {  # <dir> <command> [env...]
  local dir=$1 comm=$2 pid cycles=0
  shift 2
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_TMUX_WINDOW="$WINDOW" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_FAKE_TMUX_CURRENT_COMMAND="$comm" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE="$DONE_CREW_STATE" \
    FM_READY_TIMEOUT_CONTROL_BIN="$dir/fakebin/fm-control-stub" \
    FM_RT_CONTROL_LOG="$dir/control.log" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_PAUSE_RESURFACE_SECS=999999 \
    "$@" "$WATCH" >> "$dir/watch.out" 2>&1 &
  pid=$!
  while [ "$cycles" -lt 3 ]; do
    wait_poll_cycle "$dir/state" "$pid" || { wait "$pid" 2>/dev/null; return 1; }
    cycles=$((cycles + 1))
  done
  reap "$pid"
  return 0
}

stop_count() {  # <dir>
  if [ -f "$1/control.log" ]; then grep -c . "$1/control.log"; else echo 0; fi
}

expect_no_stop() {  # <dir> <label>
  [ "$(stop_count "$1")" -eq 0 ] || fail "$2: the agent was stopped: $(cat "$1/control.log")"
  [ ! -e "$1/state/rt.ready-timeout" ] || fail "$2: a timeout record was written"
}

expect_stop() {  # <dir> <timeout-secs> <label>
  [ "$(stop_count "$1")" -eq 1 ] || fail "$3: expected one stop, got $(stop_count "$1"): $(cat "$1/watch.out")"
  [ "$(cat "$1/control.log")" = "rt exit" ] || fail "$3: the stop did not use the exit verb: $(cat "$1/control.log")"
  [ "$(fm_ready_timeout_field "$1/state/rt.ready-timeout" result)" = stopped ] \
    || fail "$3: no stopped record: $(cat "$1/state/rt.ready-timeout" 2>/dev/null)"
  [ "$(fm_ready_timeout_field "$1/state/rt.ready-timeout" timeout)" = "$2" ] \
    || fail "$3: recorded timeout was not $2"
  [ "$(fm_ready_timeout_field "$1/state/rt.ready-timeout" spawn_gen)" = gen-1 ] \
    || fail "$3: the record does not name the stopped incarnation"
  [ "$(fm_ready_timeout_field "$1/state/rt.ready-timeout" pr)" = "$PR" ] \
    || fail "$3: the record does not name the pull request"
  [ -f "$1/state/rt.meta" ] && [ -f "$1/state/rt.pr-poll-registration" ] && [ -f "$1/state/rt.check.sh" ] \
    || fail "$3: the task record or merge poll did not survive the stop"
  [ ! -s "$1/state/.wake-queue" ] || fail "$3: the stop woke firstmate: $(cat "$1/state/.wake-queue")"
}

test_knob_parsing() {
  local dir="$TMP_ROOT/knob" v rc
  mkdir -p "$dir"
  rc=0; fm_ready_timeout_secs "$dir" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "an absent knob should read disabled (rc=$rc)"
  for pair in ':7200' '# two hours by default:7200' '3600:3600' '90m:5400' '4h:14400' \
    ' 45m :2700' '0120s:120'; do
    printf '%s\n' "${pair%:*}" > "$dir/ready-session-timeout"
    v=$(fm_ready_timeout_secs "$dir") || fail "knob '${pair%:*}' was rejected"
    [ "$v" = "${pair##*:}" ] || fail "knob '${pair%:*}' read $v, want ${pair##*:}"
  done
  for bad in 30 59s 0h abc 2d -5m 1.5h; do
    printf '%s\n' "$bad" > "$dir/ready-session-timeout"
    rc=0; v=$(fm_ready_timeout_secs "$dir") || rc=$?
    [ "$rc" -eq 2 ] && [ -z "$v" ] || fail "knob '$bad' should be rejected, got rc=$rc value=$v"
  done
  pass "the knob reads absent as off, empty as two hours, and rejects values under a minute or unparseable"
}

test_disabled_by_default() {
  local dir
  dir=$(ready_fixture disabled 90000) || fail "fixture failed"
  watch_rounds "$dir" claude || fail "watcher exited: $(cat "$dir/watch.out")"
  expect_no_stop "$dir" "no config file"
  printf 'bogus\n' > "$dir/config/ready-session-timeout"
  watch_rounds "$dir" claude || fail "watcher exited on a rejected knob: $(cat "$dir/watch.out")"
  expect_no_stop "$dir" "a rejected value"
  grep -F 'ready-session timeout off' "$dir/state/.watch-triage.log" >/dev/null \
    || fail "a rejected value was not noted in the triage log"
  pass "without a valid config/ready-session-timeout no ready worker is stopped"
}

test_enabled_default_duration() {
  local dir
  dir=$(ready_fixture default-under 7000) || fail "fixture failed"
  : > "$dir/config/ready-session-timeout"
  watch_rounds "$dir" claude || fail "watcher exited: $(cat "$dir/watch.out")"
  expect_no_stop "$dir" "under two hours ready"
  dir=$(ready_fixture default-over 7300) || fail "fixture failed"
  : > "$dir/config/ready-session-timeout"
  watch_rounds "$dir" claude || fail "watcher exited: $(cat "$dir/watch.out")"
  expect_stop "$dir" 7200 "past two hours ready"
  pass "an empty knob stops a worker ready and idle for two hours, and not before"
}

test_custom_duration() {
  local dir
  dir=$(ready_fixture custom-under 500) || fail "fixture failed"
  printf '10m\n' > "$dir/config/ready-session-timeout"
  watch_rounds "$dir" claude || fail "watcher exited: $(cat "$dir/watch.out")"
  expect_no_stop "$dir" "under the custom ten minutes"
  dir=$(ready_fixture custom-over 700) || fail "fixture failed"
  printf '10m\n' > "$dir/config/ready-session-timeout"
  watch_rounds "$dir" claude || fail "watcher exited: $(cat "$dir/watch.out")"
  expect_stop "$dir" 600 "past the custom ten minutes"
  pass "a configured duration replaces the default"
}

test_busy_or_active_worker_is_left_running() {
  local dir gen
  dir=$(ready_fixture busy 90000) || fail "fixture failed"
  : > "$dir/config/ready-session-timeout"
  gen=$(cat "$dir/state/rt.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" rt busy --gen "$gen" \
    --source claude-hook --event prompt >/dev/null || fail "could not mark the agent busy"
  watch_rounds "$dir" claude || fail "watcher exited: $(cat "$dir/watch.out")"
  expect_no_stop "$dir" "a busy agent"

  dir=$(ready_fixture recent-turn 90000) || fail "fixture failed"
  : > "$dir/config/ready-session-timeout"
  touch "$dir/state/rt.turn-ended"
  # Already seen, so the turn-end itself does not end the round as a signal.
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f '%z:%Fm' "$dir/state/rt.turn-ended" > "$dir/state/.seen-rt_turn-ended"
  else
    stat -c '%s:%Y' "$dir/state/rt.turn-ended" > "$dir/state/.seen-rt_turn-ended"
  fi
  watch_rounds "$dir" claude || fail "watcher exited: $(cat "$dir/watch.out")"
  expect_no_stop "$dir" "a turn completed just now"

  dir=$(ready_fixture unread-steer 90000) || fail "fixture failed"
  : > "$dir/config/ready-session-timeout"
  mkdir -p "$dir/state/rt.inbox/handled"
  printf 'rebase onto main\n' > "$dir/state/rt.inbox/001.msg"
  set_mtime "$(( $(date +%s) - 90000 ))" "$dir/state/rt.inbox/001.msg"
  set_mtime "$(( $(date +%s) - 90000 ))" "$dir/state/rt.inbox/handled"
  set_mtime "$(( $(date +%s) - 90000 ))" "$dir/state/rt.inbox"
  watch_rounds "$dir" claude || fail "watcher exited: $(cat "$dir/watch.out")"
  expect_no_stop "$dir" "an unacknowledged steer"

  dir=$(ready_fixture no-agent 90000) || fail "fixture failed"
  : > "$dir/config/ready-session-timeout"
  watch_rounds "$dir" zsh || fail "watcher exited: $(cat "$dir/watch.out")"
  expect_no_stop "$dir" "an agent that is already gone"

  pass "a busy, recently active, unread-steer, or agent-less worker is never stopped"
}

test_only_a_done_crew_state_is_stopped() {
  local dir reading n=0
  for reading in 'state: working · source: run-step · ci (running)' \
    'state: parked · source: run-step · fix_review' \
    'state: blocked · source: status-log · waiting on a rebase' \
    'state: paused · source: status-log · waiting on the vendor' \
    'state: failed · source: run-step · ci failed' \
    'state: unknown · source: none · no current-state source available'; do
    n=$((n + 1))
    dir=$(ready_fixture "crew-state-$n" 90000) || fail "fixture failed"
    : > "$dir/config/ready-session-timeout"
    watch_rounds "$dir" claude FM_FAKE_CREW_STATE="$reading" \
      || fail "watcher exited: $(cat "$dir/watch.out")"
    expect_no_stop "$dir" "crew state '$reading'"
  done
  pass "a ready worker whose crew state is working, parked, blocked, paused, failed, or unknown is never stopped"
}

# After the stop the pane holds a bare shell, the exit fired a turn-end, and the
# delivered wait's recheck is due at once: nothing may wake firstmate. The
# control keeps everything identical except that the record names another
# incarnation, and then the very same state does wake firstmate - so the quiet
# comes from the timeout record, not from a vacuous fixture.
test_no_alarm_after_a_timeout_stop() {
  local dir
  dir=$(ready_fixture parked 90000) || fail "fixture failed"
  : > "$dir/config/ready-session-timeout"
  watch_rounds "$dir" claude || fail "watcher exited: $(cat "$dir/watch.out")"
  expect_stop "$dir" 7200 "the timeout stop"
  printf 'jr@host wt %% ' > "$dir/pane.txt"
  touch "$dir/state/rt.turn-ended"
  watch_rounds "$dir" zsh FM_PAUSE_RESURFACE_SECS=1 FM_STALE_ESCALATE_SECS=1 \
    FM_FAKE_CREW_STATE='state: unknown · source: none · backend target gone: test:fm-rt (agent gone, pane shell remains)' \
    || fail "a stopped ready worker woke the watcher: $(cat "$dir/watch.out")"
  [ ! -s "$dir/state/.wake-queue" ] || fail "a stopped ready worker queued a wake: $(cat "$dir/state/.wake-queue")"
  [ ! -e "$dir/state/.dead-reported-$KEY" ] || fail "a stopped ready worker was reported as a dead endpoint"
  [ "$(stop_count "$dir")" -eq 1 ] || fail "the stop was repeated for the same incarnation"

  sed -i.bak 's/^spawn_gen=gen-1$/spawn_gen=gen-0/' "$dir/state/rt.ready-timeout"
  touch "$dir/state/rt.turn-ended"
  watch_rounds "$dir" zsh FM_PAUSE_RESURFACE_SECS=1 FM_STALE_ESCALATE_SECS=1 \
    FM_FAKE_CREW_STATE='state: unknown · source: none · backend target gone: test:fm-rt (agent gone, pane shell remains)' \
    && fail "the control case without a matching stop record never woke the watcher"
  [ -s "$dir/state/.wake-queue" ] || fail "the control case exited without queuing a wake"
  pass "a worker the timeout stopped raises no stale, turn-end, or dead-endpoint alarm"
}

test_knob_parsing
test_disabled_by_default
test_enabled_default_duration
test_custom_duration
test_busy_or_active_worker_is_left_running
test_only_a_done_crew_state_is_stopped
test_no_alarm_after_a_timeout_stop

echo "all fm-ready-timeout tests passed"
