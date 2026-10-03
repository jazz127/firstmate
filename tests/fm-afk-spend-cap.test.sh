#!/usr/bin/env bash
# Synthetic/offline away spend admission through production backend and DoD classifiers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-spend-cap)
fm_git_identity fmtest fmtest@example.invalid

# Only external tool reads are faked; the spend, crew-state, busy and DoD
# classifiers all execute their production code. No real backend is driven.
install_tools() {  # <case-dir>
  local dir=$1 tool
  mkdir -p "$dir/fakebin" "$dir/state"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows)
    case "$3" in
      *unreadable*) echo 'no current client' >&2; exit 1 ;;
      *missing*) exit 0 ;;
    esac
    printf 'worker\n'
    ;;
  display-message)
    case "${*: -1}" in
      '#{pane_current_command}')
        case "$4" in
          dead:*) printf 'bash\n' ;;
          ambiguous:*) printf 'sleep\n' ;;
          *) printf 'claude\n' ;;
        esac
        ;;
      '#{pane_id}') printf '%%1\n' ;;
      *) exit 1 ;;
    esac
    ;;
  capture-pane) printf 'all quiet\n> \n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
# No attributed run in this fixture; production crew-state reads busy/log state.
exit 0
SH
  for tool in herdr orca zellij cmux; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/fakebin/$tool"
  done
  chmod +x "$dir/fakebin/"*
}

test_positive_death_and_ambiguous_endpoint() {
  local dir count
  dir="$TMP_ROOT/death-count"
  install_tools "$dir"
  fm_write_meta "$dir/state/stopped.meta" "kind=ship" "window=dead:worker"
  fm_write_meta "$dir/state/ambiguous.meta" "kind=ship" "window=ambiguous:worker"
  count=$(count_workers "$dir") || fail "death count failed"
  [ "$count" = 1 ] || fail "positive-death/ambiguous count=$count, expected 1"
  pass "positive endpoint death frees cap room while an unattributed process still counts"
}

count_workers() {  # <case-dir>
  PATH="$1/fakebin:$PATH" NM_HOME="$1/unused-nm-home" \
    FM_HOME="$1" "$ROOT/bin/fm-afk-spend-count.sh" "$1/state"
}

read_worker() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" NM_HOME="$1/unused-nm-home" \
    FM_HOME="$1" FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" "$2"
}

test_exited_worker_does_not_fill_cap() {
  local home root out rc
  home="$TMP_ROOT/exited"
  root="$home/project"
  install_tools "$home"
  mkdir -p "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$root/bin"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null \
    || fail "away entry failed"
  fm_write_meta "$home/state/exited.meta" "window=missing:worker" "kind=ship"

  rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-spawn.sh" fresh \
    --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "expected queued-work gate, got rc=$rc: $out"
  assert_contains "$out" "queued unblocked work" "spawn never reached the next admission gate: $out"
  assert_not_contains "$out" "caps concurrent workers" "an exited worker filled the cap: $out"
  pass "an exited worker frees cap room and spawn reaches its queued-work gate"
}

test_unreadable_and_unverified_backends_still_count() {
  local dir backend target count
  dir="$TMP_ROOT/backend-count"
  install_tools "$dir"
  for backend in tmux herdr orca zellij cmux; do
    case "$backend" in
      tmux) target=unreadable:worker ;;
      herdr) target=fm-lab-synthetic:w1:p2 ;;
      *) target=recorded-target ;;
    esac
    fm_write_meta "$dir/state/$backend.meta" "kind=ship" "backend=$backend" "window=$target"
  done
  fm_write_meta "$dir/state/exited.meta" "kind=scout" "window=missing:worker"
  fm_write_meta "$dir/state/no-target.meta" "kind=ship"
  fm_write_meta "$dir/state/mate.meta" "kind=secondmate" "window=unreadable:worker"
  count=$(count_workers "$dir") || fail "backend count failed"
  [ "$count" = 5 ] || fail "unreadable/unverified backend count=$count, expected 5 (one per supported backend)"
  pass "five unreadable/unverified backends count; missing endpoints, absent targets and secondmates do not"
}

test_handoff_and_ready_use_production_crew_state() {
  local dir head out count
  dir="$TMP_ROOT/delivery-count"
  install_tools "$dir"
  git init -q -b fm/worker "$dir/wt"
  git -C "$dir/wt" commit -q --allow-empty -m init
  git -C "$dir/wt" update-ref refs/remotes/origin/main "$(git -C "$dir/wt" rev-parse HEAD)"
  git -C "$dir/wt" commit -q --allow-empty -m 'unpublished implementation'
  head=$(git -C "$dir/wt" rev-parse HEAD)
  fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/wt" \
    "project=$dir/wt" "kind=ship" "mode=no-mistakes" "harness=claude"
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" task --state idle \
    --source claude-hook --event stop >/dev/null || fail "idle record failed"

  printf 'done: implementation complete\n' > "$dir/state/task.status"
  out=$(read_worker "$dir" task)
  assert_contains "$out" "state: done" "fixture did not reach production handoff classification: $out"
  count=$(count_workers "$dir") || fail "handoff count failed"
  [ "$count" = 1 ] || fail "unpublished pre-validation handoff count=$count, expected 1; crew-state: $out"
  pass "production crew-state accepts a handoff but away spend keeps it counted"

  printf 'done: PR https://example.test/o/r/pull/9 checks green\n' > "$dir/state/task.status"
  out=$(read_worker "$dir" task)
  assert_contains "$out" "state: blocked" "invalid ready head was not blocked: $out"
  assert_contains "$out" "named head $head is unreachable" "named-head gate was not exercised: $out"
  count=$(count_workers "$dir") || fail "invalid-ready count failed"
  [ "$count" = 1 ] || fail "invalid ready head count=$count, expected 1"
  pass "production named-head refusal keeps an unpublished ready claim counted"

  git -C "$dir/wt" update-ref refs/remotes/origin/worker "$head"
  out=$(read_worker "$dir" task)
  assert_contains "$out" "state: done" "preserved ready head was not accepted: $out"
  count=$(count_workers "$dir") || fail "ready count failed"
  [ "$count" = 0 ] || fail "accepted ready head count=$count, expected 0"
  pass "accepted terminal-ready delivery leaves the away spend count"

  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" task busy --current-gen \
    --source claude-hook --event user-prompt-submit >/dev/null || fail "busy record failed"
  out=$(read_worker "$dir" task)
  assert_contains "$out" "state: working" "stale ready log hid authoritative busy state: $out"
  count=$(count_workers "$dir") || fail "busy recount failed"
  [ "$count" = 1 ] || fail "stale ready log with active current state count=$count, expected 1"
  pass "authoritative busy state overrides an unchanged ready log for spend admission"

  printf 'working: review feedback arrived\n' >> "$dir/state/task.status"
  count=$(count_workers "$dir") || fail "resumed recount failed"
  [ "$count" = 1 ] || fail "explicitly resumed worker count=$count, expected 1"
  pass "an explicit working declaration keeps resumed work counted"
}

test_other_delivery_modes_and_scout() {
  local dir mode count
  dir="$TMP_ROOT/other-deliveries"
  install_tools "$dir"
  git init -q -b fm/worker "$dir/wt"
  git -C "$dir/wt" commit -q --allow-empty -m init
  git -C "$dir/wt" update-ref refs/remotes/origin/worker "$(git -C "$dir/wt" rev-parse HEAD)"
  git clone -q "$dir/wt" "$dir/project"
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" task --state idle \
    --source claude-hook --event stop >/dev/null || fail "idle record failed"
  for mode in direct-PR local-only; do
    fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/wt" \
      "project=$dir/project" "kind=ship" "mode=$mode" "harness=claude"
    printf 'done: ready for review\n' > "$dir/state/task.status"
    count=$(count_workers "$dir") || fail "$mode count failed"
    [ "$count" = 0 ] || fail "accepted $mode delivery count=$count, expected 0"
  done
  fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/wt" \
    "project=$dir/project" "kind=ship" "harness=claude"
  printf 'done: implementation complete\n' > "$dir/state/task.status"
  count=$(count_workers "$dir") || fail "default-mode count failed"
  [ "$count" = 1 ] || fail "default no-mistakes handoff count=$count, expected 1"
  fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/wt" \
    "kind=scout" "harness=claude"
  printf 'done: report complete\n' > "$dir/state/task.status"
  count=$(count_workers "$dir") || fail "scout count failed"
  [ "$count" = 0 ] || fail "finished scout count=$count, expected 0"
  pass "direct-PR, local-only and scout deliveries are excluded; the default-mode handoff still counts"
}

test_exited_worker_does_not_fill_cap
test_unreadable_and_unverified_backends_still_count
test_positive_death_and_ambiguous_endpoint
test_handoff_and_ready_use_production_crew_state
test_other_delivery_modes_and_scout
