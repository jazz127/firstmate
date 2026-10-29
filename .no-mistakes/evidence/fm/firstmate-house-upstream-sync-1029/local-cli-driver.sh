#!/usr/bin/env bash
set -euo pipefail
CODE=$PWD
EVID=~/.no-mistakes/evidence/01M639H6QD1WK1K19WXV59CK32
LAB="$CODE/.gate-test-tmp/live"
SOCK="$EVID/fm-lab.sock"
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export TMPDIR="$CODE/.gate-test-tmp"
. "$CODE/tests/git-config-helpers.sh"
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid
export GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
cleanup() { tmux -S "$SOCK" kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
bash bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" FM_DATA_OVERRIDE="$LAB/data"
export FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_RECONCILE_BUDGET_SECS=30
unset FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE FM_DOD_LOCKED_META FM_INACTIVE_CREW_STATE_BIN
tmux -S "$SOCK" new-session -d -s fm-lab-validation -x 100 -y 30 -c "$CODE" 'sleep 600'
export TMUX
TMUX=$(tmux -S "$SOCK" display-message -p '#{socket_path},#{pid},#{session_id}' | sed 's/\$//g')
pane=$(tmux -S "$SOCK" display-message -p '#{pane_id}')
PROJ="$LAB/projects/project"
WT="$LAB/projects/worker"
git init -q -b main "$PROJ"
printf 'initial\n' > "$PROJ/base.txt"
git -C "$PROJ" add .
git -C "$PROJ" commit -qm initial
base=$(git -C "$PROJ" rev-parse HEAD)
git -C "$PROJ" worktree add -q -b fm/child "$WT"
printf 'approved change\n' > "$WT/approved.txt"
git -C "$WT" add .
git -C "$WT" commit -qm approved
approved=$(git -C "$WT" rev-parse HEAD)
cat > "$LAB/state/child.meta" <<EOF
window=$pane
worktree=$WT
project=$PROJ
branch=fm/child
backend=tmux
harness=claude
kind=ship
mode=local-only
spawn_gen=lab-one
EOF
printf 'done: approved local work\n' > "$LAB/state/child.status"
gen=$(bash bin/fm-busy-event.sh arm "$LAB/state" child)
bash bin/fm-busy-event.sh apply "$LAB/state" child idle --gen "$gen" --source claude-hook --event stop
age() { local stamp; stamp=$(date -r "$(( $(date +%s) - 120 ))" +%Y%m%d%H%M.%S); touch -t "$stamp" "$LAB/state/child.meta" "$LAB/state/child.status"; }
age
printf '\nMAIN-HOME CADENCE: first scan\n'
bash bin/fm-inactive-reconcile.sh scan --startup
cat "$LAB/state/child.meta" "$LAB/state/.wake-queue" "$LAB/state/terminal-outcomes/"*.pending
test "$(sed -n 's/^local_done_head=//p' "$LAB/state/child.meta")" = "$approved"
test ! -e "$LAB/state/.meta-child.lock"
test "$(wc -l < "$LAB/state/.wake-queue" | tr -d ' ')" = 1
age
bash bin/fm-inactive-reconcile.sh scan --startup
test "$(wc -l < "$LAB/state/.wake-queue" | tr -d ' ')" = 1
bash bin/fm-crew-state.sh child

printf '\nSECOND-MATE LEDGER: one parent delivery and no duplicates\n'
MATE="$LAB/mate"
bash bin/fm-lab-home.sh create "$MATE"
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB" > "$MATE/.fm-secondmate-parent"
sed '/^local_done_head=/d' "$LAB/state/child.meta" > "$MATE/state/child.meta"
cp "$LAB/state/child.status" "$MATE/state/child.status"
FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash bin/fm-inactive-reconcile.sh scan --startup
cat "$LAB/state/mate.status" "$MATE/state/terminal-outcomes/"*.reported
test "$(sed -n 's/^local_done_head=//p' "$MATE/state/child.meta")" = "$approved"
FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash bin/fm-inactive-reconcile.sh scan --startup
test "$(wc -l < "$LAB/state/mate.status" | tr -d ' ')" = 1

printf '\nADVERSARIAL: branch advances after approved completion\n'
printf 'unapproved\n' > "$WT/later.txt"
git -C "$WT" add .
git -C "$WT" commit -qm later
bash bin/fm-crew-state.sh child | tee "$EVID/stale-head-state.txt"
grep -Fq 'state: blocked' "$EVID/stale-head-state.txt"
if bash bin/fm-merge-local.sh child; then echo 'ERROR: stale branch landed'; exit 1; fi
test "$(git -C "$PROJ" rev-parse HEAD)" = "$base"
test "$(sed -n 's/^local_done_head=//p' "$LAB/state/child.meta")" = "$approved"
printf 'done: later unapproved work\n' >> "$MATE/state/child.status"
FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash bin/fm-inactive-reconcile.sh scan --startup
test "$(wc -l < "$LAB/state/mate.status" | tr -d ' ')" = 1

printf '\nLANDING: restore approved head and land exactly it\n'
git -C "$WT" reset -q --hard "$approved"
bash bin/fm-merge-local.sh child
test "$(git -C "$PROJ" rev-parse HEAD)" = "$approved"
test "$(cat "$PROJ/approved.txt")" = 'approved change'
test ! -e "$PROJ/later.txt"
test -z "$(git -C "$PROJ" status --porcelain)"
git -C "$PROJ" log -2 --oneline

printf '\nADVERSARIAL: malformed approval is refused\n'
cp "$LAB/state/child.meta" "$LAB/original-meta"
sed "s/^local_done_head=.*/local_done_head=${approved:0:8}/" "$LAB/original-meta" > "$LAB/state/child.meta"
if bash bin/fm-merge-local.sh child; then echo 'ERROR: malformed approval landed'; exit 1; fi
cp "$LAB/original-meta" "$LAB/state/child.meta"

printf '\nREVIEW: default and publishing use origin; opt-in local review omits existing local landings\n'
ORIGIN="$LAB/projects/origin.git"
git init -q --bare -b main "$ORIGIN"
git -C "$PROJ" remote add origin "$ORIGIN"
git -C "$PROJ" push -q origin "$base:refs/heads/main"
git -C "$PROJ" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$PROJ" worktree add -q -b fm/review "$LAB/projects/review"
printf 'review only\n' > "$LAB/projects/review/own.txt"
git -C "$LAB/projects/review" add .
git -C "$LAB/projects/review" commit -qm own
printf 'worktree=%s\nproject=%s\nbranch=fm/review\nmode=local-only\n' "$LAB/projects/review" "$PROJ" > "$LAB/state/review.meta"
bash bin/fm-review-diff.sh review > "$EVID/review-default.txt"
touch "$LAB/config/spawn-base-primary-checkout"
bash bin/fm-review-diff.sh review > "$EVID/review-local.txt"
sed 's/mode=local-only/mode=direct-PR/' "$LAB/state/review.meta" > "$LAB/pub-meta"
mv "$LAB/pub-meta" "$LAB/state/review.meta"
bash bin/fm-review-diff.sh review > "$EVID/review-publishing.txt"
grep -q 'approved.txt' "$EVID/review-default.txt"
grep -q 'approved.txt' "$EVID/review-publishing.txt"
! grep -q 'approved.txt' "$EVID/review-local.txt"
grep -q 'own.txt' "$EVID/review-local.txt"
cat "$EVID/review-local.txt" "$EVID/review-publishing.txt"
printf '\nAll direct Git/CLI scenarios completed; no replacement CLI or forge used.\n'
