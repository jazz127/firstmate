#!/usr/bin/env bash
set -euo pipefail
CODE=$PWD
EVID=~/.no-mistakes/evidence/01M639H6QD1WK1K19WXV59CK32
LAB="$CODE/.gate-test-tmp/spawn-live"
SOCK="$EVID/fm-lab-spawn.sock"
export TMPDIR="$CODE/.gate-test-tmp"
. tests/git-config-helpers.sh
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
cleanup() {
  tmux -S "$SOCK" kill-server 2>/dev/null || true
  # The product deliberately makes hook snapshots read-only.
  python3 - "$LAB" <<'PY'
import os,sys
for path,dirs,files in os.walk(sys.argv[1],followlinks=False):
    os.chmod(path,0o700)
PY
  rm -rf "$LAB"
}
trap cleanup EXIT
bash bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config"
export TREEHOUSE_ROOT="$LAB/pool" HISTFILE="$LAB/history" SHELL=/bin/bash
printf 'manual\n' > "$LAB/config/backlog-backend"
PROJ="$LAB/projects/project"
ORIGIN="$LAB/projects/origin.git"
git init -q -b main "$PROJ"
printf 'remote base\n' > "$PROJ/base.txt"
git -C "$PROJ" add .
git -C "$PROJ" commit -qm base
git clone -q --bare "$PROJ" "$ORIGIN"
git -C "$PROJ" remote add origin "$ORIGIN"
git -C "$PROJ" fetch -q origin
git -C "$PROJ" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
remote=$(git -C "$PROJ" rev-parse origin/main)
printf 'local landing\n' > "$PROJ/local.txt"
git -C "$PROJ" add .
git -C "$PROJ" commit -qm 'local landing'
local_head=$(git -C "$PROJ" rev-parse HEAD)
git -C "$PROJ" push -q origin "$remote:refs/heads/feature"
tmux -S "$SOCK" new-session -d -s fm-lab-spawn -x 110 -y 35 -c "$CODE" 'sleep 600'
export TMUX
TMUX=$(tmux -S "$SOCK" display-message -p '#{socket_path},#{pid},#{session_id}' | sed 's/\$//g')
for variant in default optin publishing explicit-base runtime; do
  id="lab-$variant"
  [ "$variant" != optin ] || touch "$LAB/config/spawn-base-primary-checkout"
  mode=local-only
  case "$variant" in publishing|explicit-base) mode=direct-PR ;; esac
  if [ "$variant" = runtime ]; then
    git -C "$PROJ" config firstmate.runtimeBranch main
    git -C "$PROJ" config branch.main.remote origin
    git -C "$PROJ" config branch.main.merge refs/heads/main
  fi
  base_args=()
  [ "$variant" != explicit-base ] || base_args=(--base-branch feature)
  bash bin/fm-brief.sh "$id" lab-project --mode "$mode" ${base_args[@]+"${base_args[@]}"} > /dev/null
  python3 - "$LAB/data/$id/brief.md" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text().replace('{TASK}', 'Observe the launch base, make no edits, do not publish, do not start no-mistakes, and stop.').replace('{FIRSTMATE_SPEC}', 'This is a disposable launch verification. Do not run setup or create a task branch. Remain idle for inspection.')
p.write_text(s)
PY
  bash bin/fm-dispatch-resolve.sh "$LAB/data/$id/brief.md"
  printf '\nREAL SPAWN variant=%s expected-origin=%s expected-local=%s\n' "$variant" "$remote" "$local_head"
  bash bin/fm-spawn.sh "$id" "$PROJ" --mode "$mode" --yolo off --harness codex --backend tmux --effort low ${base_args[@]+"${base_args[@]}"}
  cat "$LAB/state/$id.meta"
  wt=$(sed -n 's/^worktree=//p' "$LAB/state/$id.meta")
  actual=$(git -C "$wt" rev-parse HEAD)
  printf 'observed worktree HEAD=%s\n' "$actual"
  expected=$remote
  [ "$variant" != optin ] || expected=$local_head
  test "$actual" = "$expected"
  target=$(sed -n 's/^window=//p' "$LAB/state/$id.meta")
  sleep 3
  tmux -S "$SOCK" display-message -p -t "$target" 'foreground=#{pane_current_command} grid=#{pane_width}x#{pane_height}'
  tmux -S "$SOCK" capture-pane -p -t "$target" > "$EVID/spawn-$variant-pane.txt"
done
printf '\nReal tmux and Treehouse selected the required origin/local bases. Canonical Codex launched; no trust accepted or model result claimed.\n'
