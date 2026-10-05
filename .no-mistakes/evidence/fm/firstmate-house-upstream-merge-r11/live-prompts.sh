#!/bin/bash
set -eu
TASK_EVIDENCE=/Users/jarad/.no-mistakes/evidence/01M455W9R326CJ1BPJVJB6ADKS
LAB=$(mktemp -d "$PWD/.test-phase/tmp/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
for mode in no-mistakes direct-PR local-only; do
  ship="ship-$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
  scout="promote-$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
  bin/fm-brief.sh "$ship" fixture-project --mode "$mode" >/dev/null
  bin/fm-brief.sh "$scout" fixture-project --scout >/dev/null
  python3 - "$LAB/data/$scout/brief.md" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text().replace('{TASK}','Preserve worktree cleanliness while collecting proof.').replace('{FIRSTMATE_SPEC}','Keep implementation in the worktree and place scratch output in the task data directory.')
p.write_text(s)
PY
  printf 'window=fm-%s\nkind=scout\nworktree=%s/fixture-worktree\n' "$scout" "$LAB" > "$LAB/state/$scout.meta"
  bin/fm-promote.sh "$scout" --mode "$mode" --yolo off > "$TASK_EVIDENCE/promotion-$mode.log" 2>&1
  cp "$LAB/data/$ship/brief.md" "$TASK_EVIDENCE/ship-brief-$mode.md"
  cp "$LAB/data/$scout/ship-instructions.md" "$TASK_EVIDENCE/promoted-instructions-$mode.md"
  cp "$LAB/data/$scout/brief.md" "$TASK_EVIDENCE/promoted-relaunch-$mode.md"
  # These are the intentional generated prompt contracts, not source code.
  for f in "$TASK_EVIDENCE/ship-brief-$mode.md" "$TASK_EVIDENCE/promoted-instructions-$mode.md" "$TASK_EVIDENCE/promoted-relaunch-$mode.md"; do
    /usr/bin/grep -q 'keep proof and scratch output outside it' "$f"
    /usr/bin/grep -q 'Outside the worktree, write only that task material and the status and steering-inbox records authorized below.' "$f"
    /usr/bin/grep -q 'Leave the worktree clean before reporting done.' "$f"
    /usr/bin/grep -q "Delivery contract: mode=$mode" "$f"
  done
  /usr/bin/grep -q '^kind=ship$' "$LAB/state/$scout.meta"
  printf '%s: scaffold, promoted delivery and relaunch briefs carry the scratch boundary and selected delivery contract.\n' "$mode"
done
