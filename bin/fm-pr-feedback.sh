#!/usr/bin/env bash
# One opt-in, token-free GitHub PR feedback check for this home's ship tasks.
# Usage: fm-pr-feedback.sh arm|disarm|poll|enabled
#
# arm binds state/pr-feedback.check.sh through fm-check-register.sh; disarm
# removes only that shim and binding. The ordinary watcher slow-check cadence
# and FM_CHECK_TIMEOUT apply. No scheduler, forge writes, or model calls run.
# poll scans recorded GitHub pr= values and attributed no-mistakes runs (whose
# PR may not be registered yet), including delivered tasks awaiting merge.
# GitLab, Gerrit, remote secondmates and retired task metadata are out of scope.
# New reviews, inline and conversation comments, terminal CI states, and parked
# pipeline gates become concise task-inbox pointers, batched into one message
# and one doorbell per task per sweep. The authenticated GitHub
# login's own feedback is excluded; bots are included. Existing feedback is
# delivered on the first sweep. Inbox root and handled/ records are the only
# delivery history; no new cursor store is maintained. A poll lock serializes
# concurrent sweeps. One summary line per batch informs firstmate, naming
# relaunch=<ids> when a worker has exited; only firstmate controls relaunch.
# An interrupted sweep flushes its unfinished task names before the shared
# check timeout kills its group; size FM_CHECK_TIMEOUT for the home's API load.
#
# Internal bridge operations used by fm-pr-feedback.py:
#   pipeline <task> <observed-run-ids>  attributed read-only axi status, or empty
#   deliver <task> <meta-hash> <message>  idempotent existing-inbox enqueue/ring
#   github <url>                canonical GitHub path and PR number
# They revalidate task identity; forge prose is never an instruction payload.
# Dependencies: Python 3 and gh-axi, plus no-mistakes for pipeline events.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME FM_STATE_OVERRIDE="$STATE"

# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
die() { printf 'pr-feedback: %s\n' "$*" >&2; exit 1; }

case "${1:---help}" in
  --help|-h) usage; exit 0 ;;
  arm|disarm|poll|enabled) [ "$#" -eq 1 ] || die "expected one operation" ;;
  pipeline) [ "$#" -eq 3 ] || die "expected a task and observed run IDs" ;;
  github) [ "$#" -eq 2 ] || die "expected a PR URL" ;;
  deliver) [ "$#" -eq 4 ] || die "expected a task, metadata hash and message" ;;
  *) die "unknown operation" ;;
esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
FM_HOME=$(CDPATH='' cd -- "$FM_HOME" && pwd -P) || die "home directory is unavailable"
STATE=$(CDPATH='' cd -- "$STATE" && pwd -P) || die "state directory is unavailable"
export FM_HOME FM_STATE_OVERRIDE="$STATE"

case "$1" in
  github)
    fm_pr_url_parse "$2" && [ "$FM_PR_PROVIDER" = github ] || die "expected a canonical GitHub PR"
    printf '%s\n%s\n' "$FM_PR_PATH" "$FM_PR_NUMBER"
    ;;
  enabled) fm_custom_check_registered "$STATE" pr-feedback; exit ;;
  disarm) exec "$SCRIPT_DIR/fm-check-unregister.sh" pr-feedback ;;
  arm)
    command -v python3 >/dev/null || die "Python 3 is required"
    command -v gh-axi >/dev/null || die "gh-axi is required"
    [ ! -e "$STATE/pr-feedback.meta" ] || die "check name belongs to a task"
    shim="$STATE/pr-feedback.check.sh"
    device=$(fm_pr_file_device "$STATE")
    fm_pr_regular_destination_on_device_or_absent "$shim" "$device" || die "unsafe check path"
    tmp=$(mktemp "$STATE/.pr-feedback-shim.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    {
      printf '#!/usr/bin/env bash\n'
      printf 'export FM_HOME=%q FM_STATE_OVERRIDE=%q\n' "$FM_HOME" "$STATE"
      [ -z "${FM_CONFIG_OVERRIDE:-}" ] || printf 'export FM_CONFIG_OVERRIDE=%q\n' "$FM_CONFIG_OVERRIDE"
      printf 'exec %q poll\n' "$SCRIPT_DIR/fm-pr-feedback.sh"
    } > "$tmp"
    chmod 0700 "$tmp"
    mv -f -- "$tmp" "$shim"
    "$SCRIPT_DIR/fm-check-register.sh" pr-feedback >/dev/null
    printf 'armed: state/pr-feedback.check.sh\n'
    ;;
  poll)
    fm_custom_check_registered "$STATE" pr-feedback || die "check is not armed"
    lock="$STATE/.pr-feedback.lock"
    fm_task_inbox_lock_acquire "$lock" || exit 0
    trap 'fm_lock_release "$lock"' EXIT
    python3 "$SCRIPT_DIR/fm-pr-feedback.py" "$STATE" "$SCRIPT_DIR/fm-pr-feedback.sh"
    ;;
  pipeline|deliver)
    task=$2
    fm_pr_task_id_valid "$task" || die "invalid task"
    meta="$STATE/$task.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || die "task metadata unavailable"
    [ "$(fm_meta_get "$meta" kind)" = ship ] || die "expected a ship"
    [ -z "$(fm_meta_get "$meta" remote_host)" ] || die "remote task is out of scope"
    if [ "$1" = pipeline ]; then
      [ "$(fm_meta_get "$meta" mode)" = no-mistakes ] || exit 0
      wt=$(fm_meta_get "$meta" worktree)
      [ -d "$wt" ] || exit 0
      branch=$(fm_meta_get "$meta" branch)
      [ -n "$branch" ] || branch=$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null) || exit 0
      overview=$(fm_nm_run_checked "$wt" 3 axi) || exit 1
      selection=$(fm_nm_select_run "$branch" "$overview" "$wt" 3)
      case "$selection" in
        selected\|*) IFS='|' read -r _ run_id selected_status _ <<< "$selection" ;;
        absent) exit 0 ;;
        *) exit 1 ;;
      esac
      out=$(fm_nm_run_checked "$wt" 3 axi status --run "$run_id") || exit 1
      [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")" = "$run_id" ] || exit 1
      case "$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")" in
        pending|running|fixing|ci|awaiting_approval|fix_review|completed|failed|cancelled) ;;
        *) exit 1 ;;
      esac
      if fm_nm_run_is_active "$out"; then run_class=live; else run_class=terminal; fi
      [ "$(fm_nm_run_status_class "$selected_status")" = "$run_class" ] || exit 1
      [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")" = "$branch" ] || exit 0
      head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head_sha)")
      [ -n "$head" ] || head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")
      if ! fm_nm_head_matches_worktree "$wt" "$head" \
        && ! fm_nm_run_is_pipeline_owned_active "$out"; then
        if [ "$run_class" = terminal ]; then
          case ",$3," in *,"$run_id",*) ;; *) exit 0 ;; esac
        else
          fm_nm_run_is_executing "$out" || exit 0
          fm_nm_run_checked "$wt" 3 daemon status >/dev/null || exit 1
        fi
      fi
      printf '%s\n' "$out"
      status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
      if ! fm_nm_run_is_parked "$out" && fm_nm_run_is_active "$out" \
        && ! printf '%s\n' "$out" | grep -Eq '^[[:space:]]*ci,[[:space:]]*"?fixing"?[[:space:]]*,' \
        && { [ "$status" = ci ] || { [ "$status" = running ] \
          && printf '%s\n' "$out" | grep -Eq '^[[:space:]]*ci,[[:space:]]*"?running"?[[:space:]]*,'; }; }; then
        if [ "$(fm_nm_ci_checks_state "$wt" "$run_id" 3)" = green ]; then
          ci_head=$(fm_nm_resolve_commit "$wt" "$head")
          printf 'feedback_ci_head: %s\n' "${ci_head:-$head}"
        fi
      fi
    else
      lock=$(fm_meta_lock_path "$meta")
      fm_task_inbox_lock_acquire "$lock" || die "cannot lock task metadata"
      trap 'fm_lock_release "$lock"' EXIT
      [ "$(fm_custom_check_sha256 "$meta")" = "$3" ] || die "task metadata changed"
      for dir in "$STATE/$task.inbox" "$STATE/$task.inbox/handled"; do
        if [ -L "$dir" ]; then die "unsafe task inbox"; fi
        if [ -e "$dir" ] && [ ! -d "$dir" ]; then die "unsafe task inbox"; fi
      done
      rec=$(fm_task_inbox_write_idempotent "$STATE" "$task" "$4") || die "inbox enqueue failed"
      backend=$(fm_backend_of_meta "$meta")
      target=$(fm_backend_target_of_meta "$meta") || target=
      fm_lock_release "$lock"
      trap - EXIT
      if [ "${rec%/*}" = "$STATE/$task.inbox/handled" ]; then
        printf 'delivered\n'
        exit 0
      fi
      ring_rc=0
      if [ -n "$target" ]; then
        fm_task_inbox_ring "$backend" "$target" "$rec" "fm-$task" || ring_rc=$?
      else
        ring_rc=3
      fi
      if [ "$ring_rc" -eq 3 ]; then printf 'relaunch\n'; else printf 'delivered\n'; fi
    fi
    ;;
esac
