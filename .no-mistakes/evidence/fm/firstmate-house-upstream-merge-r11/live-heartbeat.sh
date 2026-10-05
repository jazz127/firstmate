#!/bin/bash
set -eu
TASK_EVIDENCE=/Users/jarad/.no-mistakes/evidence/01M455W9R326CJ1BPJVJB6ADKS
TASK_SCRATCH=$(mktemp -d "$PWD/.test-phase/tmp/worker-live.XXXXXX")
mkdir -p "$TASK_SCRATCH/account"
WORKER_PID=
cleanup() {
  if [ -n "$WORKER_PID" ]; then
    kill -CONT "$WORKER_PID" 2>/dev/null || true
    kill -TERM "$WORKER_PID" 2>/dev/null || true
    wait "$WORKER_PID" 2>/dev/null || true
  fi
  rm -rf "$TASK_SCRATCH"
}
trap cleanup EXIT
export FM_REMOTE_JOB_STATE_ROOT="$TASK_SCRATCH/state"
. bin/fm-remote-job-lib.sh
HOME="$TASK_SCRATCH/account" FM_ROOT_OVERRIDE="$PWD" FM_REMOTE_JOB_STATE_ROOT="$TASK_SCRATCH/state" bin/fm-remote-job-worker.sh --serve > "$TASK_EVIDENCE/heartbeat-worker.log" 2>&1 &
WORKER_PID=$!
for n in $(seq 1 160); do [ -f "$TASK_SCRATCH/state/worker.ready" ] && break; sleep 0.05; done
fm_remote_job_probe "$TASK_SCRATCH/account"
OWNER=$(cat "$TASK_SCRATCH/state/worker.lock/pid")
[ "$OWNER" = "$WORKER_PID" ]
{
  printf 'Real worker owner: %s\n' "$OWNER"
  printf 'Initial readiness:\n'
  cat "$TASK_SCRATCH/state/worker.ready"
  kill -STOP "$OWNER"
  rm "$TASK_SCRATCH/state/worker.ready"
  for n in $(seq 1 40); do [ -f "$TASK_SCRATCH/state/worker.ready" ] && break; sleep 0.05; done
  printf 'Readiness recreated with the serving owner stopped:\n'
  cat "$TASK_SCRATCH/state/worker.ready"
  [ "$(head -1 "$TASK_SCRATCH/state/worker.ready")" = "$OWNER" ]
  [ "$(stat -f '%Lp' "$TASK_SCRATCH/state/worker.ready")" = 600 ]
  sleep 12
  printf 'Serving process state after 12 seconds:\n'
  /bin/ps -p "$OWNER" -o pid=,state=,comm=
  printf 'Readiness file timestamp:\n'
  stat -f '%Sm mode=%Lp' -t '%Y-%m-%dT%H:%M:%S' "$TASK_SCRATCH/state/worker.ready"
  fm_remote_job_probe "$TASK_SCRATCH/account"
  printf 'Probe passed beyond the 10-second freshness bound while serving remained stopped.\n'
  kill -CONT "$OWNER"
} > "$TASK_EVIDENCE/heartbeat-live.log" 2>&1
cat "$TASK_EVIDENCE/heartbeat-live.log"
