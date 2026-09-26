#!/usr/bin/env bash
# drive.sh <bin-dir> <label> <duration-secs> [blip-at-secs]
set -u
BIN=$1 LABEL=$2 DUR=$3 BLIP=${4:-}
: "${LAB:?}"
export FM_HOME="$LAB"
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
export TMUX_TMPDIR="$LAB/tmux"
T="tmux -L fm-lab"
$T kill-server 2>/dev/null
rm -rf "$LAB/state"; mkdir -p "$LAB/state"
$T new-session -d -s crew -n fm-held -x 120 -y 30 "bash --norc -c 'echo worker idle, waiting on upstream CI; exec ${PANE_CMD:-sleep 100000}'"
sock=$($T display-message -p '#{socket_path}'); spid=$($T display-message -p '#{pid}')
export TMUX="$sock,$spid,0"
printf 'window=crew:fm-held\nkind=ship\nharness=claude\nbackend=tmux\n' > "$LAB/state/held.meta"
printf '%s\n' "${STATUS_LINE:-paused: waiting on upstream CI run to finish}" > "$LAB/state/held.status"
export FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_PAUSE_RESURFACE_SECS=30 FM_STALE_ESCALATE_SECS=8
start=$(date +%s); blipped=
log="$LAB/$LABEL.log"; : > "$log"
while [ $(( $(date +%s) - start )) -lt "$DUR" ]; do
  now=$(( $(date +%s) - start ))
  remaining=$(( DUR - now ))
  ( "$BIN/fm-watch.sh" > "$LAB/w.out" 2>"$LAB/w.err" ) &
  wp=$!
  while kill -0 $wp 2>/dev/null; do
    el=$(( $(date +%s) - start ))
    if [ -n "$BLIP" ] && [ -z "$blipped" ] && [ "$el" -ge "$BLIP" ]; then
      $T send-keys -t crew:fm-held 'x' ; sleep 1; blipped=1
      echo "[t+${el}s] pane blip: keystroke changed the pane" >> "$log"
    fi
    if [ -n "${MID_AT:-}" ] && [ -z "${midded:-}" ] && [ "$el" -ge "$MID_AT" ]; then
      printf '%s\n' "$MID_LINE" >> "$LAB/state/held.status"; midded=1
      echo "[t+${el}s] status append: $MID_LINE" >> "$log"
    fi
    if [ -n "${MID2_AT:-}" ] && [ -z "${midded2:-}" ] && [ "$el" -ge "$MID2_AT" ]; then
      printf '%s\n' "$MID2_LINE" >> "$LAB/state/held.status"; midded2=1
      echo "[t+${el}s] status append: $MID2_LINE" >> "$log"
    fi
    [ "$el" -ge "$DUR" ] && { kill $wp; break; }
    sleep 1
  done
  wait $wp 2>/dev/null
  el=$(( $(date +%s) - start ))
  if [ -s "$LAB/w.out" ]; then
    sed "s/^/[t+${el}s] watcher wake: /" "$LAB/w.out" >> "$log"
    "$BIN/fm-wake-drain.sh" > "$LAB/d.out" 2> "$LAB/d.err"
    seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation.*$/\1/p' "$LAB/d.err")
    gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$LAB/d.err")
    [ -n "$seq" ] && "$BIN/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  fi
done
echo "[t+$(( $(date +%s) - start ))s] end of run" >> "$log"
$T kill-server 2>/dev/null
cat "$log"
