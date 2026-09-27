#!/usr/bin/env bash
# Synthetic process records pin the remote worker's Linux ownership token.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-identity)
mkdir -p "$TMP_ROOT/proc/$$" "$TMP_ROOT/proc/sys/kernel/random" "$TMP_ROOT/account"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
export FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/proc"
export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/state"
BOOT_ID=97bd96b2-61ca-4873-8988-39c3bfc0662e
printf '%s\n' "$BOOT_ID" > "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id"

write_stat() { # <start ticks> [comm] [pid]
  local ticks=$1 comm=${2:-'worker ) odd'} pid=${3:-$$} i
  mkdir -p "$FM_PROC_ROOT_OVERRIDE/$pid"
  printf '%s (%s) S' "$pid" "$comm" > "$FM_PROC_ROOT_OVERRIDE/$pid/stat"
  for ((i=0; i<18; i++)); do printf ' 1' >> "$FM_PROC_ROOT_OVERRIDE/$pid/stat"; done
  printf ' %s\n' "$ticks" >> "$FM_PROC_ROOT_OVERRIDE/$pid/stat"
}

write_stat 23347095
COMMAND=$(fm_remote_job_process_command "$$") || fail "could not read fixture process command"
FIRST=$(fm_remote_job_process_start "$$") || fail "could not read synthetic Linux process start"
[ "$FIRST" = "linux-starttime=23347095 boot-id=$BOOT_ID" ] || fail "wrong Linux process token"
WALL_BEFORE='Sun Sep 27 21:51:10 2026'
WALL_AFTER='Sun Sep 27 21:51:11 2026'
[ "$WALL_BEFORE" != "$WALL_AFTER" ] || fail "synthetic wall-clock renderings did not diverge"
write_stat 23347095
[ "$(fm_remote_job_process_start "$$")" = "$FIRST" ] || fail "wall-clock rendering changed process identity"
fm_remote_job_process_identity_matches "$$" "$FIRST" "$COMMAND" || fail "stable process was rejected"
pass "fixed PID, start ticks, and boot ID keep identity across synthetic wall-clock rendering changes"

write_stat 23347096
! fm_remote_job_process_identity_matches "$$" "$FIRST" "$COMMAND" \
  || fail "reused PID with changed start ticks was accepted"
write_stat 23347095
! fm_remote_job_process_identity_matches "$$" "$FIRST" "$COMMAND different" \
  || fail "changed command was accepted"
printf '%s\n' 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' > "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id"
! fm_remote_job_process_identity_matches "$$" "$FIRST" "$COMMAND" \
  || fail "a different boot retained an old identity"
printf '%s\n' "$BOOT_ID" > "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id"
pass "PID reuse, command changes, and reboot invalidate identity"

printf '%s\n' "$$ (unterminated S 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 23347095" > "$FM_PROC_ROOT_OVERRIDE/$$/stat"
! fm_remote_job_process_start "$$" >/dev/null || fail "malformed proc stat was accepted"
write_stat invalid
! fm_remote_job_process_start "$$" >/dev/null || fail "nonnumeric start ticks were accepted"
write_stat 23347095
printf '%s\n' invalid > "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id"
! fm_remote_job_process_start "$$" >/dev/null || fail "malformed boot ID was accepted"
printf '%s\n' "$BOOT_ID" > "$FM_PROC_ROOT_OVERRIDE/sys/kernel/random/boot_id"
pass "malformed proc and boot records fail closed"

# The upgrade cases exercise the Linux pidfd signal path. Darwin keeps its
# existing refusal to signal a live process without a bound pidfd.
if [ "$(uname -s 2>/dev/null || true)" != Linux ]; then
  pass "legacy worker upgrade signal cases require Linux"
  exit 0
fi
unset FM_PROC_ROOT_OVERRIDE

fm_remote_job_prepare_state "$TMP_ROOT/account" || fail "could not prepare ownership fixture"
LOCK=$(fm_remote_job_worker_lock_path)
mkdir -p "$TMP_ROOT/root/bin"
cat > "$TMP_ROOT/root/bin/fm-remote-job-worker.sh" <<'WORKER'
#!/bin/bash
[ "${FM_TEST_OLD_WORKER:-}" = 1 ] || exit 0
while :; do sleep 0.1; done
WORKER
chmod +x "$TMP_ROOT/root/bin/fm-remote-job-worker.sh"
OLD_PID=
# This fixture tests replacement of a legacy process; its dummy replacement
# does not serve jobs or publish a ready file.
fm_remote_job_wait_for_probe() { return 0; }

start_old_worker() {
  set -m
  FM_TEST_OLD_WORKER=1 "$TMP_ROOT/root/bin/fm-remote-job-worker.sh" &
  OLD_PID=$!
  set +m
  for _ in $(seq 1 50); do
    case "$(fm_remote_job_process_command "$OLD_PID" 2>/dev/null || true)" in
      *fm-remote-job-worker.sh*) return 0 ;;
    esac
    sleep 0.1
  done
  fail "old worker fixture did not start"
}

stop_old_worker() {
  [ -n "$OLD_PID" ] || return 0
  kill -KILL -- "-$OLD_PID" 2>/dev/null || true
  wait "$OLD_PID" 2>/dev/null || true
  OLD_PID=
}
trap 'stop_old_worker; rm -rf -- "$TMP_ROOT"' EXIT

write_legacy_lock() { # <start> <command>
  rm -rf -- "$LOCK"
  mkdir "$LOCK"
  printf '%s\n' "$OLD_PID" > "$LOCK/pid"
  printf '%s\n' "$1" > "$LOCK/start"
  printf '%s\n' "$2" > "$LOCK/command"
  printf '%s\n' "$OLD_PID" > "$(fm_remote_job_worker_pid_path)"
  printf '%s\n' 'pre-upgrade-identity' > "$(fm_remote_job_worker_identity_path)"
  : > "$(fm_remote_job_worker_ready_path)"
}

assert_legacy_worker_upgraded() { # <start> <case>
  local old=$OLD_PID
  write_legacy_lock "$1" "$(fm_remote_job_process_command "$old")"
  fm_remote_job_start_linux_worker "$TMP_ROOT/root" "$TMP_ROOT/account" \
    || fail "$2 legacy worker was not replaced: ${FM_REMOTE_JOB_ERROR:-}"
  ! kill -0 "$old" 2>/dev/null || fail "$2 legacy worker survived the upgrade"
  OLD_PID=
}

start_old_worker
assert_legacy_worker_upgraded "$(LC_ALL=C ps -p "$OLD_PID" -o lstart=)" stable-lstart
pass "a stable-lstart legacy worker is stopped and replaced on upgrade"

start_old_worker
assert_legacy_worker_upgraded "$WALL_BEFORE" drifted-lstart
pass "a drifted-lstart legacy worker with its recorded command is stopped and replaced"

start_old_worker
assert_legacy_worker_upgraded 'dim. sept. 27 21:51:10 2026' non-English
pass "a non-English legacy lstart record is still recognized as the pre-upgrade worker"

start_old_worker
write_legacy_lock "$WALL_BEFORE" "/bin/bash $TMP_ROOT/elsewhere/fm-remote-job-worker.sh"
! fm_remote_job_lock_owner_matches_process "$TMP_ROOT/account" \
  || fail "a reused PID running a different command was adopted as the lock owner"
mkdir -p "$TMP_ROOT/stage"
printf '%s\n' "$OLD_PID" > "$TMP_ROOT/stage/.owner-pid"
printf '%s\n' "$WALL_BEFORE" > "$TMP_ROOT/stage/.owner-start"
! fm_remote_job_stage_owner_alive "$TMP_ROOT/stage" \
  || fail "a legacy stage owner whose PID runs another command was kept alive"
printf '%s\n' "$$" > "$TMP_ROOT/stage/.owner-pid"
printf '%s\n' "$WALL_BEFORE" > "$TMP_ROOT/stage/.owner-start"
! fm_remote_job_stage_owner_alive "$TMP_ROOT/stage" \
  || fail "a legacy stage owner reused by the test shell was kept alive"
pass "a legacy record whose PID now runs a different command is dead"

# The worker's own helpers run with its dispatch removed so they can be called.
mkdir -p "$TMP_ROOT/worker-bin"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$TMP_ROOT/worker-bin/"
sed '/^case "${1:-}" in$/,$d' "$ROOT/bin/fm-remote-job-worker.sh" > "$TMP_ROOT/worker-bin/fm-remote-job-worker.sh"
JOB="$TMP_ROOT/job"
write_legacy_execution() { # <start>
  mkdir -p "$JOB/.claim"
  printf '%s\n' "$TMP_ROOT/root" > "$JOB/root"
  printf '%s\n' "$OLD_PID" > "$JOB/.claim/owner"
  printf '%s\n' "$1" > "$JOB/.claim/owner_start"
  printf '%s\n' "$OLD_PID" > "$JOB/.claim/supervisor"
  printf '%s\n' "$1" > "$JOB/.claim/supervisor_start"
}
write_legacy_execution "$(LC_ALL=C ps -p "$OLD_PID" -o lstart=)"
(
  set +eu
  # shellcheck disable=SC2030,SC2031 # each subshell deliberately scopes its own override
  export FM_ROOT_OVERRIDE="$TMP_ROOT/root"
  # shellcheck source=/dev/null
  . "$TMP_ROOT/worker-bin/fm-remote-job-worker.sh"
  worker_claim_owner_alive "$JOB" || fail "a live legacy claim owner was treated as dead"
  worker_recorded_execution_alive "$JOB" process "$OLD_PID" \
    || fail "a live legacy supervisor was not recognized"
  worker_stop_recorded_execution "$JOB" || fail "a legacy supervisor record was not stopped"
  ! kill -0 "$OLD_PID" 2>/dev/null || fail "the legacy supervisor survived its stop"
  printf '%s\n' "$$" > "$JOB/.claim/owner"
  ! worker_claim_owner_alive "$JOB" || fail "a legacy claim owner reused by another command was kept"
) || exit 1
wait "$OLD_PID" 2>/dev/null || true
OLD_PID=
pass "proven legacy claim and supervisor records are recognized, signalled, and stopped"

start_old_worker
write_legacy_execution "$WALL_BEFORE"
(
  set +eu
  # shellcheck disable=SC2030,SC2031 # each subshell deliberately scopes its own override
  export FM_ROOT_OVERRIDE="$TMP_ROOT/root"
  # shellcheck source=/dev/null
  . "$TMP_ROOT/worker-bin/fm-remote-job-worker.sh"
  ! worker_claim_owner_alive "$JOB" || fail "an unproven legacy claim owner was kept alive"
  ! worker_recorded_execution_alive "$JOB" process "$OLD_PID" \
    || fail "an unproven legacy supervisor was treated as live"
  worker_stop_recorded_execution "$JOB" || fail "an unproven legacy supervisor record was not cleared"
  [ ! -e "$JOB/.claim/supervisor" ] || fail "an unproven legacy supervisor record was kept"
) || exit 1
kill -0 "$OLD_PID" 2>/dev/null || fail "a reused PID with a mismatched legacy start was signalled"
mkdir -p "$TMP_ROOT/stage"
printf '%s\n' "$OLD_PID" > "$TMP_ROOT/stage/.owner-pid"
printf '%s\n' "$WALL_BEFORE" > "$TMP_ROOT/stage/.owner-start"
! fm_remote_job_stage_owner_alive "$TMP_ROOT/stage" || fail "an unproven legacy stage owner was kept alive"
stop_old_worker
pass "a reused PID that fails the legacy start proof is never signalled and its records are reclaimed"
