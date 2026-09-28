#!/usr/bin/env bash
# Live check: run the REAL fm-remote-job-worker.sh as a launchd worker would
# (LC_ALL=C, clean env, real macOS /bin/ps, no platform override), then probe
# it from an "SSH session" shell carrying a non-C LANG, using the library from
# the given source checkout (base or target commit).
set -u
SRC=$1; LABEL=$2
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-locale-live.XXXXXX"); T=$(cd "$T" && pwd -P)
R="$T/remote-root"; A="$T/account"; S="$T/remote-jobs"; H="$T/home-a"
mkdir -p "$R/bin" "$A" "$H"
cp "$SRC"/bin/*.sh "$R/bin/"; mkdir -p "$R/bin/backends"; cp "$SRC/bin/backends/herdr.sh" "$R/bin/backends/"
printf '#!/bin/bash\nprintf "steer-ok %%s\\n" "$1" > "$2"\n' > "$R/bin/fm-mark-job.sh"; chmod +x "$R/bin"/*.sh
printf 'fixture\n' > "$R/AGENTS.md"
git -C "$R" init -q -b main; git -C "$R" -c user.email=t@e -c user.name=t add -A; git -C "$R" -c user.email=t@e -c user.name=t commit -qm fixture
cleanup() { [ -f "$S/worker.pid" ] && kill -TERM -- "$(cat "$S/worker.pid")" 2>/dev/null; pkill -f "$R/bin/fm-remote-job-worker.sh" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
echo "== [$LABEL] source: $SRC"
# launchd-style start: C locale, minimal env
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$A" LC_ALL=C FM_ROOT_OVERRIDE="$R" FM_REMOTE_JOB_STATE_ROOT="$S" \
  "$R/bin/fm-remote-job-worker.sh" > "$T/worker.out" 2> "$T/worker.err" &
for _ in $(seq 1 100); do [ -f "$S/worker.ready" ] && break; sleep 0.05; done
[ -f "$S/worker.ready" ] || { echo "worker never became ready"; cat "$T/worker.err"; exit 1; }
echo "worker lock/start recorded by C-locale worker: $(cat "$S/worker.lock/start")"
for loc in en_AU.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 C; do
  (
    unset LC_ALL LC_TIME; export LANG=$loc HOME="$A" FM_ROOT_OVERRIDE="$R" FM_REMOTE_JOB_STATE_ROOT="$S"
    . "$R/bin/fm-remote-job-lib.sh"
    pid=$(cat "$S/worker.lock/pid")
    printf -- '-- SSH caller LANG=%s: raw ps lstart="%s"\n' "$loc" "$(/bin/ps -p "$pid" -o lstart= | sed 's/ *$//')"
    printf '   fm_remote_job_process_start => "%s"\n' "$(fm_remote_job_process_start "$pid")"
    if fm_remote_job_lock_owner_matches_process "$A"; then echo "   lock_owner_matches_process: MATCH"; else echo "   lock_owner_matches_process: MISMATCH"; fi
    if fm_remote_job_worker_owned_alive "$R" "$A"; then echo "   worker_owned_alive: yes"; else echo "   worker_owned_alive: NO"; fi
  )
done
echo "-- steer round-trip from LANG=en_AU.UTF-8 caller (stage+wait a real job through the worker):"
(
  unset LC_ALL; export LANG=en_AU.UTF-8 HOME="$A" FM_ROOT_OVERRIDE="$R" FM_REMOTE_JOB_STATE_ROOT="$S"
  . "$R/bin/fm-remote-job-lib.sh"
  s=$(date +%s)
  fm_remote_job_stage "$A" "$R" "$H" fm-mark-job.sh hello "$T/out" </dev/null >/dev/null || { echo "   stage failed: $FM_REMOTE_JOB_ERROR"; exit 1; }
  fm_remote_job_wait "$A" "$FM_REMOTE_JOB_ID" || { echo "   wait failed: $FM_REMOTE_JOB_ERROR"; exit 1; }
  echo "   exit=$FM_REMOTE_JOB_EXIT output=$(cat "$T/out") elapsed=$(( $(date +%s)-s ))s"
)
echo "-- adversarial: tamper recorded start (simulated PID reuse) from en_AU caller:"
cp "$S/worker.lock/start" "$T/start.bak"; printf 'Tue Sep 29 01:02:03 2026\n' > "$S/worker.lock/start"
(
  unset LC_ALL; export LANG=en_AU.UTF-8 HOME="$A" FM_ROOT_OVERRIDE="$R" FM_REMOTE_JOB_STATE_ROOT="$S"
  . "$R/bin/fm-remote-job-lib.sh"
  if fm_remote_job_lock_owner_matches_process "$A"; then echo "   tampered start: MATCH (guard broken)"; else echo "   tampered start: rejected (guard intact)"; fi
)
cp "$T/start.bak" "$S/worker.lock/start"
