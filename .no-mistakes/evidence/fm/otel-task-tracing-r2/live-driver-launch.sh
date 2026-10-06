#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/jarad/.no-mistakes/evidence/01M49NWEKR13QYMQCKQZYD09Z2
export FM_HOME="$E/l" TREEHOUSE_ROOT="$ROOT/.live-validation/pool" TREEHOUSE_NO_FETCH=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
export FM_SPAWN_NO_GUARD=1
P="$ROOT/.live-validation/project"
mkdir -p "$P"
git -C "$P" init -q -b main
printf 'Disposable live tracing project\n' > "$P/README"
git -C "$P" add README
git -C "$P" -c user.name=Lab -c user.email=lab@example.invalid -c commit.gpgsign=false commit -qm initial
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
touch "$FM_HOME/config/trace-context"
printf 'Authorization: Bearer disposable-lab-token\n' > "$FM_HOME/config/auth-header"
chmod 600 "$FM_HOME/config/auth-header"
jq -n --arg auth "$FM_HOME/config/auth-header" '{enabled:true,endpoint:"http://127.0.0.1:24318/v1/traces","auth-header-file":$auth}' > "$FM_HOME/config/trace-export.json"
. "$ROOT/bin/fm-trace-context-lib.sh"
fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"
ID=trace-live-a7
mkdir -p "$FM_HOME/data/$ID"
cat > "$FM_HOME/data/$ID/brief.md" <<'BRIEF'
# Task
## Captain's intent
Perform a disposable tracing smoke check.
## Firstmate spec
Reply TRACE_WORKER_READY without using tools or changing files.
BRIEF
RAW='codex --disable hooks exec --skip-git-repo-check "Reply TRACE_WORKER_READY without using tools or changing files."'
echo '=== Fresh enabled launch ==='
"$ROOT/bin/fm-spawn.sh" "$ID" "$P" --scout --backend tmux --harness "$RAW"
cp "$FM_HOME/state/$ID.meta" "$E/fresh.meta"
echo '=== Duplicate launch must refuse ==='
if "$ROOT/bin/fm-spawn.sh" "$ID" "$P" --scout --backend tmux --harness "$RAW"; then exit 21; fi
printf 'launch-complete\n' > "$E/launch-ready"
