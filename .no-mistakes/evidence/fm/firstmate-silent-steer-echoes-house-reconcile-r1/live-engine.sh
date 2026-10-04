#!/usr/bin/env bash
set -eu
TASK_EVIDENCE=/Users/jarad/.no-mistakes/evidence/01M4372PFF3JWKYX618ESNHJ6Q
LAB="$PWD/.gate-test-tmp/engine-home"
bin/fm-lab-home.sh create "$LAB"
cleanup() {
  [ ! -f "$LAB/state/branch-outcomes.jsonl" ] || cp "$LAB/state/branch-outcomes.jsonl" "$TASK_EVIDENCE/live-engine-outcomes.jsonl"
  [ ! -f "$LAB/state/.supervision-host-receipts" ] || cp "$LAB/state/.supervision-host-receipts" "$TASK_EVIDENCE/live-engine-receipts.tsv"
  rm -rf "$LAB"
}
trap cleanup EXIT
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_ROOT="$PWD" STATE="$LAB/state" FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=lab-classification
export TMPDIR="$PWD/.gate-test-tmp"
touch "$LAB/config/supervision-host"
bin/fm-branch-prompt.sh > "$TASK_EVIDENCE/delivered-branch-prompt.txt"
cat > "$LAB/state/.supervision-host-turn" <<'TURN'
turn=lab-classification
rows=1 2 3 4 5 6 7 8 9 10 11
row_tasks=1=echo 2=recheck 3=paused 4=hold 5=cleared 6=changed 7=action 8=decision 9=failure 10=merge 11=requested
posture=attended
wake=signal: lab reporting observations
TURN
cat > "$TASK_EVIDENCE/live-engine-observations.txt" <<'OBS'
This fleet wake resumes at step 4 (report) after drain, lease handling, current-state inspection and all necessary actions have already completed. There is no pending acknowledgement or lease release in this reporting-only continuation. The current live report turn is lab-classification. These are the verified handling observations, one handled event per row:
1 task echo: The branch just wrote/steered the worker's existing pause/status record. The outcome only repeats that record. No additional action, changed terms, or new result exists.
2 task recheck: A scheduled recheck of an already registered release-window pause found identical worker state and identical waiting terms. Nothing was done.
3 task paused: The worker's declared pause remains true on exactly the same terms as already recorded. No new information or action.
4 task hold: The open captain hold has already been reported and still holds on the same terms. There is no new decision or action.
5 task cleared: The previously registered pause cleared and the worker resumed. This is newly observed progress; the captain did not request an update.
6 task changed: The task progressed from waiting to building, with a new build result. This is unsolicited routine progress.
7 task action: In addition to reading back the existing pause, the branch successfully recovered the worker. Recovery is a real additional action, and no captain action is needed.
8 task decision: A new design choice requires the captain to decide between two incompatible public API contracts. This has never been reported.
9 task failure: A new unrecoverable build failure remains after the recovery playbook was exhausted.
10 task merge: The requested change's PR merged, ordinary teardown succeeded, and the requested work shipped. This result has never been reported. No external PR URL is present in the record.
11 task requested: The captain explicitly requested a health check; that check just finished with a healthy result, never previously reported.
For each handled event, now use the real bin/fm-branch-report.sh with that row and task, deciding verdict and silence under the system prompt. Do not perform or repeat any actions or invent facts, URLs, or captain answers. Reporting is the only remaining work. Report all 11 events individually, using concise summaries of the observed result. Do not edit any other files. The real tools are Bash and Read; the report command durably writes the outcomes and host receipts inside the disposable FM_HOME.
OBS
. bin/fm-wake-lib.sh
. bin/fm-timeout-lib.sh
. bin/fm-supervision-engine-lib.sh
SESSION=$(python3 -c 'import uuid;print(uuid.uuid4())')
fm_supervision_engine_turn claude sonnet "$TASK_EVIDENCE/delivered-branch-prompt.txt" "$TASK_EVIDENCE/live-engine-observations.txt" "$SESSION" new 240 "$TASK_EVIDENCE/live-engine-result.json" "$TASK_EVIDENCE/live-engine-errors.txt"
fm_supervision_engine_result claude "$TASK_EVIDENCE/live-engine-result.json"
bin/fm-branch-outcome.sh list --recent 20
