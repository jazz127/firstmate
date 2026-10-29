#!/usr/bin/env bash
set -euo pipefail
CODE=$PWD
LAB="$CODE/.gate-test-tmp/teardown-live"
EVID=~/.no-mistakes/evidence/01M639H6QD1WK1K19WXV59CK32
mkdir -p "$CODE/.gate-test-tmp/tools"
ln -sf /opt/homebrew/bin/git "$CODE/.gate-test-tmp/tools/git"
ln -sf /opt/homebrew/bin/jq "$CODE/.gate-test-tmp/tools/jq"
ln -sf /opt/homebrew/bin/tmux "$CODE/.gate-test-tmp/tools/tmux"
export PATH="$CODE/.gate-test-tmp/tools:/usr/bin:/bin:/usr/sbin:/sbin"
. "$CODE/tests/git-config-helpers.sh"
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
export TMPDIR="$CODE/.gate-test-tmp"
trap 'rm -rf "$LAB"' EXIT
bash bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config"
export TMUX="$EVID/fm-lab-never.sock,0,0"
PROJ="$LAB/projects/project"
WT="$LAB/projects/worker"
git init -q -b main "$PROJ"
printf 'initial\n' > "$PROJ/base"
git -C "$PROJ" add .
git -C "$PROJ" commit -qm initial
git -C "$PROJ" worktree add -q -b fm/check "$WT"
printf 'a:\n  b: 1\n' > "$WT/config.yml"
git -C "$WT" add .
git -C "$WT" commit -qm 'nested key'
printf 'a:\nb: 1\n' > "$PROJ/config.yml"
git -C "$PROJ" add .
git -C "$PROJ" commit -qm 'independent top-level key'
head=$(git -C "$WT" rev-parse HEAD)
printf 'kind=ship\nmode=no-mistakes\nbranch=fm/check\nproject=%s\nworktree=%s\nwindow=fm-lab-validation:fm-check\nbackend=tmux\nharness=claude\nspawn_gen=lab-one\n' "$PROJ" "$WT" > "$LAB/state/check.meta"
printf '\nUnlanded semantic indentation change: real teardown must refuse\n'
rc=0
bash bin/fm-teardown.sh check > "$EVID/teardown-refusal.txt" 2>&1 || rc=$?
cat "$EVID/teardown-refusal.txt"
test "$rc" -ne 0
grep -Fq 'has work not on any remote and not landed' "$EVID/teardown-refusal.txt"
test -f "$LAB/state/check.meta"
test "$(git -C "$WT" rev-parse HEAD)" = "$head"
test "$(cat "$WT/config.yml")" = $'a:\n  b: 1'
printf '\nDirty untracked work: real teardown must refuse and retain the file\n'
printf 'keep me\n' > "$WT/untracked.txt"
rc=0
bash bin/fm-teardown.sh check > "$EVID/teardown-dirty-refusal.txt" 2>&1 || rc=$?
cat "$EVID/teardown-dirty-refusal.txt"
test "$rc" -ne 0
test "$(cat "$WT/untracked.txt")" = 'keep me'
test -f "$LAB/state/check.meta"
printf '\nBoth refusals retained the exact worker commit, files and metadata. No forge or replacement Git used.\n'
