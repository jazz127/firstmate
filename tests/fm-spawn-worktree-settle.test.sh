#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# A pane's foreground-cwd read can transiently report a stale, unrelated-but-real
# path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled foreground-cwd sequence with fake tmux/process tools and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds fake tmux and process tools whose foreground
# cwd returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_tty}"*) printf '%s\n' '/dev/pts/91'; exit 0 ;;
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    for arg in "$@"; do
      if [ "$arg" = 'treehouse get' ] && [ -n "${FM_FAKE_LOCK_PATH:-}" ]; then
        if [ -d "$FM_FAKE_LOCK_PATH" ]; then
          printf 'held\n' > "$FM_FAKE_LOCK_RESULT"
        else
          printf 'released\n' > "$FM_FAKE_LOCK_RESULT"
        fi
      fi
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-t pts/91"*) printf '%s\n' '987654321 987654321 987654321' ;;
esac
SH
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
n=0
[ -f "$countfile" ] && n=$(cat "$countfile")
n=$((n + 1))
printf '%s\n' "$n" > "$countfile"
if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
  path=${FM_FAKE_PANE_STALE:-}
else
  path=${FM_FAKE_PANE_PATH:-}
fi
[ -n "$path" ] || exit 1
printf 'p987654321\nfcwd\nn%s\n' "$path"
SH
  chmod +x "$fakebin/ps" "$fakebin/lsof"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_LOCK_PATH="${FM_FAKE_LOCK_PATH:-}" FM_FAKE_LOCK_RESULT="${FM_FAKE_LOCK_RESULT:-}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale foreground-cwd read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 4 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, the post-relock slot check, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

# Concurrent treehouse gets must not be serialized behind Firstmate's project
# lock. The fake terminal holds both panes at `treehouse get` until both calls
# arrive, then reports each task's isolated worktree. This drives the real
# fm-spawn entry point while the only Treehouse behavior is synthetic/offline.
make_concurrent_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_tty}"*) printf '%s\n' '/dev/pts/91'; exit 0 ;;
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{window_id}"*) printf '%s\n' "${FM_FAKE_WINDOW_ID:-@fake}"; exit 0 ;;
esac
case "${1:-}" in
  display-message)
    for arg in "$@"; do case "$arg" in *pane_tty*) printf '%s\n' '/dev/pts/91'; exit 0 ;; esac; done
    printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    for arg in "$@"; do
      if [ "$arg" = 'treehouse get' ]; then
        printf '%s\n' "${FM_FAKE_WINDOW_ID:?}" >> "${FM_FAKE_GETS:?}"
        if [ -e "${FM_FAKE_PROJECT_LOCK:?}" ] || [ -L "$FM_FAKE_PROJECT_LOCK" ]; then
          printf '%s\n' "$FM_FAKE_WINDOW_ID" >> "${FM_FAKE_LOCK_HELD_AT_GET:?}"
        fi
        for _ in $(seq 1 200); do
          [ "$(wc -l < "$FM_FAKE_GETS")" -ge 2 ] && exit 0
          /bin/sleep 0.01
        done
        exit 0
      fi
    done
    exit 0
    ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_test_fake_tmux_foreground_cwd "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse claude
  printf '%s\n' "$fakebin"
}

test_concurrent_spawns_reach_treehouse_get_without_project_lock() {
  local dir="$TMP_ROOT/concurrent" home1 home2 project wt1 wt2 fakebin gets lockheld lock id1 id2 out1 out2 rc1 rc2
  id1=settle-concurrent-a-z5
  id2=settle-concurrent-b-z6
  home1="$dir/home-root"
  home2="$dir/home-child"
  project="$dir/project"
  wt1="$dir/worktree-a"
  wt2="$dir/worktree-b"
  gets="$dir/treehouse-get-arrivals"
  lockheld="$dir/project-lock-held-at-get"
  out1="$dir/spawn-a.out"
  out2="$dir/spawn-b.out"
  mkdir -p "$dir"
  fm_test_spawn_home "$home1" claude
  fm_test_spawn_home "$home2" claude
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home1" \
    > "$home2/.fm-secondmate-parent"
  fm_test_spawn_brief "$home1" "$id1" "Exercise concurrent treehouse get for $id1."
  fm_test_spawn_brief "$home2" "$id2" "Exercise concurrent treehouse get for $id2."
  fm_git_worktree "$project" "$wt1" concurrent-a
  git -C "$project" worktree add --quiet -b concurrent-b "$wt2"
  fakebin=$(make_concurrent_fakebin "$dir/fake")
  : > "$gets"
  : > "$lockheld"
  lock=$(FM_HOME="$home1" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$project") \
    || fail "could not resolve the shared Treehouse project lock in the synthetic homes"

  FM_FAKE_GETS="$gets" FM_FAKE_PROJECT_LOCK="$lock" FM_FAKE_LOCK_HELD_AT_GET="$lockheld" FM_FAKE_WINDOW_ID=@concurrent-a \
    fm_test_run_spawn "$home1" "$wt1" "$fakebin" "$id1" "$project" --mode no-mistakes --yolo off > "$out1" 2>&1 &
  local pid1=$!
  FM_FAKE_GETS="$gets" FM_FAKE_PROJECT_LOCK="$lock" FM_FAKE_LOCK_HELD_AT_GET="$lockheld" FM_FAKE_WINDOW_ID=@concurrent-b \
    fm_test_run_spawn "$home2" "$wt2" "$fakebin" "$id2" "$project" --mode no-mistakes --yolo off > "$out2" 2>&1 &
  local pid2=$!
  wait "$pid1"; rc1=$?
  wait "$pid2"; rc2=$?

  [ "$rc1" -eq 0 ] || fail "first concurrent spawn failed (exit $rc1)"$'\n'"$(cat "$out1")"
  [ "$rc2" -eq 0 ] || fail "second concurrent spawn failed (exit $rc2)"$'\n'"$(cat "$out2")"
  [ "$(wc -l < "$gets")" -eq 2 ] || fail "only $(wc -l < "$gets") concurrent treehouse get calls reached the fake terminal"
  [ ! -s "$lockheld" ] || fail "Treehouse get ran while the shared project lock was held by $(cat "$lockheld")"
  assert_grep "worktree=$wt1" "$home1/state/$id1.meta" "first concurrent spawn did not record its own worktree"
  assert_grep "worktree=$wt2" "$home2/state/$id2.meta" "second concurrent spawn did not record its own worktree"
  pass "concurrent spawns reach treehouse get without holding the project lock"
}

# Releasing the project lock for treehouse get lets an exited task's teardown
# run in that window. Task A's worker has exited, so Treehouse hands A's slot to
# spawn B; while B waits on get, the real fm-teardown.sh for A still reads the
# slot claim as A's and returns the slot, which ends B's pane lease there. The
# second stable cwd read returns the slot during the unlocked get wait; B then
# must prove the slot still belongs to its pane after relocking, abandon it
# untouched, and fail rather than claim it.
make_returned_slot_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_tty}"*) printf '%s\n' '/dev/pts/91'; exit 0 ;;
  *"#{window_id}"*) printf '%s\n' '@returned'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    for arg in "$@"; do
      if [ "$arg" = 'treehouse get' ]; then
        slot=${FM_FAKE_SLOT:?}
        printf '%s\n' "$slot" > "${FM_FAKE_PANE_FILE:?}"
        : > "${FM_FAKE_PANE_COUNTFILE:?}"
        state="$(dirname "$(dirname "$slot")")/treehouse-state.json"
        printf '{"worktrees":[{"name":"1","path":"%s","leased":true}]}\n' "$slot" > "$state"
      fi
    done
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-t pts/91"*) printf '%s\n' '987654321 987654321 987654321'; exit 0 ;;
esac
PATH=${PATH#"$(dirname "$0")":} exec ps "$@"
SH
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-p 987654321"*) ;;
  *) PATH=${PATH#"$(dirname "$0")":} exec lsof "$@" ;;
esac
countfile="${FM_FAKE_PANE_COUNTFILE:?}"
n=0
[ -f "$countfile" ] && n=$(cat "$countfile")
n=$((n + 1))
printf '%s\n' "$n" > "$countfile"
path=$(cat "${FM_FAKE_PANE_FILE:?}" 2>/dev/null)
[ -n "$path" ] || exit 1
printf 'p987654321\nfcwd\nn%s\n' "$path"
[ "$n" -ne "${FM_FAKE_TEARDOWN_AT:?}" ] || "${FM_FAKE_TEARDOWN:?}" >> "${FM_FAKE_TEARDOWN_LOG:?}" 2>&1
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
if [ "${1:-}" = return ]; then
  printf '%s\n' "${FM_FAKE_PROJECT:?}" > "${FM_FAKE_PANE_FILE:?}"
fi
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/ps" "$fakebin/lsof" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" claude
  printf '%s\n' "$fakebin"
}

test_slot_returned_by_exited_task_teardown_during_get_is_abandoned() {
  local dir="$TMP_ROOT/returned-slot" home_b home_a project slot fakebin teardown out rc
  local id_a=settle-exited-a-z7 id_b=settle-returned-b-z8
  home_b="$dir/home-root"
  home_a="$dir/home-child"
  project="$dir/project"
  slot="$dir/pool/1/project"
  mkdir -p "$dir/pool/1"
  fm_test_spawn_home "$home_b" claude
  fm_test_spawn_home "$home_a" claude
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home_b" \
    > "$home_a/.fm-secondmate-parent"
  fm_test_spawn_brief "$home_b" "$id_b" "Exercise a slot returned during get for $id_b."
  fm_git_worktree "$project" "$slot" returned-slot
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot" > "$dir/pool/treehouse-state.json"
  printf 'task=%s\nhome=%s\n' "$id_a" "$home_a" > "$dir/pool/1/.fm-slot-owner"
  fm_write_meta "$home_a/state/$id_a.meta" \
    "window=firstmate:fm-$id_a" "endpoint_task_id=$id_a" \
    "worktree=$slot" "project=$project" "kind=scout"
  fakebin=$(make_returned_slot_fakebin "$dir/fake")
  teardown="$dir/teardown-a"
  cat > "$teardown" <<SH
#!/usr/bin/env bash
FM_HOME='$home_a' FM_STATE_OVERRIDE='$home_a/state' FM_DATA_OVERRIDE='$home_a/data' \\
  FM_PROJECTS_OVERRIDE='$home_a/projects' FM_CONFIG_OVERRIDE='$home_a/config' \\
  '$ROOT/bin/fm-teardown.sh' '$id_a' --force
SH
  chmod +x "$teardown"
  out="$dir/spawn-b.out"

  FM_FAKE_SLOT="$slot" FM_FAKE_PROJECT="$project" FM_FAKE_PANE_FILE="$dir/pane" \
    FM_FAKE_PANE_COUNTFILE="$dir/reads" FM_FAKE_TEARDOWN_AT=2 FM_FAKE_TEARDOWN="$teardown" \
    FM_FAKE_TEARDOWN_LOG="$dir/teardown-a.out" FM_FAKE_TREEHOUSE_LOG="$dir/treehouse.log" \
    fm_test_run_spawn "$home_b" "$project" "$fakebin" "$id_b" "$project" --mode no-mistakes --yolo off > "$out" 2>&1
  rc=$?

  assert_grep "treehouse return --force" "$dir/treehouse.log" \
    "teardown of the exited task did not return its slot during get"$'\n'"$(cat "$dir/teardown-a.out" 2>/dev/null)"
  [ "$rc" -ne 0 ] || fail "spawn claimed a slot that was returned while it waited on treehouse get"$'\n'"$(cat "$out")"
  assert_grep "no longer held by this spawn's pane" "$out" \
    "spawn did not explain the abandoned slot: $(cat "$out")"
  assert_absent "$home_b/state/$id_b.meta" "spawn published a record for a returned slot"
  assert_absent "$dir/pool/1/.fm-slot-owner" "spawn claimed a returned slot"
  [ "$(grep -c '^treehouse return' "$dir/treehouse.log")" -eq 1 ] \
    || fail "spawn returned or forced the abandoned slot itself: $(cat "$dir/treehouse.log")"
  pass "a slot an exited task's teardown returns during get is abandoned, not claimed"
}

make_pool_case() { # <name> <id> <stale-reads>
  local name=$1 id=$2 stale_reads=$3 case_dir home project pool first second fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  first="$pool/1/project"
  second="$pool/2/project"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_init_commit "$project"
  mkdir -p "$pool/1" "$pool/2"
  git -C "$project" worktree add --quiet -b "protected-$name" "$first"
  printf 'unique work\n' > "$first/unique.txt"
  git -C "$first" add unique.txt
  git -C "$first" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm unique
  git -C "$project" worktree add --quiet --detach "$second"
  printf '{"worktrees":[{"name":"1","path":"%s"},{"name":"2","path":"%s","owner_pid":%s}]}\n' \
    "$first" "$second" "$$" > "$pool/treehouse-state.json"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$project|$second|$first|$fakebin|$countfile|$stale_reads"
}

test_inspected_unreserved_slot_is_not_adopted() {
  local rec id out status before
  id=settle-rejected-slot-z5
  rec=$(make_pool_case settle-rejected-slot "$id" 2)
  read_settle_record "$rec"
  before=$(git -C "$STALE_DIR" rev-parse HEAD)
  printf 'task=older\nhome=elsewhere\n' > "$(dirname "$STALE_DIR")/.fm-slot-owner"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should wait for Treehouse's reserved slot"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "spawn recorded the inspected slot instead of the reserved slot"
  [ "$(git -C "$STALE_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved the inspected slot's protected branch"
  assert_grep 'task=older' "$(dirname "$STALE_DIR")/.fm-slot-owner" \
    "spawn replaced the inspected slot's claim"
  pass "an inspected unreserved pool slot is not recorded, claimed, or reset"
}

test_treehouse_get_runs_without_project_lock() {
  local rec id out status
  id=settle-lock-window-z6
  rec=$(make_pool_case settle-lock-window "$id" 0)
  read_settle_record "$rec"
  FM_FAKE_LOCK_PATH=$(FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$PROJ_DIR")
  FM_FAKE_LOCK_RESULT="$HOME_DIR/lock-result"
  export FM_FAKE_LOCK_PATH FM_FAKE_LOCK_RESULT
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should claim the second slot"$'\n'"$out"
  assert_grep 'released' "$FM_FAKE_LOCK_RESULT" \
    "the project lock still surrounded treehouse get"
  unset FM_FAKE_LOCK_PATH FM_FAKE_LOCK_RESULT
  pass "treehouse get runs outside the project lock and spawn reacquires it"
}


make_presentation_lock_fakebin() {
  local fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$1" codex)
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
case "${1:-} ${2:-}" in
  'status --json')
    printf '{"client":{"version":"0.9.1","protocol":22},"server":{"running":true,"version":"0.9.1","protocol":22}}\n'
    ;;
  'session list')
    : > "$FM_FAKE_LOCK_REACHED"
    printf '{"sessions":[{"name":"lock-order","running":true,"socket_path":"%s"}]}\n' "$FM_FAKE_SOCKET"
    ;;
  'workspace list')
    if [ -e "$FM_FAKE_LOCK_REACHED" ] && [ ! -e "$FM_FAKE_HERDR_LOG.read" ]; then
      : > "$FM_FAKE_HERDR_LOG.read"
      [ -e "$FM_FAKE_PROJECT_LOCK" ] || : > "$FM_FAKE_UNPROTECTED"
    fi
    printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n'
    ;;
  'tab list') printf '{"result":{"tabs":[]}}\n' ;;
  'tab create') printf '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"w1:p1"}}}\n' ;;
  'pane get')
    printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' "$3" "$FM_FAKE_PANE_PATH"
    ;;
  'agent get') printf '{"error":{"code":"agent_not_found"}}\n' ;;
  'pane run')
    if [ "$4" = 'treehouse get' ]; then
      [ ! -e "$FM_FAKE_PROJECT_LOCK" ] || : > "$FM_FAKE_LOCK_HELD_AT_GET"
    fi
    ;;
  'pane send-text'|'pane send-keys') ;;
  *) printf 'unexpected fake herdr command: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

run_presentation_lock_case() {
  local mode=$1 dir="$TMP_ROOT/presentation-$1" id="settle-presentation-$1"
  local home1="$dir/home-root" home2="$dir/home-child" project="$dir/project" wt="$dir/wt"
  local fakebin code="$dir/code" lock presentation peer_pid peer_rc spawn_rc journal
  local args=()
  mkdir -p "$code" "$dir/presentation"
  chmod 700 "$dir/presentation"
  cp -R "$ROOT/bin" "$code/bin"
  cp "$SPAWN" "$code/bin/fm-spawn.sh"
  ln -s "$ROOT/.agents" "$code/.agents"
  ln -s "$ROOT/docs" "$code/docs"
  sed "s|'/tmp/firstmate-herdr-presentation'|'$dir/presentation'|" \
    "$ROOT/bin/backends/herdr.sh" > "$code/bin/backends/herdr.sh"
  fm_test_spawn_home "$home1" codex
  fm_test_spawn_home "$home2" codex
  mkdir -p "$home2/user-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home1" \
    > "$home2/.fm-secondmate-parent"
  fm_test_spawn_brief "$home2" "$id" 'Serialize recovery without blocking the presentation owner.'
  fm_git_worktree "$project" "$wt" "presentation-$mode"
  fakebin=$(make_presentation_lock_fakebin "$dir/fake")
  printf 'on\n' > "$home2/config/herdr-presentation-spaces"
  journal="$home2/state/$id.herdr-presentation"
  case "$mode" in
    create) ;;
    project) printf 'project\n' > "$home2/config/herdr-presentation-spaces" ;;
    *) printf 'version=1\ntask_id=%s\nprojection_id=AAAAAAAAAAAAAAAAAAAAAA\n' "$id" > "$journal" ;;
  esac
  case "$mode" in wait|batch|changed) args+=(--herdr-resume-lock-wait) ;; esac
  case "$mode" in
    batch) args+=("$id=$project") ;;
    *) args+=("$id" "$project") ;;
  esac
  lock=$(FM_HOME="$home1" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$project") || fail 'could not resolve project lock'
  presentation=$(FM_HOME="$home1" FM_FAKE_HERDR_LOG="$dir/herdr.log" \
    FM_FAKE_SOCKET="$dir/fake.sock" FM_FAKE_LOCK_REACHED="$dir/resolve-lock" PATH="$fakebin:$PATH" \
    bash -c '. "$1"; . "$2"; fm_backend_herdr_presentation_session_lock_path lock-order' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$code/bin/backends/herdr.sh") || fail 'could not resolve fake presentation lock'
  rm -f "$dir/resolve-lock"
  FM_HOME="$home1" bash -c '
    set -eu
    . "$1/bin/fm-wake-lib.sh"
    project_lock=$2; presentation_lock=$3; dir=$4; mode=$5; journal=$6
    trap '\''fm_lock_release "$project_lock" || true; fm_lock_release "$presentation_lock" || true'\'' EXIT
    fm_lock_acquire_wait "$presentation_lock"
    : > "$dir/owner-ready"
    for _ in $(seq 1 1000); do
      [ ! -e "$dir/resolve-lock" ] || break
      sleep 0.01
    done
    [ -e "$dir/resolve-lock" ] || exit 2
    fm_lock_acquire_wait_max "$project_lock" 10 || exit 3
    : > "$dir/owner-retook-project"
    if [ "$mode" = changed ]; then
      printf "version=1\ntask_id=foreign-task\nprojection_id=AAAAAAAAAAAAAAAAAAAAAA\n" > "$journal"
    fi
    fm_lock_release "$project_lock"
    case "$mode" in
      wait|batch|changed) sleep 0.2 ;;
      *)
        for _ in $(seq 1 3000); do
          [ ! -e "$dir/spawn-done" ] || break
          sleep 0.01
        done
        [ -e "$dir/spawn-done" ] || exit 4
        ;;
    esac
  ' _ "$ROOT" "$lock" "$presentation" "$dir" "$mode" "$journal" > "$dir/peer.out" 2>&1 &
  peer_pid=$!
  for _ in $(seq 1 1000); do
    [ ! -e "$dir/owner-ready" ] || break
    /bin/sleep 0.01
  done
  [ -e "$dir/owner-ready" ] || { wait "$peer_pid"; fail 'presentation owner never became ready'; }
  FM_ROOT_OVERRIDE="$code" FM_HOME="$home2" HOME="$home2/user-home" \
    CLAUDE_CONFIG_DIR='' FM_STATE_OVERRIDE="$home2/state" FM_DATA_OVERRIDE="$home2/data" \
    FM_PROJECTS_OVERRIDE="$home2/projects" FM_CONFIG_OVERRIDE="$home2/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=herdr HERDR_SESSION=lock-order \
    HERDR_ENV='' HERDR_PANE_ID='' HERDR_TAB_ID='' HERDR_WORKSPACE_ID='' HERDR_SOCKET_PATH='' \
    FM_BACKEND_HERDR_BIN="$fakebin/herdr" FM_BACKEND_HERDR_CLIENT_SESSION=lock-order \
    FM_FAKE_SOCKET="$dir/fake.sock" FM_FAKE_LOCK_REACHED="$dir/resolve-lock" \
    FM_FAKE_PROJECT_LOCK="$lock" FM_FAKE_UNPROTECTED="$dir/unprotected" \
    FM_FAKE_LOCK_HELD_AT_GET="$dir/held-at-get" FM_FAKE_PANE_PATH="$wt" \
    FM_FAKE_HERDR_LOG="$dir/herdr.log" PATH="$fakebin:$PATH" \
    bash "$code/bin/fm-spawn.sh" "${args[@]}" --mode no-mistakes --yolo off > "$dir/spawn.out" 2>&1
  spawn_rc=$?
  : > "$dir/spawn-done"
  wait "$peer_pid"; peer_rc=$?
  [ "$peer_rc" -eq 0 ] || fail "$mode: presentation owner could not retake project lock (exit $peer_rc)"$'\n'"$(cat "$dir/peer.out" "$dir/spawn.out")"
  [ -e "$dir/owner-retook-project" ] || fail "$mode: competing lock sequence was not exercised"
  [ ! -e "$dir/unprotected" ] || fail "$mode: recovery read protected state before retaking project lock"
  case "$mode" in
    refuse)
      [ "$spawn_rc" -ne 0 ] || fail 'default recovery waited instead of refusing'
      assert_grep 'refusing a concurrent resume' "$dir/spawn.out" 'default recovery lost its refusal'
      assert_no_grep 'tab create' "$dir/herdr.log" 'refused recovery provisioned a task'
      ;;
    changed)
      [ "$spawn_rc" -ne 0 ] || fail 'recovery accepted a journal invalidated during the wait'
      assert_grep 'malformed herdr presentation journal' "$dir/spawn.out" 'recovery did not revalidate its journal'
      assert_no_grep 'tab create' "$dir/herdr.log" 'invalidated recovery provisioned a task'
      ;;
    *)
      expect_code 0 "$spawn_rc" "$mode: spawn failed"$'\n'"$(cat "$dir/spawn.out")"
      assert_grep "worktree=$wt" "$home2/state/$id.meta" "$mode: successful spawn lost its worktree"
      [ ! -e "$dir/held-at-get" ] || fail "$mode: treehouse get held the project lock"
      ;;
  esac
  pass "herdr $mode releases the project lock during presentation contention and revalidates before provisioning"
}

test_presentation_lock_order() {
  local mode
  for mode in wait batch refuse create project changed; do
    run_presentation_lock_case "$mode"
  done
}

if [ "${1:-}" = herdr-lock-order ]; then
  test_presentation_lock_order
  exit 0
fi

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_concurrent_spawns_reach_treehouse_get_without_project_lock
test_slot_returned_by_exited_task_teardown_during_get_is_abandoned
test_inspected_unreserved_slot_is_not_adopted
test_treehouse_get_runs_without_project_lock
test_presentation_lock_order

echo "# all fm-spawn-worktree-settle tests passed"
