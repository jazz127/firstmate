#!/usr/bin/env bash
set -eu
TASK_EVIDENCE=/Users/jarad/.no-mistakes/evidence/01M4372PFF3JWKYX618ESNHJ6Q
LAB="$PWD/.gate-test-tmp/engine-boundary-home"
bin/fm-lab-home.sh create "$LAB"
cleanup() {
  [ ! -f "$LAB/state/branch-outcomes.jsonl" ] || cp "$LAB/state/branch-outcomes.jsonl" "$TASK_EVIDENCE/live-boundary-outcomes.jsonl"
  [ ! -f "$LAB/state/.supervision-host-receipts" ] || cp "$LAB/state/.supervision-host-receipts" "$TASK_EVIDENCE/live-boundary-receipts.tsv"
  rm -rf "$LAB"
}
trap cleanup EXIT
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_ROOT="$PWD" STATE="$LAB/state" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=lab-boundary
export TMPDIR="$PWD/.gate-test-tmp"
touch "$LAB/config/supervision-host"
bin/fm-branch-prompt.sh > "$TASK_EVIDENCE/delivered-branch-prompt.txt"
cat > "$LAB/state/.supervision-host-turn" <<'TURN'
turn=lab-boundary
rows=1 2 3
row_tasks=1=blocker 2=uncertain 3=newterms
posture=attended
wake=signal: reporting changed or uncertain conditions
TURN
cat > "$TASK_EVIDENCE/live-boundary-observations.txt" <<'OBS'
This wake resumes at report step 4 after drain and all required current-state inspections; reporting is the only remaining work. No acknowledgement or lease release remains. These are the verified handled-event observations:
1 task blocker: A previously reported waiting condition now has a new actionable blocker: the required release credential is no longer available. No credential handling was attempted, and MAIN must arrange access. This has not previously been reported.
2 task uncertain: A registered pause was rechecked, but the observations cannot establish whether the task is still on the same terms; there may be a new failure. Inspection exhausted the available evidence, so this uncertainty needs MAIN's judgment. Nothing confirms the old state.
3 task newterms: An open captain hold was rechecked and its terms changed. The captain now needs to choose whether to proceed without a newly missing compatibility guarantee; this is a new decision and was not part of the previous hold.
Use the real bin/fm-branch-report.sh for each row and task, choosing verdict and silence under the system prompt. Do not perform additional actions, make up facts, answer captain decisions or edit files other than the report command's durable writes. These are reporting-phase observations in a disposable FM_HOME.
OBS
. bin/fm-wake-lib.sh
. bin/fm-timeout-lib.sh
. bin/fm-supervision-engine-lib.sh
SESSION=$(python3 -c 'import uuid;print(uuid.uuid4())')
fm_supervision_engine_turn claude sonnet "$TASK_EVIDENCE/delivered-branch-prompt.txt" "$TASK_EVIDENCE/live-boundary-observations.txt" "$SESSION" new 240 "$TASK_EVIDENCE/live-boundary-result.json" "$TASK_EVIDENCE/live-boundary-errors.txt"
fm_supervision_engine_result claude "$TASK_EVIDENCE/live-boundary-result.json"
bin/fm-branch-outcome.sh list --recent 20
