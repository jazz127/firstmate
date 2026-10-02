#!/usr/bin/env bash
# Drives the real bin/fm-pr-merge.sh against a disposable, synthetic/offline
# fake `gh` (the test suite's mocks) in throwaway FM_HOME/state dirs.
set -u
cd "$1"
eval "$(sed -n "1,2378p" tests/fm-pr-merge.test.sh | grep -v "^test_[a-z_]*$" | sed "s|\$(dirname \"\${BASH_SOURCE\[0\]}\")|$PWD/tests|")"
OLD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa NEW=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
show() { local d=$1 rc=$2; echo "exit=$rc"; echo "--- stderr"; cat "$d/stderr"; echo "--- stdout"; cat "$d/stdout"; echo "--- fake gh mutating calls"; grep -E 'pr (update-branch|merge)' "$d/gh.log" || echo "(none)"; echo "--- github head now: $(cat "$d/github-head")"; grep '^pr_head=' "$d/state/task-x1.meta" 2>/dev/null; echo; }
behind() { local d=$1; add_gh_mocks "$d" "$OLD"; jq '.mergeStateStatus="BEHIND"' "$d/github-view.json" > "$d/t"; mv "$d/t" "$d/github-view.json"; }

echo "=== S1: green PR behind base, no --update-branch consent"
d=$(make_case s1); behind "$d"
echo '$ fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/6178'
run_pr_merge "$d" task-x1 https://github.com/example/repo/pull/6178 >"$d/stdout" 2>"$d/stderr"; show "$d" $?

echo "=== S2: green PR behind base, --update-branch, updated head green"
d=$(make_case s2); behind "$d"
jq --arg h "$NEW" '.mergeStateStatus="CLEAN"|.headRefOid=$h' "$d/github-view.json" > "$d/github-view-after-update.json"
printf '%s\n' "$NEW" > "$d/github-head-after-update"
echo '$ fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/6178 --update-branch -- --squash'
FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=1 run_pr_merge "$d" task-x1 https://github.com/example/repo/pull/6178 --update-branch -- --squash >"$d/stdout" 2>"$d/stderr"; show "$d" $?

echo "=== S3: --update-branch but a guard refuses (draft PR)"
d=$(make_case s3); behind "$d"; jq '.isDraft=true' "$d/github-view.json" > "$d/t"; mv "$d/t" "$d/github-view.json"
echo '$ fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/6178 --update-branch'
run_pr_merge "$d" task-x1 https://github.com/example/repo/pull/6178 --update-branch >"$d/stdout" 2>"$d/stderr"; show "$d" $?

echo "=== S4: --update-branch, updated head has failed check beside a pending one (CheckRun)"
d=$(make_case s4); behind "$d"
jq --arg h "$NEW" '.mergeStateStatus="CLEAN"|.headRefOid=$h|.statusCheckRollup=[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","name":"slow","status":"IN_PROGRESS","conclusion":null}]' "$d/github-view.json" > "$d/github-view-after-update.json"
printf '%s\n' "$NEW" > "$d/github-head-after-update"
echo '$ fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/6178 --update-branch'
s=$SECONDS; FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=1 run_pr_merge "$d" task-x1 https://github.com/example/repo/pull/6178 --update-branch >"$d/stdout" 2>"$d/stderr"; rc=$?; echo "elapsed_s=$((SECONDS-s))"; show "$d" $rc

echo "=== S5: --update-branch, updated head checks stay pending past the capped wait"
d=$(make_case s5); behind "$d"
jq --arg h "$NEW" '.mergeStateStatus="CLEAN"|.headRefOid=$h|.statusCheckRollup=[{"__typename":"CheckRun","name":"ci","status":"IN_PROGRESS","conclusion":null}]' "$d/github-view.json" > "$d/github-view-after-update.json"
printf '%s\n' "$NEW" > "$d/github-head-after-update"
echo '$ FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=1 fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/6178 --update-branch'
s=$SECONDS; FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=1 run_pr_merge "$d" task-x1 https://github.com/example/repo/pull/6178 --update-branch >"$d/stdout" 2>"$d/stderr"; rc=$?; echo "elapsed_s=$((SECONDS-s))"; show "$d" $rc

echo "=== S6: --update-branch --allow-red ci, updated head briefly mergeable=UNKNOWN then MERGEABLE"
d=$(make_case s6); behind "$d"
jq --arg h "$NEW" '.mergeStateStatus="CLEAN"|.headRefOid=$h|.mergeable="UNKNOWN"|.statusCheckRollup[0].conclusion="FAILURE"' "$d/github-view.json" > "$d/github-view-after-update.json"
jq '.mergeable="MERGEABLE"' "$d/github-view-after-update.json" > "$d/github-view-after-update-final.json"
printf '%s\n' "$NEW" > "$d/github-head-after-update"
echo '$ fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/6178 --update-branch --allow-red ci -- --squash'
FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=1 run_pr_merge "$d" task-x1 https://github.com/example/repo/pull/6178 --update-branch --allow-red ci -- --squash >"$d/stdout" 2>"$d/stderr"; show "$d" $?

echo "=== S7: --update-branch, post-update PR state unreadable"
d=$(make_case s7); behind "$d"; printf '[]\n' > "$d/github-view-after-update.json"; printf '%s\n' "$NEW" > "$d/github-head-after-update"
echo '$ fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/6178 --update-branch -- --merge'
FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 run_pr_merge "$d" task-x1 https://github.com/example/repo/pull/6178 --update-branch -- --merge >"$d/stdout" 2>"$d/stderr"; show "$d" $?

echo "=== S8: --update-branch on GitLab is rejected"
d=$(make_case s8)
echo '$ fm-pr-merge.sh task-x1 https://gitlab.example/group/subgroup/project/-/merge_requests/7 --update-branch'
run_pr_merge "$d" task-x1 "https://gitlab.example/group/subgroup/project/-/merge_requests/7" --update-branch >"$d/stdout" 2>"$d/stderr"; echo "exit=$?"; cat "$d/stderr"
