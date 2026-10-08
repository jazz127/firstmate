#!/bin/bash
set -eu
E=/Users/jarad/.no-mistakes/evidence/01M4BYXMSQ45VRM1V0Y30Z00VR
LAB="$PWD/.nm-owner"
SOCK="$E/s"
REAL_TMUX=$(command -v tmux)
cleanup() {
  TMUX_TMPDIR="$SOCK" "$REAL_TMUX" -L fm-lab kill-server 2>/dev/null || true
  rm -rf "$LAB" "$SOCK"
}
trap cleanup EXIT
bash bin/fm-lab-home.sh create "$LAB"
mkdir -p "$SOCK" "$LAB/route"
chmod 700 "$SOCK"
printf '#!/bin/sh\nexec %s -L fm-lab "$@"\n' "$REAL_TMUX" > "$LAB/route/tmux"
chmod 700 "$LAB/route/tmux"
export TMUX_TMPDIR="$SOCK" FM_HOME="$LAB" PATH="$LAB/route:$PATH" FM_TEST_SENTINEL=kept
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
bash -c '
  export FM_TIMEOUT_OWNER_PID=$$ FM_EXEC_TIMED_OWNER_PID=$$
  printf "%s\n" "$$" > "$FM_HOME/owner.pid"
  . bin/fm-backend.sh
  fm_backend_source tmux
  fm_backend_tmux_container_ensure
  fm_backend_tmux_create_task firstmate fm-recovered "$PWD"
'
OWNER=$(cat "$LAB/owner.pid")
if kill -0 "$OWNER" 2>/dev/null; then exit 1; fi
printf 'Owner %s has exited.\n' "$OWNER"
tmux show-environment -g | sed -n '/FM_TIMEOUT_OWNER_PID\|FM_EXEC_TIMED_OWNER_PID\|FM_TEST_SENTINEL/p'
if tmux show-environment -g | rg '^FM_(TIMEOUT_OWNER_PID|EXEC_TIMED_OWNER_PID)='; then exit 1; fi
COMMAND="printf 'timeout_owner=%s exec_owner=%s sentinel=%s\\n' \"\${FM_TIMEOUT_OWNER_PID-unset}\" \"\${FM_EXEC_TIMED_OWNER_PID-unset}\" \"\$FM_TEST_SENTINEL\"; . '$PWD/bin/fm-timeout-lib.sh'; fm_run_timed 3 bash -c 'sleep 0.2; echo startup-complete'"
tmux send-keys -t firstmate:fm-recovered "$COMMAND" Enter
for i in {1..50}; do
  tmux capture-pane -p -t firstmate:fm-recovered > "$E/live-owner-pane.txt"
  if rg '^startup-complete$' "$E/live-owner-pane.txt"; then break; fi
  sleep 0.1
done
rg '^timeout_owner=unset exec_owner=unset sentinel=kept$' "$E/live-owner-pane.txt"
rg '^startup-complete$' "$E/live-owner-pane.txt"
printf 'Fresh real server and pane completed timed startup after owner exit.\n'
