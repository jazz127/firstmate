#!/usr/bin/env bash
# Behavior tests for bin/fm-dod-lib.sh's named-head reachability gate on ship
# done: acceptance (issue 4768). The gate must test the commit the worker names,
# not merely that some remote-tracking branch exists or moved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dod-lib)
fm_git_identity fmtest fmtest@example.invalid

accept_done() {  # <kind> <mode> <worktree> <project> <line> [<state> <id> <meta>]
  fm_dod_accept_ship_done "$@"
}

write_merge_marker() {  # <state> <id> <provider> <host> <path> <number>
  printf '%s\n' fm-pr-poll-merge-notified-v1 "$3" "$4" "$5" "$6" > "$1/$2.pr-poll-merge-notified"
  chmod 600 "$1/$2.pr-poll-merge-notified"
}

test_scout_done_is_not_gated() {
  local repo wt
  repo="$TMP_ROOT/scout-repo"
  wt="$TMP_ROOT/scout-wt"
  fm_git_worktree "$repo" "$wt" fm/scout
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  accept_done scout no-mistakes "$wt" "$repo" 'done: report written' \
    || fail "scout done: must not require named-head reachability outside the copy"
  pass "scout done: is not gated"
}

test_evidence_claim_requires_provenance() {
  local root intent out rc artifact
  root="$TMP_ROOT/evidence-claim"
  artifact="$root/worktree/evidence.txt"
  mkdir -p "$root/home" "$root/worktree" "$root/tmp"
  printf '%s\n' captured output > "$artifact"
  intent='2 of 3 scenarios driven live'
  set +e
  out=$(fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "evidence claim without provenance was accepted"
  assert_contains "$out" "missing evidence-artifact" "missing artifact refusal was unclear"
  intent=$(printf '2 of 3 scenarios driven live\nevidence-artifact: %s\n' "$artifact")
  set +e
  out=$(fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "evidence claim without command and time was accepted"
  assert_contains "$out" "missing evidence-command" "missing command refusal was unclear"
  intent=$(printf '2 of 3 scenarios\ndriven live\nevidence-artifact: %s\n' "$artifact")
  out=$(fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "line-split evidence claim without provenance was accepted"
  assert_contains "$out" "missing evidence-command" "line-split claim refusal was unclear"
  intent=$(printf '2 of 3\nscenarios\ndriven live\nevidence-artifact: %s\n' "$artifact")
  out=$(fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "three-line evidence claim without provenance was accepted"
  assert_contains "$out" "missing evidence-command" "three-line claim refusal was unclear"
  intent=$(printf '2 of 3 scenarios driven live\nevidence-artifact: %s\nevidence-command:   \nevidence-captured:   \n' "$artifact")
  out=$(fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "whitespace-only evidence metadata was accepted"
  assert_contains "$out" "missing evidence-command" "whitespace-only command refusal was unclear"
  pass "evidence claims require artifact provenance"
}

test_evidence_claim_enforces_mechanical_provenance() {
  local root artifact intent out rc
  root="$TMP_ROOT/evidence-claim-valid"
  artifact="$root/worktree/evidence.txt"
  mkdir -p "$root/home" "$root/worktree" "$root/tmp"
  printf '%s\n' captured output > "$artifact"
  intent=$(cat <<EOF
2 of 3 scenarios driven live
evidence-artifact: $artifact
evidence-command: ./run-scenarios --live
evidence-captured: 2026-09-25T10:00:00+10:00
EOF
)
  fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" \
    || fail "mechanically valid evidence provenance was refused"
  rm -f "$artifact"
  fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" \
    || fail "valid evidence provenance was rejected before its artifact existed"
  set +e
  out=$(fm_dod_validate_published_intent "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "publication accepted a missing evidence artifact"
  assert_contains "$out" "missing or unreadable" "missing artifact publication refusal was unclear"
  printf '%s\n' captured output > "$artifact"
  fm_dod_validate_published_intent "$intent" "$root/worktree" "$root/tmp" \
    || fail "publication refused a mechanically valid evidence artifact"
  mkdir -p "$root/outside"
  printf '%s\n' captured > "$root/outside/evidence.txt"
  intent=${intent/$artifact/$root\/worktree\/..\/outside\/evidence.txt}
  set +e
  out=$(fm_dod_validate_published_intent "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "publication accepted an artifact escaping the worktree"
  assert_contains "$out" "outside the" "path traversal refusal was unclear"
  mkdir -p "$root/tmp-other"
  printf '%s\n' captured > "$root/tmp-other/evidence.txt"
  intent=$(cat <<EOF
2 of 3 scenarios driven live
evidence-artifact: $root/tmp-other/evidence.txt
evidence-command: ./run-scenarios --live
evidence-captured: 2026-09-25T10:00:00+10:00
EOF
)
  out=$(fm_dod_validate_published_intent "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "publication accepted an artifact from another task temp root"
  assert_contains "$out" "outside the" "task temp root refusal was unclear"
  printf '%s\n' outside > "$root/outside/secret.txt"
  ln -s "$root/outside/secret.txt" "$root/worktree/linked-evidence.txt"
  intent=$(cat <<EOF
2 of 3 scenarios driven live
evidence-artifact: $root/worktree/linked-evidence.txt
evidence-command: ./run-scenarios --live
evidence-captured: 2026-09-25T10:00:00+10:00
EOF
)
  out=$(fm_dod_validate_published_intent "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "publication accepted an artifact symlink escaping the worktree"
  assert_contains "$out" "outside the allowed roots" "escaping symlink refusal was unclear"
  fm_dod_validate_intent_evidence 'Improve live reload wording' "$root/worktree" "$root/tmp" \
    || fail "ordinary prose containing live was refused"
  fm_dod_validate_intent_evidence 'Improve live reload test wording' "$root/worktree" "$root/tmp" \
    || fail "ordinary prose containing live and test was refused"
  fm_dod_validate_intent_evidence 'Improve live reload test result wording' "$root/worktree" "$root/tmp" \
    || fail "ordinary prose containing live and result was refused"
  fm_dod_validate_intent_evidence 'Investigate external test evidence' "$root/worktree" "$root/tmp" \
    || fail "request prose containing evidence was refused"
  fm_dod_validate_intent_evidence 'Do not claim live validation' "$root/worktree" "$root/tmp" \
    || fail "negated prose containing evidence vocabulary was refused"
  fm_dod_validate_intent_evidence 'Do not claim live test passed' "$root/worktree" "$root/tmp" \
    || fail "negated affirmative claim was refused"
  fm_dod_validate_intent_evidence 'Example: external validation passed' "$root/worktree" "$root/tmp" \
    || fail "example prose containing an evidence claim was refused"
  fm_dod_validate_intent_evidence 'Please verify external validation passed' "$root/worktree" "$root/tmp" \
    || fail "request prose containing an evidence claim was refused"
  fm_dod_validate_intent_evidence 'For example, external validation passed' "$root/worktree" "$root/tmp" \
    || fail "example prose with a lead-in was refused"
  fm_dod_validate_intent_evidence 'Can you verify external validation passed?' "$root/worktree" "$root/tmp" \
    || fail "question prose containing an evidence claim was refused"
  fm_dod_validate_intent_evidence 'external validation did not pass' "$root/worktree" "$root/tmp" \
    || fail "negative result prose was refused"
  fm_dod_validate_intent_evidence 'not externally confirmed' "$root/worktree" "$root/tmp" \
    || fail "short negative result prose was refused"
  fm_dod_validate_intent_evidence 'external validation was not confirmed' "$root/worktree" "$root/tmp" \
    || fail "auxiliary negative result prose was refused"
  fm_dod_validate_intent_evidence "external validation wasn't confirmed" "$root/worktree" "$root/tmp" \
    || fail "contracted negative result prose was refused"
  intent='offline validation did not pass, but external validation passed'
  out=$(fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "later affirmative assertion after a negation was erased"
  assert_contains "$out" "missing evidence-artifact" "later assertion after negation refusal was unclear"
  intent=$(cat <<'EOF'
Please verify external validation passed
external validation passed
EOF
)
  out=$(fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "real assertion after a request was erased"
  assert_contains "$out" "missing evidence-artifact" "assertion after request refusal was unclear"
  intent='Please verify external validation passed; external validation passed'
  out=$(fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "affirmative assertion after a request clause was erased"
  assert_contains "$out" "missing evidence-artifact" "assertion after request clause refusal was unclear"
  fm_dod_validate_intent_evidence '2 of 3 requested endpoints' "$root/worktree" "$root/tmp" \
    || fail "ordinary ratio prose was refused"
  for claim in \
    'external validation passed' \
    'live test passed' \
    'independent scenario completed' \
    'live scenarios driven' \
    'live check passed' \
    'external run succeeded' \
    'independent probe completed successfully' \
    'real account test passed' \
    'The scenarios were run against a real account' \
    'The scenarios ran live against the product' \
    'external result passed' \
    'live measurement completed' \
    'independent account confirmed' \
    'The scenarios were independently confirmed' \
    'real result passed' \
    'validation was verified' \
    'results were live' \
    'external scenarios were validated' \
    'independently validated results'; do
    out=$(fm_dod_validate_intent_evidence "$claim" "$root/worktree" "$root/tmp" 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "affirmative evidence claim was accepted without provenance: $claim"
    assert_contains "$out" "missing evidence-artifact" "affirmative claim refusal was unclear: $claim"
  done
  intent='0 of 5 / 2 of 3'
  out=$(fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "compact multi-ratio evidence label was accepted without provenance"
  assert_contains "$out" "missing evidence-artifact" "compact multi-ratio refusal was unclear"
  intent=$(cat <<EOF
external validation passed
evidence-artifact: $root/worktree/evidence.txt
evidence-command: ./run-scenarios
evidence-captured: tomorrow
EOF
)
  out=$(fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "invalid evidence-captured timestamp was accepted"
  assert_contains "$out" "invalid evidence-captured timestamp" "invalid timestamp refusal was unclear"
  intent=${intent/tomorrow/2026-99-99T99:99:99+99:99}
  out=$(fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "impossible evidence-captured timestamp was accepted"
  assert_contains "$out" "invalid evidence-captured timestamp" "impossible timestamp refusal was unclear"
  intent=$(cat <<EOF
external validation passed
evidence-artifact: $root/worktree/evidence.txt
evidence-artifact: $root/worktree/evidence.txt
evidence-command: ./run-scenarios
evidence-captured: 2026-09-25T10:00:00+10:00
EOF
)
  out=$(fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "duplicate evidence metadata was accepted"
  assert_contains "$out" "duplicate evidence-artifact" "duplicate artifact metadata refusal was unclear"
  intent=$(cat <<EOF
2 of 3 scenarios driven live
evidence-artifact: $root/worktree
evidence-command: ./run-scenarios --live
evidence-captured: 2026-09-25T10:00:00+10:00
EOF
)
  out=$(fm_dod_validate_published_intent "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "directory evidence artifact was accepted"
  assert_contains "$out" "missing or unreadable" "directory artifact refusal was unclear"
  pass "evidence claims accept readable provenance and spare ordinary prose"
}

test_scenario_consistency_is_publication_only() {
  local root artifact intent out rc
  root="$TMP_ROOT/scenario-publication-only"
  artifact="$root/worktree/evidence.txt"
  mkdir -p "$root/worktree" "$root/tmp"
  printf '%s\n' captured > "$artifact"
  intent=$(cat <<EOF
| Scenario | Result | Live | Evidence |
| --- | --- | --- | --- |
| Account A | pass | yes | captured |
| Account B | pass | fixture-based | local fixture |

0 of 2 scenarios driven live against the product.
evidence-artifact: $artifact
evidence-command: cat $artifact
evidence-captured: 2026-09-25T10:00:00+10:00
EOF
)
  fm_dod_validate_intent_evidence "$intent" "$root/worktree" "$root/tmp" \
    || fail "brief intent quoting a contradictory PR body was refused"
  out=$(fm_dod_validate_published_intent "$intent" "$root/worktree" "$root/tmp" 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "contradictory PR body was accepted at publication"
  assert_contains "$out" "contradictory driven-scenario results" \
    "publication refusal did not identify the contradiction"
  pass "scenario consistency is enforced only for PR-body publication"
}

test_unpushed_ship_done_is_refused() {
  local repo wt sha reason rc
  repo="$TMP_ROOT/unpushed-repo"
  wt="$TMP_ROOT/unpushed-wt"
  fm_git_worktree "$repo" "$wt" fm/unpushed
  git -C "$wt" commit -q --allow-empty -m 'fix only in the worktree'
  sha=$(git -C "$wt" rev-parse HEAD)
  reason=$(accept_done ship no-mistakes "$wt" "$repo" "done: PR https://example.test/o/r/pull/1 checks green")
  rc=$?
  [ "$rc" -eq 1 ] || fail "unpushed ship done: was accepted (exit $rc)"
  case "$reason" in
    *"named head $sha is unreachable outside the worker copy") ;;
    *) fail "unpushed refusal did not name the commit: $reason" ;;
  esac
  pass "unpushed ship done: is refused"
}

test_remote_containing_named_head_is_accepted() {
  local repo wt sha
  repo="$TMP_ROOT/pushed-repo"
  wt="$TMP_ROOT/pushed-wt"
  fm_git_worktree "$repo" "$wt" fm/pushed
  git -C "$wt" commit -q --allow-empty -m 'fix on the branch'
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/remotes/origin/fm/pushed "$sha"
  accept_done ship no-mistakes "$wt" "$repo" "done: PR https://example.test/o/r/pull/2 checks green" \
    || fail "named head on a remote-tracking ref was refused"
  pass "named head on a remote-tracking ref is accepted"
}

test_moved_branch_without_named_head_is_refused() {
  local repo wt main_sha fix_sha reason rc
  repo="$TMP_ROOT/moved-repo"
  wt="$TMP_ROOT/moved-wt"
  fm_git_worktree "$repo" "$wt" fm/moved
  main_sha=$(git -C "$repo" rev-parse main)
  git -C "$wt" commit -q --allow-empty -m 'the actual fix'
  fix_sha=$(git -C "$wt" rev-parse HEAD)
  # The fork branch exists and moved, but only to a merge of the default
  # branch: reachability of that branch is not reachability of the named head.
  git -C "$wt" update-ref refs/remotes/origin/fm/moved "$main_sha"
  reason=$(accept_done ship no-mistakes "$wt" "$repo" "done: PR https://example.test/o/r/pull/3 checks green")
  rc=$?
  [ "$rc" -eq 1 ] || fail "moved remote branch without the named head was accepted"
  case "$reason" in
    *"named head $fix_sha is unreachable outside the worker copy") ;;
    *) fail "moved-branch refusal did not name the fix commit: $reason" ;;
  esac
  pass "a moved remote branch that lacks the named head is refused"
}

test_no_mistakes_prevalidation_done_is_not_gated() {
  local repo wt
  repo="$TMP_ROOT/preval-repo"
  wt="$TMP_ROOT/preval-wt"
  fm_git_worktree "$repo" "$wt" fm/preval
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  accept_done ship no-mistakes "$wt" "$repo" 'done: implementation complete' \
    || fail "no-mistakes pre-validation done: must not require named-head reachability"
  pass "no-mistakes pre-validation done: is not gated"
}

test_local_only_linked_branch_is_accepted() {
  local repo wt
  repo="$TMP_ROOT/local-repo"
  wt="$TMP_ROOT/local-wt"
  fm_git_worktree "$repo" "$wt" fm/local
  git -C "$wt" commit -q --allow-empty -m 'local-only work'
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/local" \
    || fail "local-only named branch in a linked worktree was refused"
  pass "local-only linked named branch is reachable from the project clone"
}

test_local_only_detached_head_is_refused() {
  local repo wt sha rc
  repo="$TMP_ROOT/detach-repo"
  wt="$TMP_ROOT/detach-wt"
  fm_git_worktree "$repo" "$wt" fm/detach
  git -C "$wt" commit -q --allow-empty -m 'detached only'
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q --detach HEAD
  git -C "$wt" branch -q -D fm/detach
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/detach" >/dev/null \
    && fail "detached local-only head whose branch was deleted was accepted"
  rc=0
  accept_done ship local-only "$wt" "$repo" "done: implementation complete" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "detached local-only HEAD was accepted as done"
  pass "local-only detached HEAD only in the disposable copy is refused"
}

test_standalone_local_only_needs_project_ref() {
  local repo wt sha
  repo="$TMP_ROOT/stand-project"
  wt="$TMP_ROOT/stand-copy"
  fm_git_init_commit "$repo"
  git clone --quiet "$repo" "$wt"
  git -C "$wt" checkout -q -b fm/stand
  git -C "$wt" commit -q --allow-empty -m 'only in the standalone copy'
  sha=$(git -C "$wt" rev-parse HEAD)
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/stand" >/dev/null \
    && fail "standalone local-only copy was accepted without the named head in the project clone"
  git -C "$repo" fetch -q "$wt" "fm/stand:fm/stand"
  [ "$(git -C "$repo" rev-parse fm/stand)" = "$sha" ] \
    || fail "project clone did not gain the named head"
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/stand" \
    || fail "standalone local-only named head present in the project clone was refused"
  pass "standalone local-only done: requires the named head in the project clone"
}

test_free_text_sha_is_not_the_named_head() {
  local repo wt old new reason rc
  repo="$TMP_ROOT/hex-repo"
  wt="$TMP_ROOT/hex-wt"
  fm_git_worktree "$repo" "$wt" fm/hex
  old=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/remotes/origin/main "$old"
  git -C "$wt" commit -q --allow-empty -m 'actual fix'
  new=$(git -C "$wt" rev-parse HEAD)
  reason=$(accept_done ship direct-PR "$wt" "$repo" "done: reverted $old and fixed the retry")
  rc=$?
  [ "$rc" -eq 1 ] || fail "free-text SHA on origin/main made an unpushed HEAD accept"
  case "$reason" in
    *"named head $new is unreachable outside the worker copy") ;;
    *) fail "free-text SHA scan still selected the old commit: $reason" ;;
  esac
  pass "a 40-hex token in the note is not the named head"
}

test_recorded_merged_pr_is_landed_after_prune() {
  local repo wt meta state
  repo="$TMP_ROOT/merged-repo"
  wt="$TMP_ROOT/merged-wt"
  state="$TMP_ROOT/merged-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/merged
  git -C "$wt" commit -q --allow-empty -m 'fix, squash-merged and branch pruned'
  meta="$state/merged.meta"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/7\n' \
    "$wt" "$repo" > "$meta"
  write_merge_marker "$state" merged github github.com o/r 7
  accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/7" "$state" merged "$meta" \
    || fail "recorded merged PR was refused after its remote-tracking ref was pruned"
  pass "a recorded merged PR satisfies the gate after prune"
}

test_merge_marker_binds_to_the_named_pr() {
  local repo wt meta state reason rc sha
  repo="$TMP_ROOT/bind-repo"
  wt="$TMP_ROOT/bind-wt"
  state="$TMP_ROOT/bind-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/bind
  git -C "$wt" commit -q --allow-empty -m 'second PR head, never pushed'
  sha=$(git -C "$wt" rev-parse HEAD)
  meta="$state/bind.meta"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/7\n' \
    "$wt" "$repo" > "$meta"
  write_merge_marker "$state" bind github github.com o/r 7
  reason=$(accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/9" "$state" bind "$meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "merge of recorded PR 7 accepted an unpushed done naming PR 9"
  case "$reason" in
    *"named head $sha is unreachable outside the worker copy") ;;
    *) fail "PR 9 refusal did not name the unpushed head: $reason" ;;
  esac
  write_merge_marker "$state" bind github github.com other/r 7
  accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/7" "$state" bind "$meta" >/dev/null \
    && fail "merge marker for another repository's PR 7 was accepted"
  pass "the merged-PR short-circuit applies only to the recorded PR the done line names"
}

test_forge_recorded_head_is_accepted_without_local_object() {
  local repo wt meta state forge_head
  repo="$TMP_ROOT/forge-repo"
  wt="$TMP_ROOT/forge-wt"
  state="$TMP_ROOT/forge-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/forge
  git -C "$wt" commit -q --allow-empty -m 'worker head, not pushed from this copy'
  # The pipeline's own commit: on the forge and in the gate repo, never
  # fetched into the worker clone.
  forge_head=0123456789abcdef0123456789abcdef01234567
  meta="$state/forge.meta"
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/5\npr_head=%s\n' \
    "$wt" "$repo" "$forge_head" > "$meta"
  accept_done ship no-mistakes "$wt" "$repo" "done: PR https://github.com/o/r/pull/5 checks green" \
    "$state" forge "$meta" \
    || fail "forge-recorded pr_head the worker clone never fetched was refused"
  accept_done ship no-mistakes "$wt" "$repo" "done: PR https://github.com/o/r/pull/6 checks green" \
    "$state" forge "$meta" >/dev/null \
    && fail "pr_head recorded for PR 5 was accepted for a done naming PR 6"
  pass "a forge-recorded head for the named PR is accepted without a local object"
}

# A direct-PR worker pushes from its own copy: a commit made after the PR's
# recorded head, never pushed, is the named head and is refused.
test_direct_pr_recorded_head_does_not_cover_unpushed_commit() {
  local repo wt meta state pushed later reason rc
  repo="$TMP_ROOT/postopen-repo"
  wt="$TMP_ROOT/postopen-wt"
  state="$TMP_ROOT/postopen-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/postopen
  git -C "$wt" commit -q --allow-empty -m 'pushed when the PR opened'
  pushed=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/remotes/origin/fm/postopen "$pushed"
  git -C "$wt" commit -q --allow-empty -m 'the fix, only in the worktree'
  later=$(git -C "$wt" rev-parse HEAD)
  meta="$state/postopen.meta"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/5\npr_head=%s\n' \
    "$wt" "$repo" "$pushed" > "$meta"
  reason=$(accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/5" "$state" postopen "$meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "direct-PR recorded pr_head accepted an unpushed later commit"
  case "$reason" in
    *"named head $later is unreachable outside the worker copy") ;;
    *) fail "direct-PR refusal did not name the unpushed commit: $reason" ;;
  esac
  pass "a direct-PR recorded head does not cover a later unpushed commit"
}

test_ci_ready_variants_are_gated() {
  local repo wt line rc
  repo="$TMP_ROOT/variant-repo"
  wt="$TMP_ROOT/variant-wt"
  fm_git_worktree "$repo" "$wt" fm/variant
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  for line in \
    'done: PR https://github.com/o/r/pull/5 checks green, risk low' \
    'done: PR https://github.com/o/r/pull/5 - checks green' \
    'done: PR https://github.com/o/r/pull/5 checks green.' \
    'done: PR https://github.com/o/r/pull/5 (checks green)' \
    'done: PR https://github.com/o/r/pull/5 ready for review (CI skipped: base has no configured check workflows)'; do
    rc=0
    accept_done ship no-mistakes "$wt" "$repo" "$line" >/dev/null || rc=$?
    [ "$rc" -eq 1 ] || fail "no-mistakes CI-ready variant skipped the gate: $line"
  done
  pass "no-mistakes ready-PR done: with extra text or an explicit CI skip is gated"
}

test_keyed_and_spaced_done_lines_are_gated() {
  local repo wt line mode rc
  repo="$TMP_ROOT/keyed-repo"
  wt="$TMP_ROOT/keyed-wt"
  fm_git_worktree "$repo" "$wt" fm/keyed
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  for line in \
    'no-mistakes|done [key=fix]: PR https://github.com/o/r/pull/5 checks green' \
    'no-mistakes|done : PR https://github.com/o/r/pull/5 checks green' \
    'direct-PR|done [key=fix]: PR https://github.com/o/r/pull/5' \
    'direct-PR|done: [key=fix] PR https://github.com/o/r/pull/5'; do
    mode=${line%%|*}
    rc=0
    accept_done ship "$mode" "$wt" "$repo" "${line#*|}" >/dev/null || rc=$?
    [ "$rc" -eq 1 ] || fail "$mode done line skipped the gate: ${line#*|}"
  done
  pass "keyed and spaced ship done: lines are gated"
}

test_non_done_lines_are_not_gated() {
  local repo wt
  repo="$TMP_ROOT/nongate-repo"
  wt="$TMP_ROOT/nongate-wt"
  fm_git_worktree "$repo" "$wt" fm/nongate
  git -C "$wt" commit -q --allow-empty -m 'unpushed'
  accept_done ship no-mistakes "$wt" "$repo" 'working: still implementing' \
    || fail "working: line was gated"
  accept_done ship no-mistakes "$wt" "$repo" 'blocked: waiting on a credential' \
    || fail "blocked: line was gated"
  pass "non-done lines are not gated"
}

# Issue 3608: a legacy `# Task` body's provenance marker must be read the way
# bin/fm-brief-heading-lib.sh reads headings - outside fenced blocks and never
# from an indented example - or a fenced `Captain:` sample becomes the ship
# contract's intent while the real ask is dropped.
test_fenced_and_indented_captain_lines_are_not_intent() {
  local home id meta out status words
  home="$TMP_ROOT/fenced-home"
  mkdir -p "$home/state" "$home/data"
  words=$(fm_brief_marked_captain_words 'Investigate the promotion gate.

```markdown
Captain: This fenced example must not become intent.
[captain] Neither must this one.
```

~~~
Captain: Nor this tilde-fenced one.
~~~

    Captain: An indented example is not the ask either.
	[captain] Nor a tab-indented one.
Keep this Firstmate constraint out of captain intent.')
  assert_equals "" "$words" "fenced or indented Captain lines were extracted as authorized intent"

  words=$(fm_brief_marked_captain_words '```
Captain: fenced example
```
  [captain] Preserve the real ask after the fence closes.
````
Captain: a longer fence that a shorter closer must not end
```
Captain: still fenced
````')
  assert_equals "Preserve the real ask after the fence closes." "$words" \
    "the marker after a closed fence, or inside a longer fence, was misread"

  id=promote-fenced-captain
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
Investigate the promotion gate.

```markdown
Captain: This fenced example must not become intent.
```

    Captain: An indented example is not the ask either.

# Setup
This is a SCOUT task: the deliverable is a written report, not a PR.
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-promote.sh" "$id" --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion whose only Captain lines are fenced or indented examples should fail"
  assert_contains "$out" "has no provenance-marked Captain's intent" \
    "fenced-example promotion did not refuse like an unmarked legacy brief"
  assert_absent "$home/data/$id/ship-instructions.md" \
    "fenced-example promotion published a fenced sample as captain intent"
  assert_grep 'kind=scout' "$meta" "fenced-example promotion changed the task record"
  pass "fenced and indented Captain lines are not authorized intent"
}

# The draft check the DoD hands a worker must be the gh-axi path that rule 3 of
# every ship brief requires for GitHub operations, never raw gh (issue 5325).
test_pr_based_dod_draft_check_uses_gh_axi() {
  local mode out
  for mode in direct-PR no-mistakes; do
    out="$TMP_ROOT/dod-$mode.md"
    fm_dod_block "$mode" dod-draft-task > "$out"
    assert_no_grep 'gh pr view' "$out" "$mode: DoD must not document a raw gh draft check"
    # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
    assert_grep 'confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`' "$out" \
      "$mode: DoD must read the draft state through gh-axi"
  done
  pass "PR-based DoD draft check uses gh-axi"
}

test_scout_done_is_not_gated
test_evidence_claim_requires_provenance
test_evidence_claim_enforces_mechanical_provenance
test_scenario_consistency_is_publication_only
test_unpushed_ship_done_is_refused
test_no_mistakes_prevalidation_done_is_not_gated
test_remote_containing_named_head_is_accepted
test_moved_branch_without_named_head_is_refused
test_free_text_sha_is_not_the_named_head
test_recorded_merged_pr_is_landed_after_prune
test_merge_marker_binds_to_the_named_pr
test_forge_recorded_head_is_accepted_without_local_object
test_direct_pr_recorded_head_does_not_cover_unpushed_commit
test_ci_ready_variants_are_gated
test_keyed_and_spaced_done_lines_are_gated
test_local_only_linked_branch_is_accepted
test_local_only_detached_head_is_refused
test_standalone_local_only_needs_project_ref
test_non_done_lines_are_not_gated
test_fenced_and_indented_captain_lines_are_not_intent
test_pr_based_dod_draft_check_uses_gh_axi

echo "all fm-dod-lib tests passed"
