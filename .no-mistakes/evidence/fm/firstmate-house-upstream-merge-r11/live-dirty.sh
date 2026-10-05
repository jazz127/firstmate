#!/bin/bash
set -eu
TASK_EVIDENCE=/Users/jarad/.no-mistakes/evidence/01M455W9R326CJ1BPJVJB6ADKS
LAB=$(mktemp -d "$PWD/.test-phase/tmp/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/repo"
git -C "$LAB/repo" init -q -b main
printf 'baseline\n' > "$LAB/repo/tracked.txt"
git -C "$LAB/repo" add tracked.txt
git -C "$LAB/repo" -c user.name=Test -c user.email=test@example.invalid commit -qm baseline
git -C "$LAB/repo" worktree add -q -b fm/dirty "$LAB/task"
cat > "$LAB/state/dirty.meta" <<EOF
window=fm-lab-dirty:fm-dirty
backend=tmux
endpoint_task_id=dirty
spawn_gen=live-test-dirty
worktree=$LAB/task
project=$LAB/repo
kind=ship
mode=local-only
harness=claude
EOF
touch "$LAB/state/.last-watcher-beat"
for n in $(seq -w 1 12); do printf 'scratch\n' > "$LAB/task/scratch-$n.txt"; done
run_refusal() {
  set +e
  env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" bin/fm-teardown.sh dirty > "$TASK_EVIDENCE/$1.log" 2>&1
  status=$?
  set -e
  cat "$TASK_EVIDENCE/$1.log"
  [ "$status" -ne 0 ]
  [ -f "$LAB/task/scratch-12.txt" ]
  [ -f "$LAB/state/dirty.meta" ]
}
run_refusal dirty-untracked
/usr/bin/grep -q 'untracked-only leftovers' "$TASK_EVIDENCE/dirty-untracked.log"
/usr/bin/grep -q 'additional untracked paths omitted' "$TASK_EVIDENCE/dirty-untracked.log"
printf 'edited\n' > "$LAB/task/tracked.txt"
run_refusal dirty-tracked
/usr/bin/grep -q 'includes tracked edits' "$TASK_EVIDENCE/dirty-tracked.log"
[ "$(cat "$LAB/task/tracked.txt")" = edited ]
printf 'Refusals preserved the task metadata, tracked edit and all 12 scratch files.\n'
