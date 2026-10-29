# shellcheck shell=bash disable=SC2034
# fm-secondmate-restart-lib.sh - the shared contract for restarting a second
# mate onto the current instruction surface and launch-time wiring. Source only.
#
# Two consumers, one owner:
#   - bin/fm-update.sh decides WHICH live mates belong in the restart set, so it
#     needs the capability test before it prints its action lines.
#   - bin/fm-secondmate-restart.sh performs the pass, so it needs the same test
#     again on its own argv rather than trusting a caller's list.
#
# The capability test is the pre-stop half of the control plane's own refusals
# (bin/fm-control-lib.sh owns those tables): a mate whose recorded backend has
# no recovery-grade agent-state classifier or cannot launch a replacement agent,
# or whose harness has no verified control mechanics, can never have "the old
# agent stopped and the replacement came up" proven for it. Asking here keeps
# that verdict on the side of the transaction where nothing has been touched
# yet, so an incapable mate is routed to the ordinary re-read nudge instead of
# being stopped for a launch that must be refused.
#
# Placement is resolved from the same remote_host= signal bin/fm-send.sh routes
# on, and it changes only the transport: the restart itself is bin/fm-control.sh
# <id> relaunch either way, run here for a local mate and run on the host over
# bin/fm-on.sh for a remote one.

_FM_SECONDMATE_RESTART_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh disable=SC1091
. "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-control-lib.sh"

# The persist request the primary sends before it restarts anything. It is the
# open-record half of /stow and nothing more: a restart needs the state of work
# written down, not a memory curation pass, and bundling one would make every
# instruction update cost far more than the reload it is paying for.
# The mate answers through its parent channel, which is what resolves the
# parent-owned reply expectation fm-send arms for a marked request; only that
# correlated terminal `done` answer, never the wall clock, releases the restart.
FM_SECONDMATE_PERSIST_REQUEST='Firstmate was updated and I am about to restart your agent so it comes up on the current instructions and launch-time settings, which drops your conversation but keeps every durable record. Before that, persist the open work you are holding only in this conversation, following the /stow skill'"'"'s "Open-record persistence" section and nothing else from that skill: file a task for each open record that exists only in this conversation, including any captain call you had formed but never registered, and correct any task whose status no longer reflects what you now know. Do NOT run the memory, learnings, or captain-preference sweeps. Then reply on your parent channel with a done status saying it is done, including anything you deliberately left alone and why; if you could not write it down, reply blocked or failed and say why instead.'

# Resolve one mate's restart capability from its durable record alone.
# Publishes, on success:
#   FM_SECONDMATE_RESTART_PLACEMENT  local|remote
#   FM_SECONDMATE_RESTART_BACKEND    the backend whose classifier must prove the stop
#   FM_SECONDMATE_RESTART_HARNESS    the verified control adapter it runs on
#   FM_SECONDMATE_RESTART_HOST       the configured host (remote placement only)
# and on failure sets FM_SECONDMATE_RESTART_REASON to one operator-readable line.
FM_SECONDMATE_RESTART_PLACEMENT=""
FM_SECONDMATE_RESTART_BACKEND=""
FM_SECONDMATE_RESTART_HARNESS=""
FM_SECONDMATE_RESTART_HOST=""
FM_SECONDMATE_RESTART_REASON=""
fm_secondmate_restart_capable() {  # <meta-file>
  local meta=$1 kind window remote_host backend harness family
  FM_SECONDMATE_RESTART_PLACEMENT=""
  FM_SECONDMATE_RESTART_BACKEND=""
  FM_SECONDMATE_RESTART_HARNESS=""
  FM_SECONDMATE_RESTART_HOST=""
  FM_SECONDMATE_RESTART_REASON=""

  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    FM_SECONDMATE_RESTART_REASON="no durable record for this second mate in this home"
    return 1
  fi
  kind=$(fm_meta_get "$meta" kind)
  if [ "$kind" != secondmate ]; then
    FM_SECONDMATE_RESTART_REASON="the durable record is not a second mate's"
    return 1
  fi
  window=$(fm_meta_get "$meta" window)
  if [ -z "$window" ]; then
    FM_SECONDMATE_RESTART_REASON="the durable record names no endpoint, so there is no agent to replace"
    return 1
  fi
  harness=$(fm_meta_get "$meta" harness)
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    FM_SECONDMATE_RESTART_PLACEMENT=remote
    FM_SECONDMATE_RESTART_HOST=$remote_host
    # A remote mate's endpoint record lives on its host; the parent's own record
    # names the backend that launch established there, and the remote route
    # accepts nothing but herdr.
    backend=$(fm_meta_get "$meta" remote_backend)
    [ -n "$backend" ] || backend=herdr
  else
    FM_SECONDMATE_RESTART_PLACEMENT=local
    backend=$(fm_backend_of_meta "$meta")
  fi
  FM_SECONDMATE_RESTART_BACKEND=$backend
  if ! fm_control_backend_state_verified "$backend"; then
    FM_SECONDMATE_RESTART_REASON="its runtime cannot prove an agent stopped and came back (backend $backend)"
    return 1
  fi
  if ! fm_control_backend_relaunch_supported "$backend"; then
    FM_SECONDMATE_RESTART_REASON="its runtime cannot launch a replacement agent (backend $backend)"
    return 1
  fi
  if ! family=$(fm_control_harness_family "$harness") \
    || ! fm_control_harness_supported "$family" \
    || ! fm_control_harness_supports_kind "$family" secondmate; then
    FM_SECONDMATE_RESTART_REASON="its worker runtime '${harness:-none}' has no verified restart mechanics for a second mate"
    return 1
  fi
  FM_SECONDMATE_RESTART_HARNESS=$family
  return 0
}

# Caller holds the home's task-set lock through the stop, preventing a child
# spawn from publishing between this preflight and the verified agent exit.
# Like retirement's preflight, any child record still owns potentially unlanded
# work even when its endpoint is stopped or its last status says done.
fm_secondmate_pause_home_valid() { # <home> <id>
  local home=$1 id=$2
  [ -d "$home" ] && [ ! -L "$home" ] \
    && [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] \
    && [ "$(cat "$home/.fm-secondmate-home")" = "$id" ] \
    && [ -d "$home/state" ] && [ ! -L "$home/state" ] \
    || { echo "error: $id has no safe seeded home to pause" >&2; return 1; }
}

fm_secondmate_pause_safe() { # <home> <id>
  local home=$1 id=$2 child dirty backend backlog rows count
  fm_secondmate_pause_home_valid "$home" "$id" || return 1
  for child in "$home/state"/*.meta "$home/state"/*.backlog-close; do
    if [ -e "$child" ] || [ -L "$child" ]; then
      echo "error: cannot pause $id: in-flight or unlanded work remains at $child; finish and land it first" >&2
      return 1
    fi
  done
  # Ask the backlog's existing owner, including non-markdown adapters, rather
  # than assuming absent child metadata proves there is no in-flight work.
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$_FM_SECONDMATE_RESTART_LIB_DIR/fm-backlog-transition-lib.sh"
  backend=$(fm_tasks_axi_backend "$home") || return 1
  backlog="$home/data/backlog.md"
  if [ "$backend" != markdown ] || [ -e "$backlog" ] || [ -L "$backlog" ]; then
    if [ "$backend" = markdown ] && { [ ! -f "$backlog" ] || [ -L "$backlog" ]; }; then
      echo "error: cannot pause $id: unsafe backlog" >&2; return 1
    fi
    rows=$(fm_backlog_row_list "$home/data" --state in_flight) || {
      echo "error: cannot inspect $id's in-flight backlog: $rows" >&2; return 1;
    }
    count=$(printf '%s\n' "$rows" | sed -n 's/^count: //p')
    [ "$count" = 0 ] || {
      echo "error: cannot pause $id: in-flight backlog work remains or its count is unreadable" >&2; return 1;
    }
  fi
  dirty=$(git -C "$home" status --porcelain 2>/dev/null) \
    || { echo "error: cannot inspect $id's home before pausing" >&2; return 1; }
  [ -z "$dirty" ] \
    || { echo "error: cannot pause $id: its home has uncommitted work" >&2; return 1; }
}
