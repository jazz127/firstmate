#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/jarad/.no-mistakes/evidence/01M49NWEKR13QYMQCKQZYD09Z2
export FM_HOME="$E/l" TREEHOUSE_ROOT="$ROOT/.live-validation/pool" FM_SPAWN_NO_GUARD=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
. "$ROOT/bin/fm-trace-context-lib.sh"
fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"
ID=trace-live-a7
RAW='codex --disable hooks exec --skip-git-repo-check "Reply TRACE_WORKER_READY without using tools or changing files."'
printf 'Disposable scout completed.\n' > "$FM_HOME/data/$ID/report.md"
"$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none
printf 'done [at=1712345678]: completed\nnote: cleanup follows\n' > "$FM_HOME/state/$ID.status"
echo '=== Malformed cursor refuses cleanup ==='
printf 'invalid cursor\n' > "$FM_HOME/state/.status-presentation-cursor"
if "$ROOT/bin/fm-teardown.sh" "$ID"; then exit 31; fi
test -f "$FM_HOME/state/$ID.meta"
cp "$FM_HOME/state/$ID.meta" "$E/refused-cleanup.meta"
echo '=== Repair cursor and retry cleanup ==='
rm "$FM_HOME/state/.status-presentation-cursor"
"$ROOT/bin/fm-teardown.sh" "$ID"
echo '=== Repeat cleanup refuses missing record ==='
if "$ROOT/bin/fm-teardown.sh" "$ID"; then exit 32; fi
echo '=== Remove disposable pool slot created by initial inherited environment ==='
treehouse destroy /Users/jarad/.treehouse/project-c32741/1/project --yes
printf 'lifecycle-complete\n' > "$E/lifecycle-ready"
