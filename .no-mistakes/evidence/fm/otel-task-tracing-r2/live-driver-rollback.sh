#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/jarad/.no-mistakes/evidence/01M49NWEKR13QYMQCKQZYD09Z2
export FM_HOME="$E/l" TREEHOUSE_ROOT="$ROOT/.live-validation/pool" FM_SPAWN_NO_GUARD=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
. "$ROOT/bin/fm-trace-context-lib.sh"
fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"
ID=trace-live-rollback-a7
mkdir -p "$FM_HOME/data/$ID"
cp "$FM_HOME/data/trace-live-a7/brief.md" "$FM_HOME/data/$ID/brief.md"
RAW='codex --disable hooks exec --skip-git-repo-check "Reply TRACE_WORKER_READY without using tools or changing files."'
python3 "$ROOT/.live-validation/rollback.py" > "$E/rollback-injection.log" 2>&1 &
watcher=$!
rc=0
"$ROOT/bin/fm-spawn.sh" "$ID" "$ROOT/.live-validation/project" --scout --backend tmux --harness "$RAW" || rc=$?
wait "$watcher"
printf 'spawn-exit=%s metadata-present=%s\n' "$rc" "$([ -f "$FM_HOME/state/$ID.meta" ] && printf yes || printf no)"
[ "$rc" -ne 0 ]
[ ! -e "$FM_HOME/state/$ID.meta" ]
printf 'rollback-complete\n' > "$E/rollback-ready"
