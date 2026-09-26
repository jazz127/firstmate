LAB=/var/folders/9h/6hvtvt257md69k7nq7ycyq5h0000gn/T//fm-lab.4RiunP
L() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" TMUX="$LAB/tmux/tmux-$(id -u)/fm-lab,0,0" "$@"; }
L_exec() { exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" TMUX="$LAB/tmux/tmux-$(id -u)/fm-lab,0,0" "$@"; }
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
watch_for() { # <secs> <outfile>
  (L_exec env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_PAUSE_RESURFACE_SECS=999999 ${WATCH_EXTRA:-} bin/fm-watch.sh > "$2" 2>&1) & local p=$!
  local i=0; while [ $i -lt $1 ] && kill -0 $p 2>/dev/null; do sleep 1; i=$((i+1)); done
  if kill -0 $p 2>/dev/null; then kill $p; wait $p 2>/dev/null; echo "watcher still running after $1s (killed)"; else wait $p; echo "watcher exited rc=$?"; fi
}
