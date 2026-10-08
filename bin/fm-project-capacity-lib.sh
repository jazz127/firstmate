#!/usr/bin/env bash
# fm-project-capacity-lib.sh - how many workers a project admits at once on this
# machine, and whether a fresh worker spawn still fits.
#
# A project can depend on a machine-local resource that only a few workers can
# use at the same time: a heavy test suite, a local editor stack, a device.
# Firstmate cannot see which part of a worker's life touches that resource, so
# the captain declares how many workers the project admits on this machine, and
# bin/fm-spawn.sh defers a fresh worker beyond that number instead of launching
# it only to spend full-context turns retrying the resource. A deferred task
# keeps its queued backlog item and is dispatched again when a place frees.
# Without a declaration nothing changes and dispatch stays uncapped
# (AGENTS.md section 7).
#
# This file is the single owner of the declaration format, of what holds a
# place, and of the admission verdict. docs/configuration.md "Project capacity"
# is the operator reference, and bin/fm-spawn.sh owns where the check runs.
#
# Declaration: config/project-capacity in the local root Firstmate home (the home
# bin/fm-wake-lib.sh's fm_firstmate_root_home resolves), so every home on this
# machine reads the same number for the same machine's resources. One line per
# project:
#   <project-name> <capacity>
# <project-name> is the project's registered name, which is the basename of its
# clone directory, and <capacity> is a positive integer of at most six digits,
# without leading zeros.
# The capacity is the last whitespace-separated field, so the name before it may
# contain spaces. Blank lines are ignored. A line is a comment when it is `#`,
# when `#` is followed by whitespace, or when it starts with `#` and its last
# field is not an integer. A project whose name begins with `#` is declared by
# writing that `#` immediately against the rest of the name and ending the line
# with the capacity, for example `#repo 2`. A name that is `#`, or that begins
# with `#` followed by a space, is the same spelling as a comment and cannot be
# declared. Any other shape, a project named twice, or an unreadable file makes
# the whole declaration unreadable, and bin/fm-spawn.sh then refuses every fresh
# ship or scout spawn from this machine's homes rather than guessing which limit
# was meant.
#
# Occupancy: a place is held by every task record, in any local Firstmate home on
# this machine (fm_local_firstmate_state_dirs in bin/fm-wake-lib.sh), that
#   - is not a secondmate, which is a persistent home rather than a worker,
#   - names the same project identity, meaning its project resolves to the same
#     shared project lock path (fm_treehouse_project_lock_path), which is keyed
#     by the project's resolved origin, so workers in any clone of that origin
#     are counted, and
#   - has no recorded PR handoff: the pr= line bin/fm-pr-check.sh records when a
#     worker's PR is ready, after which the worker waits on review or merge and
#     no longer uses local resources.
# A place therefore frees when a PR-based ship records its ready PR, or when any
# task is cleaned up and its record removed. A local-only ship and a scout have
# no recorded handoff and hold their place until cleanup. A worker that is
# steered back into work after its PR handoff is not counted again.
# The declaration is matched by the spawning clone's directory name, so clones
# of one origin share the cap only when they use that same directory name. A
# clone of that origin under a different directory name finds no declaration
# and is not capped, though its workers still count as holders for a
# same-origin clone that is capped.
# A record whose project directory no longer exists cannot be matched and holds
# no place. Remote homes are never walked, because their workers run on another
# machine.
#
# Race safety: admission and reservation publication run under the shared
# project lock. A pending admission holds a process-owned reservation beside
# that lock until its task metadata takes over, including while Treehouse or
# Herdr ordering releases the project lock. Every fresh backend reserves when
# any project is capped, including an uncapped same-origin clone and Orca.
# Reservations name the canonical task state directory, id, and spawn_gen; only
# metadata with the same spawn_gen supersedes its reservation. Until then, the
# reservation holds one place even if an older PR-ready record survives a
# restart, and that older record is excluded so the task counts once. Successful
# publication retires the reservation before releasing the project lock; failed
# launches retire it in their EXIT cleanup. Counting reaps reservations whose
# original process is proven gone using the PID-start identity lock machinery;
# uncertain identity remains occupied. Prepared directories are renamed into
# the counted namespace atomically so interrupted writes cannot hide a holder.
# Retirement atomically renames a reservation out of that namespace before
# deleting its contents. A reader ignores a reservation that disappeared
# during its snapshot, but surviving unreadable or malformed state refuses
# admission. tests/fm-project-capacity.test.sh pins restart handoff and retirement.
# Freeing a place needs no lock, because removing a record or reservation, or
# adding pr=, only ever lowers the count.
#
# Requires bin/fm-wake-lib.sh (root home, local homes, project lock path),
# bin/fm-secondmate-registry-lib.sh (which the local-homes walk reads), and
# bin/fm-backend.sh (fm_meta_get) to be sourced first. No side effects on source.

# Exit status of a spawn deferred because the project is at capacity: the
# sysexits "temporary failure" code, so a caller can tell a deferral that leaves
# the task queued from an ordinary failure.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_PROJECT_CAPACITY_DEFER_EXIT=75

# The config directory holding this machine's declaration: the spawning home's
# own <config-dir> when that home is the local root (so an override of it
# applies), otherwise the root home's config/.
fm_project_capacity_config_dir() {  # <spawning-home> <spawning-config-dir>
  local home=$1 config=$2 root home_real
  root=$(fm_firstmate_root_home "$home") || return 1
  home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  if [ "$root" = "$home_real" ]; then
    printf '%s\n' "$config"
  else
    printf '%s/config\n' "$root"
  fi
}

# Read the declared capacity for one project.
# Sets FM_PROJECT_CAPACITY_FILE to the declaration path, FM_PROJECT_CAPACITY
# to the project's capacity, or to empty when the project declares none, and
# FM_PROJECT_CAPACITY_ANY to 1 when the declaration caps any project at all.
# Returns 1 with FM_PROJECT_CAPACITY_ERROR when the declaration is unreadable.
fm_project_capacity_lookup() {  # <config-dir> <project-name>
  local name=$2 line lineno=0 pname pcap seen='|'
  FM_PROJECT_CAPACITY_FILE="$1/project-capacity"
  FM_PROJECT_CAPACITY=
  FM_PROJECT_CAPACITY_ANY=
  FM_PROJECT_CAPACITY_ERROR=
  if [ ! -e "$FM_PROJECT_CAPACITY_FILE" ] && [ ! -L "$FM_PROJECT_CAPACITY_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_PROJECT_CAPACITY_FILE" ] || [ ! -r "$FM_PROJECT_CAPACITY_FILE" ]; then
    FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    # '#' followed by whitespace is always a comment, including one that ends
    # with a number. A line that begins with '#' glued to the rest of a name is
    # a declaration only when its last field is an integer; any other such line
    # stays a comment, so a note does not refuse every spawn.
    case "$line" in
      '' | '#' | '#'[[:space:]]*) continue ;;
      '#'*)
        case "${line##*[[:space:]]}" in
          *[!0-9]*) continue ;;
        esac
        ;;
    esac
    # The capacity is the last field, so the name before it may hold spaces.
    pcap=${line##*[[:space:]]}
    pname=${line%"$pcap"}
    pname=${pname%"${pname##*[![:space:]]}"}
    if [ -z "$pname" ]; then
      FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno is not '<project-name> <capacity>'"
      FM_PROJECT_CAPACITY=
      return 1
    fi
    case "$pcap" in
      '' | *[!0-9]* | 0*)
        FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno gives $pname a capacity that is not a positive integer"
        FM_PROJECT_CAPACITY=
        return 1
        ;;
    esac
    if [ "${#pcap}" -gt 6 ]; then
      FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno gives $pname a capacity longer than six digits"
      FM_PROJECT_CAPACITY=
      return 1
    fi
    case "$seen" in
      *"|$pname|"*)
        FM_PROJECT_CAPACITY_ERROR="$FM_PROJECT_CAPACITY_FILE line $lineno names $pname a second time"
        FM_PROJECT_CAPACITY=
        return 1
        ;;
    esac
    seen="$seen$pname|"
    [ "$pname" != "$name" ] || FM_PROJECT_CAPACITY=$pcap
  done < "$FM_PROJECT_CAPACITY_FILE"
  [ "$seen" = '|' ] || FM_PROJECT_CAPACITY_ANY=1
  return 0
}

# Count the task records holding a place in one project's capacity.
# <project-lock> is fm_treehouse_project_lock_path for the project being
# admitted, and <project-dir> is that project's own directory, which matches
# without recomputing its identity. The local homes come from
# fm_local_firstmate_state_dirs <first-state>. <own-id> is the task being
# admitted; its own record in <first-state> is the one this spawn replaces, so
# it is not counted.
# Sets FM_PROJECT_CAPACITY_OCCUPANTS to the count and
# FM_PROJECT_CAPACITY_OCCUPANT_IDS to a comma-separated list of the holders,
# each outside <first-state> qualified with its home. Returns 1 with
# FM_PROJECT_CAPACITY_ERROR when the local homes cannot be enumerated, or when
# a state directory or task record in them cannot be read, since skipping it
# could undercount the holders.
fm_project_capacity_occupants() {  # <project-lock> <project-dir> <first-state> <own-id>
  local want=$1 own=$2 first=$3 self=$4 state meta kind project lock id label i pending covered
  local -a cache_dirs cache_locks
  FM_PROJECT_CAPACITY_OCCUPANTS=0
  FM_PROJECT_CAPACITY_OCCUPANT_IDS=
  FM_PROJECT_CAPACITY_ERROR=
  fm_local_firstmate_state_dirs "$first" || {
    FM_PROJECT_CAPACITY_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
    return 1
  }
  fm_project_capacity_pending "$want" "$first" "$self" || return 1
  cache_dirs=("$own")
  cache_locks=("$want")
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ -e "$state" ] && { [ ! -d "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; }; then
      FM_PROJECT_CAPACITY_ERROR="local Firstmate state directory $state cannot be read"
      return 1
    fi
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "$meta" != "$first/$self.meta" ] || continue
      [ -r "$meta" ] || {
        FM_PROJECT_CAPACITY_ERROR="task record $meta cannot be read"
        return 1
      }
      covered=0
      for pending in ${FM_PROJECT_CAPACITY_PENDING_TASKS[@]+"${FM_PROJECT_CAPACITY_PENDING_TASKS[@]}"}; do
        if [ "$pending" = "$meta" ] || [ "$pending" -ef "$meta" ]; then
          covered=1
          break
        fi
      done
      [ "$covered" = 0 ] || continue
      kind=$(fm_meta_get "$meta" kind)
      [ "$kind" != secondmate ] || continue
      [ -z "$(fm_meta_get "$meta" pr)" ] || continue
      project=$(fm_meta_get "$meta" project)
      [ -n "$project" ] || continue
      lock=
      i=0
      while [ "$i" -lt "${#cache_dirs[@]}" ]; do
        if [ "${cache_dirs[$i]}" = "$project" ]; then
          lock=${cache_locks[$i]}
          break
        fi
        i=$((i + 1))
      done
      if [ "$i" -ge "${#cache_dirs[@]}" ]; then
        lock=$(fm_treehouse_project_lock_path "$project" 2>/dev/null) || lock=
        cache_dirs+=("$project")
        cache_locks+=("$lock")
      fi
      [ -n "$lock" ] && [ "$lock" = "$want" ] || continue
      id=$(basename "$meta" .meta)
      label=$id
      [ "$state" = "$first" ] || label="$id in $(dirname "$state")"
      FM_PROJECT_CAPACITY_OCCUPANTS=$((FM_PROJECT_CAPACITY_OCCUPANTS + 1))
      FM_PROJECT_CAPACITY_OCCUPANT_IDS="${FM_PROJECT_CAPACITY_OCCUPANT_IDS:+$FM_PROJECT_CAPACITY_OCCUPANT_IDS, }$label"
    done
  done
  return 0
}

# Publish a reservation while the caller holds <project-lock>. Capture this
# frame's pid before any substitution so the lease belongs to the spawn, not a
# short-lived child. Sets FM_PROJECT_CAPACITY_RESERVATION on success.
fm_project_capacity_reserve() {  # <project-lock> <state-dir> <task-id> <spawn-gen>
  local lock=$1 state=$2 id=$3 generation=$4 pid tmp reservation
  FM_PROJECT_CAPACITY_RESERVATION=
  [ -n "$generation" ] || return 1
  fm_current_pid pid || return 1
  state=$(CDPATH='' cd -- "$state" && pwd -P) || return 1
  tmp=$(mktemp -d "${lock}.capacity-tmp.XXXXXXXX") || return 1
  reservation="${lock}.capacity.${tmp##*.}"
  # The project lock excludes other publishers; refuse a reused random suffix
  # rather than letting mv nest this directory inside an existing admission.
  if [ -e "$reservation" ] || [ -L "$reservation" ] ||
    [ -e "${lock}.capacity-retired.${tmp##*.}" ] || [ -L "${lock}.capacity-retired.${tmp##*.}" ]; then
    rm -rf -- "$tmp"
    return 1
  fi
  if ! fm_lock_prepare_owner "$tmp" "$pid" ||
    ! printf 'state=%s\nid=%s\nspawn_gen=%s\n' "$state" "$id" "$generation" > "$tmp/task" ||
    ! mv -- "$tmp" "$reservation"; then
    rm -rf -- "$tmp"
    return 1
  fi
  FM_PROJECT_CAPACITY_RESERVATION=$reservation
}

# The creating process retires its unique directory; counting may also reap a
# proven-dead owner. Deletion lowers occupancy, so EXIT cleanup needs no lock.
fm_project_capacity_release() {  # <reservation>
  local reservation=$1 retired
  [ -n "$1" ] || return 0
  [ -e "$reservation" ] || [ -L "$reservation" ] || return 0
  retired="${reservation%.capacity.*}.capacity-retired.${reservation##*.}"
  [ ! -e "$retired" ] && [ ! -L "$retired" ] || return 1
  if ! mv -- "$reservation" "$retired"; then
    [ ! -e "$reservation" ] && [ ! -L "$reservation" ]
    return $?
  fi
  rm -rf -- "$retired"
}

# Add pending admissions to the metadata count, under the project lock.
# A dead process lease can be removed here without racing a new reservation;
# an unreadable or malformed lease refuses admission instead of undercounting.
fm_project_capacity_pending() {  # <project-lock> <first-state> <own-id>
  local lock=$1 first=$2 self=$3 reservation pid state id generation label first_real task line owner_start
  FM_PROJECT_CAPACITY_PENDING_TASKS=()
  first_real=$(CDPATH='' cd -- "$first" && pwd -P) || return 1
  for reservation in "${lock}".capacity.*; do
    [ -e "$reservation" ] || [ -L "$reservation" ] || continue
    if [ ! -d "$reservation" ] || [ -L "$reservation" ] ||
      [ ! -r "$reservation/pid" ] || [ ! -r "$reservation/lock-owner-start" ] ||
      [ ! -r "$reservation/task" ] ||
      ! pid=$(cat "$reservation/pid" 2>/dev/null) ||
      ! owner_start=$(cat "$reservation/lock-owner-start" 2>/dev/null) ||
      ! task=$(cat "$reservation/task" 2>/dev/null); then
      [ -e "$reservation" ] || [ -L "$reservation" ] || continue
      FM_PROJECT_CAPACITY_ERROR="project reservation $reservation cannot be read"
      return 1
    fi
    [ -e "$reservation" ] || [ -L "$reservation" ] || continue
    case "$pid" in
      ''|*[!0-9]*|0)
        FM_PROJECT_CAPACITY_ERROR="project reservation $reservation has no valid owner pid"
        return 1 ;;
    esac
    if [ -z "$owner_start" ]; then
      FM_PROJECT_CAPACITY_ERROR="project reservation $reservation has no owner identity"
      return 1
    fi
    if ! fm_lock_owner_alive "$reservation" "$pid"; then
      fm_project_capacity_release "$reservation" || return 1
      continue
    fi
    state= id= generation=
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        state=*) state=${line#*=} ;;
        id=*) id=${line#*=} ;;
        spawn_gen=*) generation=${line#*=} ;;
      esac
    done <<< "$task"
    if [ -z "$state" ] || [ -z "$id" ] || [ -z "$generation" ]; then
      FM_PROJECT_CAPACITY_ERROR="project reservation $reservation has no task identity"
      return 1
    fi
    [ "$state/$id" != "$first_real/$self" ] || continue
    [ "$(fm_meta_get "$state/$id.meta" spawn_gen)" != "$generation" ] || continue
    FM_PROJECT_CAPACITY_PENDING_TASKS+=("$state/$id.meta")
    label="$id (pending)"
    [ "$state" = "$first_real" ] || label="$id in $(dirname "$state") (pending)"
    FM_PROJECT_CAPACITY_OCCUPANTS=$((FM_PROJECT_CAPACITY_OCCUPANTS + 1))
    FM_PROJECT_CAPACITY_OCCUPANT_IDS="${FM_PROJECT_CAPACITY_OCCUPANT_IDS:+$FM_PROJECT_CAPACITY_OCCUPANT_IDS, }$label"
  done
  return 0
}
