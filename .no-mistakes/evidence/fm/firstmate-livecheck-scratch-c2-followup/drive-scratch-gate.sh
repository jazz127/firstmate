#!/usr/bin/env bash
# Live driver: real fm-crew-state.sh / fm-pr-body-preflight.sh against a lab FM_HOME,
# a real lab tmux pane, and real git repos reproducing the quota-axi PR 289 scratch bundle.
set -u
ROOT=$1 LAB=$2
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export TMUX_TMPDIR="$LAB/tmux"
tmux -L fm-lab new-session -d -s fm -n fm-lab-scratch "sleep 600"
tmux -L fm-lab new-window -d -t fm: -n fm-lab-clean "sleep 600"
tmux -L fm-lab new-window -d -t fm: -n fm-lab-gone "sleep 600"
SOCK=$(tmux -L fm-lab display-message -p '#{socket_path}')
export TMUX="$SOCK,$$,0"
G="$LAB/git"; mkdir -p "$G"
git init -q --bare -b main "$G/origin.git"
git clone -q "$G/origin.git" "$G/project" 2>/dev/null
git -C "$G/project" -c user.name=L -c user.email=l@x commit -q --allow-empty -m init
git -C "$G/project" push -q origin main
git -C "$G/project" remote set-head origin main
mkwt() {  # <name> <branch>
  git -C "$G/project" worktree add -q -b "$2" "$G/$1" main
  git -C "$G/$1" config user.name L; git -C "$G/$1" config user.email l@x
  for i in $(seq 1 10); do printf 'product %s\n' "$i" > "$G/$1/src$i.txt"; done
  git -C "$G/$1" add . && git -C "$G/$1" commit -q -m 'intended ten files'
}
bundle() {  # <wt> : the 8-file corepack pnpm bundle from quota-axi PR 289
  local d="$G/$1/.codex-live-check/cache/node/corepack/v1/pnpm/11.1.1"
  mkdir -p "$d/bin" "$d/dist"
  for f in LICENSE README.md package.json bin/pnpm.cjs bin/pnpx.cjs dist/pnpm.cjs dist/worker.js .corepack; do
    printf 'vendored %s\n' "$f" > "$d/$f"; done
  git -C "$G/$1" add -f .codex-live-check && git -C "$G/$1" commit -q -m 'fix round (harness scratch rode along)'
}
meta() {  # <id> <wt> <mode> <extra...>
  local id=$1 wt=$2 mode=$3; shift 3
  { printf 'kind=ship\nmode=%s\nharness=claude\nbackend=tmux\nwindow=fm:%s\nworktree=%s\nproject=%s\n' \
      "$mode" "$id" "$wt" "$G/project"; for kv in "$@"; do printf '%s\n' "$kv"; done; } > "$LAB/state/$id.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" "$id" idle --gen "$gen" --source claude-hook --event stop >/dev/null
}
GERRIT=https://review.example.test/c/o/r/+/42
echo "=== S1: recorded Gerrit PR, fix-round commit adds PR-289 corepack bundle -> ship done: must be blocked"
mkwt wt-scratch fm/lab-scratch; bundle wt-scratch
git -C "$G/wt-scratch" push -q origin fm/lab-scratch
meta fm-lab-scratch "$G/wt-scratch" direct-PR "pr=$GERRIT"
printf 'done: PR %s published\n' "$GERRIT" > "$LAB/state/fm-lab-scratch.status"
echo "\$ fm-crew-state.sh fm-lab-scratch"; FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" fm-lab-scratch
echo
echo "=== S2: same recorded Gerrit PR, clean branch (no scratch) -> ship done: accepted"
mkwt wt-clean fm/lab-clean
git -C "$G/wt-clean" push -q origin fm/lab-clean
meta fm-lab-clean "$G/wt-clean" direct-PR "pr=$GERRIT"
printf 'done: PR %s published\n' "$GERRIT" > "$LAB/state/fm-lab-clean.status"
echo "\$ fm-crew-state.sh fm-lab-clean"; FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" fm-lab-clean
echo
echo "=== S3: worker pre-publication preflight on the scratch worktree (before any push)"
mkwt wt-pre fm/lab-pre; bundle wt-pre
echo "\$ fm-pr-body-preflight.sh --scratch wt-pre"; "$ROOT/bin/fm-pr-body-preflight.sh" --scratch "$G/wt-pre"; echo "exit=$?"
echo "\$ git status after preflight (nothing pushed):"; git -C "$G/project" ls-remote origin 'refs/heads/fm/lab-pre' | wc -l | sed 's/^ */remote refs for fm\/lab-pre: /'
echo "--- staged-but-uncommitted scratch (adversarial: index path)"
mkwt wt-idx fm/lab-idx; mkdir -p "$G/wt-idx/.codex-live-check/cache"; echo x > "$G/wt-idx/.codex-live-check/cache/a.js"; git -C "$G/wt-idx" add -f .codex-live-check
"$ROOT/bin/fm-pr-body-preflight.sh" --scratch "$G/wt-idx"; echo "exit=$?"
echo "--- clean worktree"
"$ROOT/bin/fm-pr-body-preflight.sh" --scratch "$G/wt-clean"; echo "exit=$?"
echo "--- adversarial: scratch added then deleted on branch (net diff clean)"
mkwt wt-del fm/lab-del; bundle wt-del; git -C "$G/wt-del" rm -rq .codex-live-check; git -C "$G/wt-del" commit -q -m 'remove scratch'
"$ROOT/bin/fm-pr-body-preflight.sh" --scratch "$G/wt-del"; echo "exit=$?"
echo
echo "=== S4: recorded GitHub pr_head no-mistakes, worktree torn down -> ship done: not refused by scratch check"
meta fm-lab-gone "$G/wt-missing" no-mistakes "pr=https://github.com/o/r/pull/5" "pr_head=0123456789abcdef0123456789abcdef01234567"
printf 'done: PR https://github.com/o/r/pull/5 checks green\n' > "$LAB/state/fm-lab-gone.status"
echo "\$ fm-crew-state.sh fm-lab-gone"; FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" fm-lab-gone
tmux -L fm-lab kill-server
