#!/bin/bash
set -eu
TASK_EVIDENCE=/Users/jarad/.no-mistakes/evidence/01M455W9R326CJ1BPJVJB6ADKS
# Short worktree-local home keeps the private Darwin tmux socket under 104 bytes.
LAB=$(mktemp -d "$PWD/lXXX")
WATCH_PID=
cleanup() {
  [ -z "$WATCH_PID" ] || { kill -TERM "$WATCH_PID" 2>/dev/null || true; wait "$WATCH_PID" 2>/dev/null || true; }
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/pi"
# The real Pi CLI is idle; a lost-stop-hook busy state is injected through the
# public busy-event interface rather than a fake backend or agent binary.
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" PI_CODING_AGENT_DIR="$LAB/pi" tmux -L fm-lab new-session -d -s primary -n fm-busy -x 110 -y 32 -c "$PWD" -e FM_HOME="$LAB" -e FM_TASK_ID=busy 'pi --offline --approve --no-extensions --no-skills --no-prompt-templates --no-themes --no-context-files --no-session'
TASK_TMUX=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},0')
cat > "$LAB/state/busy.meta" <<EOF
window=primary:fm-busy
backend=tmux
endpoint_task_id=busy
spawn_gen=live-inbox
worktree=$PWD
project=$PWD
harness=pi
kind=ship
mode=local-only
EOF
sleep 2
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary > "$TASK_EVIDENCE/inbox-pi-before.txt"
bin/fm-busy-event.sh arm "$LAB/state" busy --state busy --source fm-recovery --event lost-stop-hook >/dev/null
rec=$(FM_HOME="$LAB" bash -c '. bin/fm-task-inbox-lib.sh; fm_task_inbox_write "$FM_HOME/state" busy "Please inspect the stranded operation."')
touch -t 202001010000 "$rec"
run_watch() {
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" TMUX="$TASK_TMUX" TMUX_TMPDIR="$LAB/tmux" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_BUSY_MAX=2 bin/fm-watch.sh > "$TASK_EVIDENCE/$1.log" 2>&1 &
  WATCH_PID=$!
}
run_watch inbox-live-busy
for n in $(seq 1 160); do kill -0 "$WATCH_PID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$WATCH_PID" 2>/dev/null && { cat "$TASK_EVIDENCE/inbox-live-busy.log"; exit 1; }
wait "$WATCH_PID"
WATCH_PID=
cat "$TASK_EVIDENCE/inbox-live-busy.log"
cat "$LAB/state/.wake-queue" > "$TASK_EVIDENCE/inbox-live-queue.log"
cat "$TASK_EVIDENCE/inbox-live-queue.log"
/usr/bin/grep -q 'stuck-busy after 2' "$TASK_EVIDENCE/inbox-live-queue.log"
[ -f "$rec" ]
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary > "$TASK_EVIDENCE/inbox-pi-after.txt"
# No repeated escalation for the same unhandled record after watcher restart.
run_watch inbox-live-dedup
sleep 3
[ "$(/usr/bin/grep -c 'stuck-busy after 2' "$LAB/state/.wake-queue")" = 1 ]
kill -TERM "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=
# Acknowledgement clears the durable busy budget and leaves the inbox quiet.
mv "$rec" "$LAB/state/busy.inbox/handled/"
FM_HOME="$LAB" bash -c '. bin/fm-task-inbox-lib.sh; fm_task_inbox_due_action "$FM_HOME/state" busy' > "$TASK_EVIDENCE/inbox-live-ack.log"
[ ! -e "$LAB/state/busy.inbox/.busy-state" ]
cat "$TASK_EVIDENCE/inbox-live-ack.log"
printf 'One stuck-busy wake; no duplicate on restart; record survived until acknowledgement; acknowledgement cleared busy budget.\n' >> "$TASK_EVIDENCE/inbox-live-ack.log"
