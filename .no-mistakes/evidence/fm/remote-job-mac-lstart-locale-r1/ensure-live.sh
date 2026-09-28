#!/usr/bin/env bash
# Live check: a C-locale worker is already serving; an en_AU.UTF-8 SSH caller
# runs fm_remote_job_ensure_worker (non-launchd supervisor path, since driving
# the operator's real gui/<uid> launchd domain is out of bounds). Healthy
# identity => ensure is a no-op (REPAIRED=0, same worker pid).
set -u
SRC=$1; LABEL=$2
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-ensure-live.XXXXXX"); T=$(cd "$T" && pwd -P)
R="$T/remote-root"; A="$T/account"; S="$T/remote-jobs"
mkdir -p "$R/bin" "$A"; cp "$SRC"/bin/*.sh "$R/bin/"; mkdir -p "$R/bin/backends"; cp "$SRC/bin/backends/herdr.sh" "$R/bin/backends/"
printf 'fixture\n' > "$R/AGENTS.md"
git -C "$R" init -q -b main; git -C "$R" -c user.email=t@e -c user.name=t add -A; git -C "$R" -c user.email=t@e -c user.name=t commit -qm fixture
cleanup() { pkill -f "$R/bin/fm-remote-job-worker.sh" 2>/dev/null; sleep 0.3; rm -rf "$T"; }
trap cleanup EXIT
echo "== [$LABEL]"
set -m
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$A" LC_ALL=C FM_ROOT_OVERRIDE="$R" FM_REMOTE_JOB_STATE_ROOT="$S" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$R/bin/fm-remote-job-worker.sh" > "$T/worker.out" 2> "$T/worker.err" &
set +m
for _ in $(seq 1 100); do [ -f "$S/worker.ready" ] && break; sleep 0.05; done
before=$(cat "$S/worker.pid")
echo "C-locale worker pid=$before"
(
  unset LC_ALL; export LANG=en_AU.UTF-8 HOME="$A" FM_REMOTE_JOB_STATE_ROOT="$S" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
  . "$R/bin/fm-remote-job-lib.sh"
  if fm_remote_job_ensure_worker "$R" "$A"; then rc=0; else rc=$?; fi
  sleep 1.5
  echo "en_AU caller ensure_worker rc=$rc REPAIRED=$FM_REMOTE_JOB_REPAIRED error='${FM_REMOTE_JOB_ERROR:-}'"
  echo "worker pid after=$(cat "$S/worker.pid")  worker processes running=$(pgrep -f "$R/bin/fm-remote-job-worker.sh" | wc -l | tr -d ' ')"
)
