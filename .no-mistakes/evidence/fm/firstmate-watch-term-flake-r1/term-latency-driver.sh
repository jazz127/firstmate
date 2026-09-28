#!/usr/bin/env bash
# term-latency-driver.sh <tree> <trials> : replays the fixture of
# test_term_stops_a_watcher_blocked_inside_a_poll against <tree>/bin/fm-watch.sh
# and prints the TERM->exit latency (ms), whether the lock was released, and
# whether the stop record could be acknowledged.
set -u
TREE=$1; N=${2:-5}
prelude=$(mktemp "${TMPDIR:-/tmp}/termdrv.XXXXXX")
sed -n '1,/^# CI.s stock macOS Bash lane/p' "$TREE/tests/fm-watch-triage.test.sh" | sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$TREE/tests#" > "$prelude"
. "$prelude"; rm -f "$prelude"
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
for t in $(seq 1 "$N"); do
  dir=$(make_case term-drv-$t); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; fifo="$dir/pane.fifo"; window="test:fm-blocked-capture"
  mkfifo "$fifo"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/blocked.meta"
  printf 'working: implementing\n' > "$state/blocked.status"
  sig=$(seen_sig "$state/blocked.status"); printf '%s' "$sig" > "$state/.seen-blocked_status"
  ( exec 3> "$fifo"; : > "$dir/capture-blocked"; exec sleep 30 ) & holder=$!
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$fifo" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$TREE/bin/fm-watch.sh" > "$out" & pid=$!
  i=0; while [ ! -e "$dir/capture-blocked" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
  sleep 0.3
  t0=$(now_ms); kill "$pid" 2>/dev/null
  i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1));  done
  if kill -0 "$pid" 2>/dev/null; then lat=">20000(still alive)"; kill -9 "$pid"; else lat=$(( $(now_ms) - t0 )); fi
  wait "$pid" 2>/dev/null
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  lock=released; [ -e "$state/.watch.lock" ] && lock=HELD
  ack=ok; ack_stopped_cycle "$state" >/dev/null 2>&1 || ack=FAILED
  printf "trial=%s term_to_exit_ms=%s poll_ticks=%s lock=%s stop_ack=%s\n" "$t" "$lat" "$i" "$lock" "$ack"
done
