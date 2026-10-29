#!/usr/bin/env bash
# bin/fm-secondmate-restart.sh: persist-then-restart, and the honest fallback.
#
# What these pin, all through the real commands (real fm-send, real durable
# steering inbox, real parent-owned reply expectation, real fm-control
# transaction) against a lifecycle-modelling session-provider stub:
#
#   1. The persist request is a GATE. Nothing is stopped until that mate's own
#      correlated answer lands on the parent channel, and a mate that never
#      answers keeps its agent and gets the re-read message instead.
#   2. The order is persist THEN restart, observable in what reaches the pane.
#   3. The persist request is the task-subset of /stow: it asks for open records
#      and task status, and explicitly not for the memory, learnings, or
#      captain-preference sweeps.
#   4. Every unsafe case says what is known: pre-restart capability and persist
#      failures use the nudge path, while a failed relaunch is reported as an
#      unknown outcome; none is reported as a clean reload.
#   5. A remote mate restarts by running the SAME local control-plane relaunch on
#      its host, over the fm-on transport, with the profile resolved from the
#      PARENT's own pin rather than the remote home's copy of it.
#   6. End to end with bin/fm-update.sh: a live mate whose home needed no
#      fast-forward is still named for restart and genuinely restarted, and one
#      whose runtime cannot prove a restart keeps the honest re-read path with
#      its agent left running.
#   7. A T3 mate, whose thread keeps its conversation so no replacement can be
#      launched into it, is routed by both passes to the re-read message on its
#      thread and never asked to persist for a restart that cannot come.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/t3-fake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/t3-fake-lib.sh"

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-restart)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 't3_fake_stop; chmod -R u+w "$TMP_ROOT" 2>/dev/null || true; rm -rf -- "$TMP_ROOT"' EXIT

# A session-provider stub that models the two things this pass depends on: the
# harness exit command stops the agent, a launch brief starts the replacement,
# and - when armed - the live mate ANSWERS a doorbell by doing what the persist
# request asks and reporting it on the parent channel with the correlation token
# the request carried. That answer is a real status append read by the real
# pending-reply machinery, not a stubbed verdict.
make_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          if [ -e "$D/remote-relaunch-start" ] && [ ! -e "$D/remote-relaunch-end" ]; then
            : > "$D/local-relaunch-during-remote"
          fi
          printf 'zsh' > "$D/command.$target"
          ;;
        *'launch-brief: Read and follow'* | *'Firstmate operational input waiting: read'*) cat "$D/becomes" > "$D/command.$target" ;;
        ': Firstmate instruction waiting: list '*)
          printf 'doorbell\n' >> "$D/rings"
          if [ -x "$D/on-doorbell" ]; then
            "$D/on-doorbell" "$payload"
          fi
          if [ -f "$D/answer-inbox" ]; then
            # Model the mate: read the newest instruction it was handed and
            # report back on the parent channel, carrying the correlation token
            # the request itself embedded.
            inbox=$(cat "$D/answer-inbox")
            corr=$(cat "$inbox"/*.msg 2>/dev/null \
              | grep -oE 'corr=[0-9a-f]{16}' | head -1)
            if [ -n "$corr" ]; then
              verb=$(cat "$D/answer-verb" 2>/dev/null || printf 'done')
              printf '%s [%s]: persistence response\n' "$verb" "$corr" \
                >> "$(cat "$D/answer-status")"
            fi
          fi
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    target=
    prev=
    for a in "$@"; do
      if [ "$prev" = -t ]; then target=$a; fi
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*)
          if [ -f "$D/command.$target" ]; then cat "$D/command.$target"; else cat "$D/command"; fi
          printf '\n'; exit 0 ;;
        *pane_tty*) printf '/dev/pts/91\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
      prev=$a
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ''|*[!0-9]*) ;;
  *) /bin/sleep 0.01 ;;
esac
exit 0
SH
  chmod +x "$fb/sleep"
}

# A synthetic Herdr CLI for the restart-to-control boundary. It presents a
# native working Pi with a blank separator composer, then models /quit and the
# replacement launch while the real restart and control scripts run unchanged.
make_working_pi_herdr_stub() {  # <case-dir>
  local fb="$1/fakebin"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-calls"
handle_payload() {
  local payload=$1 inbox corr
  printf '%s\n' "$payload" >> "$D/literal"
  case "$payload" in
    /quit) printf zsh > "$D/command" ;;
    ". '"*"'") printf pi > "$D/command" ;;
    *'Firstmate instruction waiting: list '*)
      inbox=$(cat "$D/answer-inbox")
      corr=$(cat "$inbox"/*.msg 2>/dev/null | grep -oE 'corr=[0-9a-f]{16}' | head -1)
      [ -z "$corr" ] || printf 'done [%s]: open records written down\n' "$corr" >> "$(cat "$D/answer-status")"
      ;;
    *'launch-brief: Read and follow'* | *'Firstmate operational input waiting: read'*) printf pi > "$D/command" ;;
  esac
}
case "${1:-} ${2:-}" in
  'status --json') printf '{"client":{"protocol":22},"server":{"running":true,"protocol":22,"compatible":true}}\n' ;;
  'pane get') printf '{"result":{"pane":{"pane_id":"w1:p1","foreground_cwd":"%s","workspace_id":"w1","tab_id":"w1:t1"}}}\n' "$(cat "$D/cwd")" ;;
  'agent get')
    if [ "$(cat "$D/command")" = pi ]; then
      printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi ;;
  'pane process-info')
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":%s,"foreground_processes":[{"pid":%s,"name":"pi","argv":["pi"],"cmdline":"pi"}]}}}\n' "$PPID" "$PPID" ;;
  'pane read')
    printf 'transcript\n─────────────────────────────────────────────────────\n%s\n─────────────────────────────────────────────────────\n' "$(cat "$D/draft" 2>/dev/null || true)" ;;
  'pane send-text') printf '%s' "${4:-}" > "$D/draft" ;;
  'pane send-keys')
    case "${4:-}" in
      enter)
        payload=$(cat "$D/draft" 2>/dev/null || true)
        : > "$D/draft"
        handle_payload "$payload"
        ;;
    esac ;;
  'pane run') handle_payload "${4:-}" ;;
  'workspace list') printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"2ndmate-sm1"}]}}\n' ;;
  'tab list') printf '{"result":{"tabs":[{"tab_id":"w1:t1","label":"fm-sm1","workspace_id":"w1","root_pane_id":"w1:p1"}]}}\n' ;;
  'tab get') printf '{"result":{"tab":{"tab_id":"w1:t1","workspace_id":"w1","root_pane_id":"w1:p1","label":"fm-sm1"}}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
SH
  chmod +x "$fb/herdr"
}

# new_case <name> -> a parent home with a stub session provider.
new_case() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fake"
  printf 'claude\n' > "$dir/home/config/secondmate-harness"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/rings"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  make_stub "$dir"
  # Launch commands are recorded by the session-provider stub, never executed.
  # Keep the fixture hermetic on hosts without an installed Pi executable.
  printf '#!/usr/bin/env bash\nprintf "pi 0.0.0 synthetic fixture\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  fm_test_fake_tmux_foreground_cwd "$dir/fakebin" "$dir/fake/cwd"
  printf '%s\n' "$dir"
}

# add_local_mate <case-dir> <id> [harness] [backend-line]
# A live LOCAL second mate: a real git worktree for its home, plus the durable
# record this home keeps for it.
add_local_mate() {
  local dir=$1 id=$2 harness=${3:-claude} backend=${4:-}
  local home="$dir/home" smhome="$dir/$id-home"
  fm_git_worktree "$dir/$id-repo" "$smhome" "sm-$id"
  mkdir -p "$smhome/state" "$smhome/data" "$smhome/bin" "$home/data/$id"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# agents\n' > "$smhome/AGENTS.md"
  printf '# charter\n' > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
    [ -z "$backend" ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/cwd"
}

# add_repo_backed_mate <case-dir> <id> [harness] [backend-line]
# Like add_local_mate, but the world is the one /updatefirstmate actually runs
# against: a bare origin, a firstmate repo clone on its default branch, and the
# mate's home as a DETACHED worktree of that repo already sitting on origin's tip.
# That "already current" home is the shape the old classifier skipped entirely.
add_repo_backed_mate() {  # <case-dir> <id> [harness] [backend]
  local dir=$1 id=$2 harness=${3:-claude} backend=${4:-}
  local home="$dir/home" repo="$dir/fmrepo" smhome="$dir/$id-home"
  if [ ! -d "$repo" ]; then
    git init -q --bare "$dir/origin.git"
    git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
    git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
    mkdir -p "$dir/seed/bin" "$dir/seed/.agents/skills"
    printf '# agents\n' > "$dir/seed/AGENTS.md"
    printf 'echo a\n' > "$dir/seed/bin/tool.sh"
    printf 's1\n' > "$dir/seed/.agents/skills/note.md"
    # The operational dirs a live home carries are gitignored in a real firstmate
    # checkout; without that the home would read as dirty and be skipped.
    printf '/data/\n/state/\n/config/\n/projects/\n/.no-mistakes/\n.fm-secondmate-home\n' \
      > "$dir/seed/.gitignore"
    git -C "$dir/seed" add -A
    git -C "$dir/seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm c1
    git -C "$dir/seed" push -q origin main
    git clone -q "$dir/origin.git" "$repo"
    git -C "$repo" remote set-head origin main >/dev/null 2>&1 || true
    touch "$home/state/.last-watcher-beat"
  fi
  git -C "$repo" worktree add -q --detach "$smhome" main
  mkdir -p "$smhome/state" "$smhome/data" "$home/data/$id"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# charter\n' > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
    [ -z "$backend" ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/cwd"
}

# run_update_in_case <case-dir>: the real /updatefirstmate mechanics over that world.
run_update_in_case() {
  local dir=$1
  env PATH="$dir/fakebin:$PATH" FM_FAKE_DIR="$dir/fake" \
    FM_ROOT_OVERRIDE="$dir/fmrepo" FM_HOME="$dir/home" \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    "$ROOT/bin/fm-update.sh" 2>/dev/null
}

# arm_answer <case-dir> <id>: make the modelled mate answer the persist request.
arm_answer() {
  local dir=$1 id=$2
  printf '%s' "$dir/home/state/$id.inbox" > "$dir/fake/answer-inbox"
  printf '%s' "$dir/home/state/$id.status" > "$dir/fake/answer-status"
}

run_restart() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 FM_SECONDMATE_PERSIST_POLL=1 \
    FM_SECONDMATE_PERSIST_WAIT="${FM_TEST_PERSIST_WAIT:-30}" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    "$ROOT/bin/fm-secondmate-restart.sh" "$@" 2>&1
}

# --- T1: the persist request is the task subset of /stow, and it gates --------
test_persist_gates_and_asks_only_for_open_records() {
  local dir out rc request
  dir=$(new_case gate)
  add_local_mate "$dir" sm1
  # No answer armed: the mate never confirms its open work is written down.
  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" fm-sm1); rc=$?

  expect_code 3 "$rc" "an unconfirmed persist is a fallback, not a success"$'\n'"$out"
  assert_contains "$out" "nudged: sm1:" "an unconfirmed persist must fall back to the re-read message"
  assert_contains "$out" "its open work is written down" "the fallback must name the missing confirmation"
  assert_not_contains "$out" "restarted: sm1" "a mate that never confirmed must not be restarted"
  assert_contains "$out" "summary: 0 of 1 restarted" "the summary must not claim a reload"
  # The agent is untouched: nothing exited, nothing relaunched.
  assert_no_grep '^/exit$' "$dir/fake/literal" "the agent was stopped without a confirmed persist"
  assert_absent "$dir/home/state/sm1.control-relaunch" \
    "a restart transaction was opened without a confirmed persist"
  grep -h '^phase=' "$dir/home/state/pending-replies"/* | grep -q '^phase=awaiting_report$' \
    || fail "the timed-out persist expectation was closed instead of left to recovery"

  # The request the mate actually received is the open-record half of /stow only.
  request=$(cat "$dir/home/state/sm1.inbox"/*.msg)
  assert_contains "$request" "Open-record persistence" "the request must reuse stow's open-record contract"
  assert_contains "$request" "file a task for each open record" "the request must ask for the unfiled open records"
  assert_contains "$request" "correct any task whose status" "the request must ask for stale task status"
  assert_contains "$request" "captain call you had formed but never registered" \
    "the request must flush an unregistered captain call"
  assert_contains "$request" "Do NOT run the memory, learnings, or captain-preference sweeps" \
    "the request must exclude the memory curation half of stow"
  assert_contains "$request" "reply on your parent channel with a done status" \
    "the request must name the done reply that alone releases the restart"
  pass "T1 persist is a gate, and asks for open records and task status only"
}

# --- T2: persist THEN restart, in that order --------------------------------
test_persist_precedes_restart() {
  local dir out rc doorbell_line exit_line
  dir=$(new_case order)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a confirmed persist should restart the mate"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (claude)" "the mate should be restarted on its pinned runtime"
  assert_contains "$out" "summary: 1 of 1 restarted, 0 nudged, 0 unreached" "the summary should report the reload"
  # The pane transcript orders the two phases: the instruction doorbell first,
  # the harness exit command only after it.
  doorbell_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | head -1 | cut -d: -f1)
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  [ -n "$doorbell_line" ] || fail "the persist request never reached the mate"
  [ -n "$exit_line" ] || fail "the mate was never stopped, so it was not restarted"
  [ "$doorbell_line" -lt "$exit_line" ] \
    || fail "the agent was stopped before it was asked to persist (persist line $doorbell_line, exit line $exit_line)"
  # The reply expectation is settled rather than left open behind the restart.
  grep -h '^phase=' "$dir/home/state/pending-replies"/* | grep -q '^phase=resolved$' \
    || fail "the persist answer did not settle its durable expectation"
  pass "T2 the mate persists before anything is stopped"
}

# A successful persist reply arrives while Pi still reports working. The
# restart command must reach the same fm-control relaunch gate as a hand-run
# and submit /quit when the native Pi composer is structurally blank.
test_working_pi_blank_composer_restarts() {
  local dir out rc
  dir=$(new_case working-pi-blank)
  add_repo_backed_mate "$dir" sm1 pi herdr
  # The launch also arms the busy-state contract from the mate's code root.
  cp "$ROOT/bin/fm-git-strip-ai-trailers.sh" "$ROOT/bin/fm-operational-input.sh" \
    "$ROOT/bin/fm-busy-event.sh" "$ROOT/bin/fm-busy-lib.sh" "$dir/fmrepo/bin/"
  arm_answer "$dir" sm1
  make_working_pi_herdr_stub "$dir"
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf 'pi\n' > "$dir/home/config/secondmate-harness"
  sed 's/^window=.*/window=fm-lab-synthetic:w1:p1/' "$dir/home/state/sm1.meta" \
    > "$dir/home/state/sm1.meta.tmp"
  mv "$dir/home/state/sm1.meta.tmp" "$dir/home/state/sm1.meta"
  {
    printf 'herdr_session=fm-lab-synthetic\n'
    printf 'herdr_workspace_id=w1\n'
    printf 'herdr_tab_id=w1:t1\n'
    printf 'herdr_pane_id=w1:p1\n'
  } >> "$dir/home/state/sm1.meta"

  out=$(FM_ROOT_OVERRIDE="$dir/fmrepo" FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?
  expect_code 0 "$rc" "a working Pi with a blank native Herdr composer should restart"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (pi)" "the restart pass must report its real control outcome"
  grep -Fxq '/quit' "$dir/fake/literal" \
    || fail "the control gate must submit /quit after persistence"
  assert_contains "$(cat "$dir/fake/herdr-calls")" "pane read w1:p1" \
    "the real control path must inspect the native Pi composer"
  pass "T2a a working Pi's blank composer passes the restart-to-control exit gate"
}

# --- T2b: an answer delivered at a zero-second bound still releases the gate -
test_arrived_answer_precedes_deadline_check() {
  local dir out rc
  dir=$(new_case arrived-at-bound)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "an answer delivered with the request must beat the deadline check"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the arrived persist answer was ignored at the deadline"
  pass "T2b an arrived persist answer is resolved before timeout"
}

# --- T2c: only a correlated done reply releases the gate --------------------
# Cases adapted from kunchenguid/firstmate#5600.
test_only_done_persist_reply_releases_restart_gate() {
  local dir out rc verb phase corr
  for verb in blocked failed needs-decision working; do
    dir=$(new_case "persist-$verb")
    add_local_mate "$dir" sm1
    arm_answer "$dir" sm1
    printf '%s\n' "$verb" > "$dir/fake/answer-verb"

    out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?

    expect_code 3 "$rc" "$verb persistence reply must not authorize a restart"$'\n'"$out"
    assert_not_contains "$out" "restarted: sm1" "$verb persistence reply authorized a restart"
    assert_contains "$out" "nudged: sm1:" "$verb persistence reply did not take the safe fallback"
    [ "$verb" = working ] || assert_contains "$out" "reported $verb instead of done" \
      "$verb persistence reply reason was not reported"
    assert_no_grep '^/exit$' "$dir/fake/literal" "$verb persistence reply stopped the live mate"
    assert_absent "$dir/home/state/sm1.control-relaunch" \
      "$verb persistence reply opened a relaunch transaction"
    # The fallback nudge arms its own reply record, so read the persist
    # request's record by the correlation its answer carried.
    corr=$(grep -oE 'corr=[0-9a-f]{16}' "$dir/home/state/sm1.status" | head -1)
    corr=${corr#corr=}
    phase=$(sed -n 's/^phase=//p' "$dir/home/state/pending-replies/$corr")
    if [ "$verb" = working ]; then
      [ "$phase" = awaiting_report ] || fail "progress reply unexpectedly settled its persistence expectation"
    else
      [ "$phase" = resolved ] || fail "terminal non-success reply did not settle its persistence expectation"
    fi
  done
  pass "T2c only a correlated done persistence reply releases the restart gate"
}

# --- T2d: progress does not release the gate, but later success does ---------
test_progress_then_success_releases_gate() {
  local dir out rc
  dir=$(new_case answer-during-wait)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'working\n' > "$dir/fake/answer-verb"

  # The live mate first reports progress, then completes persistence while the
  # restart pass waits. The first status must not release the gate; the later
  # terminal success must still be observed before timeout.
  cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
set -u
inbox=$(cat "$FM_FAKE_DIR/answer-inbox" 2>/dev/null || true)
status=$(cat "$FM_FAKE_DIR/answer-status" 2>/dev/null || true)
corr=$(cat "$inbox"/*.msg 2>/dev/null | grep -oE 'corr=[0-9a-f]{16}' | head -1)
if [ -n "$corr" ] && [ ! -e "$FM_FAKE_DIR/answer-after-progress" ] \
  && grep -q "^working \\[$corr\\]" "$status"; then
  : > "$FM_FAKE_DIR/answer-after-progress"
  printf 'done [%s]: persistence completed\n' "$corr" >> "$status"
fi
/bin/sleep 0.01
SH
  chmod +x "$dir/fakebin/sleep"

  out=$(FM_TEST_PERSIST_WAIT=2 run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a later terminal success must release the gate after progress"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the later correlated success was ignored"
  assert_not_contains "$out" "nudged: sm1" "a confirmed mate must not take the timeout fallback"
  pass "T2d progress leaves the gate open for a later terminal success"
}

# --- T3: a runtime that cannot prove a restart never gets one ----------------
test_unprovable_runtime_falls_back() {
  local dir out rc
  dir=$(new_case unprovable)
  # zellij has no recovery-grade agent-state classifier, so "the old agent
  # stopped and the replacement came up" can never be established there.
  add_local_mate "$dir" sm1 claude zellij

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unprovable runtime must not report a reload"$'\n'"$out"
  assert_contains "$out" "nudged: sm1:" "an unprovable runtime must fall back to the re-read message"
  assert_contains "$out" "cannot prove an agent stopped" "the fallback must name the runtime limit"
  assert_not_contains "$out" "restarted: sm1" "an unprovable runtime must not be reported as restarted"
  # It is never even asked to spend a turn persisting, because it could not be
  # restarted afterwards either way; the only thing it was handed is the nudge.
  assert_no_grep 'Open-record persistence' "$dir/home/state/sm1.inbox/001.msg" \
    "a mate that cannot be restarted should not be asked to persist first"
  assert_grep 're-read your AGENTS.md' "$dir/home/state/sm1.inbox/001.msg" \
    "the fallback should hand the mate the ordinary re-read message"
  pass "T3 a runtime that cannot prove a restart falls back to the re-read message"
}

# --- T4: a mate with no durable record in this home --------------------------
test_unknown_mate_is_accounted_for() {
  local dir out rc
  dir=$(new_case unknown)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(run_restart "$dir" sm1 ghost); rc=$?

  expect_code 3 "$rc" "an unknown mate must not pass silently"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the known mate should still be restarted"
  assert_contains "$out" "ghost:" "the unknown mate must be accounted for by name"
  assert_contains "$out" "no durable record" "the unknown mate's reason must be concrete"
  assert_contains "$out" "summary: 1 of 2 restarted, 0 nudged, 1 unreached" "the summary must count both mates"
  pass "T4 every named mate is accounted for, including one this home does not know"
}

# --- T5: a refused restart leaves the mate running and says so ---------------
test_refused_restart_falls_back_without_claiming_a_reload() {
  local dir out rc before
  dir=$(new_case refused)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  # muse is a crewmate-only adapter, so the control plane refuses a secondmate
  # relaunch onto it BEFORE stopping anything.
  printf 'muse\n' > "$dir/home/config/secondmate-harness"
  before=$(cat "$dir/fake/command")

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a refused restart must not be reported as a reload"$'\n'"$out"
  assert_contains "$out" "unreached: sm1:" "a failed restart must be reported as unknown"
  assert_contains "$out" "restart outcome is unknown" "the report must not attribute an ambiguous failure"
  assert_not_contains "$out" "nudged: sm1" "a failed restart must not claim the old agent was nudged"
  assert_not_contains "$out" "restarted: sm1" "a refused restart must not be reported as restarted"
  [ "$(cat "$dir/fake/command")" = "$before" ] \
    || fail "a refusal before the stop should leave the running agent exactly as it was"
  assert_no_grep '^/exit$' "$dir/fake/literal" "a pre-stop refusal must not have stopped the agent"
  pass "T5 a refused restart leaves the mate running and reports an unknown outcome"
}

# --- T6: a remote mate restarts over the fm-on hop, on the parent's pin -------
# The seam decodes what fm-on.sh actually put on the wire, so this pins the
# host-local command and the profile the PARENT resolved, not a local shortcut.
# The far side also models the live mate: it answers the persist request that
# crossed the same hop, on the parent channel, with that request's own token.
setup_remote_case() {  # <case-dir> <id> <ssh-mode>
  local dir=$1 id=$2 mode=$3
  local fb="$dir/fakebin"
  mkdir -p "$dir/$id-home"
  {
    echo "window=remote:$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/$id-home"
    echo "project=$dir/$id-home"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/$id-home"
    echo "remote_host=remote-mac"
    echo "remote_backend=herdr"
    echo "remote_target=fm-remote:2ndmate-$id"
  } > "$dir/home/state/$id.meta"
  printf -- '- %s - remote domain (host: remote-mac; root: /srv/fm; home: /srv/%s; scope: things; projects: p; added 2026-09-03)\n' \
    "$id" "$id" > "$dir/home/data/secondmates.md"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2  # host, fm-remote-entrypoint.sh
argv_b64=$4
decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D; }
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done < <(decode "$argv_b64")
stdin_payload=$(cat)
printf '%s\n' "${rargs[*]}" >> "$FM_FAKE_SSH_LOG"
case "${FM_FAKE_SSH_MODE:-ok}" in
  unreachable) exit 255 ;;
esac
case "${rargs[1]:-}" in
  pause)
    [ "${FM_FAKE_SSH_MODE:-ok}" != prestop-refusal ] || exit 3
    ;;
  sync)
    [ "${FM_FAKE_SSH_MODE:-ok}" != sync-fail ] || exit 1
    printf 'current: %s\n' "${rargs[3]}"
    ;;
  put|absent)
    [ "${FM_FAKE_SSH_MODE:-ok}" != inherit-fail ] || exit 1
    if [ "${rargs[1]}" = put ] && [ -n "${FM_FAKE_REMOTE_HOME:-}" ]; then
      mkdir -p "$FM_FAKE_REMOTE_HOME/$(dirname "${rargs[2]}")"
      printf '%s' "$stdin_payload" > "$FM_FAKE_REMOTE_HOME/${rargs[2]}"
    fi
    ;;
  send-stdin)
    # Model the live remote mate: act on the instruction and report back on the
    # parent channel, carrying the correlation token the request embedded.
    if [ -n "${FM_FAKE_ANSWER_STATUS:-}" ]; then
      corr=$(printf '%s' "$stdin_payload" | grep -oE 'corr=[0-9a-f]{16}' | head -1)
      [ -z "$corr" ] || printf 'done [%s]: open records written down\n' "$corr" \
        >> "$FM_FAKE_ANSWER_STATUS"
    fi
    ;;
  relaunch|resume)
    case "${FM_FAKE_SSH_MODE:-ok}" in
      slow-relaunch)
        : > "$FM_FAKE_DIR/remote-relaunch-start"
        /bin/sleep 2
        : > "$FM_FAKE_DIR/remote-relaunch-end"
        ;;
    esac
    printf 'relaunched %s harness=%s from=claude model=%s effort=%s backend=herdr endpoint=fm-remote:2ndmate-%s worktree=/srv/fm\n' \
      "${rargs[2]}" "${rargs[3]}" "${rargs[4]}" "${rargs[5]}" "${rargs[2]}"
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=herdr\n'
    printf 'target=fm-remote:2ndmate-%s\n' "${rargs[2]}"
    printf 'herdr_session=fm-remote\n'
    printf 'harness=%s\n' "${rargs[3]}"
    printf 'model=%s\n' "${rargs[4]}"
    printf 'effort=%s\n' "${rargs[5]}"
    ;;
esac
exit 0
SH
  chmod +x "$fb/fake-ssh"
  : > "$dir/ssh.log"
  export FM_FAKE_SSH_LOG="$dir/ssh.log"
  export FM_FAKE_SSH_MODE="$mode"
  export FM_TEST_SSH_BIN="$fb/fake-ssh"
}

test_remote_mate_restarts_over_the_transport_hop() {
  local dir out rc relaunch_line
  dir=$(new_case remote)
  setup_remote_case "$dir" sm2 ok
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm2.status"
  # The parent's own pin is what the replacement must run on; the remote home's
  # copy of config/secondmate-harness is a different home's file.
  printf 'codex big-model high\n' > "$dir/home/config/secondmate-harness"
  mkdir -p "$dir/home/config/secondmate-harness.d"
  printf 'pi deepseek/deepseek-v4-pro high\n' > "$dir/home/config/secondmate-harness.d/sm2"

  out=$(run_restart "$dir" fm-sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "a remote mate should restart over its transport hop"$'\n'"$out"
  assert_contains "$out" "restarted: sm2 on remote-mac (pi)" \
    "a remote restart should be reported with its host and the parent's pinned runtime"
  relaunch_line=$(grep '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" | head -1)
  [ -n "$relaunch_line" ] || fail "no relaunch crossed the transport hop"$'\n'"$(cat "$dir/ssh.log")"
  [ "$relaunch_line" = "fm-remote-secondmate-control.sh relaunch sm2 pi deepseek/deepseek-v4-pro high" ] \
    || fail "the host-local relaunch did not carry the parent's resolved profile: $relaunch_line"
  # The persist request crossed the SAME hop before the restart did.
  [ "$(grep -n '^fm-remote-secondmate-control.sh send-stdin' "$dir/ssh.log" | head -1 | cut -d: -f1)" \
     -lt "$(grep -n '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" | head -1 | cut -d: -f1)" ] \
    || fail "the remote mate was restarted before it was asked to persist"$'\n'"$(cat "$dir/ssh.log")"
  pass "T6 a remote mate restarts through the host-local control plane over the fm-on hop"
}

# --- T6b: a per-mate override decides which runtime that mate lands on -------
# The default line is what a mate without its own override gets; a mate with one
# gets its own, and an unreadable pin is a per-mate refusal that keeps the
# running agent instead of migrating it onto whatever the default says today.
test_remote_restart_lands_on_the_per_mate_pin() {
  local dir out rc relaunch_line
  dir=$(new_case matepin)
  setup_remote_case "$dir" sm2 ok
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm2.status"
  printf 'codex big-model high\nmate sm2: pi mate-model max\n' > "$dir/home/config/secondmate-harness"

  out=$(run_restart "$dir" sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "a mate with its own override should restart onto it"$'\n'"$out"
  relaunch_line=$(grep '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" | head -1)
  [ "$relaunch_line" = "fm-remote-secondmate-control.sh relaunch sm2 pi mate-model max" ] \
    || fail "the mate's own override did not reach the host relaunch: $relaunch_line\n$out"
  pass "T6a a remote mate with a per-mate override restarts onto that override, not the default pin"
}

test_remote_restart_uses_the_default_for_an_unpinned_mate() {
  local dir out rc relaunch_line
  dir=$(new_case matenopin)
  setup_remote_case "$dir" sm2 ok
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm2.status"
  printf 'codex big-model high\nmate some-other-mate: muse other-model low\n' > "$dir/home/config/secondmate-harness"

  out=$(run_restart "$dir" sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "a mate with no override should restart onto the default pin"$'\n'"$out"
  relaunch_line=$(grep '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" | head -1)
  [ "$relaunch_line" = "fm-remote-secondmate-control.sh relaunch sm2 codex big-model high" ] \
    || fail "an unpinned mate did not resolve the default pin: $relaunch_line\n$out"
  pass "T6b a remote mate with no override line still restarts onto the default pin"
}

# The restart half of the opt-in scope: a pin file that declares no
# "mate <id>:" line is read exactly as it was before that grammar existed, so a
# second default line and a fourth token must not stop the restart. The mate
# still restarts onto the first line's runtime.
test_remote_restart_with_a_legacy_pin_file_uses_the_first_line() {
  local dir out rc relaunch_line
  dir=$(new_case matelegacypin)
  setup_remote_case "$dir" sm2 ok
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm2.status"
  printf 'codex big-model high extra\ngrok other-model low\n' > "$dir/home/config/secondmate-harness"

  out=$(run_restart "$dir" sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "a legacy pin file must not refuse a restart"$'\n'"$out"
  relaunch_line=$(grep '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" | head -1)
  [ "$relaunch_line" = "fm-remote-secondmate-control.sh relaunch sm2 codex big-model high" ] \
    || fail "the restart did not use the first line of the legacy pin: $relaunch_line\n$out"
  pass "T6d a legacy pin file still restarts the mate onto its first line"
}

test_remote_restart_refuses_an_unreadable_per_mate_pin() {
  local dir out rc
  dir=$(new_case matebadpin)
  setup_remote_case "$dir" sm2 ok
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm2.status"
  printf 'codex big-model high\nmate sm2: pi mate-model max\nmate sm2: muse other-model low\n' > "$dir/home/config/secondmate-harness"

  out=$(run_restart "$dir" sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 3 "$rc" "an unreadable pin is a fallback, never a claimed reload"$'\n'"$out"
  assert_contains "$out" "its configured runtime pin could not be read" \
    "the per-mate refusal must name what could not be resolved"
  assert_contains "$out" "line 3" "the per-mate refusal must carry the pin file's line number"
  assert_contains "$out" "summary: 0 of 1 restarted" "an unreadable pin must not be reported as a reload"
  [ -z "$(grep '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" || true)" ] \
    || fail "a mate with an unreadable pin must not be restarted over the transport hop"
  pass "T6c an unreadable per-mate pin falls back to the re-read path with its agent left running"
}

# --- T7: an unreachable host is unknown, never a claimed reload --------------
test_unreachable_host_is_reported_unknown() {
  local dir out rc
  dir=$(new_case unreachable)
  setup_remote_case "$dir" sm3 unreachable

  out=$(run_restart "$dir" sm3); rc=$?

  expect_code 3 "$rc" "an unreachable host must not be reported as a reload"$'\n'"$out"
  assert_not_contains "$out" "restarted: sm3" "an unreachable host must not be claimed as restarted"
  assert_contains "$out" "sm3:" "the unreachable mate must still be named"
  assert_contains "$out" "could not be delivered" "an unreachable host must be reported as undelivered, not as reloaded"
  pass "T7 an unreachable host is reported honestly instead of claimed as reloaded"
}

# --- T8: a local restart lands on this home's durable pin, and says which -----
test_local_restart_uses_the_home_pin_and_reports_what_ran() {
  local dir out rc
  dir=$(new_case pin)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'codex\n' > "$dir/home/config/secondmate-harness"
  printf 'codex' > "$dir/fake/becomes"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a pinned local restart should succeed"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (codex)" \
    "the restart should land on this home's pin and report the runtime that actually came up"
  [ "$(grep '^harness=' "$dir/home/state/sm1.meta" | tail -1)" = "harness=codex" ] \
    || fail "the durable record did not follow the replacement onto the pinned runtime"
  pass "T8 a local restart re-resolves this home's pin and reports the runtime that came up"
}

test_native_ultra_restart_keeps_local_and_remote_profiles() {
  local dir out rc relaunch_line
  dir=$(new_case native-local)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'pi codex-native/gpt-6-astra ultra\n' > "$dir/home/config/secondmate-harness"
  printf 'pi' > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  out=$(run_restart "$dir" sm1); rc=$?
  expect_code 0 "$rc" "native local restart failed: $out"
  assert_contains "$out" "restarted: sm1 (pi)" "native local restart did not complete"
  assert_contains "$(cat "$dir/home/state/sm1.meta")" "effort=ultra" "local restart dropped native effort"
  assert_contains "$(cat "$dir/fake/literal")" "--codex-effort 'ultra'" "local restart dropped native launch flag"

  dir=$(new_case native-remote)
  setup_remote_case "$dir" sm2 ok
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm2.status"
  printf 'pi-signed codex-native/gpt-6-astra ultra\n' > "$dir/home/config/secondmate-harness"
  out=$(run_restart "$dir" sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS
  expect_code 0 "$rc" "native remote restart failed: $out"
  relaunch_line=$(grep '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" | head -1)
  [ "$relaunch_line" = "fm-remote-secondmate-control.sh relaunch sm2 pi-signed codex-native/gpt-6-astra ultra" ] \
    || fail "remote restart dropped native profile: $relaunch_line"
  pass "native Ultra survives local restart and the remote restart transport"
}

# --- T9: an unrelated concurrent reply cannot release the persist gate -------
test_concurrent_reply_cannot_release_persist_gate() {
  local dir out rc state corr rec
  dir=$(new_case correlation)
  add_local_mate "$dir" sm1
  state="$dir/home/state"
  corr=ffffffffffffffff
  rec="$state/pending-replies/$corr"
  cat > "$dir/fake/on-doorbell" <<SH
#!/usr/bin/env bash
[ ! -e "$dir/fake/concurrent-created" ] || exit 0
: > "$dir/fake/concurrent-created"
mkdir -p "$state/pending-replies"
cat > "$rec" <<EOF
phase=awaiting_report
task_id=sm1
parent_status=$state/sm1.status
parent_status_scan_signature=
delivered_epoch=1
resolved_epoch=
resolved_via=
EOF
printf 'done [corr=$corr]: unrelated request answered\n' >> "$state/sm1.status"
SH
  chmod +x "$dir/fake/on-doorbell"

  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unrelated concurrent answer must not release the persist gate"$'\n'"$out"
  assert_not_contains "$out" "restarted: sm1" "the unrelated answer authorized a restart"
  assert_no_grep '^/exit$' "$dir/fake/literal" "the unrelated answer stopped the mate"
  pass "T9 the persist gate retains its explicitly allocated correlation"
}

# --- T10: one unanswered mate does not hold a confirmed mate behind it -------
test_persist_waits_are_polled_together() {
  local dir out rc exit_line nudge_line
  dir=$(new_case concurrent-waits)
  add_local_mate "$dir" sm1
  add_local_mate "$dir" sm2
  arm_answer "$dir" sm2

  out=$(FM_TEST_PERSIST_WAIT=3 run_restart "$dir" sm1 sm2); rc=$?

  expect_code 3 "$rc" "the unanswered mate should fall back after the confirmed mate restarts"$'\n'"$out"
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  nudge_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | tail -1 | cut -d: -f1)
  [ -n "$exit_line" ] && [ -n "$nudge_line" ] && [ "$exit_line" -lt "$nudge_line" ] \
    || fail "the first mate's timeout held the confirmed second mate behind it: $out"
  pass "T10 pending persist answers are polled as one fleet"
}

# --- T11: a failed post-stop relaunch is not described as a nudge ------------
test_post_stop_failure_is_reported_unreached() {
  local dir out rc
  dir=$(new_case post-stop)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'zsh' > "$dir/fake/becomes"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a post-stop relaunch failure must remain accounted for"$'\n'"$out"
  assert_contains "$out" "unreached: sm1:" "a stopped mate must be reported as unreached"
  assert_contains "$out" "restart outcome is unknown" "the report must not attribute the failed lifecycle operation"
  assert_not_contains "$out" "nudged: sm1" "a durable enqueue must not masquerade as a running mate's nudge"
  assert_contains "$out" "summary: 0 of 1 restarted, 0 nudged, 1 unreached" \
    "the summary must not claim that a stopped mate remains on older instructions with a message"
  pass "T11 post-stop restart failure is never misreported as a nudge"
}

# --- T12: relaunch work does not stop polling other persist answers ----------
test_relaunches_do_not_block_persist_polling() {
  local dir out rc
  dir=$(new_case relaunch-polling)
  setup_remote_case "$dir" sm1 slow-relaunch
  add_local_mate "$dir" sm2
  printf -- '- sm2 - local domain (home: %s; scope: things; projects: p; added 2026-09-03)\n' \
    "$dir/sm2-home" >> "$dir/home/data/secondmates.md"
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm1.status"
  arm_answer "$dir" sm2

  out=$(FM_TEST_PERSIST_WAIT=5 run_restart "$dir" sm1 sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "both confirmed mates should restart independently"$'\n'"$out"
  assert_present "$dir/fake/local-relaunch-during-remote" \
    "the slow first relaunch blocked lifecycle progress for the second mate"
  assert_contains "$out" "summary: 2 of 2 restarted, 0 nudged, 0 unreached" \
    "parallel relaunches were not both accounted for"
  assert_grep 'fm-remote-secondmate-control.sh relaunch sm1 claude default default' "$dir/ssh.log" \
    "an absent remote model and effort pin were not expressed as explicit defaults"
  pass "T12 relaunch waits do not block fleet persistence polling"
}

# --- T13: a worker that cannot publish its result cannot hang the pass -------
test_unpublished_worker_result_is_accounted_for() {
  local dir out rc_file driver i result_dir
  dir=$(new_case worker-result)
  setup_remote_case "$dir" sm1 slow-relaunch
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm1.status"
  out="$dir/restart.out"
  rc_file="$dir/restart.rc"

  ( run_restart "$dir" sm1 > "$out" 2>&1; printf '%s\n' "$?" > "$rc_file" ) &
  driver=$!
  result_dir=
  i=0
  while [ "$i" -lt 200 ]; do
    result_dir=$(find "$dir/home/state" -maxdepth 1 -type d -name '.secondmate-restart.*' -print -quit)
    [ -e "$dir/fake/remote-relaunch-start" ] && [ -n "$result_dir" ] && break
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -n "$result_dir" ] || { kill "$driver" 2>/dev/null || true; fail "restart result directory never appeared"; }
  rm -rf -- "$result_dir"
  i=0
  while kill -0 "$driver" 2>/dev/null && [ "$i" -lt 400 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  if kill -0 "$driver" 2>/dev/null; then
    kill "$driver" 2>/dev/null || true
    wait "$driver" 2>/dev/null || true
    fail "a terminated restart worker left the parent hung"
  fi
  wait "$driver" 2>/dev/null || true
  unset FM_FAKE_ANSWER_STATUS

  [ "$(cat "$rc_file")" = 3 ] || fail "an unpublished worker result did not fail as accounted"
  assert_contains "$(cat "$out")" "restart worker exited before publishing an outcome" \
    "the missing worker result was not reported"
  assert_contains "$(cat "$out")" "summary: 0 of 1 restarted, 0 nudged, 1 unreached" \
    "the missing worker result was not included in the summary"
  pass "T13 a dead restart worker cannot hang the parent"
}

# --- T14: result publication after the first probe remains authoritative -----
test_result_published_while_reaping_is_honored() {
  local dir out rc
  dir=$(new_case result-race)
  setup_remote_case "$dir" sm1 slow-relaunch
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm1.status"
  cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ -e "$FM_FAKE_DIR/remote-relaunch-start" ] && [ ! -e "$FM_FAKE_DIR/result-race-injected" ]; then
  result=$(find "$FM_HOME/state" -maxdepth 2 -name '0.result' -print -quit)
  if [ -z "$result" ]; then
    result_dir=$(find "$FM_HOME/state" -maxdepth 1 -type d -name '.secondmate-restart.*' -print -quit)
    if [ -n "$result_dir" ]; then
      printf 'restarted: sm1 on remote-mac (claude)\n' > "$result_dir/0.result"
      : > "$FM_FAKE_DIR/result-race-injected"
      printf 'Z\n'
      exit 0
    fi
  fi
fi
exec /bin/ps "$@"
SH
  chmod +x "$dir/fakebin/ps"

  out=$(run_restart "$dir" sm1); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "a result published while the worker is reaped must remain authoritative"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 on remote-mac (claude)" \
    "the result published during the reap window was replaced with a worker failure"
  assert_not_contains "$out" "exited before publishing" \
    "the parent failed to recheck the worker result after wait"
  pass "T14 a result published during reaping is honored"
}

# --- T15: an already-current mate still restarts, end to end -----------------
# The SSHHIP regression, driven through BOTH real commands rather than either
# one's own idea of the other. The mate's home needs no fast-forward at all, so
# the old instruction-diff classifier left it out of every action set and its
# agent kept running the launch-time wiring it started with. The update pass must
# now name it, and the restart pass must then persist its open records and only
# afterwards replace the agent.
test_already_current_mate_restarts_end_to_end() {
  local dir out restart_line ids rc head_before head_after doorbell_line exit_line
  dir=$(new_case already-current)
  add_repo_backed_mate "$dir" sm1
  arm_answer "$dir" sm1
  head_before=$(git -C "$dir/sm1-home" rev-parse HEAD)

  out=$(run_update_in_case "$dir")

  assert_contains "$out" "secondmate sm1: already current" \
    "the fixture must model a home that needs no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  assert_contains "$restart_line" "fm-sm1" \
    "an already-current live second mate must still be named for restart"
  assert_contains "$out" "nudge-secondmates: none" \
    "a mate named for restart must not also be steered"

  ids=${restart_line#restart-secondmates: }
  # shellcheck disable=SC2086
  out=$(run_restart "$dir" $ids); rc=$?

  expect_code 0 "$rc" "the mate named by the update pass did not restart"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "an already-current mate must actually be replaced"
  assert_contains "$out" "summary: 1 of 1 restarted, 0 nudged, 0 unreached" \
    "the pass must report the reload it performed"
  # Persist strictly before replace, read off the pane transcript.
  doorbell_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | head -1 | cut -d: -f1)
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  [ -n "$doorbell_line" ] || fail "the persist request never reached the already-current mate"
  [ -n "$exit_line" ] || fail "the already-current mate was never stopped, so it was not restarted"
  [ "$doorbell_line" -lt "$exit_line" ] \
    || fail "the agent was stopped before it was asked to persist (persist line $doorbell_line, exit line $exit_line)"
  # Nothing about the home's git state was touched to buy that restart.
  head_after=$(git -C "$dir/sm1-home" rev-parse HEAD)
  [ "$head_after" = "$head_before" ] || fail "the already-current home's checkout moved"
  [ -z "$(git -C "$dir/sm1-home" status --porcelain)" ] \
    || fail "the restart left the mate's home dirty"
  pass "T15 an already-current live mate is named by the update pass and genuinely restarted"
}

# --- T16: an already-current mate that cannot prove a restart stays honest ----
# Same already-current home, a runtime with no recovery-grade state classifier.
# Unconditional restart must not become an unconditional CLAIM of one: the update
# pass routes it to the re-read steer, and the restart pass reports a nudge with
# the agent still running.
test_already_current_unprovable_mate_stays_on_the_nudge_path() {
  local dir out rc restart_line nudge_line before
  dir=$(new_case already-current-unprovable)
  # zellij can never establish "the old agent stopped and the replacement came up".
  add_repo_backed_mate "$dir" sm1 claude zellij
  arm_answer "$dir" sm1
  before=$(cat "$dir/fake/command")

  out=$(run_update_in_case "$dir")

  assert_contains "$out" "secondmate sm1: already current" \
    "the fixture must model a home that needs no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_not_contains "$restart_line" "sm1" \
    "a mate whose restart cannot be proven must stay out of the restart set"
  assert_contains "$nudge_line" "fm-sm1" \
    "a live mate that cannot be restarted must keep the honest re-read steer"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unprovable restart must not report success"$'\n'"$out"
  assert_contains "$out" "nudged: sm1:" "the fallback must be reported as a nudge"
  assert_not_contains "$out" "restarted: sm1" "an unprovable mate must never be reported as reloaded"
  [ "$(cat "$dir/fake/command")" = "$before" ] \
    || fail "the unprovable mate's agent was stopped anyway"
  assert_no_grep '^/exit$' "$dir/fake/literal" "nothing may be stopped on the nudge path"
  pass "T16 an already-current mate with an unprovable runtime keeps the honest nudge path"
}

# --- T17: a T3 mate has no replacement to launch, so it keeps the nudge -------
# T3 proves its agent's state, but its thread keeps the conversation across
# turns, so the control plane refuses a relaunch onto it before stopping
# anything. The update pass must route a live T3 mate to the re-read steer, and
# the restart pass must deliver the re-read message on its thread without first
# asking it to persist for a restart that can never come.
test_t3_mate_stays_on_the_nudge_path() {
  local dir out rc restart_line nudge_line sends
  dir=$(new_case t3-mate)
  add_repo_backed_mate "$dir" sm1 claude t3code
  printf 't3_thread_id=thread-sm1\nt3_project_id=proj-1\n' >> "$dir/home/state/sm1.meta"
  fm_fake_exit0 "$dir/fakebin" treehouse
  t3_fake_start "$dir/t3-server"
  t3_fake_case "$dir/t3"
  FM_T3_HOME="$dir/sm1-home" t3_fake_set '
w = { tokens: [],
  projects: [{ id: "proj-1", title: "sm1-home", workspaceRoot: process.env.FM_T3_HOME, deletedAt: null,
    defaultModelSelection: { instanceId: "claudeAgent", model: "claude-sonnet-5" } }],
  threads: { "thread-sm1": { threadId: "thread-sm1", projectId: "proj-1", status: "idle", activeRunId: null,
    archived: false, worktreePath: null, pendingRequestCount: 0, providerInstanceId: "claudeAgent",
    runtimeMode: "full-access", parentThreadId: null, items: [], runs: [] } } };'
  t3_fake_credential "$dir/home/config/t3code-token"
  arm_answer "$dir" sm1

  out=$(run_update_in_case "$dir")

  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_not_contains "$restart_line" "sm1" \
    "a T3 mate, which cannot be given a replacement agent, must stay out of the restart set"
  assert_contains "$nudge_line" "fm-sm1" \
    "a live T3 mate must keep the re-read steer"

  out=$(run_restart "$dir" sm1); rc=$?
  sends=$(t3_fake_calls t3_thread_send)
  t3_fake_stop

  expect_code 3 "$rc" "a T3 mate must not report a reload"$'\n'"$out"
  assert_contains "$out" "nudged: sm1: its runtime cannot launch a replacement agent (backend t3code)" \
    "the T3 mate must be nudged, naming the runtime limit"
  assert_not_contains "$out" "restarted: sm1" "a T3 mate must never be reported as restarted"
  assert_contains "$out" "summary: 0 of 1 restarted, 1 nudged, 0 unreached" \
    "the pass must count the T3 mate as nudged"
  assert_no_grep 'Open-record persistence' "$dir/home/state/sm1.inbox/001.msg" \
    "a T3 mate should not be asked to persist for a restart that cannot come"
  assert_grep 're-read your AGENTS.md' "$dir/home/state/sm1.inbox/001.msg" \
    "the T3 mate should be handed the ordinary re-read message"
  [ "$(printf '%s\n' "$sends" | grep -c .)" = 1 ] \
    || fail "the T3 thread should receive exactly the one re-read doorbell, got: $sends"
  assert_contains "$sends" "Firstmate instruction waiting" \
    "the re-read doorbell must reach the T3 thread"
  [ "$(t3_fake_mutations)" = t3_thread_send ] \
    || fail "nothing but the doorbell may reach the T3 thread, got '$(t3_fake_mutations)'"
  pass "T17 a T3 mate is routed to the re-read message by both passes, never restarted"
}

# Pause/resume reuses the same executable lifecycle paths as restart. These
# cases are synthetic session-provider tests; they do not use a Herdr server.
clean_pause_home() {
  local dir=$1 id=$2 home="$1/$2-home"
  printf '/state/\n/data/\n/config/\n/projects/\n.fm-secondmate-home\n' > "$home/.gitignore"
  git -C "$home" add -A
  git -C "$home" commit -qm 'seed fixture home'
}

test_pause_authorizes_before_publishing_intent() {
  local dir out rc placement
  for placement in local remote; do
    dir=$(new_case "pause-lease-$placement")
    if [ "$placement" = local ]; then
      add_local_mate "$dir" sm1
      clean_pause_home "$dir" sm1
    else
      setup_remote_case "$dir" sm1 ok
    fi
    printf '%s\n' "$$" > "$dir/home/state/.lock"
    printf 'branch\t%s\t123\n' "$$" > "$dir/home/state/.lease-sm1"
    out=$(FM_SUPERVISION_ACTOR=main run_restart "$dir" --pause sm1); rc=$?
    expect_code 6 "$rc" "pause must honor $placement branch authority"$'\n'"$out"
    assert_absent "$dir/home/state/.secondmate-paused-sm1" 'authorization refusal must not publish pause intent'
    assert_no_grep '/exit' "$dir/fake/literal" 'authorization refusal must not stop the agent'
    if [ "$placement" = remote ]; then
      assert_no_grep ' pause ' "$dir/ssh.log" 'authorization refusal must not contact the host'
      printf '1\n' > "$dir/home/state/.secondmate-paused-sm1"
      out=$(FM_SUPERVISION_ACTOR=main run_restart "$dir" --resume sm1); rc=$?
      expect_code 6 "$rc" "remote resume must honor parent lease authority"$'\n'"$out"
      out=$(env FM_SUPERVISION_ACTOR=main FM_HOME="$dir/home" FM_SSH_BIN="$FM_TEST_SSH_BIN" \
        "$ROOT/bin/fm-remote-secondmate-relaunch.sh" sm1 claude default default resume 2>&1); rc=$?
      expect_code 6 "$rc" "direct remote resume must honor parent lease authority"$'\n'"$out"
      assert_present "$dir/home/state/.secondmate-paused-sm1" 'lease refusal retains pause'
      [ ! -s "$dir/ssh.log" ] || fail 'unauthorized resume performed remote convergence or launch'
    fi
  done
  unset FM_TEST_SSH_BIN FM_FAKE_SSH_MODE
  pass 'local and remote pause authorize before publishing intent'
}

test_pause_control_contention_keeps_the_mate_unpaused() {
  local dir out rc
  dir=$(new_case pause-control-contention)
  add_local_mate "$dir" sm1
  clean_pause_home "$dir" sm1
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock="$FM_HOME/state/.control-sm1.lock"
    fm_lock_try_acquire "$lock" || exit 99
    "$1/bin/fm-secondmate-restart.sh" --pause sm1
    rc=$?
    fm_lock_release "$lock"
    exit "$rc"
  ' _ "$ROOT" 2>&1); rc=$?
  expect_code 3 "$rc" "control contention is a pre-stop refusal"$'\n'"$out"
  assert_absent "$dir/home/state/.secondmate-paused-sm1" 'control contention must not publish false pause state'
  assert_no_grep '/exit' "$dir/fake/literal" 'control contention must not stop the agent'
  pass 'a busy control lock refuses pause without leaving false intent'
}

test_maintenance_cannot_resume_or_race_pause() {
  local dir out rc message
  dir=$(new_case pause-maintenance)
  add_local_mate "$dir" sm1
  clean_pause_home "$dir" sm1
  out=$(run_restart "$dir" --pause sm1); rc=$?
  expect_code 0 "$rc" "pause before maintenance"$'\n'"$out"
  for message in 're-read AGENTS.md and inherited config' 'persist open work for update' 'reconcile your backlog' 'repost your missed report'; do
    out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
      "$ROOT/bin/fm-send.sh" sm1 "$message" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail 'maintenance was accepted by a paused mate'
    assert_present "$dir/home/state/.secondmate-paused-sm1" 'maintenance must preserve pause'
    assert_absent "$dir/home/state/sm1.inbox" 'maintenance must not queue a nudge while paused'
  done
  out=$(run_restart "$dir" --resume sm1); rc=$?
  expect_code 0 "$rc" "resume before lifecycle exclusion check"$'\n'"$out"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock="$FM_HOME/state/.secondmate-liveness-sm1.lock"
    fm_lock_try_acquire "$lock" || exit 99
    "$1/bin/fm-send.sh" sm1 "re-read config"
    rc=$?
    fm_lock_release "$lock"
    exit "$rc"
  ' _ "$ROOT" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail 'maintenance bypassed a lifecycle action already in progress'
  assert_contains "$out" 'lifecycle is busy' 'the maintenance send observes lifecycle ownership'
  for message in "$dir/home/state/sm1.inbox"/*.msg; do
    [ ! -e "$message" ] || fail 'a concurrent lifecycle action allowed final maintenance delivery'
  done
  pass 'maintenance preserves pause and final delivery obeys lifecycle exclusion'
}

test_pause_after_persist_prevents_update_replacement() {
  local dir out rc
  dir=$(new_case pause-after-persist)
  add_local_mate "$dir" sm1
  clean_pause_home "$dir" sm1
  cat > "$dir/fake/on-doorbell" <<'SH'
#!/usr/bin/env bash
(
  . "$FM_TEST_ROOT/bin/fm-wake-lib.sh"
  lock="$FM_HOME/state/.secondmate-liveness-sm1.lock"
  fm_lock_acquire_wait "$lock" || exit 1
  fm_lock_release "$lock"
  "$FM_TEST_ROOT/bin/fm-secondmate-restart.sh" --pause sm1 || exit 1
  corr=$(grep -oE 'corr=[0-9a-f]{16}' "$FM_HOME/state/sm1.inbox"/*.msg | head -1)
  printf 'done [%s]: persisted\n' "$corr" >> "$FM_HOME/state/sm1.status"
) > "$FM_FAKE_DIR/concurrent-pause.log" 2>&1 &
SH
  chmod +x "$dir/fake/on-doorbell"
  out=$(FM_TEST_ROOT="$ROOT" run_restart "$dir" sm1); rc=$?
  expect_code 0 "$rc" "update must skip a mate paused after persistence delivery"$'\n'"$out"$'\n'"$(cat "$dir/fake/concurrent-pause.log" 2>/dev/null)"
  assert_contains "$out" 'skipped: sm1 intentionally paused' 'the final replacement checks pause under the lifecycle lock'
  assert_present "$dir/home/state/.secondmate-paused-sm1" 'update preserves the concurrent pause'
  assert_absent "$dir/home/state/sm1.control-relaunch" 'update must not replace a paused mate'
  pass 'pause after persistence delivery excludes the update replacement'
}

test_pause_refuses_live_and_stopped_unlanded_children() {
  local dir out rc kind
  for kind in live stopped-unlanded; do
    dir=$(new_case "pause-$kind")
    add_local_mate "$dir" sm1
    clean_pause_home "$dir" sm1
    printf 'kind=ship\nworktree=%s\n' "$dir/child" > "$dir/sm1-home/state/child.meta"
    [ "$kind" != stopped-unlanded ] || printf 'done: awaiting landing\n' > "$dir/sm1-home/state/child.status"
    out=$(run_restart "$dir" --pause sm1); rc=$?
    expect_code 3 "$rc" "pause must refuse $kind child work"$'\n'"$out"
    assert_contains "$out" 'in-flight or unlanded work' 'refusal names the safety boundary'
    assert_absent "$dir/home/state/.secondmate-paused-sm1" 'unsafe pause must leave no intent marker'
    assert_no_grep '/exit' "$dir/fake/literal" 'unsafe pause must not stop the agent'
  done
  pass 'pause refuses both live workers and stopped workers awaiting landing'
}

test_explicit_pause_and_resume() {
  local dir out rc
  dir=$(new_case pause-resume)
  add_local_mate "$dir" sm1
  clean_pause_home "$dir" sm1
  out=$(run_restart "$dir" --pause sm1); rc=$?
  expect_code 0 "$rc" "safe pause succeeds"$'\n'"$out"
  assert_contains "$out" 'paused: sm1' 'pause is reported'
  assert_present "$dir/home/state/.secondmate-paused-sm1" 'pause survives a new command process'
  assert_present "$dir/home/state/sm1.meta" 'pause retains the route'
  assert_present "$dir/sm1-home" 'pause retains the home'
  assert_grep '/exit' "$dir/fake/literal" 'pause stops the agent through control'
  out=$(run_restart "$dir" --pause sm1); rc=$?
  expect_code 0 "$rc" 'repeated pause is idempotent'
  out=$(run_restart "$dir" sm1); rc=$?
  expect_code 0 "$rc" 'update restart skips a paused mate'
  assert_contains "$out" 'intentionally paused' 'update reports the skip'
  assert_absent "$dir/home/state/sm1.inbox" 'skipped restart sends no persistence or reread nudge'
  out=$(run_restart "$dir" --resume sm1); rc=$?
  expect_code 0 "$rc" "explicit resume succeeds"$'\n'"$out"
  assert_contains "$out" 'resumed: sm1' 'resume is reported'
  assert_absent "$dir/home/state/.secondmate-paused-sm1" 'confirmed resume clears pause intent'
  assert_present "$dir/home/state/sm1.control-relaunch" 'resume uses the ordinary relaunch transaction'
  out=$(run_restart "$dir" --resume sm1); rc=$?
  expect_code 0 "$rc" 'repeated resume is idempotent'
  pass 'explicit pause and resume preserve the home and use verified lifecycle owners'
}

test_routed_backlog_resumes_paused_mate() {
  command -v tasks-axi >/dev/null 2>&1 || { echo 'skip: tasks-axi not found'; return; }
  local dir out rc
  dir=$(new_case pause-handoff)
  add_local_mate "$dir" sm1
  clean_pause_home "$dir" sm1
  printf -- '- sm1 - domain (home: %s; scope: things; projects: p; added 2026-09-03)\n' \
    "$dir/sm1-home" > "$dir/home/data/secondmates.md"
  printf '# Backlog\n\n## Queued\n\n- [ ] routed - new work (repo: p; added 2026-10-29)\n\n## In flight\n\n## Done\n' > "$dir/home/data/backlog.md"
  printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$dir/sm1-home/data/backlog.md"
  out=$(run_restart "$dir" --pause sm1); rc=$?
  expect_code 0 "$rc" "pause before handoff"$'\n'"$out"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SUPERVISION_ACTOR=main \
    FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$ROOT/bin/fm-backlog-handoff.sh" sm1 routed 2>&1); rc=$?
  expect_code 0 "$rc" "backlog handoff resumes its paused receiver"$'\n'"$out"
  assert_grep 'routed -' "$dir/sm1-home/data/backlog.md" 'work is queued in the mate backlog'
  assert_no_grep 'routed -' "$dir/home/data/backlog.md" 'the parent does not retain dispatchable work'
  assert_absent "$dir/home/state/.secondmate-paused-sm1" 'routing automatically resumes the mate'
  assert_present "$dir/home/state/sm1.control-relaunch" 'routing relaunches through the lifecycle owner'
  assert_present "$dir/home/state/sm1.inbox" 'routed work reaches the ordinary durable inbox'
  pass 'backlog handoff queues work and automatically resumes a paused receiver'
}

test_remote_pause_resume_and_unknown_transport() {
  local dir out rc sync_line inherit_line resume_line
  dir=$(new_case remote-pause)
  setup_remote_case "$dir" sm1 ok
  fm_git_init_commit "$dir/primary"
  mkdir -p "$dir/primary/bin"
  cp "$ROOT/bin/fm-remote-secondmate-control.sh" "$ROOT/bin/fm-remote-inherit.sh" "$dir/primary/bin/"
  git -C "$dir/primary" add bin
  git -C "$dir/primary" commit -qm 'seed tracked remote commands'
  printf 'codex\n' > "$dir/home/config/crew-harness"
  export FM_FAKE_REMOTE_HOME="$dir/remote-home"
  mkdir -p "$FM_FAKE_REMOTE_HOME"
  out=$(run_restart "$dir" --pause sm1); rc=$?
  expect_code 0 "$rc" "remote pause uses transport"$'\n'"$out"
  assert_grep 'fm-remote-secondmate-control.sh pause sm1' "$dir/ssh.log" 'remote pause stays on its host'
  assert_present "$dir/home/state/.secondmate-paused-sm1" 'parent retains durable remote pause intent'
  rm -f "$dir/home/state/.secondmate-paused-sm1"
  out=$(FM_FAKE_SSH_MODE=prestop-refusal run_restart "$dir" --pause sm1); rc=$?
  expect_code 3 "$rc" 'a proven remote pre-stop refusal is distinct from lost completion'
  assert_absent "$dir/home/state/.secondmate-paused-sm1" 'remote pre-stop refusal clears newly published intent'
  out=$(run_restart "$dir" --pause sm1); rc=$?
  expect_code 0 "$rc" 'remote pause can retry after a definite refusal'
  cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -n "${FM_TEST_PAUSE_MARKER:-}" ] && [ "$arg" = "$FM_TEST_PAUSE_MARKER" ]; then
    [ -e "$FM_HOME/state/.fm-lease-command.lock" ] || exit 99
    printf 'guard held\n' > "$FM_FAKE_DIR/resume-guard-held"
  fi
done
exec "$FM_TEST_REAL_RM" "$@"
SH
  chmod +x "$dir/fakebin/rm"
  out=$(FM_SUPERVISION_ACTOR=main FM_TEST_REAL_RM="$(command -v rm)" \
    FM_TEST_PAUSE_MARKER="$dir/home/state/.secondmate-paused-sm1" \
    FM_ROOT_OVERRIDE="$dir/primary" run_restart "$dir" --resume sm1); rc=$?
  expect_code 0 "$rc" "remote resume uses transport"$'\n'"$out"
  assert_grep 'fm-remote-secondmate-control.sh resume sm1 claude' "$dir/ssh.log" 'remote resume passes the parent profile'
  assert_absent "$dir/home/state/.secondmate-paused-sm1" 'confirmed remote resume clears intent'
  assert_present "$dir/fake/resume-guard-held" 'remote resume retains lease authority through marker removal'
  rm -f "$dir/fakebin/rm"
  [ "$(cat "$dir/remote-home/config/crew-harness")" = codex ] || fail 'remote resume did not refresh inherited config'
  sync_line=$(grep -n '^fm-remote-secondmate-control.sh sync sm1 ' "$dir/ssh.log" | head -1 | cut -d: -f1)
  inherit_line=$(grep -n '^fm-remote-inherit.sh put config/crew-harness ' "$dir/ssh.log" | head -1 | cut -d: -f1)
  resume_line=$(grep -n '^fm-remote-secondmate-control.sh resume sm1 ' "$dir/ssh.log" | head -1 | cut -d: -f1)
  [ -n "$sync_line" ] && [ -n "$inherit_line" ] && [ "$sync_line" -lt "$resume_line" ] && [ "$inherit_line" -lt "$resume_line" ] \
    || fail 'remote resume launched before instruction and config convergence'
  printf '1\n' > "$dir/home/state/.secondmate-paused-sm1"
  printf 'pi\n' > "$dir/home/config/crew-harness"
  : > "$dir/ssh.log"
  out=$(env PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/primary" FM_HOME="$dir/home" \
    FM_SSH_BIN="$FM_TEST_SSH_BIN" FM_SUPERVISION_ACTOR=main \
    "$ROOT/bin/fm-send.sh" sm1 --new-work 'new scoped work' 2>&1); rc=$?
  expect_code 0 "$rc" "remote routed work converges before resume"$'\n'"$out"
  [ "$(cat "$dir/remote-home/config/crew-harness")" = pi ] || fail 'routed resume did not refresh inherited config'
  assert_absent "$dir/home/state/.secondmate-paused-sm1" 'routed remote work resumes the mate'
  assert_grep 'fm-remote-secondmate-control.sh send-stdin sm1' "$dir/ssh.log" 'routed work reaches the host after resume'
  local mode
  for mode in sync-fail inherit-fail; do
    printf '1\n' > "$dir/home/state/.secondmate-paused-sm1"
    : > "$dir/ssh.log"
    export FM_FAKE_SSH_MODE=$mode
    out=$(FM_ROOT_OVERRIDE="$dir/primary" run_restart "$dir" --resume sm1); rc=$?
    [ "$rc" -ne 0 ] || fail "remote resume ignored $mode"
    assert_present "$dir/home/state/.secondmate-paused-sm1" 'failed convergence retains pause'
    assert_no_grep 'fm-remote-secondmate-control.sh resume ' "$dir/ssh.log" 'failed convergence must prevent launch'
  done
  export FM_FAKE_SSH_MODE=unreachable
  out=$(run_restart "$dir" --pause sm1); rc=$?
  expect_code 255 "$rc" 'unknown transport is not a confirmed pause'
  assert_present "$dir/home/state/.secondmate-paused-sm1" 'unknown pause completion suppresses liveness recovery'
  out=$(run_restart "$dir" --resume sm1); rc=$?
  [ "$rc" -ne 0 ] || fail 'unreachable resume must fail'
  assert_present "$dir/home/state/.secondmate-paused-sm1" 'failed resume preserves pause intent'
  unset FM_TEST_SSH_BIN FM_FAKE_SSH_MODE FM_FAKE_REMOTE_HOME
  pass 'remote pause and resume use host transport and preserve intent on unknown completion'
}

test_host_local_pause_refuses_children() {
  local dir home out rc
  dir=$(new_case remote-pause-child)
  add_local_mate "$dir" sm1
  clean_pause_home "$dir" sm1
  home="$dir/sm1-home"
  mkdir -p "$home/state/parent-route"
  printf 'kind=ship\n' > "$home/state/child.meta"
  cat > "$home/state/parent-route/sm1.meta" <<EOF
kind=secondmate
harness=claude
backend=herdr
herdr_session=fm-remote
herdr_workspace_id=ws1
herdr_tab_id=tab1
herdr_pane_id=2ndmate-sm1
window=fm-remote:2ndmate-sm1
endpoint_task_id=sm1
home=$home
worktree=$home
project=$home
EOF
  bash -c '. "$1/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "$2" sm1' _ \
    "$ROOT" "$home/state/parent-route/sm1.meta" || fail 'host fixture must pass endpoint validation'
  # A guard stub makes accidental Herdr access an immediate test failure. The
  # host-local safety refusal must occur before any lifecycle backend call.
  # shellcheck disable=SC2016 # Expanded by the guard stub when it runs.
  printf '#!/usr/bin/env bash\nprintf touched > "$FM_FAKE_DIR/herdr-called"\nexit 99\n' > "$dir/fakebin/herdr"
  chmod +x "$dir/fakebin/herdr"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" pause sm1 2>&1); rc=$?
  expect_code 3 "$rc" "host-local pause refuses children"$'\n'"$out"
  assert_contains "$out" 'in-flight or unlanded work' 'remote safety uses the shared preflight'
  assert_absent "$dir/fake/herdr-called" 'unsafe remote pause never calls Herdr'
  rm -f "$home/state/child.meta"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock="$FM_HOME/state/.task-set.lock"
    fm_lock_try_acquire "$lock" || exit 99
    "$1/bin/fm-remote-secondmate-control.sh" pause sm1
    rc=$?
    fm_lock_release "$lock"
    exit "$rc"
  ' _ "$ROOT" 2>&1); rc=$?
  expect_code 3 "$rc" "host task-set contention is a pre-stop refusal"$'\n'"$out"
  assert_absent "$home/state/parent-route/.secondmate-paused-sm1" 'host contention must leave no new pause record'
  assert_absent "$dir/fake/herdr-called" 'host contention must precede backend access'
  ln -s "$home/state/missing-record" "$home/state/child.meta"
  printf '1\n' > "$home/state/parent-route/.secondmate-paused-sm1"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" resume sm1 claude default default 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail 'host-local resume hid its control-plane refusal'
  assert_present "$home/state/parent-route/.secondmate-paused-sm1" 'host control failure preserves pause intent'
  assert_absent "$dir/fake/herdr-called" 'host checkpoint refusal must precede Herdr access'
  pass 'host-local pause and failed resume preserve in-flight work before backend access'
}

test_pause_refuses_orphan_backlog_dirty_home_and_spawn_race() {
  local dir out rc lock
  dir=$(new_case pause-safety)
  add_local_mate "$dir" sm1
  clean_pause_home "$dir" sm1
  printf '## In flight\n- [ ] orphan - still in flight (repo: p)\n\n## Queued\n\n## Done\n' > "$dir/sm1-home/data/backlog.md"
  out=$(run_restart "$dir" --pause sm1); rc=$?
  expect_code 3 "$rc" "orphan in-flight backlog refuses pause"$'\n'"$out"
  assert_contains "$out" 'in-flight backlog work' 'orphan refusal names the backlog'
  printf '## Queued\n\n## Done\n' > "$dir/sm1-home/data/backlog.md"
  printf 'uncommitted\n' >> "$dir/sm1-home/AGENTS.md"
  out=$(run_restart "$dir" --pause sm1); rc=$?
  expect_code 3 "$rc" 'uncommitted home work refuses pause'
  git -C "$dir/sm1-home" add AGENTS.md
  git -C "$dir/sm1-home" commit -qm 'fixture clean'
  # A concurrent spawn owns the existing home-wide task-set lock. Pause must
  # refuse before checking a snapshot that could miss its unpublished child.
  lock="$dir/sm1-home/state/.task-set.lock"
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  env FM_HOME="$dir/home" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$2" || exit 1
    printf ready > "$3"
    while [ ! -e "$4" ]; do sleep 0.1; done
    fm_lock_release "$2"
  ' _ "$ROOT" "$lock" "$dir/ready" "$dir/release" &
  local holder=$! i
  for ((i=0; i<100; i++)); do [ ! -e "$dir/ready" ] || break; sleep 0.1; done
  [ -e "$dir/ready" ] || fail 'fixture lock holder did not start'
  out=$(run_restart "$dir" --pause sm1); rc=$?
  : > "$dir/release"
  wait "$holder"
  [ "$rc" -ne 0 ] || fail 'pause raced a child spawn'
  assert_contains "$out" 'task set is busy' 'pause refuses a concurrently changing task set'
  assert_absent "$dir/home/state/.secondmate-paused-sm1" 'all safety refusals preserve running posture'
  assert_no_grep '/exit' "$dir/fake/literal" 'unsafe pauses never stop the agent'
  pass 'pause refuses orphan backlog work, dirty homes and concurrent child creation'
}

test_paused_current_state_and_failed_resume() {
  local dir out rc
  dir=$(new_case pause-current)
  add_local_mate "$dir" sm1
  clean_pause_home "$dir" sm1
  out=$(run_restart "$dir" --pause sm1); rc=$?
  expect_code 0 "$rc" "pause before current-state read"$'\n'"$out"
  out=$(FM_HOME="$dir/home" "$ROOT/bin/fm-crew-state.sh" sm1 2>&1); rc=$?
  expect_code 0 "$rc" "paused current state is readable"$'\n'"$out"
  assert_contains "$out" 'paused' 'current state reports intentional downtime'
  # Refusal from the ordinary control owner must retain the pause marker.
  printf 'unverified-adapter\n' > "$dir/home/config/secondmate-harness"
  out=$(run_restart "$dir" --resume sm1); rc=$?
  [ "$rc" -ne 0 ] || fail 'unsupported replacement must refuse'
  assert_present "$dir/home/state/.secondmate-paused-sm1" 'failed resume preserves pause intent'
  pass 'paused state is explicit and failed resume keeps the marker'
}

test_pause_authorizes_before_publishing_intent
test_pause_control_contention_keeps_the_mate_unpaused
test_maintenance_cannot_resume_or_race_pause
test_pause_after_persist_prevents_update_replacement
test_pause_refuses_orphan_backlog_dirty_home_and_spawn_race
test_paused_current_state_and_failed_resume

test_pause_refuses_live_and_stopped_unlanded_children
test_explicit_pause_and_resume
test_routed_backlog_resumes_paused_mate
test_remote_pause_resume_and_unknown_transport
test_host_local_pause_refuses_children

test_persist_gates_and_asks_only_for_open_records
test_persist_precedes_restart
test_working_pi_blank_composer_restarts
test_arrived_answer_precedes_deadline_check
test_only_done_persist_reply_releases_restart_gate
test_progress_then_success_releases_gate
test_unprovable_runtime_falls_back
test_unknown_mate_is_accounted_for
test_refused_restart_falls_back_without_claiming_a_reload
test_local_restart_uses_the_home_pin_and_reports_what_ran
test_native_ultra_restart_keeps_local_and_remote_profiles
test_remote_mate_restarts_over_the_transport_hop
test_remote_restart_lands_on_the_per_mate_pin
test_remote_restart_uses_the_default_for_an_unpinned_mate
test_remote_restart_with_a_legacy_pin_file_uses_the_first_line
test_remote_restart_refuses_an_unreadable_per_mate_pin
test_unreachable_host_is_reported_unknown
test_concurrent_reply_cannot_release_persist_gate
test_persist_waits_are_polled_together
test_post_stop_failure_is_reported_unreached
test_relaunches_do_not_block_persist_polling
test_unpublished_worker_result_is_accounted_for
test_result_published_while_reaping_is_honored
test_already_current_mate_restarts_end_to_end
test_already_current_unprovable_mate_stays_on_the_nudge_path
test_t3_mate_stays_on_the_nudge_path

echo "# all fm-secondmate-restart tests passed"
