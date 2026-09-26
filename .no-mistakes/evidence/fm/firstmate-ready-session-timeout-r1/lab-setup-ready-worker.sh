#!/usr/bin/env bash
# Hand-publishes a ready ship worker "rt" into a lab FM_HOME, bound to the real
# claude pane lab:fm-rt on the lab tmux socket, aged <age> seconds.
set -eu
ROOT=$1 LAB=$2 AGE=$3
PR=https://github.com/jazz127/firstmate/pull/99999
STATE=$LAB/state
. "$ROOT/bin/fm-pr-lib.sh"
now=$(date +%s)
printf 'window=lab:fm-rt\nproject=firstmate\nkind=ship\nharness=claude\nspawn_gen=gen-1\nworktree=%s\npr=%s\npr_head=%s\n' "$ROOT" "$PR" "$(git -C "$ROOT" rev-parse HEAD)" > "$STATE/rt.meta"
fm_pr_poll_prepare "$STATE" rt github "$PR" github.com jazz127/firstmate 99999 "$ROOT/bin/fm-pr-poll.sh"
fm_pr_poll_publish_prepared
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" rt)
"$ROOT/bin/fm-busy-event.sh" apply "$STATE" rt idle --gen "$gen" --source claude-hook --event stop >/dev/null
printf 'done [at=%s]: PR %s checks green\n' "$((now-AGE))" "$PR" > "$STATE/rt.status"
stamp=$(date -r "$((now-AGE))" +%Y%m%d%H%M.%S)
touch -t "$stamp" "$STATE/rt.status" "$STATE/rt.meta" "$STATE/rt.pr-poll-registration"
for f in "$STATE"/rt.busy*; do touch -t "$stamp" "$f"; done
touch "$STATE/.last-check" "$STATE/.last-heartbeat"
# Mark the published status line as already seen (firstmate read it when it was written).
. "$ROOT/bin/fm-classify-lib.sh"
printf 'v2\t%s\t%s@%s' "$(status_observed_signature "$STATE/rt.status")" \
  "$(LC_ALL=C wc -c < "$STATE/rt.status" | tr -d '[:space:]')" \
  "$(_fm_open_decisions_file_ident "$STATE/rt.status")" > "$STATE/.seen-rt_status"
