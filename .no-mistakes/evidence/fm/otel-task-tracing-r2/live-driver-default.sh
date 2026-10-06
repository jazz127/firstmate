#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/jarad/.no-mistakes/evidence/01M49NWEKR13QYMQCKQZYD09Z2
export FM_HOME="$E/l" TREEHOUSE_ROOT="$ROOT/.live-validation/pool" FM_SPAWN_NO_GUARD=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND FM_TRACE_CONTEXT FM_TRACE_EXPORT
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
rm "$FM_HOME/config/trace-context"
. "$ROOT/bin/fm-trace-context-lib.sh"
fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"
ID=trace-default-off-a7
mkdir -p "$FM_HOME/data/$ID"
cp "$FM_HOME/data/trace-live-a7/brief.md" "$FM_HOME/data/$ID/brief.md"
RAW='codex --disable hooks exec --skip-git-repo-check "Reply TRACE_WORKER_READY without using tools or changing files."; printf "carrier-after-worker:%s\n" "${TRACEPARENT-unset}"'
echo '=== Default-off launch with export configured ==='
"$ROOT/bin/fm-spawn.sh" "$ID" "$ROOT/.live-validation/project" --scout --backend tmux --harness "$RAW"
cp "$FM_HOME/state/$ID.meta" "$E/default-off.meta"
sleep 8
tmux capture-pane -p -t "primary:fm-$ID" > "$E/default-off.txt"
printf 'Disposable check complete.\n' > "$FM_HOME/data/$ID/report.md"
"$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none
"$ROOT/bin/fm-teardown.sh" "$ID"
printf 'default-complete\n' > "$E/default-ready"
