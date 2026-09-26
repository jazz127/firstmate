#!/usr/bin/env bash
# Naming, skip, commit-choice, and create-only push behavior of bin/fm-housefeature-cut.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CUT="$ROOT/bin/fm-housefeature-cut.sh"
TMP_ROOT=$(fm_test_tmproot fm-housefeature-cut)
fm_git_identity

test_name_derivation() {
  local ref expected got
  while read -r ref expected; do
    got=$("$CUT" name "$ref") || fail "name $ref exited non-zero"
    assert_equals "$expected" "$got" "name for $ref"
  done <<'EOF'
fm/firstmate-evidence-contradiction-c2 evidence-contradiction
fm/firstmate-auto-validation-handoff-r1 auto-validation-handoff
fm/firstmate-housefeature-autocut-r12 housefeature-autocut
fm/quota-tab quota-tab
firstmate-board-r3 board
housefeature/already-named-r1 already-named-r1
fm/firstmate-keeps-round-word keeps-round-word
EOF
  expect_code 1 "$("$CUT" name fm/ >/dev/null 2>&1; echo $?)" "empty name is refused"
  expect_code 1 "$("$CUT" name 'fm/bad..name' >/dev/null 2>&1; echo $?)" "invalid ref name is refused"
  pass "feature names strip fm/, firstmate-, and a round suffix; housefeature/ refs keep theirs"
}

classify_with() {
  env HF_MERGED=true HF_BASE_REF=house HF_HEAD_REF=fm/firstmate-alpha-r1 \
    HF_BASE_REPO=jazz127/firstmate HF_HEAD_REPO=jazz127/firstmate "$@" "$CUT" classify
}

test_classify_skips() {
  assert_equals "cut alpha" "$(classify_with)" "merged house PR is cut"
  assert_contains "$(classify_with HF_MERGED=false)" "skip " "unmerged PR skips"
  assert_contains "$(classify_with HF_BASE_REF=main)" "skip base is main" "non-house base skips"
  assert_contains "$(classify_with HF_HEAD_REPO=someone/firstmate)" "skip head is from another repository" "fork PR skips"
  assert_contains "$(classify_with HF_HEAD_REPO=)" "skip head is from another repository" "deleted head repo skips"
  assert_contains "$(classify_with HF_HEAD_REF=fm/firstmate-upstream-merge-r1)" "brings upstream main" "upstream merge skips"
  assert_contains "$(classify_with HF_HEAD_REF=fm/house-reconcile-2026-09)" "brings upstream main" "reconcile skips"
  pass "unmerged, non-house, cross-repository, and upstream-merge pull requests are skipped"
}

# Fixture fork: main holds base.txt; house adds house.txt on top of main.
make_fork() {
  local work=$TMP_ROOT/work
  fm_git_init_commit "$work" >/dev/null
  printf 'base\n' > "$work/base.txt"
  git -C "$work" add base.txt && git -C "$work" commit -qm base
  git -C "$work" checkout -qb house
  printf 'house only\n' > "$work/house.txt"
  git -C "$work" add house.txt && git -C "$work" commit -qm house-only
  git clone -q --bare "$work" "$TMP_ROOT/fork.git"
  git clone -q "$TMP_ROOT/fork.git" "$TMP_ROOT/clone"
}

# merge_feature <branch> <file> <content>: land a feature on house with a merge
# commit and print "<head-sha> <merge-sha>".
merge_feature() {
  local branch=$1 file=$2 content=$3 clone=$TMP_ROOT/clone head merge
  git -C "$clone" fetch -q origin
  git -C "$clone" checkout -qB "$branch" origin/house
  printf '%s\n' "$content" >> "$clone/$file"
  git -C "$clone" add "$file" && git -C "$clone" commit -qm "change $file"
  head=$(git -C "$clone" rev-parse HEAD)
  git -C "$clone" checkout -qB house origin/house
  git -C "$clone" merge -q --no-ff -m "Merge $branch" "$branch"
  merge=$(git -C "$clone" rev-parse HEAD)
  git -C "$clone" push -q origin house "$branch"
  git -C "$clone" checkout -q --detach
  printf '%s %s\n' "$head" "$merge"
}

run_cut() {
  local branch=$1 head=$2 merge=$3
  shift 3
  (cd "$TMP_ROOT/clone" && env GITHUB_STEP_SUMMARY="$TMP_ROOT/summary.md" \
    HF_MERGED=true HF_BASE_REF=house HF_HEAD_REF="$branch" \
    HF_BASE_REPO=jazz127/firstmate HF_HEAD_REPO=jazz127/firstmate \
    HF_PR_NUMBER=7 HF_PR_TITLE="Feature $branch" HF_HEAD_SHA="$head" HF_MERGE_SHA="$merge" \
    "$@" "$CUT" run)
}

remote_ref() {
  git --git-dir="$TMP_ROOT/fork.git" rev-parse --verify -q "refs/heads/$1"
}

test_run_cuts_and_captures() {
  local shas head merge main alpha out before
  make_fork
  main=$(remote_ref main)

  shas=$(merge_feature fm/firstmate-alpha-r1 alpha.txt alpha)
  head=${shas% *} merge=${shas#* }
  out=$(run_cut fm/firstmate-alpha-r1 "$head" "$merge") || fail "clean cut failed: $out"
  assert_contains "$out" "cut from \`main\`" "clean change reports a main cut"
  alpha=$(remote_ref housefeature/alpha) || fail "housefeature/alpha was not created"
  assert_equals "$main" "$(git --git-dir="$TMP_ROOT/fork.git" rev-parse "$alpha^")" "main cut sits on main"
  assert_equals "alpha" "$(git --git-dir="$TMP_ROOT/fork.git" show "$alpha:alpha.txt")" "main cut carries the change"
  git --git-dir="$TMP_ROOT/fork.git" cat-file -e "$alpha:house.txt" 2>/dev/null \
    && fail "main cut must not carry house-only files"
  assert_grep "Created \`housefeature/alpha\`" "$TMP_ROOT/summary.md" "summary records the main cut"

  shas=$(merge_feature fm/firstmate-beta-c2 house.txt beta)
  head=${shas% *} merge=${shas#* }
  out=$(run_cut fm/firstmate-beta-c2 "$head" "$merge") || fail "capture failed: $out"
  assert_contains "$out" "captured from the merged pull request head" "house-dependent change is captured"
  assert_equals "$head" "$(remote_ref housefeature/beta)" "capture points at the pull request head"

  before=$(remote_ref housefeature/alpha)
  out=$(run_cut fm/firstmate-alpha-r2 "$head" "$merge") || fail "existing branch run failed: $out"
  assert_contains "$out" "Left existing \`housefeature/alpha\`" "existing branch is reported"
  assert_equals "$before" "$(remote_ref housefeature/alpha)" "existing branch is never moved"

  out=$(run_cut fm/firstmate-upstream-merge-r1 "$head" "$merge" HF_PR_NUMBER=9) || fail "skip run failed"
  assert_contains "$out" "Skipped pull request #9" "skip is reported"
  remote_ref housefeature/upstream-merge >/dev/null && fail "skip must not push"
  out=$(run_cut fm/firstmate-gamma-r1 "$head" "$merge" HF_HEAD_REPO=other/firstmate) || fail "fork skip run failed"
  remote_ref housefeature/gamma >/dev/null && fail "cross-repository skip must not push"
  assert_equals "$main" "$(remote_ref main)" "main is untouched"
  pass "clean changes are cut from main, house-dependent ones captured, existing branches left alone"
}

test_name_derivation
test_classify_skips
test_run_cuts_and_captures
