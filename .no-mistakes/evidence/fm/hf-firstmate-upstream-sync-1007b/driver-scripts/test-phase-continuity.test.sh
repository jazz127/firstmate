#!/usr/bin/env bash
# End-to-end remote reply relay through fm-on and the process-event runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-reply)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/reply" "$CLAIMS"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
# The recorded worker pid is the serving child, not its restart supervisor, so
# stopping that pid alone leaves the supervisor to respawn - the leak
# tests/fm-remote-job-orphan-reap.test.sh pins. Stop the whole worker tree.
cleanup() {
  local worker_pid=''
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
printf '# Detailed remote answer\n\nThe build is green.\n' > "$REMOTE/data/reply/report.md"
printf '# Mentioned but never offered\n' > "$REMOTE/data/reply/prose-only.md"
: > "$REMOTE/state/parent-replies.status"
SOURCE_BEFORE="$TMP_ROOT/source-before"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_BEFORE"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
if [ -n "${FM_REMOTE_REPLY_POLL_LOG:-}" ]; then
  printf 'x\n' >> "$FM_REMOTE_REPLY_POLL_LOG"
fi
[ "${FM_REMOTE_REPLY_FAIL_READ:-}" != 1 ] || exit 255
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS="${FM_REMOTE_REPLY_WAIT_SECONDS:-10}" \
  "$@"
}

wait_for() {
  local path=$1
  for _ in $(seq 1 100); do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

reply_owner() {
  remote_env "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$SID" 'NR > 1 && $1 == id { print $3; exit }'
}

stop_reply_listener() {
  local pid _
  pid=$(sed -n '2p' "$CLAIMS/$SID.claim" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 80); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}

# Block until this generation's capture has been applied. A live listener keeps
# its claim across polls, so start is only launched when nothing owns the source.
await_reply_result() { # <result-path>
  local result=$1 handled=${1%.result}.handled _
  if [ "$(reply_owner)" != live ]; then
    remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
  fi
  for _ in $(seq 1 800); do
    [ -s "$result" ] && [ -f "$handled" ] && return 0
    sleep 0.05
  done
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# Drive the real delta-reader executable across its unchanged-file wait.
# The recording sleep appends a complete line after the initial empty snapshot,
# so the next snapshot must deliver it without consuming or modifying the log.
delta_cadence_case() {
  local label=$1 override=$2 expected=$3 dir log empty_hash
  dir="$TMP_ROOT/delta-$label"
  mkdir -p "$dir/bin" "$dir/home/state"
  log="$dir/home/state/replies.status"
  : > "$log"
  empty_hash=$(sha256_file "$log")
  cat > "$dir/bin/sleep" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$FM_DELTA_SLEEP_LOG"
printf 'cadence-delivered\n' >> "$FM_DELTA_APPEND_LOG"
exec /bin/sleep "$@"
SH
  chmod +x "$dir/bin/sleep"
  FM_HOME="$dir/home" PATH="$dir/bin:$PATH" FM_REMOTE_DELTA_POLL_SECONDS="$override" \
    FM_DELTA_SLEEP_LOG="$dir/sleeps" FM_DELTA_APPEND_LOG="$log" \
    "$BASH" "$ROOT/bin/fm-remote-delta-read.sh" state/replies.status 0 "$empty_hash" 30 \
    > "$dir/result" || fail "$label delta reader failed"
  [ "$(cat "$dir/sleeps")" = "$expected" ] || fail "$label delta reader did not wait $expected seconds"
  assert_grep 'status=delta' "$dir/result" "$label delta reader did not publish a delta"
  assert_grep 'cadence-delivered' "$dir/result" "$label delta reader lost the appended complete line"
  [ "$(cat "$log")" = cadence-delivered ] || fail "$label delta reader changed its source log"
  pass "$label delta reader waits $expected seconds then delivers a non-destructive complete-line delta"
}
ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
SID=$(remote_env "$ADAPTER" source-id ios)
out=$(remote_env "$ADAPTER" arm ios)
assert_contains "$out" "armed: $SID offset=0" "remote reply source was not armed at the empty cursor"

remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-one.out" 2>&1 &
wait_for "$CLAIMS/$SID.claim" || fail "process-event runner never claimed the remote reply source"
printf 'done [corr=0123456789abcdef] [at=1700000000]: build verified report=data/reply/report.md\n' \
  >> "$REMOTE/state/parent-replies.status"
RESULT=
for _ in $(seq 1 800); do
  RESULT=$(find "$PARENT/state/procevent-inbox" -name "$SID.1.result" -print -quit 2>/dev/null || true)
  [ -n "$RESULT" ] && [ -f "${RESULT%.result}.handled" ] && break
  sleep 0.05
done
RESULT=$(find "$PARENT/state/procevent-inbox" -name "$SID.1.result" -print -quit 2>/dev/null || true)
if [ -z "$RESULT" ]; then
  printf 'runner output:\n%s\n' "$(cat "$TMP_ROOT/start-one.out")" >&2
  fail "the remote reply delta was not durably captured"
fi
assert_grep 'done [corr=0123456789abcdef]' "$RESULT" "captured delta lost the correlated status line"
# One remote note, one announcement: the adapter declares self-announcing, so a
# fully autohandled capture publishes NO check wake - the mirrored status bytes
# are the single announcement, observed here through the same signature-vs-seen
# gate the watcher's signal scan and the drain's annotation check consume.
if [ -e "$PARENT/state/.wake-queue" ] && grep -q "procevent remote-reply $SID 1" "$PARENT/state/.wake-queue"; then
  fail "an autohandled remote-reply capture still published a duplicate check wake"
fi
FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_signal_seen_current "$2/state" "$2/state/ios.status"
' _ "$ROOT" "$PARENT" && fail "the mirrored reply bytes are not visible to the watcher signal scan"
cmp -s "$SOURCE_BEFORE" "$REMOTE/state/parent-replies.status" \
  && fail "fixture did not append the expected source line"
SOURCE_AFTER="$TMP_ROOT/source-after"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_AFTER"
pass "a blocking non-destructive remote delta reaches durable process-event capture"


. "$ROOT/bin/fm-classify-lib.sh"
GEN=1
# The adapter re-armed at the committed cursor. Truncation is detected from the
# next blocking source and escalated once; it is never silently treated as a new
# log or re-armed past the break.
stop_reply_listener || fail "the reply listener did not stop before the continuity break"
printf 'failed [corr=fedcba9876543210]: source was replaced\n' > "$REMOTE/state/parent-replies.status"
GEN=$((GEN + 1))
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-two.out" 2>&1 &
RUNNER=$!
wait "$RUNNER" || fail "continuity break was not captured as a structured result"
RESULT_TWELVE=$(find "$PARENT/state/procevent-inbox" -name "$SID.$GEN.result" -print -quit)
[ -n "$RESULT_TWELVE" ] || fail "continuity break produced no durable result"
[ "$(remote_env "$ADAPTER" classify "$RESULT_TWELVE")" = continuity-broken ] \
  || fail "truncated source was not classified as a continuity break"
set +e
remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_TWELVE" > "$TMP_ROOT/handle-nine.out" 2>&1
handle_rc=$?
set -e
[ "$handle_rc" -eq 3 ] || fail "continuity handling returned an unexpected status: $handle_rc"
assert_grep 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status" "continuity break did not escalate"
assert_absent "$PARENT/state/procevent/$SID.source" "continuity break was re-armed without an operator rebase"
remote_env "$ADAPTER" ingest ios "$RESULT_TWELVE" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "continuity replay duplicated the escalation"
first_offset=$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/ios.cursor")
first_hash=$(sed -n 's/^prefix_sha256=//p' "$PARENT/state/remote-replies/ios.cursor" | tr 'A-F' 'a-f')
first_prefix=$(printf '%.12s' "$first_hash")
assert_grep "at offset ${first_offset} prefix ${first_prefix} retirements 0" "$PARENT/state/ios.status" \
  "continuity break did not record the reader position"
assert_no_grep "prefix ${first_hash}" "$PARENT/state/ios.status" \
  "continuity break recorded the full prefix hash"
assert_absent "$PARENT/state/remote-replies/ios.retirements" \
  "a route that has never been retired gained a retirement count"
status_line_at_epoch "$(grep -F 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" >/dev/null \
  || fail "new continuity escalation has unknown emission time"
if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
  printf '\nNew continuity escalation after ingest retry:\n'
  grep -F 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status"
fi
pass "truncation is detected, escalated once, and not silently rebased"

# The break does not advance the cursor, so a later read of the unchanged
# remote log reports the same break. An operator resolve in between must not
# make that repeat look like a new break.
printf '%s\n' 'resolved [key=remote-reply-continuity-ios]: operator accepted the break' \
  >> "$PARENT/state/ios.status"
[ -z "$(status_open_decisions "$PARENT/state/ios.status")" ] \
  || fail "operator resolve left the continuity decision open"
rm -f "$PARENT/state/procevent-inbox/$SID.$GEN.handled"
set +e
remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_TWELVE" > "$TMP_ROOT/handle-resolved.out" 2>&1
handle_rc=$?
set -e
[ "$handle_rc" -eq 3 ] || fail "repeated continuity handling returned an unexpected status: $handle_rc"
remote_env "$ADAPTER" ingest ios "$RESULT_TWELVE" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "a repeated continuity break appended again after the operator resolve"
[ -z "$(status_open_decisions "$PARENT/state/ios.status")" ] \
  || fail "a repeated continuity break reopened the decision the operator resolved"
pass "a repeated continuity break after an operator resolve appends nothing"

rm -f "$PARENT/state/procevent-inbox/$SID.$GEN.handled"
if remote_env "$ADAPTER" retire ios > "$TMP_ROOT/retire-pending.out" 2>&1; then
  fail "remote reply retirement accepted an unhandled captured result"
fi
assert_grep 'unhandled captured result' "$TMP_ROOT/retire-pending.out" \
  "remote reply retirement did not explain its pending-result refusal"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "refused retirement left the reply source running past its pending-result check"
remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_TWELVE" >/dev/null 2>&1 || [ "$?" -eq 3 ] \
  || fail "pending continuity result could not be acknowledged after retirement refusal"
remote_env "$ADAPTER" retire ios >/dev/null
assert_absent "$PARENT/state/remote-replies/ios.cursor" "adapter retirement left its cursor"
recorded_retirements=$(cat "$PARENT/state/remote-replies/ios.retirements" 2>/dev/null || true)
[ "$recorded_retirements" = count=1 ] \
  || fail "adapter retirement did not record its count (got: ${recorded_retirements:-absent})"
assert_absent "$PARENT/state/remote-replies/ios.caught-up" \
  "adapter retirement left a caught-up watermark a later route could inherit"
pass "remote reply retirement quiesces and refuses unhandled captured results"

# Empty the remote log under the committed cursor and handle the break the
# next blocking source reports. Sets RESULT_BREAK.
break_repaired_route() { # <label> [expected-handle-status]
  local label=$1 expected=${2:-3} runner handle_rc
  stop_reply_listener || fail "the reply listener did not stop before the $label continuity break"
  : > "$REMOTE/state/parent-replies.status"
  GEN=$((GEN + 1))
  remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-$label-break.out" 2>&1 &
  runner=$!
  wait "$runner" || fail "the $label continuity break was not captured"
  RESULT_BREAK=$(find "$PARENT/state/procevent-inbox" -name "$SID.$GEN.result" -print -quit)
  [ -n "$RESULT_BREAK" ] || fail "the $label continuity break produced no durable result"
  [ "$(remote_env "$ADAPTER" classify "$RESULT_BREAK")" = continuity-broken ] \
    || fail "the $label truncation was not classified as a continuity break"
  set +e
  remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_BREAK" > "$TMP_ROOT/handle-$label-break.out" 2>&1
  handle_rc=$?
  set -e
  [ "$handle_rc" -eq "$expected" ] || fail "the $label continuity break returned an unexpected status: $handle_rc"
}

# Close the open continuity decision, put back the log the cursor was committed
# against with one more line, and let the reader advance over that line. The
# route is not retired, so the cursor moves only because new bytes were read.
resolve_and_extend_route() { # <label> <log-content>
  local label=$1 content=$2 bytes blocked_before
  blocked_before=$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")
  printf '%s\n' 'resolved [key=remote-reply-continuity-ios]: operator accepted the break' \
    >> "$PARENT/state/ios.status"
  printf '%s' "$content" > "$REMOTE/state/parent-replies.status"
  bytes=$(wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
  remote_env "$ADAPTER" arm ios >/dev/null
  GEN=$((GEN + 1))
  await_reply_result "$PARENT/state/procevent-inbox/$SID.$GEN.result" \
    || fail "the route extended after the $label break was not read"
  assert_grep "offset=$bytes" "$PARENT/state/remote-replies/ios.cursor" \
    "the route extended after the $label break did not advance the cursor"
  [ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq "$blocked_before" ] \
    || fail "extending the route after the $label break appended a continuity break"
  [ -z "$(status_open_decisions "$PARENT/state/ios.status")" ] \
    || fail "extending the route after the $label break reopened the continuity decision"
}

# The resolved break above stays closed through an unchanged re-read. Repair
# the log, let the reader advance, and truncate again. The later break is at
# another reader position, so its line is new and the decision opens again.
printf 'working: route restored and readable again\n' > "$REMOTE/state/parent-replies.status"
restored_bytes=$(wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
remote_env "$ADAPTER" arm ios >/dev/null
GEN=$((GEN + 1))
await_reply_result "$PARENT/state/procevent-inbox/$SID.$GEN.result" \
  || fail "the repaired route was not read"
assert_grep "offset=$restored_bytes" "$PARENT/state/remote-replies/ios.cursor" \
  "the repaired route did not advance the cursor"
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "repairing the route appended a continuity break"
[ -z "$(status_open_decisions "$PARENT/state/ios.status")" ] \
  || fail "repairing the route reopened the continuity decision"
break_repaired_route "second" 3
RESULT_SECOND=$RESULT_BREAK
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 2 ] \
  || fail "a later continuity break after repair appended nothing"
second_offset=$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/ios.cursor")
second_hash=$(sed -n 's/^prefix_sha256=//p' "$PARENT/state/remote-replies/ios.cursor" | tr 'A-F' 'a-f')
second_prefix=$(printf '%.12s' "$second_hash")
assert_grep "at offset ${second_offset} prefix ${second_prefix} retirements 1" "$PARENT/state/ios.status" \
  "a later continuity break after repair did not record its reader position"
assert_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  $'remote-reply-continuity-ios\t' \
  "a later continuity break after repair did not reopen the decision"
remote_env "$ADAPTER" ingest ios "$RESULT_SECOND" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 2 ] \
  || fail "a repeated read of the later continuity break appended again"
assert_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  $'remote-reply-continuity-ios\t' \
  "a repeated read of the later continuity break closed the decision"
pass "a later continuity break after repair and re-advance opens the decision again"

# A line from before the reader position was recorded names the route and the
# reason only. It does not match the new line, so this same break appends once.
awk '
  /blocked \[key=remote-reply-continuity-ios\]/ {
    sub(/ at offset [0-9]+ prefix [0-9a-f]+( retirements [0-9]+)?$/, "")
  }
  { print }
' "$PARENT/state/ios.status" > "$TMP_ROOT/ios-status-old-format"
mv "$TMP_ROOT/ios-status-old-format" "$PARENT/state/ios.status"
printf '%s\n' 'resolved [key=remote-reply-continuity-ios]: operator accepted the break' \
  >> "$PARENT/state/ios.status"
[ -z "$(status_open_decisions "$PARENT/state/ios.status")" ] \
  || fail "operator resolve left the old-format continuity decision open"
set +e
remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_SECOND" > "$TMP_ROOT/handle-old-format.out" 2>&1
handle_rc=$?
set -e
[ "$handle_rc" -eq 3 ] || fail "a continuity break after an old-format line returned an unexpected status: $handle_rc"
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 3 ] \
  || fail "a continuity break after an old-format line appended nothing"
assert_grep "at offset ${second_offset} prefix ${second_prefix} retirements 1" "$PARENT/state/ios.status" \
  "a continuity break after an old-format line did not record the reader position"
assert_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  $'remote-reply-continuity-ios\t' \
  "a continuity break after an old-format line did not reopen the decision"
remote_env "$ADAPTER" ingest ios "$RESULT_SECOND" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 3 ] \
  || fail "a repeated read after the old-format upgrade appended again"
assert_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  $'remote-reply-continuity-ios\t' \
  "a repeated read after the old-format upgrade closed the decision"
pass "an old-format continuity line does not swallow the next break"

# No retirement this time. The cursor leaves the escalated offset only because
# the reader consumed new bytes, and that alone makes the next break new.
LOG_RESTORED=$'working: route restored and readable again\n'
LOG_EXTENDED=$LOG_RESTORED$'working: route extended without retirement\n'
resolve_and_extend_route "second" "$LOG_EXTENDED"
break_repaired_route "third" 3
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 4 ] \
  || fail "a later continuity break after the cursor moved without retirement appended nothing"
moved_offset=$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/ios.cursor")
moved_hash=$(sed -n 's/^prefix_sha256=//p' "$PARENT/state/remote-replies/ios.cursor" | tr 'A-F' 'a-f')
moved_prefix=$(printf '%.12s' "$moved_hash")
assert_grep "at offset ${moved_offset} prefix ${moved_prefix} retirements 1" "$PARENT/state/ios.status" \
  "a later continuity break after the cursor moved did not record its reader position"
assert_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  $'remote-reply-continuity-ios\t' \
  "a later continuity break after the cursor moved without retirement did not reopen the decision"
pass "a later continuity break after the cursor moves without retirement opens the decision again"

# Retire, put the same bytes back, and break at the same offset. The retirement
# count makes that line new, so the decision opens once. The repeat stays silent.
printf '%s\n' 'resolved [key=remote-reply-continuity-ios]: operator accepted the break' \
  >> "$PARENT/state/ios.status"
[ -z "$(status_open_decisions "$PARENT/state/ios.status")" ] \
  || fail "operator resolve left the extended continuity decision open"
remote_env "$ADAPTER" retire ios >/dev/null
recorded_retirements=$(cat "$PARENT/state/remote-replies/ios.retirements" 2>/dev/null || true)
[ "$recorded_retirements" = count=2 ] \
  || fail "the second retirement did not advance the count (got: ${recorded_retirements:-absent})"
printf '%s' "$LOG_EXTENDED" > "$REMOTE/state/parent-replies.status"
remote_env "$ADAPTER" arm ios >/dev/null
GEN=$((GEN + 1))
await_reply_result "$PARENT/state/procevent-inbox/$SID.$GEN.result" \
  || fail "the restored route was not read"
assert_grep "offset=${moved_offset}" "$PARENT/state/remote-replies/ios.cursor" \
  "restoring the same bytes did not reach the same offset"
restored_hash=$(sed -n 's/^prefix_sha256=//p' "$PARENT/state/remote-replies/ios.cursor" | tr 'A-F' 'a-f')
[ "$restored_hash" = "$moved_hash" ] || fail "restoring the same bytes changed the prefix hash"
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 4 ] \
  || fail "restoring the same bytes appended a continuity break"
[ -z "$(status_open_decisions "$PARENT/state/ios.status")" ] \
  || fail "restoring the same bytes reopened the continuity decision"
break_repaired_route "retired-same" 3
RESULT_RETIRED=$RESULT_BREAK
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 5 ] \
  || fail "a continuity break after an identical restore appended nothing"
assert_grep "at offset ${moved_offset} prefix ${moved_prefix} retirements 2" "$PARENT/state/ios.status" \
  "a continuity break after an identical restore did not record the new retirement count"
assert_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  $'remote-reply-continuity-ios\t' \
  "a continuity break after an identical restore did not reopen the decision"
remote_env "$ADAPTER" ingest ios "$RESULT_RETIRED" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 5 ] \
  || fail "a repeated read of the break after an identical restore appended again"
assert_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  $'remote-reply-continuity-ios\t' \
  "a repeated read of the break after an identical restore closed the decision"
pass "a continuity break after retirement and an identical restore opens the decision once"


cp "$PARENT/state/ios.status" "$FM_CONTINUITY_EVIDENCE/status.txt"
cp "$PARENT/state/remote-replies/ios.cursor" "$FM_CONTINUITY_EVIDENCE/cursor.txt"
cp "$PARENT/state/remote-replies/ios.retirements" "$FM_CONTINUITY_EVIDENCE/retirements.txt"
printf 'Final open decisions from the public classifier:\n'
status_open_decisions "$PARENT/state/ios.status"
