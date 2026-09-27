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

write_stat() { # <start ticks> [comm]
  local ticks=$1 comm=${2:-'worker ) odd'} i
  printf '%s (%s) S' "$$" "$comm" > "$FM_PROC_ROOT_OVERRIDE/$$/stat"
  for ((i=0; i<18; i++)); do printf ' 1' >> "$FM_PROC_ROOT_OVERRIDE/$$/stat"; done
  printf ' %s\n' "$ticks" >> "$FM_PROC_ROOT_OVERRIDE/$$/stat"
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

fm_remote_job_prepare_state "$TMP_ROOT/account" || fail "could not prepare ownership fixture"
LOCK=$(fm_remote_job_worker_lock_path)
mkdir "$LOCK"
printf '%s\n' "$$" > "$LOCK/pid"
printf '%s\n' "$WALL_BEFORE" > "$LOCK/start"
printf '%s\n' "$COMMAND" > "$LOCK/command"
! fm_remote_job_lock_owner_matches_process "$TMP_ROOT/account" \
  || fail "old wall-clock record was accepted as stable identity"
fm_remote_job_lock_owner_uncertain_alive "$TMP_ROOT/account" \
  || fail "live old-format lock was not protected"
mkdir -p "$TMP_ROOT/root/bin" "$TMP_ROOT/stage"
printf '#!/bin/bash\n' > "$TMP_ROOT/root/bin/fm-remote-job-worker.sh"
chmod +x "$TMP_ROOT/root/bin/fm-remote-job-worker.sh"
! fm_remote_job_start_linux_worker "$TMP_ROOT/root" "$TMP_ROOT/account" \
  || fail "a live old-format worker was replaced without verified ownership"
[ -f "$LOCK/pid" ] || fail "the old-format lock was deleted"
printf '%s\n' "$$" > "$TMP_ROOT/stage/.owner-pid"
printf '%s\n' "$WALL_BEFORE" > "$TMP_ROOT/stage/.owner-start"
fm_remote_job_stage_owner_alive "$TMP_ROOT/stage" \
  || fail "a live old-format stage was treated as abandoned"
printf '%s\n' "$COMMAND different" > "$LOCK/command"
! fm_remote_job_lock_owner_uncertain_alive "$TMP_ROOT/account" \
  || fail "a different command retained old-format lock protection"
pass "live old-format lock and stage records are protected without adoption or signalling"
