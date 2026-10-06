#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a temp root /tmp/fm-<id>/ with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the task's
# meta. fm-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise fm-teardown directly as a subprocess against a fake FM_HOME/FM_ROOT
# built so the real script resolves into it, with stub helper scripts.
# The isolated fm-spawn subprocess in fm-kimi-harness.test.sh covers temp-root creation,
# metadata publication, and the pane environment export.
set -u

# This suite does not source tests/lib.sh, so exempt its teardown subprocess from
# the gate-lifecycle refusal (bin/fm-gate-refuse-lib.sh) the way lib.sh does for
# the rest of the suite: the no-mistakes gate runs this suite from a gate worktree,
# which the guard would otherwise refuse.
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-gotmp-tests.XXXXXX")
mkdir -p "$TMP_ROOT/fakebin"
FM_TRACE_TEST_REAL_RM=$(command -v rm)
export FM_TRACE_TEST_REAL_RM
cat > "$TMP_ROOT/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -n "${FM_TRACE_FAIL_META_REMOVE:-}" ] && [ "$arg" = "$FM_TRACE_FAIL_META_REMOVE" ]; then
    exit 1
  fi
done
exec "$FM_TRACE_TEST_REAL_RM" "$@"
SH
chmod +x "$TMP_ROOT/fakebin/rm"
cat > "$TMP_ROOT/fakebin/curl" <<'SH'
#!/usr/bin/env bash
body=$(cat)
[ -n "${FM_TRACE_CAPTURE_DIR:-}" ] || exit 1
mkdir -p "$FM_TRACE_CAPTURE_DIR"
n=$(find "$FM_TRACE_CAPTURE_DIR" -type f -name 'request-*.json' | wc -l | tr -d ' ')
printf '%s' "$body" > "$FM_TRACE_CAPTURE_DIR/request-$((n + 1)).json"
SH
chmod +x "$TMP_ROOT/fakebin/curl"

enable_trace_export() {  # <home> <capture-dir> <status> <task-id>
  local home=$1 capture=$2 status=$3 id=$4 auth="$1/config/auth-header"
  mkdir -p "$capture"
  printf 'Authorization: Bearer synthetic-token\n' > "$auth"
  chmod 600 "$auth"
  jq -n --arg auth "$auth" '{enabled:true,endpoint:"http://127.0.0.1:14318/v1/traces","auth-header-file":$auth}' \
    > "$home/config/trace-export.json"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s on\n' "$$" > "$home/state/.trace-context-effective"
  printf 'traceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\nspawn_gen=s1.1.1\n' \
    >> "$home/state/$id.meta"
  printf '%s\n' "$status" > "$home/state/$id.status"
}

# Build a fake FM_HOME/FM_ROOT so the real fm-teardown.sh (symlinked in) resolves
# state and helper scripts inside it. Stub the helper scripts fm-teardown calls so no
# live tmux/treehouse/fleet state is touched. A nonexistent worktree path makes both
# `if [ -d "$WT" ]` guards skip, so teardown runs straight to the cleanup + state rm.
make_fake_root() {
  local id=$1 tasktmp=$2
  local fake="$TMP_ROOT/$id"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data" "$fake/config"
  # Symlink the REAL teardown so the test exercises actual code, not a copy.
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  # fm-backend.sh is real, while its adapter is stubbed so this temp-cleanup
  # test cannot depend on or mutate a host tmux server. Teardown still refuses
  # unless every sibling the real tmux adapter sources is present.
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  cat > "$fake/bin/backends/tmux.sh" <<'SH'
fm_backend_tmux_kill() { return 0; }
SH
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-session-lock-lib.sh" "$fake/bin/fm-session-lock-lib.sh"
  ln -s "$ROOT/bin/fm-agent-process-lib.sh" "$fake/bin/fm-agent-process-lib.sh"
  ln -s "$ROOT/bin/fm-gemini-lib.sh" "$fake/bin/fm-gemini-lib.sh"
  ln -s "$ROOT/bin/fm-cursor-lib.sh" "$fake/bin/fm-cursor-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  # fm-lock-lib.sh: teardown sources it for the shared lock-staleness proof.
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  # fm-lease-lib.sh: teardown sources it for the supervision lease guard.
  ln -s "$ROOT/bin/fm-lease-lib.sh" "$fake/bin/fm-lease-lib.sh"
  # Lifecycle serialization, status presentation retirement, and shared adapter
  # ownership are sourced by teardown.
  ln -s "$ROOT/bin/fm-control-lib.sh" "$fake/bin/fm-control-lib.sh"
  ln -s "$ROOT/bin/fm-classify-lib.sh" "$fake/bin/fm-classify-lib.sh"
  # fm-timeout-lib.sh: the shared hard bound fm-classify-lib.sh sources for the
  # wedge detector's bounded worktree write probe.
  ln -s "$ROOT/bin/fm-timeout-lib.sh" "$fake/bin/fm-timeout-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  ln -s "$ROOT/bin/fm-path-lib.sh" "$fake/bin/fm-path-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-public-followup-lib.sh (and the fm-x-lib.sh and fm-env-lib.sh it
  # sources): teardown sources it for the relay-activation gate on the
  # promised-public-reply check. None does anything in this fixture, which has
  # no .env, but all three are real siblings teardown now requires.
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-env-lib.sh" "$fake/bin/fm-env-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
  # Receiver-wake retirement sources the pending-reply library, which in turn
  # requires the marker helper even for this ordinary-task teardown fixture.
  ln -s "$ROOT/bin/fm-pending-reply-lib.sh" "$fake/bin/fm-pending-reply-lib.sh"
  ln -s "$ROOT/bin/fm-marker-lib.sh" "$fake/bin/fm-marker-lib.sh"
  ln -s "$ROOT/bin/fm-operational-input.sh" "$fake/bin/fm-operational-input.sh"
  ln -s "$ROOT/bin/fm-trace-span-lib.sh" "$fake/bin/fm-trace-span-lib.sh"
  ln -s "$ROOT/bin/fm-trace-context-lib.sh" "$fake/bin/fm-trace-context-lib.sh"
  ln -s "$ROOT/bin/fm-timing-lib.sh" "$fake/bin/fm-timing-lib.sh"
  # Ordinary teardown reports any final ledger outcome before removing records.
  ln -s "$ROOT/bin/fm-inactive-reconcile.sh" "$fake/bin/fm-inactive-reconcile.sh"
  ln -s "$ROOT/bin/fm-parent-channel-lib.sh" "$fake/bin/fm-parent-channel-lib.sh"
  # fm-guard.sh: stub (teardown calls it with `|| true`).
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  # fm-fleet-sync.sh: stub (called for non-scout/non-local-only teardowns).
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  # fm-tasks-axi-lib.sh: stub (teardown sources it). Report no backend so the
  # fused backlog close is skipped and the follow-up echo takes the plain-message
  # path; there is no tasks-axi and no backlog in this fixture.
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
FM_TASKS_AXI_MIN=0.2.6
fm_tasks_axi_backend() { printf 'markdown\n'; }
fm_tasks_axi_backend_available() { return 1; }
fm_tasks_axi_compatible() { return 1; }
fm_backlog_backend_manual() { return 1; }
SH
  ln -s "$ROOT/bin/fm-backlog-transition-lib.sh" "$fake/bin/fm-backlog-transition-lib.sh"
  # Meta with a nonexistent worktree so the dirty/treehouse blocks skip.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-worktree-$id
project=$TMP_ROOT/nonexistent-project-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$tasktmp
META
  printf '%s' "$fake"
}

# --- fm-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2
  local task_tmp="$TMP_ROOT/fm-$id"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  # Sanity: dir + contents exist before teardown.
  [ -d "$task_tmp/gotmp" ] || fail "precondition: gotmp missing before teardown"
  # Run the REAL teardown against the fake root.
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a valid tasktmp"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "fm-teardown removes the dir pointed to by tasktmp= in meta"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake="$TMP_ROOT/$id-root"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data"
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  cat > "$fake/bin/backends/tmux.sh" <<'SH'
fm_backend_tmux_kill() { return 0; }
SH
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-session-lock-lib.sh" "$fake/bin/fm-session-lock-lib.sh"
  ln -s "$ROOT/bin/fm-agent-process-lib.sh" "$fake/bin/fm-agent-process-lib.sh"
  ln -s "$ROOT/bin/fm-gemini-lib.sh" "$fake/bin/fm-gemini-lib.sh"
  ln -s "$ROOT/bin/fm-cursor-lib.sh" "$fake/bin/fm-cursor-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  ln -s "$ROOT/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.sh"
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  # fm-lease-lib.sh: teardown sources it for the supervision lease guard.
  ln -s "$ROOT/bin/fm-lease-lib.sh" "$fake/bin/fm-lease-lib.sh"
  ln -s "$ROOT/bin/fm-control-lib.sh" "$fake/bin/fm-control-lib.sh"
  ln -s "$ROOT/bin/fm-classify-lib.sh" "$fake/bin/fm-classify-lib.sh"
  # fm-timeout-lib.sh: the shared hard bound fm-classify-lib.sh sources for the
  # wedge detector's bounded worktree write probe.
  ln -s "$ROOT/bin/fm-timeout-lib.sh" "$fake/bin/fm-timeout-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  ln -s "$ROOT/bin/fm-path-lib.sh" "$fake/bin/fm-path-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  # fm-pr-lib.sh: teardown uses its canonical task-ID validator for poll cleanup.
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake/bin/fm-pr-lib.sh"
  # fm-public-followup-lib.sh (and the fm-x-lib.sh and fm-env-lib.sh it
  # sources): teardown sources it for the relay-activation gate on the
  # promised-public-reply check. None does anything in this fixture, which has
  # no .env, but all three are real siblings teardown now requires.
  ln -s "$ROOT/bin/fm-public-followup-lib.sh" "$fake/bin/fm-public-followup-lib.sh"
  ln -s "$ROOT/bin/fm-x-lib.sh" "$fake/bin/fm-x-lib.sh"
  ln -s "$ROOT/bin/fm-env-lib.sh" "$fake/bin/fm-env-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-registry-lib.sh" "$fake/bin/fm-secondmate-registry-lib.sh"
  ln -s "$ROOT/bin/fm-secondmate-parent-lib.sh" "$fake/bin/fm-secondmate-parent-lib.sh"
  ln -s "$ROOT/bin/fm-pending-reply-lib.sh" "$fake/bin/fm-pending-reply-lib.sh"
  ln -s "$ROOT/bin/fm-marker-lib.sh" "$fake/bin/fm-marker-lib.sh"
  ln -s "$ROOT/bin/fm-trace-span-lib.sh" "$fake/bin/fm-trace-span-lib.sh"
  ln -s "$ROOT/bin/fm-trace-context-lib.sh" "$fake/bin/fm-trace-context-lib.sh"
  ln -s "$ROOT/bin/fm-timing-lib.sh" "$fake/bin/fm-timing-lib.sh"
  ln -s "$ROOT/bin/fm-operational-input.sh" "$fake/bin/fm-operational-input.sh"
  ln -s "$ROOT/bin/fm-inactive-reconcile.sh" "$fake/bin/fm-inactive-reconcile.sh"
  ln -s "$ROOT/bin/fm-parent-channel-lib.sh" "$fake/bin/fm-parent-channel-lib.sh"
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
FM_TASKS_AXI_MIN=0.2.6
fm_tasks_axi_backend() { printf 'markdown\n'; }
fm_tasks_axi_backend_available() { return 1; }
fm_tasks_axi_compatible() { return 1; }
fm_backlog_backend_manual() { return 1; }
SH
  ln -s "$ROOT/bin/fm-backlog-transition-lib.sh" "$fake/bin/fm-backlog-transition-lib.sh"
  # No tasktmp= line at all.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-wt-$id
project=$TMP_ROOT/nonexistent-proj-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
META
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp= was absent"
  pass "fm-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_teardown_skips_gracefully_when_dir_missing() {
  # tasktmp= points to a path that does not exist. Teardown must not error.
  local id=td-missing-z4
  local task_tmp="$TMP_ROOT/never-created-fm-$id"
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_terminal_spans_follow_successful_cleanup_only() {
  local id status line rc fake capture request
  for status in 'done [at=1712345678]: finished' 'failed [at=1712345678]: failed' '' secondmate; do
    case "$status" in done*) id=trace-done ;; failed*) id=trace-failed ;; secondmate) id=trace-secondmate; status= ;; *) id=trace-unknown ;; esac
    fake=$(make_fake_root "$id" "")
    if [ "$id" = trace-failed ]; then
      printf 'endpoint_task_id=%s\n' "$id" >> "$fake/state/$id.meta"
    fi
    if [ "$id" = trace-secondmate ]; then
      sed 's/^kind=ship$/kind=secondmate/' "$fake/state/$id.meta" > "$fake/state/$id.meta.tmp"
      mv "$fake/state/$id.meta.tmp" "$fake/state/$id.meta"
    fi
    capture="$TMP_ROOT/$id-spans"
    enable_trace_export "$fake" "$capture" "$status" "$id"
    # The missing-start case models historical task metadata from before tracing.
    rc=0
    if [ "$id" = trace-done ]; then
      mv "$fake/bin/fm-nm-run-lib.sh" "$fake/bin/fm-nm-run-lib.saved"
      FM_HOME="$fake" PATH="$TMP_ROOT/fakebin:$PATH" \
        FM_TRACE_CAPTURE_DIR="$capture" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 || rc=$?
      [ "$rc" -ne 0 ] || fail "refused cleanup unexpectedly succeeded"
      [ "$(find "$capture" -type f -name 'request-*.json' | wc -l | tr -d ' ')" -eq 0 ] \
        || fail "refused cleanup emitted a terminal root"
      mv "$fake/bin/fm-nm-run-lib.saved" "$fake/bin/fm-nm-run-lib.sh"
    fi
    case "$id" in
      trace-done|trace-failed)
        rc=0
        FM_HOME="$fake" PATH="$TMP_ROOT/fakebin:$PATH" FM_TRACE_CAPTURE_DIR="$capture" \
          FM_TRACE_FAIL_META_REMOVE="$fake/state/$id.meta" \
          bash "$fake/bin/fm-teardown.sh" "$id" > "$fake/refused.out" 2> "$fake/refused.err" || rc=$?
        [ "$rc" -ne 0 ] || fail "$id final task-record removal unexpectedly succeeded"
        grep -Fq 'task record could not be removed' "$fake/refused.err" \
          || fail "$id did not reach the final removal refusal"
        [ -f "$fake/state/$id.meta" ] || fail "$id lost metadata on refused removal"
        [ "$(cat "$fake/state/$id.status")" = "$status" ] \
          || fail "$id lost terminal status before record retirement committed"
        [ "$(find "$capture" -type f -name 'request-*.json' | wc -l | tr -d ' ')" -eq 0 ] \
          || fail "$id refused final removal emitted a root"
        ;;
    esac
    FM_HOME="$fake" PATH="$TMP_ROOT/fakebin:$PATH" FM_TRACE_CAPTURE_DIR="$capture" \
      bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
      || fail "$id cleanup failed"
    [ "$(find "$capture" -type f -name 'request-*.json' | wc -l | tr -d ' ')" -eq 1 ] \
      || fail "$id cleanup should emit exactly one terminal root"
    request="$capture/request-1.json"
    jq -e --arg id "$id" '
      .resourceSpans[0].resource.attributes
      | map({key:.key,value:.value.stringValue}) | from_entries
      | .["firstmate.task.id"] == $id
    ' "$request" >/dev/null || fail "$id terminal span used a snapshot filename as task identity"
    [ ! -e "$fake/state/$id.meta" ] && [ ! -e "$fake/state/$id.status" ] \
      || fail "$id successful cleanup retained task records"
    line=$(jq -r '.resourceSpans[0].scopeSpans[0].spans[0] | [.name, (.attributes[] | select(.key == "firstmate.task.outcome").value.stringValue)] | @tsv' "$request")
    case "$id:$line" in
      "trace-done:firstmate.task"$'\t'done) jq -e '.resourceSpans[0].scopeSpans[0].spans[0].status.code == 1' "$request" >/dev/null || fail "done should map to OK" ;;
      "trace-failed:firstmate.task"$'\t'failed) jq -e '.resourceSpans[0].scopeSpans[0].spans[0].status.code == 2' "$request" >/dev/null || fail "failed should map to ERROR" ;;
      "trace-unknown:firstmate.task"$'\t'unknown) jq -e '(.resourceSpans[0].scopeSpans[0].spans[0] | has("status") | not)' "$request" >/dev/null || fail "unknown should leave status unset" ;;
      "trace-secondmate:firstmate.task"$'\t'unknown) jq -e '
        (.resourceSpans[0].resource.attributes | map({key:.key,value:.value.stringValue}) | from_entries)
          ["firstmate.task.kind"] == "secondmate"
        and (.resourceSpans[0].scopeSpans[0].spans[0] | has("status") | not)
      ' "$request" >/dev/null || fail "secondmate without terminal status should leave status unset" ;;
      *) fail "$id emitted unexpected root span: $line" ;;
    esac
    [ "$(jq -r '.resourceSpans[0].scopeSpans[0].spans[0].startTimeUnixNano' "$request")" -gt 0 ] \
      || fail "$id missing historical start data did not get a safe current start"
    if [ "$id" = trace-done ]; then
      rc=0
      FM_HOME="$fake" PATH="$TMP_ROOT/fakebin:$PATH" FM_TRACE_CAPTURE_DIR="$capture" \
        bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 || rc=$?
      [ "$rc" -ne 0 ] || fail "repeated cleanup unexpectedly succeeded after record removal"
      [ "$(find "$capture" -type f -name 'request-*.json' | wc -l | tr -d ' ')" -eq 1 ] \
        || fail "repeated cleanup duplicated the terminal root"
    fi
  done
  pass "successful cleanup emits one done/failed/unknown root with missing-start fallback; refusal and repeat emit none"
}

test_teardown_removes_tasktmp_dir
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
test_terminal_spans_follow_successful_cleanup_only
