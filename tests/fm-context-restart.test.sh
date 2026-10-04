#!/usr/bin/env bash
# Behavior coverage for Claude turn-boundary context detection, durable crossing
# deduplication, reset-safe handoff, and the automatic primary relaunch wrapper.
# shellcheck disable=SC2016 # Single-quoted fake-harness bodies expand inside their child shells.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-restart)
HOOK="$ROOT/bin/fm-context-restart-claude-hook.sh"
HANDOFF="$ROOT/bin/fm-context-restart.sh"
WRAPPER="$ROOT/bin/fm-primary.sh"
LIB="$ROOT/bin/fm-context-restart-lib.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE HOOK HANDOFF WRAPPER LIB

make_primary() {
  local dir=$1 budget=${2:-100}
  mkdir -p "$dir/state" "$dir/config" "$dir/bin"
  git init -q "$dir"
  git -C "$dir" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  printf '%s\n' "$budget" > "$dir/config/context-restart-budget"
}

write_transcript() {  # <path> <input> <created> <read> <output>
  cat > "$1" <<JSON
{"type":"user","message":{"role":"user","content":"fixture"}}
{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":$2,"cache_creation_input_tokens":$3,"cache_read_input_tokens":$4,"output_tokens":$5}}}
{"type":"last-prompt","sessionId":"fixture"}
JSON
}

run_hook() {  # <home> <session> <transcript>
  local home=$1 session=$2 transcript=$3 rc=0
  printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}\n' \
    "$session" "$transcript" \
    | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$HOOK"
      ' 2>&1 || rc=$?
  return "$rc"
}

record_phase() {
  FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1"
    fm_context_restart_record_read "$2" >/dev/null || exit 1
    printf "%s\n" "$FM_CONTEXT_RESTART_RECORD_PHASE"
  ' _ "$LIB" "$1/state/.context-restart-crossing"
}

test_budget_parser_and_opt_in() {
  local config outside out rc
  config="$TMP_ROOT/config-parser"
  mkdir -p "$config"
  rc=0
  out=$(FM_HOME="$TMP_ROOT" FM_CONFIG_OVERRIDE="$config" "$HANDOFF" read-budget 2>&1) || rc=$?
  expect_code 1 "$rc" "an absent budget must remain opt-out"
  [ ! -e "$config/context-restart-budget" ] || fail "reading an absent budget enabled refresh"
  printf '400000\n' > "$config/context-restart-budget"
  out=$(FM_HOME="$TMP_ROOT" FM_CONFIG_OVERRIDE="$config" "$HANDOFF" read-budget) || fail "valid opt-in budget rejected"
  [ "$out" = 400000 ] || fail "opt-in budget value changed"

  printf '0042\n' > "$config/context-restart-budget"
  rc=0
  out=$(FM_HOME="$TMP_ROOT" FM_CONFIG_OVERRIDE="$config" "$HANDOFF" read-budget 2>&1) || rc=$?
  expect_code 1 "$rc" "a leading-zero context budget must be rejected"
  assert_contains "$out" 'value must be one positive decimal integer' \
    "malformed context budget did not report its exact format error"

  outside="$TMP_ROOT/outside-budget"
  printf '50\n' > "$outside"
  rm -f "$config/context-restart-budget"
  ln -s "$outside" "$config/context-restart-budget"
  rc=0
  out=$(FM_HOME="$TMP_ROOT" FM_CONFIG_OVERRIDE="$config" "$HANDOFF" read-budget 2>&1) || rc=$?
  expect_code 1 "$rc" "a symlinked context budget must be rejected"
  assert_contains "$out" 'file is symlinked' "symlink rejection was not specific"
  [ "$(cat "$outside")" = 50 ] || fail "symlink rejection changed the external target"
  pass "context restart: absent opt-out and exact safe budget validation"
}

test_threshold_and_one_directive_per_crossing() {
  local home transcript out rc
  home="$TMP_ROOT/threshold"
  transcript="$home/transcript.jsonl"
  make_primary "$home" 100

  write_transcript "$transcript" 20 20 20 20
  rc=0
  out=$(run_hook "$home" threshold-session "$transcript" 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "under-threshold Stop should remain inert"
  [ -z "$out" ] || fail "under-threshold Stop emitted output: $out"
  [ ! -e "$home/state/.context-restart-crossing" ] || fail "under-threshold Stop published a crossing"

  write_transcript "$transcript" 30 30 30 10
  rc=0
  out=$(run_hook "$home" threshold-session "$transcript" 2>/dev/null) || rc=$?
  expect_code 2 "$rc" "the first threshold crossing must force one Claude continuation"
  assert_contains "$out" $'\xE2\x81\xA3FIRSTMATE_OP: v1 context-refresh:' \
    "threshold crossing did not emit a typed context-refresh directive"
  assert_contains "$out" 'invoke /stow' "threshold directive did not require the stow handoff"
  [ "$(record_phase "$home")" = detected ] || fail "threshold crossing was not durably detected"

  rc=0
  out=$(run_hook "$home" threshold-session "$transcript" 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "a repeated above-threshold Stop must not nag"
  [ -z "$out" ] || fail "a repeated above-threshold Stop duplicated the directive: $out"

  write_transcript "$transcript" 20 20 20 20
  rc=0
  out=$(run_hook "$home" threshold-session "$transcript" 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "dropping below threshold should rearm silently"
  [ -z "$out" ] || fail "below-threshold rearm emitted output: $out"
  [ ! -e "$home/state/.context-restart-crossing" ] || fail "below-threshold rearm retained the detected crossing"

  write_transcript "$transcript" 40 30 20 10
  rc=0
  out=$(run_hook "$home" threshold-session "$transcript" 2>/dev/null) || rc=$?
  expect_code 2 "$rc" "a later genuine crossing should emit one new directive"
  [ "$(printf '%s\n' "$out" | grep -c 'FIRSTMATE_OP: v1 context-refresh:')" -eq 1 ] \
    || fail "the later crossing did not emit exactly one directive: $out"
  pass "context restart: turn-boundary threshold emits exactly one directive per crossing"
}

test_malformed_transcript_and_usage_are_inert() {
  local home transcript out rc case_name
  for case_name in malformed-json missing-assistant bad-usage negative-usage; do
    home="$TMP_ROOT/$case_name"
    transcript="$home/transcript.jsonl"
    make_primary "$home" 10
    case "$case_name" in
      malformed-json)
        printf '%s\n' '{not json' > "$transcript"
        ;;
      missing-assistant)
        printf '%s\n' '{"type":"user","message":{"role":"user"}}' > "$transcript"
        ;;
      bad-usage)
        printf '%s\n' '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":"100","output_tokens":1}}}' > "$transcript"
        ;;
      negative-usage)
        printf '%s\n' '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":100,"cache_read_input_tokens":-1,"output_tokens":1}}}' > "$transcript"
        ;;
    esac
    rc=0
    out=$(run_hook "$home" malformed-session "$transcript" 2>/dev/null) || rc=$?
    expect_code 0 "$rc" "$case_name must not trigger a context handoff"
    [ -z "$out" ] || fail "$case_name emitted a directive or diagnostic: $out"
    [ ! -e "$home/state/.context-restart-crossing" ] || fail "$case_name published a crossing"
  done
  pass "context restart: malformed transcript and latest-usage inputs cannot trigger a handoff"
}

test_concurrent_stop_firings_publish_one_directive() {
  local home transcript rc1 rc2 directives
  home="$TMP_ROOT/concurrent"
  transcript="$home/transcript.jsonl"
  make_primary "$home" 10
  write_transcript "$transcript" 10 10 10 10
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" TRANSCRIPT="$transcript" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      payload=$(printf "{\"session_id\":\"concurrent-session\",\"transcript_path\":\"%s\"}\n" "$TRANSCRIPT")
      printf "%s" "$payload" | "$HOOK" > "$FM_HOME/state/out1" 2>&1 & p1=$!
      printf "%s" "$payload" | "$HOOK" > "$FM_HOME/state/out2" 2>&1 & p2=$!
      wait "$p1"; printf "%s\n" "$?" > "$FM_HOME/state/rc1"
      wait "$p2"; printf "%s\n" "$?" > "$FM_HOME/state/rc2"
    '
  rc1=$(cat "$home/state/rc1")
  rc2=$(cat "$home/state/rc2")
  { [ "$rc1" = 2 ] && [ "$rc2" = 0 ]; } || { [ "$rc1" = 0 ] && [ "$rc2" = 2 ]; } \
    || fail "concurrent Stop hooks must return one directive and one no-op, got $rc1/$rc2"
  directives=$(grep -h -c 'FIRSTMATE_OP: v1 context-refresh:' "$home/state/out1" "$home/state/out2" | awk '{n += $1} END {print n + 0}')
  [ "$directives" -eq 1 ] || fail "concurrent Stop hooks emitted $directives directives"
  [ "$(record_phase "$home")" = detected ] || fail "concurrent crossing did not retain one durable record"
  pass "context restart: concurrent Stop firings admit exactly one crossing directive"
}

test_reset_safe_wrapper_restarts_fresh_and_releases_lock() {
  local home fake count successor_record successor_body
  home="$TMP_ROOT/wrapper-home"
  fake="$TMP_ROOT/wrapper-fakebin"
  make_primary "$home" 10
  mkdir -p "$fake"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_context_restart_record_publish "$2" wrapper-session 40 10 1700000000 detected
  ' _ "$LIB" "$home/state" || fail "could not seed the wrapper crossing"

  cat > "$fake/claude" <<'SH'
#!/usr/bin/env bash
exec -a claude /bin/bash -c '
  count=$(cat "$FM_HOME/state/launch-count" 2>/dev/null || echo 0)
  count=$((count + 1))
  printf "%s\n" "$count" > "$FM_HOME/state/launch-count"
  printf "%s\n" "$*" > "$FM_HOME/state/args-$count"
  if [ "$count" -eq 1 ]; then
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$HANDOFF" handoff --session wrapper-session --reset-safe
    sleep 5
  else
    [ ! -e "$FM_HOME/state/.lock" ] || exit 91
  fi
' claude "$@"
SH
  chmod +x "$fake/claude"

  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_CLAUDE_BIN="$fake/claude" \
    "$WRAPPER" --firstmate-initial-prompt INITIAL_BRIEF -- --effort low \
    > "$home/wrapper.out" 2> "$home/wrapper.err" \
    || fail "reset-safe wrapper did not complete its fresh successor: $(cat "$home/wrapper.err")"
  count=$(cat "$home/state/launch-count")
  [ "$count" = 2 ] || fail "wrapper launched $count Claude generations instead of exactly two"
  assert_contains "$(cat "$home/state/args-1")" 'INITIAL_BRIEF' \
    "first wrapper generation did not receive its initial prompt"
  assert_not_contains "$(cat "$home/state/args-2")" 'INITIAL_BRIEF' \
    "successor replayed the old initial prompt"
  assert_contains "$(cat "$home/state/args-2")" '--effort low' \
    "successor did not retain Claude options"
  successor_record=$(sed -n "s/^.*operational input waiting: read '\(.*\)' and handle.*$/\1/p" "$home/state/args-2")
  # Resolve the operational carrier through its public parser (Claude strips U+2063).
  successor_body=$(FM_HOME="$home" "$ROOT/bin/fm-operational-input.sh" open "$successor_record") \
    || fail "successor did not receive a readable record-backed resume turn"

  assert_contains "$successor_body" 'native SessionStart hook has already run the full digest' \
    "successor resume turn did not make the durable digest authoritative"
  assert_contains "$(cat "$home/wrapper.err")" 'starting a fresh Claude session' \
    "wrapper did not report the intentional fresh-session transition"
  [ ! -e "$home/state/.context-restart-crossing" ] || fail "wrapper retained the completed crossing sentinel"
  [ ! -e "$home/state/.lock" ] || fail "wrapper did not release the exited session's exact lock before successor launch"
  pass "context restart: reset-safe sentinel releases the old lock and starts one fresh successor"
}

test_wrapper_waits_for_publication_and_revalidates_ownership() {
  local home fake scenario rc expected count
  for scenario in contention generation record-owner session-owner; do
    home="$TMP_ROOT/publication-$scenario"
    make_primary "$home" 10
    fake="$home/fake-claude"
    cat > "$fake" <<'SCRIPT'
#!/usr/bin/env bash
exec -a claude /bin/bash -c '
  . "$LIB"
  . "$FM_REPO/bin/fm-wake-lib.sh"
  n=$(cat "$FM_HOME/generations" 2>/dev/null || echo 0)
  n=$((n + 1)); printf "%s\n" "$n" > "$FM_HOME/generations"
  if [ "$n" -eq 2 ]; then
    [ ! -e "$STATE/.lock" ] || exit 91
    [ ! -e "$STATE/.context-restart-crossing" ] || exit 92
    exit 0
  fi
  printf "%s\n" "$$" > "$STATE/.lock"
  fm_lock_try_acquire "$STATE/.context-restart.lock" || exit 81
  trap '\''fm_lock_release "$STATE/.context-restart.lock"'\'' EXIT
  fm_context_restart_record_publish "$STATE" publication-session 40 10 1700000000 \
    ready automatic "$FM_CONTEXT_RESTART_WRAPPER_TOKEN" "$$" || exit 82
  sleep 1
  [ "$(cat "$STATE/.context-restart.lock/pid")" = "$$" ] || exit 83
  fm_context_restart_record_read "$STATE/.context-restart-crossing" || exit 84
  [ "$FM_CONTEXT_RESTART_RECORD_PHASE" = ready ] || exit 85
  fm_pid_alive "$FM_CONTEXT_RESTART_BRIDGE_PID" || exit 86
  : > "$FM_HOME/foreign-lock-preserved"
  token=$FM_CONTEXT_RESTART_WRAPPER_TOKEN
  owner=$$
  case "$SCENARIO" in
    generation) token=aaaaaaaaaaaaaaaa ;;
    record-owner) owner=$FM_CONTEXT_RESTART_BRIDGE_PID ;;
    session-owner) printf "22222222\n" > "$STATE/.lock" ;;
  esac
  if [ "$SCENARIO" != contention ]; then
    fm_context_restart_record_publish "$STATE" publication-session 40 10 1700000000 \
      ready automatic "$token" "$owner" || exit 87
  fi
  fm_lock_release "$STATE/.context-restart.lock"
  trap - EXIT
  trap '\''exit 0'\'' TERM
  i=0
  while [ "$i" -lt 200 ]; do
    if [ "$SCENARIO" != contention ] && ! fm_pid_alive "$FM_CONTEXT_RESTART_BRIDGE_PID"; then
      exit 17
    fi
    sleep 0.1
    i=$((i + 1))
  done
  exit 88
' claude "$@"
SCRIPT
    chmod +x "$fake"
    rc=0
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_CLAUDE_BIN="$fake" FM_REPO="$ROOT" \
      SCENARIO="$scenario" "$WRAPPER" > "$home/wrapper.out" 2> "$home/wrapper.err" || rc=$?
    expected=17
    count=1
    if [ "$scenario" = contention ]; then expected=0; count=2; fi
    expect_code "$expected" "$rc" "$scenario publication handoff failed: $(cat "$home/wrapper.err")"
    [ -f "$home/foreign-lock-preserved" ] || fail "$scenario bridge released another process publication lock"
    [ "$(cat "$home/generations")" = "$count" ] || fail "$scenario launched an unexpected successor"
    [ ! -e "$home/state/.context-restart.lock" ] || fail "$scenario retained the released publication lock"
    if [ "$scenario" != contention ]; then
      [ "$(record_phase "$home")" = ready ] || fail "$scenario committed a stale replacement"
      [ -f "$home/state/.lock" ] || fail "$scenario released the session lock"
    fi
    if [ "$scenario" = session-owner ]; then
      [ "$(cat "$home/state/.lock")" = 22222222 ] || fail "bridge removed a foreign session lock"
    fi
    pass "context restart: $scenario publication wait preserves locks and revalidates replacement"
  done
}

test_handoff_waits_for_replacement_commit() {
  local home fake rc scenario expected count i
  for scenario in contention bridge-exit; do
    home="$TMP_ROOT/handoff-completion-$scenario"
    make_primary "$home" 10
    FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_context_restart_record_publish "$2" completion-session 40 10 1700000000 detected
  ' _ "$LIB" "$home/state" || fail "could not seed the completion crossing"
    fake="$home/fake-claude"
    cat > "$fake" <<'SCRIPT'
#!/usr/bin/env bash
exec -a claude /bin/bash -c '
  . "$LIB"
  . "$FM_REPO/bin/fm-wake-lib.sh"
  n=$(cat "$FM_HOME/generations" 2>/dev/null || echo 0)
  n=$((n + 1)); printf "%s\n" "$n" > "$FM_HOME/generations"
  if [ "$n" -eq 2 ]; then
    [ ! -e "$STATE/.lock" ] || exit 91
    [ ! -e "$STATE/.context-restart-crossing" ] || exit 92
    exit 0
  fi
  printf "%s\n" "$$" > "$STATE/.lock"
  kill -STOP "$FM_CONTEXT_RESTART_BRIDGE_PID" || exit 81
  (
    trap '\''kill -CONT "$FM_CONTEXT_RESTART_BRIDGE_PID" 2>/dev/null || true'\'' EXIT
    i=0
    until fm_context_restart_record_read "$STATE/.context-restart-crossing" \
      && [ "$FM_CONTEXT_RESTART_RECORD_PHASE" = ready ] \
      && fm_lock_try_acquire "$STATE/.context-restart.lock"; do
      i=$((i + 1)); [ "$i" -lt 100 ] || exit 82; sleep 0.1
    done
    kill -CONT "$FM_CONTEXT_RESTART_BRIDGE_PID" || exit 83
    sleep 1
    # The public handoff must keep its caller pending until the bridge can
    # commit replacement, even when publication contention delays it.
    if [ -e "$FM_HOME/handoff-returned" ]; then
      : > "$FM_HOME/returned-before-commit"
    fi
    fm_current_pid owner
    [ "$(cat "$STATE/.context-restart.lock/pid")" = "$owner" ] || exit 84
    : > "$FM_HOME/foreign-lock-preserved"
    if [ "$SCENARIO" = bridge-exit ]; then
      kill -TERM "$FM_CONTEXT_RESTART_BRIDGE_PID" || exit 85
    fi
    fm_lock_release "$STATE/.context-restart.lock"
    : > "$FM_HOME/contender-finished"
  ) &
  "$HANDOFF" handoff --session completion-session --reset-safe > "$FM_HOME/handoff.out" 2>&1
  rc=$?
  : > "$FM_HOME/handoff-returned"
  exit "$rc"
' claude "$@"
SCRIPT
    chmod +x "$fake"
    rc=0
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_CLAUDE_BIN="$fake" FM_REPO="$ROOT" \
      SCENARIO="$scenario" "$WRAPPER" > "$home/wrapper.out" 2> "$home/wrapper.err" || rc=$?
    # The contender outlives an early child exit in the broken implementation.
    i=0
    while [ ! -e "$home/contender-finished" ] && [ "$i" -lt 100 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    [ -f "$home/contender-finished" ] || fail "completion contender did not finish"
    [ ! -e "$home/returned-before-commit" ] || fail "handoff returned success before replacement committed"
    expected=0
    count=2
    if [ "$scenario" = bridge-exit ]; then
      expected=1
      count=1
      [ "$(record_phase "$home")" = ready ] || fail "failed transfer committed replacement"
      [ -f "$home/state/.lock" ] || fail "failed transfer released the session lock"
      assert_contains "$(cat "$home/handoff.out")" 'supervision transfer did not commit' \
        "handoff did not report failed transfer"
    fi
    expect_code "$expected" "$rc" "$scenario completion handoff failed: $(cat "$home/wrapper.err")"
    [ -f "$home/foreign-lock-preserved" ] || fail "completion bridge released a foreign publication lock"
    [ "$(cat "$home/generations")" = "$count" ] || fail "$scenario handoff launched an unexpected successor"
    pass "context restart: $scenario handoff waits for replacement commit without false success"
  done
}

test_opt_out_paths_are_unchanged() {
  local home out rc fake
  home="$TMP_ROOT/opt-out"
  make_primary "$home"
  rm "$home/config/context-restart-budget"
  rc=0
  out=$(run_hook "$home" off-session "$home/nonexistent.jsonl") || rc=$?
  expect_code 0 "$rc" "opted-out hook must not inspect an absent transcript"
  [ -z "$out" ] || fail "opted-out hook emitted output"
  [ ! -e "$home/state/.context-restart.lock" ] || fail "opted-out hook created a claim"
  [ ! -e "$home/state/.context-restart-crossing" ] || fail "opted-out hook created a crossing"
  rm -rf "$home/state"
  fake="$home/fake-claude"
  cat > "$fake" <<'SCRIPT'
#!/usr/bin/env bash
[ -z "${FM_CONTEXT_RESTART_WRAPPER_TOKEN:-}" ] || exit 90
printf '%s\n' "$@"
exit 17
SCRIPT
  chmod +x "$fake"
  rc=0
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_CLAUDE_BIN="$fake" \
    "$WRAPPER" --firstmate-initial-prompt original -- --resume saved --effort low) || rc=$?
  expect_code 17 "$rc" "opted-out wrapper must preserve Claude's exit status"
  [ "$out" = $'--resume\nsaved\n--effort\nlow\noriginal' ] || fail "opted-out wrapper altered the arguments: $out"
  [ ! -e "$home/config/context-restart-budget" ] || fail "opt-out launch materialized a budget"
  [ ! -e "$home/state" ] || fail "opt-out wrapper created a state directory"
  pass "context restart: absent-budget hook and wrapper preserve the plain-Claude path"
}

test_foreign_hooks_and_handoff_guards() {
  local home payload rc out transcript
  home="$TMP_ROOT/foreign"
  make_primary "$home" 1
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" 20 20 20 20
  for payload in \
    "{\"session_id\":\"foreign\",\"transcript_path\":\"$transcript\",\"cursor_version\":\"fixture\"}" \
    "{\"session_id\":\"foreign\",\"transcript_path\":\"$home/.pi/session.jsonl\"}"; do
    rc=0
    out=$(printf '%s' "$payload" | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      "$FAKE_CLAUDE" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; "$HOOK"' 2>&1) || rc=$?
    expect_code 0 "$rc" "foreign-host payload must remain inert"
    [ -z "$out" ] || fail "foreign-host payload emitted a directive"
    [ ! -e "$home/state/.context-restart-crossing" ] || fail "foreign host published a crossing"
  done
  run_hook "$home" guarded-session "$transcript" >/dev/null 2>&1 || true
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$HANDOFF" handoff --session guarded-session > "$FM_HOME/no-receipt.out" 2>&1
    [ "$?" -eq 2 ] || exit 81
    "$HANDOFF" handoff --session wrong-session --reset-safe > "$FM_HOME/wrong-session.out" 2>&1
    [ "$?" -eq 1 ] || exit 82
    "$HANDOFF" handoff --session guarded-session --reset-safe > "$FM_HOME/manual.out" 2>&1
    [ "$?" -eq 3 ] || exit 83
    "$HANDOFF" handoff --session guarded-session --reset-safe >> "$FM_HOME/manual.out" 2>&1
    [ "$?" -eq 3 ] || exit 84
  ' || fail "handoff guard or manual idempotence failed"
  [ "$(record_phase "$home")" = ready ] || fail "manual handoff did not retain the durable ready record"
  pass "context restart: foreign hooks stay inert; handoff requires receipt, matching session, and owned lock"
}

test_wrapper_ordinary_exit_and_resume_refusal() {
  local home fake rc out option
  home="$TMP_ROOT/ordinary"
  make_primary "$home" 1
  fake="$home/fake-claude"
  printf '#!/usr/bin/env bash\nprintf called >> "$FM_HOME/launches"\nexit 19\n' > "$fake"
  chmod +x "$fake"
  rc=0
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_CLAUDE_BIN="$fake" "$WRAPPER" 2>&1) || rc=$?
  expect_code 19 "$rc" "ordinary Claude exit must pass through without restart: $out"
  [ "$(cat "$home/launches")" = called ] || fail "ordinary exit restarted Claude"
  for option in --resume -r --continue --fork-session --session-id --from-pr --teleport; do
    rc=0
    out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_CLAUDE_BIN="$fake" "$WRAPPER" -- "$option" 2>&1) || rc=$?
    expect_code 2 "$rc" "opted-in wrapper must refuse $option"
    assert_contains "$out" 'restore prior conversation context' "resume refusal lost the explanation"
  done
  [ "$(cat "$home/launches")" = called ] || fail "resume refusal launched Claude"
  pass "context restart: ordinary exit never loops and resume options cannot restore old context"
}

test_wrapper_refuses_incomplete_or_foreign_handoffs() {
  local home fake scenario rc expected
  for scenario in ready foreign-token foreign-lock; do
    home="$TMP_ROOT/refusal-$scenario"
    make_primary "$home" 10
    fake="$home/fake-claude"
    cat > "$fake" <<'SCRIPT'
#!/usr/bin/env bash
exec -a claude /bin/bash -c '
  printf "launched\n" >> "$FM_HOME/launches"
  . "$LIB"
  phase=replacing
  token=$FM_CONTEXT_RESTART_WRAPPER_TOKEN
  [ "$SCENARIO" != ready ] || phase=ready
  [ "$SCENARIO" != foreign-token ] || token=aaaaaaaaaaaaaaaa
  printf "22222222\n" > "$FM_HOME/state/.lock"
  fm_context_restart_record_publish "$FM_HOME/state" refused-session 40 10 1700000000 "$phase" automatic "$token" "$$" || exit 92
  # A ready-only record cannot authorize a later ordinary exit after the
  # bridge refused this foreign session-lock owner.
  sleep 1
  exit 17
' claude "$@"
SCRIPT
    chmod +x "$fake"
    rc=0
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_CLAUDE_BIN="$fake" SCENARIO="$scenario"       "$WRAPPER" > "$home/wrapper.out" 2> "$home/wrapper.err" || rc=$?
    expected=17
    [ "$scenario" != foreign-lock ] || expected=1
    expect_code "$expected" "$rc" "$scenario must refuse automatic replacement"
    [ "$(cat "$home/launches")" = launched ] || fail "$scenario launched another generation"
    [ "$(cat "$home/state/.lock")" = 22222222 ] || fail "$scenario removed a foreign session lock"
    [ -f "$home/state/.context-restart-crossing" ] || fail "$scenario discarded the preparation record"
  done
  pass "context restart: incomplete preparation and foreign wrapper or lock never authorize replacement"
}

test_supervision_transfer_and_queued_wakes() {
  local home mode fake rc
  for mode in plain host; do
    home="$TMP_ROOT/continuity-$mode"
    make_primary "$home" 10
    fm_test_track_watcher_state "$home/state"
    printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$home/state/demo.meta"
    if [ "$mode" = plain ]; then : > "$home/config/supervision-host-off"; fi
    write_transcript "$home/transcript.jsonl" 10 10 10 10
    fake="$home/fake-claude"
    cat > "$fake" <<'SCRIPT'
#!/usr/bin/env bash
exec -a claude /bin/bash -c '
  . "$FM_REPO/bin/fm-wake-lib.sh"
  n=$(cat "$FM_HOME/generations" 2>/dev/null || echo 0)
  n=$((n+1)); printf "%s\n" "$n" > "$FM_HOME/generations"
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  payload=$(printf "{\"session_id\":\"session-%s\",\"transcript_path\":\"%s/transcript.jsonl\"}" "$n" "$FM_HOME")
  if [ "$n" -eq 1 ]; then
    printf "%s" "$payload" | "$FM_REPO/bin/fm-claude-stop-autoarm.sh" > "$FM_HOME/autoarm.out" 2>&1 & auto=$!
    trap '\''host=$(grep "^host" "$STATE/.supervision-host" 2>/dev/null | cut -f2); [ -z "$host" ] || kill -TERM "$host" 2>/dev/null; kill -TERM "$auto" 2>/dev/null; wait "$auto" 2>/dev/null; exit 0'\'' TERM
    i=0
    until fm_watcher_healthy "$STATE" "$FM_REPO/bin/fm-watch.sh" 300 "$FM_HOME"; do
      i=$((i+1)); [ "$i" -lt 200 ] || exit 81; sleep 0.1
    done
    printf "%s\n" "$FM_WATCHER_HEALTHY_PID" > "$FM_HOME/old-watcher"
    printf "%s" "$payload" | "$HOOK" > "$FM_HOME/detection.out" 2>&1
    [ "$?" -eq 2 ] || exit 82
    printf "%s" "$payload" | "$FM_REPO/bin/fm-turnend-guard.sh" --claude > "$FM_HOME/guard.out" 2>&1
    [ "$?" -eq 0 ] || exit 83
    fm_wake_append check before-refresh "check: before-refresh"
    "$HANDOFF" handoff --session session-1 --reset-safe || exit 84
    i=0; while [ "$i" -lt 300 ]; do sleep 0.1; i=$((i+1)); done; exit 93
  fi
  # Synthetic SessionStart: prove the wrapper left a supervised home before
  # any native successor hook or startup digest runs.
  fm_watcher_healthy "$STATE" "$FM_REPO/bin/fm-watch.sh" 300 "$FM_HOME" || exit 85
  [ "$FM_WATCHER_HEALTHY_PID" != "$(cat "$FM_HOME/old-watcher")" ] || exit 86
  fm_wake_append check during-startup "check: during-startup"
  sleep 1
  fm_watcher_healthy "$STATE" "$FM_REPO/bin/fm-watch.sh" 300 "$FM_HOME" || exit 87
  "$FM_REPO/bin/fm-wake-drain.sh" > "$FM_HOME/successor-drain" 2>&1 || exit 88
  grep -q before-refresh "$FM_HOME/successor-drain" || exit 89
  grep -q during-startup "$FM_HOME/successor-drain" || exit 90
  grep -q before-refresh "$STATE/.wake-queue" || exit 91
  grep -q during-startup "$STATE/.wake-queue" || exit 92
  "$FM_REPO/bin/fm-claude-stop-autoarm.sh" <<< "$payload" > "$FM_HOME/native-autoarm.out" 2>&1 & native=$!
  i=0
  until grep -q "firstmate watcher wake" "$FM_HOME/native-autoarm.out"; do
    i=$((i+1)); [ "$i" -lt 300 ] || exit 94; sleep 0.1
  done
  wait "$native"
  [ "$?" -eq 2 ] || exit 95
  grep -q before-refresh "$STATE/.wake-queue" || exit 96
  grep -q during-startup "$STATE/.wake-queue" || exit 97
  exit 0
' claude "$@"
SCRIPT
    chmod +x "$fake"
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_CLAUDE_BIN="$fake" FM_REPO="$ROOT" \
      FM_POLL=1 FM_SIGNAL_GRACE=999999 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
      "$WRAPPER" > "$home/wrapper.out" 2> "$home/wrapper.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      [ -z "${FM_CONTEXT_RESTART_TEST_EVIDENCE:-}" ] || cp -R "$home" "$FM_CONTEXT_RESTART_TEST_EVIDENCE/$mode"
      fail "$mode handoff failed (exit $rc): $(tail -80 "$home/wrapper.err") $(cat "$home/autoarm.out")"
    fi
    [ "$(cat "$home/generations")" = 2 ] || fail "$mode refresh looped"
    assert_contains "$(cat "$home/detection.out")" 'context-refresh:' "context detector did not participate in $mode Stop stack"
    pass "context restart: $mode Stop stack transfers supervision before exit and retains pre-refresh/startup wakes"
  done
}

test_successor_baseline_prevents_restart_loops() {
  local home transcript out rc
  home="$TMP_ROOT/successor-baseline"
  make_primary "$home" 10
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" 10 10 10 10
  rc=0
  out=$(FM_CONTEXT_RESTART_SUCCESSOR=1 run_hook "$home" new-session "$transcript") || rc=$?
  expect_code 0 "$rc" "a successor already above budget must not request another reset"
  assert_contains "$out" 'initial context' "too-small budget did not report the startup floor"
  [ "$(record_phase "$home")" = inhibited ] || fail "successor did not inhibit a repeated baseline reset"
  rc=0
  out=$(FM_CONTEXT_RESTART_SUCCESSOR=1 run_hook "$home" new-session "$transcript") || rc=$?
  expect_code 0 "$rc" "inhibited successor must not loop"
  [ -z "$out" ] || fail "inhibited successor repeated its diagnostic"
  printf '100\n' > "$home/config/context-restart-budget"
  out=$(FM_CONTEXT_RESTART_SUCCESSOR=1 run_hook "$home" new-session "$transcript") || fail "raising the budget did not rearm silently"
  [ -z "$out" ] || fail "below-budget successor emitted output"
  [ "$(record_phase "$home")" = armed ] || fail "successor did not record its available headroom"
  write_transcript "$transcript" 30 30 30 10
  rc=0
  out=$(FM_CONTEXT_RESTART_SUCCESSOR=1 run_hook "$home" new-session "$transcript") || rc=$?
  expect_code 2 "$rc" "a rearmed successor must refresh on its later crossing"
  assert_contains "$out" 'context-refresh:' "rearmed successor lost its directive"
  pass "context restart: over-budget successor baseline inhibits loops and a raised budget rearms it"
}

test_handoff_waits_for_replacement_commit
test_budget_parser_and_opt_in
test_threshold_and_one_directive_per_crossing
test_malformed_transcript_and_usage_are_inert
test_concurrent_stop_firings_publish_one_directive
test_reset_safe_wrapper_restarts_fresh_and_releases_lock
test_wrapper_waits_for_publication_and_revalidates_ownership
test_opt_out_paths_are_unchanged
test_foreign_hooks_and_handoff_guards
test_wrapper_ordinary_exit_and_resume_refusal
test_wrapper_refuses_incomplete_or_foreign_handoffs
test_supervision_transfer_and_queued_wakes

test_successor_baseline_prevents_restart_loops
