#!/usr/bin/env bash
set -eu
TASK_EVIDENCE=/Users/jarad/.no-mistakes/evidence/01M4372PFF3JWKYX618ESNHJ6Q
LAB="$PWD/.l"
SOCKET_DIR="$PWD/.l/tmux"
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/pi-config" "$LAB/sessions"
cleanup() {
 TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab kill-server 2>/dev/null || true
 rm -rf "$LAB"
}
trap cleanup EXIT
FM_HOME="$LAB" bin/fm-branch-outcome.sh append --task restored --verdict routine --summary 'The pause cleared and worker resumed'
FM_HOME="$LAB" bin/fm-branch-outcome.sh append --task recovered --verdict routine --summary 'The worker recovered after the registered pause'
FM_HOME="$LAB" bin/fm-branch-outcome.sh append --task held --verdict routine --summary 'The existing captain hold is unchanged' --silent true
PI_LAB_COMMAND="env PI_CODING_AGENT_DIR='$LAB/pi-config' PI_TELEMETRY=0 TMPDIR='$PWD/.gate-test-tmp' pi --offline --no-extensions --no-skills --no-prompt-templates --no-context-files --no-themes --approve --extension '$PWD/.gate-test-tmp/pi-lock.ts' --extension '$PWD/.pi/extensions/fm-branch-supervision.ts' --extension '$PWD/.gate-test-tmp/pi-observer.ts' --session-dir '$LAB/sessions' --mode rpc"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" "$PI_LAB_COMMAND"
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab send-keys -t primary '{"id":"replay","type":"get_state"}' Enter
for i in {1..120}; do
 if [ "$(cat "$LAB/state/.branch-outcomes-cursor" 2>/dev/null || true)" = 3 ]; then break; fi
 sleep 0.25
done
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab capture-pane -p -t primary -S -150 > "$TASK_EVIDENCE/live-pi-pane.txt"
cat "$TASK_EVIDENCE/live-pi-pane.txt"
cat "$LAB/lock-acquisition.txt"
[ "$(cat "$LAB/state/.branch-outcomes-cursor")" = 3 ]
cp "$LAB/state/branch-outcomes.jsonl" "$TASK_EVIDENCE/live-pi-outcomes.jsonl"
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab send-keys -t primary '{"id":"visual","type":"export_html","outputPath":"/Users/jarad/.no-mistakes/evidence/01M4372PFF3JWKYX618ESNHJ6Q/live-pi-replay.html"}' Enter
for i in {1..80}; do
 [ ! -s "$TASK_EVIDENCE/live-pi-replay.html" ] || break
 sleep 0.25
done
[ -s "$TASK_EVIDENCE/live-pi-replay.html" ]
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab capture-pane -p -J -t primary -S -150 > "$TASK_EVIDENCE/live-pi-pane.txt"
cat "$TASK_EVIDENCE/live-pi-pane.txt"
python3 - "$TASK_EVIDENCE/live-pi-session.jsonl" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1])]
messages=[r for r in rows if r.get('type')=='custom_message']
merged=[m for m in messages if m.get('customType')=='fm-branch-merge']
assert len(merged)==3,merged
assert all(m.get('display') is False for m in merged),merged
assert any('The existing captain hold is unchanged' in str(m) for m in merged),merged
assert not any(r.get('type')=='message' and r['message'].get('role')=='assistant' for r in rows),rows
print('Real Pi replay stored non-silent routines and the silent hold with display=false, and opened no assistant turn.')
PY
