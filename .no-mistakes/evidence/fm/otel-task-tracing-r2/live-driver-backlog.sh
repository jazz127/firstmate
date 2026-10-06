#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/jarad/.no-mistakes/evidence/01M49NWEKR13QYMQCKQZYD09Z2
export FM_HOME="$E/l" FM_SPAWN_NO_GUARD=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
. "$ROOT/bin/fm-trace-context-lib.sh"
fm_trace_context_session_start "$FM_HOME/config" "$FM_HOME/state/.trace-context-effective"
for mode in close retain; do
  ID="trace-restart-$mode-a7"
  tasks-axi add "$ID" "Disposable restart $mode" --kind ship --start --backend markdown --file "$FM_HOME/data/backlog.md"
  if [ "$mode" = retain ]; then tasks-axi hold "$ID" --reason 'Disposable test pending decision' --kind captain --backend markdown --file "$FM_HOME/data/backlog.md"; fi
  cat > "$FM_HOME/state/$ID.meta" <<META
window=primary:fm-$ID
endpoint_task_id=$ID
worktree=$ROOT/.live-validation/absent-$ID
project=$ROOT/.live-validation/project
harness=codex
kind=ship
mode=local-only
yolo=off
spawn_gen=restart-one
traceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
META
  printf 'failed [at=1712345678]: failed\nnote: cleanup follows\n' > "$FM_HOME/state/$ID.status"
  printf 'malformed\n' > "$FM_HOME/state/.status-presentation-cursor"
  echo "=== $mode cursor refusal before restart ==="
  if "$ROOT/bin/fm-teardown.sh" "$ID"; then exit 41; fi
  test -f "$FM_HOME/state/$ID.meta"
  test -f "$FM_HOME/state/$ID.backlog-close"
  echo "=== $mode restart recovery refuses malformed cursor ==="
  "$ROOT/bin/fm-bootstrap.sh" > "$E/bootstrap-$mode.txt" 2>&1
  test -f "$FM_HOME/state/$ID.meta"
  test -f "$FM_HOME/state/$ID.backlog-close"
  test -f "$FM_HOME/state/$ID.status"
  tasks-axi show "$ID" --backend markdown --file "$FM_HOME/data/backlog.md"
  cp "$FM_HOME/state/$ID.meta" "$E/restart-$mode-refused.meta"
  cp "$FM_HOME/state/$ID.backlog-close" "$E/restart-$mode-refused.marker"
  echo "=== $mode repair and teardown retry ==="
  rm "$FM_HOME/state/.status-presentation-cursor"
  "$ROOT/bin/fm-teardown.sh" "$ID"
  test ! -e "$FM_HOME/state/$ID.meta"
  test ! -e "$FM_HOME/state/$ID.backlog-close"
  tasks-axi show "$ID" --backend markdown --file "$FM_HOME/data/backlog.md"
done
printf 'backlog-complete\n' > "$E/backlog-ready"
