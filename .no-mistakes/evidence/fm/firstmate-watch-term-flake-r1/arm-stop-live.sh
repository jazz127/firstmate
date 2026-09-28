#!/usr/bin/env bash
# arm-stop-live.sh <tree> : live stop-path proof in a disposable lab FM_HOME.
# Arms the real <tree>/bin/fm-watch-arm.sh (watcher = real fm-watch.sh), makes
# the watcher's tmux pane capture block (tmux stand-in whose capture-pane reads
# a FIFO nobody writes), then runs the real `fm-watch-arm.sh --stop` and
# reports its verdict line, elapsed ms, and whether the watcher lock was freed.
set -u
TREE=$1
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$TREE/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
fakebin="$LAB/fakebin"; mkdir -p "$fakebin"
sed -n "/cat > \"\$fakebin\/tmux\" <<'SH'/,/^SH\$/p" "$TREE/tests/wake-helpers.sh" | sed '1d;$d' > "$fakebin/tmux"
chmod +x "$fakebin/tmux"
state="$LAB/state"; window="lab:fm-blocked-capture"; fifo="$LAB/pane.fifo"; mkfifo "$fifo"
printf 'window=%s\nkind=ship\n' "$window" > "$state/blocked.meta"
printf 'working: implementing\n' > "$state/blocked.status"
prelude=$(mktemp "${TMPDIR:-/tmp}/armprelude.XXXXXX")
sed -n "1,/^# CI.s stock macOS Bash lane/p" "$TREE/tests/fm-watch-triage.test.sh" | sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")#$TREE/tests#" > "$prelude"
sig=$(bash -c '. "$1" >/dev/null 2>&1; seen_sig "$2"' _ "$prelude" "$state/blocked.status"); rm -f "$prelude"
printf "%s" "$sig" > "$state/.seen-blocked_status"
( exec 3> "$fifo"; : > "$LAB/capture-blocked"; exec sleep 40 ) & holder=$!
export FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 PATH="$fakebin:$PATH" \
  FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$fifo" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
unset NO_MISTAKES_GATE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
"$TREE/bin/fm-watch-arm.sh" > "$LAB/arm.out" 2>&1 & arm=$!
i=0; while [ ! -e "$LAB/capture-blocked" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
sleep 1
wpid=$(cat "$state/.watch.lock/pid" 2>/dev/null)
echo "arm: $(head -1 "$LAB/arm.out")"
echo "watcher pid=$wpid blocked_in_capture=$([ -e "$LAB/capture-blocked" ] && echo yes || echo no)"
t0=$(now_ms)
stop_out=$("$TREE/bin/fm-watch-arm.sh" --stop 2>&1); stop_rc=$?
t1=$(now_ms)
echo "fm-watch-arm.sh --stop -> rc=$stop_rc elapsed_ms=$((t1 - t0)) output: $stop_out"
echo "watcher alive after --stop returned: $(kill -0 "$wpid" 2>/dev/null && echo YES || echo no)"
echo "watch lock after --stop: $([ -e "$state/.watch.lock" ] && echo HELD || echo released)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
i=0; while kill -0 "$wpid" 2>/dev/null && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done
kill -9 "$wpid" 2>/dev/null; kill "$arm" 2>/dev/null; wait "$arm" 2>/dev/null
rm -rf "$LAB"
