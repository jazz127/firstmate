#!/usr/bin/env bash
# Live driver: real macOS /bin/ps, real fm-remote-job-lib.sh (base vs head).
# 1) Start a worker-like process; record its lock start the way the launchd
#    worker does (LC_ALL=C environment).  2) Re-check lock ownership from a
#    separate shell carrying an SSH-style non-C LANG with LC_ALL unset.
set -u
WT=$1; EV=$2
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-locale-drive.XXXXXX"); T=$(cd "$T" && pwd -P)
mkdir -p "$T/account"; git -C "$WT" show 903203c53e4fed350ad88b04ee1e7ebe1c604605:bin/fm-remote-job-lib.sh > "$T/base-lib.sh"
cp "$WT/bin/fm-remote-job-lib.sh" "$T/head-lib.sh"
env LC_ALL=C sleep 300 & WPID=$!
trap 'kill $WPID 2>/dev/null; rm -rf "$T"' EXIT
sleep 0.3
for variant in base head; do
  export FM_REMOTE_JOB_STATE_ROOT="$T/state-$variant"
  # Record lock as the launchd worker would (C locale).
  env LC_ALL=C bash -c '. "$1"; fm_remote_job_prepare_state "$2" || exit 1; l=$(fm_remote_job_worker_lock_path); mkdir -p "$l"; echo "$3" >"$l/pid"; fm_remote_job_process_start "$3" >"$l/start"; fm_remote_job_process_command "$3" >"$l/command"' _ "$T/$variant-lib.sh" "$T/account" "$WPID" || { echo "$variant: record failed"; continue; }
  echo "== $variant lib: recorded start (C locale) = $(cat "$T/state-$variant/worker.lock/start")"
  for loc in C en_AU.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 ja_JP.UTF-8; do
    out=$(env -u LC_ALL LANG="$loc" bash -c '. "$1"; echo "reread=$(fm_remote_job_process_start "$3")"; if fm_remote_job_lock_owner_matches_process "$2"; then echo MATCH owner=$FM_REMOTE_JOB_OWNER_PID; else echo MISMATCH; fi' _ "$T/$variant-lib.sh" "$T/account" "$WPID" 2>&1)
    printf '   %-5s LANG=%-12s ps-raw=[%s] %s\n' "$variant" "$loc" "$(env -u LC_ALL LANG=$loc /bin/ps -p $WPID -o lstart= | sed 's/ *$//')" "$(echo $out)"
  done
done
