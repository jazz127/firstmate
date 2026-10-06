#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/jarad/.no-mistakes/evidence/01M49NWEKR13QYMQCKQZYD09Z2
export FM_HOME="$E/l" FM_SPAWN_NO_GUARD=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
cp "$FM_HOME/data/backlog.md" "$E/backlog-final.md"
rm "$FM_HOME/data/backlog.md"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
. "$ROOT/bin/fm-trace-context-lib.sh"
. "$ROOT/bin/fm-wake-lib.sh"
fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"
for outcome in failed done disabled; do
  ID="trace-remove-$outcome-a7"
  expected=$outcome
  export FM_TRACE_EXPORT=on
  if [ "$outcome" = disabled ]; then expected=failed; export FM_TRACE_EXPORT=off; fi
  meta="$FM_HOME/state/$ID.meta"
  cat > "$meta" <<META
window=primary:fm-$ID
worktree=$ROOT/.live-validation/absent-$ID
project=$ROOT/.live-validation/project
harness=codex
kind=ship
mode=local-only
yolo=off
spawn_gen=remove-one
traceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
META
  printf '%s [at=1712345678]: finished\nnote: cleanup follows\n' "$expected" > "$FM_HOME/state/$ID.status"
  fm_lock_acquire_wait "$FM_HOME/state/.status-presentation-lock"
  echo "=== $outcome final metadata removal failure ==="
  "$ROOT/bin/fm-teardown.sh" "$ID" &
  child=$!
  for n in $(seq 1 200); do
    if [ "$(sed -n 's/^trace_outcome=//p' "$meta")" = "$expected" ]; then break; fi
    sleep .05
  done
  test "$(sed -n 's/^trace_outcome=//p' "$meta")" = "$expected"
  chmod +a 'everyone deny delete' "$meta"
  fm_lock_release "$FM_HOME/state/.status-presentation-lock"
  rc=0
  wait "$child" || rc=$?
  test "$rc" -ne 0
  test -f "$meta"
  test ! -f "$FM_HOME/state/$ID.status"
  cp "$meta" "$E/remove-$outcome-refused.meta"
  chmod -N "$meta"
  echo "=== $outcome repair and retry without original status log ==="
  "$ROOT/bin/fm-teardown.sh" "$ID"
  test ! -e "$meta"
done
printf 'removal-complete\n' > "$E/removal-ready"
