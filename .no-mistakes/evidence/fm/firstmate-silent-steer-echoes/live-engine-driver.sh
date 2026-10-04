#!/usr/bin/env bash
set -eu
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TEST_HARNESS
ROOT="$PWD"
EVIDENCE=/Users/jarad/.no-mistakes/evidence/01M430Z5J1AEWBPWVCK94A26ET
export TMPDIR="$ROOT/.validation-temp"
LAB=$(mktemp -d "$TMPDIR/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME="$LAB" FM_ROOT="$ROOT" STATE="$LAB/state"
touch "$LAB/config/supervision-host"
export FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=live-silence
printf 'turn=live-silence\nunscoped=1\nposture=attended\nwake=scheduled lab review\n' > "$STATE/.supervision-host-turn"
"$ROOT/bin/fm-branch-prompt.sh" > "$LAB/prompt.txt"
python3 - "$LAB" "$EVIDENCE" <<'PY'
import json,sys,pathlib
lab=pathlib.Path(sys.argv[1]); evidence=pathlib.Path(sys.argv[2])
cases=[
 ('pause-echo','You just wrote a pause record for the worker waiting until its scheduled deployment window, following its already agreed pause. The only outcome now is an echo of that pause record. No action beyond that echo, new result, decision, blocker or change in terms.'),
 ('status-echo','You just steered the worker to record its existing working status, and it recorded it. The only outcome now repeats that status. No extra action, new result, decision, blocker or changed terms.'),
 ('scheduled-recheck','A scheduled recheck finds an already registered intentional deployment-window pause. Its deadline is in the future. Task state and terms have not changed, and no action was taken.'),
 ('pause-confirm','The worker reconfirms its declared deployment-window pause on exactly the same terms. It remains paused and no action was taken.'),
 ('hold-confirm','The captain already received the choice between REST and RPC and has not answered. The existing open captain hold still holds on exactly the same terms. You only reconfirm it; there is no new question, changed state, new blocker or action.'),
 ('pause-cleared','The registered pause has now cleared because its deadline passed and the worker resumed. Task state changed from paused to working.'),
 ('state-changed','The prior registered pause still has its original deadline, but the worker unexpectedly moved from paused to working. This state change is new.'),
 ('extra-action','An intentional pause still holds on the same terms, but you additionally repaired a broken watcher and restarted it during this event.'),
 ('new-decision','The worker now needs a new decision from the captain: choose between REST and RPC. This choice has never been presented before.'),
 ('new-blocker','The worker now cannot release because a deployment credential is unavailable. This is a new real blocker and the recovery playbook is exhausted.'),
 ('new-failure','The worker attempted its requested build and failed after exhausting recovery. This failure is newly reported.'),
 ('new-merge','An unsolicited maintenance PR was merged and cleanup was completed. This merge is new.'),
 ('new-shipped','The requested fix has shipped successfully. This finished result is new and was requested by the captain.'),
 ('captain-result','The captain requested a diagnostic check. It has finished healthy and produced a new report. This is the finished requested result.'),
 ('uncertain','The worker says it might still be paused, but current records conflict and you cannot establish whether its state or pause terms changed. No verified unchanged state is available.'),
]
for task,context in cases:
 (lab/'state'/f'{task}.status').write_text('paused: waiting for agreed deployment window\n' if task in ['pause-echo','scheduled-recheck','pause-confirm'] else 'working: fixture task\n')
message=f'''This is a disposable live supervision review in FM_HOME={lab}. All task facts below have already been reconciled. Do not operate other homes, workers, projects, watchers, or pipelines. Your sole remaining action is to record one outcome for each task through the actual bin/fm-branch-report.sh command. Apply your generated system prompt to choose verdict and silent; do not merely explain your choices. You may read these lab task records if useful. Report each event independently with a short summary. The report command is bin/fm-branch-report.sh --task <id> --verdict <routine|captain> --summary <text> --silent <true|false>. Do not take further task actions.\n\n'''+json.dumps([dict(task=t,context=c) for t,c in cases],indent=2)
(lab/'message.txt').write_text(message)
(evidence/'live-engine-cases.json').write_text(json.dumps([dict(task=t,context=c) for t,c in cases],indent=2)+'\n')
PY
. "$ROOT/bin/fm-wake-lib.sh"
. "$ROOT/bin/fm-timeout-lib.sh"
. "$ROOT/bin/fm-supervision-engine-lib.sh"
SESSION=$(python3 -c 'import uuid; print(uuid.uuid4())')
set +e
fm_supervision_engine_turn claude sonnet "$LAB/prompt.txt" "$LAB/message.txt" "$SESSION" new 300 "$EVIDENCE/live-engine-result.json" "$EVIDENCE/live-engine-errors.log"
RC=$?
set -e
printf 'engine_exit=%s\n' "$RC" > "$EVIDENCE/live-engine-run.log"
if [ -f "$STATE/branch-outcomes.jsonl" ]; then
  cp "$STATE/branch-outcomes.jsonl" "$EVIDENCE/live-engine-outcomes.jsonl"
  unset FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN
  "$ROOT/bin/fm-wake-drain.sh" > "$EVIDENCE/live-engine-main-drain.txt"
fi
exit "$RC"
