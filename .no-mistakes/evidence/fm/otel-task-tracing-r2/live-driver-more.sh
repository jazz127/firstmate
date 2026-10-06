#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/jarad/.no-mistakes/evidence/01M49NWEKR13QYMQCKQZYD09Z2
export FM_HOME="$E/l" TREEHOUSE_ROOT="$ROOT/.live-validation/pool" FM_SPAWN_NO_GUARD=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
. "$ROOT/bin/fm-trace-context-lib.sh"
fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"
# Imported historical task records are disposable data; the backend and collector remain real.
for suffix in failed unknown renewed; do
  ID="trace-historical-$suffix"
  cat > "$FM_HOME/state/$ID.meta" <<META
window=primary:fm-$ID
worktree=$ROOT/.live-validation/absent-$ID
project=$ROOT/.live-validation/project
harness=codex
kind=ship
mode=local-only
yolo=off
spawn_gen=historical-one
traceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
META
  case "$suffix" in
    failed) printf 'failed [at=1712345678]: failed\nnote: cleanup complete\n' > "$FM_HOME/state/$ID.status" ;;
    unknown) : > "$FM_HOME/state/$ID.status" ;;
    renewed) printf 'done [at=1712345678]: done\nnote: cleanup complete\nworking: renewed work\nnote: progress\n' > "$FM_HOME/state/$ID.status" ;;
  esac
  echo "=== Historical $suffix cleanup ==="
  "$ROOT/bin/fm-teardown.sh" "$ID"
done
ID=trace-live-disabled-a7
mkdir -p "$FM_HOME/data/$ID"
cp "$FM_HOME/data/trace-live-a7/brief.md" "$FM_HOME/data/$ID/brief.md"
RAW='codex --disable hooks exec --skip-git-repo-check "Reply TRACE_WORKER_READY without using tools or changing files."; printf "carrier-after-worker:%s\n" "${TRACEPARENT-unset}"'
echo '=== Enabled local-pool launch ==='
"$ROOT/bin/fm-spawn.sh" "$ID" "$ROOT/.live-validation/project" --scout --backend tmux --harness "$RAW"
cp "$FM_HOME/state/$ID.meta" "$E/disabled-before.meta"
sleep 8
tmux capture-pane -p -t "primary:fm-$ID" > "$E/disabled-before.txt"
echo '=== Disabled relaunch scrubs old trace fields and environment ==='
FM_TRACE_CONTEXT=off fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"
"$ROOT/bin/fm-spawn.sh" "$ID" --relaunch --harness "$RAW"
cp "$FM_HOME/state/$ID.meta" "$E/disabled-after.meta"
sleep 8
tmux capture-pane -p -t "primary:fm-$ID" > "$E/disabled-after.txt"
printf 'Disposable check complete.\n' > "$FM_HOME/data/$ID/report.md"
"$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none
"$ROOT/bin/fm-teardown.sh" "$ID"
printf 'more-complete\n' > "$E/more-ready"
