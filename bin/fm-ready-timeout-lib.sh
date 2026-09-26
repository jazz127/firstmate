#!/usr/bin/env bash
# fm-ready-timeout-lib.sh - the single owner of the opt-in ready-session
# timeout: stopping the idle agent of a ship worker whose pull request has sat
# ready, waiting on a merge, for longer than the configured timeout.
#
# Sourced, never executed.
#
# Opt-in. config/ready-session-timeout absent means today's behavior, with no
# agent ever stopped for waiting. Present and empty (or holding only blank and
# `#` comment lines) means the default of 7200 seconds (two hours). Its first
# other line sets the duration: a whole number of seconds, or a whole number
# followed by `s`, `m`, or `h` (`90m`, `4h`). A value under 60 seconds, or one
# that does not parse, is rejected and leaves the feature off, so a typo can
# never stop workers early; the watcher notes the rejection in its triage log.
# The file is home-local and is not inherited by secondmate homes.
#
# Eligibility, evaluated by the watcher's ready_session_timeout_tick
# (bin/fm-watch.sh) on its ordinary poll loop, never by a daemon of its own. A
# worker is stopped only when every one of these holds:
#   - its record is kind=ship (scouts and secondmates are never stopped) and
#     is not a remotely placed agent;
#   - its ready signal stands: the latest status event is a `done` naming the
#     pull request, with that pull request's merge poll armed through
#     bin/fm-pr-check.sh (the watcher's delivered_pr_wait owns this proof);
#   - nothing has happened for the timeout (fm_ready_timeout_activity_age):
#     no status event, completed turn, observed progress, task-record rewrite
#     (including a relaunch), merge-poll registration, or steering-inbox
#     movement;
#   - its steering inbox holds no unacknowledged record;
#   - its agent reads alive on a backend with a recovery-grade classifier, and
#     the semantic busy contract (bin/fm-busy-lib.sh) reads it exactly idle,
#     so a busy, unknown, or unverified agent is left running;
#   - this incarnation has not already been stopped for the timeout.
# The stop itself is `bin/fm-control.sh <id> exit`, which preserves the
# endpoint, worktree, branch, and every uncommitted change. The task record,
# pull request, and merge poll are untouched, so a later merge is still
# reported and cleaned up normally, and `bin/fm-control.sh <id> relaunch`
# brings the worker back when the pull request needs more work.
#
# Record: state/<id>.ready-timeout, atomically replaced, key=value lines:
#   v=1
#   result=stopped|failed
#   spawn_gen=<the task record's spawn_gen= at the attempt, possibly empty>
#   at=<epoch of the attempt>
#   timeout=<configured seconds>
#   pr=<pull request URL>
#   detail=<one line: fm-control's result, or its refusal>
# A `stopped` record whose spawn_gen matches the task record marks the worker
# as deliberately stopped (fm_ready_timeout_parked): the watcher skips its
# pane-staleness path and its turn-end signals, so no stale or dead-endpoint
# alarm fires for it, and bin/fm-crew-state.sh and the session-start digest
# name the stop instead of reporting an unexplained dead agent. A relaunch
# writes a new spawn_gen, which ends the parked reading on its own. A `failed`
# record (fm-control refused, for example over pending composer text) is
# retried once the timeout elapses again, never on every poll. Teardown removes
# the record with the task's other runtime files.

FM_READY_TIMEOUT_DEFAULT_SECS=7200
FM_READY_TIMEOUT_MIN_SECS=60

# Print the configured timeout in seconds.
# Returns 0 when enabled, 1 when config/ready-session-timeout is absent, and 2
# when its value is rejected (nothing printed for 1 or 2).
fm_ready_timeout_secs() {  # <config-dir>
  local file="$1/ready-session-timeout" line value='' n unit secs
  [ -e "$file" ] || [ -L "$file" ] || return 1
  [ -f "$file" ] && [ -r "$file" ] || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] || continue
    value=$line
    break
  done < "$file"
  if [ -z "$value" ]; then
    printf '%s' "$FM_READY_TIMEOUT_DEFAULT_SECS"
    return 0
  fi
  case "$value" in
    *[smh]) n=${value%?}; unit=${value#"$n"} ;;
    *) n=$value; unit=s ;;
  esac
  case "$n" in
    ''|*[!0-9]*) return 2 ;;
  esac
  # Strip leading zeros so bash arithmetic never reads the number as octal.
  n=$(printf '%s' "$n" | sed 's/^0*//')
  [ -n "$n" ] || return 2
  [ "${#n}" -le 9 ] || return 2
  case "$unit" in
    s) secs=$n ;;
    m) secs=$(( n * 60 )) ;;
    h) secs=$(( n * 3600 )) ;;
  esac
  [ "$secs" -ge "$FM_READY_TIMEOUT_MIN_SECS" ] || return 2
  printf '%s' "$secs"
}

fm_ready_timeout_record_path() {  # <state-dir> <task-id>
  printf '%s/%s.ready-timeout' "$1" "$2"
}

# The last value of <key> in a record or task metadata file, or empty.
fm_ready_timeout_field() {  # <file> <key>
  local file=$1 key=$2 line value=''
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#*=} ;;
    esac
  done < "$file" 2>/dev/null || true
  printf '%s' "$value"
}

# Atomically replace the task's record. Returns non-zero when it cannot be
# written, leaving any previous record in place.
fm_ready_timeout_record_write() {  # <state-dir> <task-id> <result> <spawn-gen> <pr> <timeout> <detail>
  local state=$1 id=$2 path tmp detail
  path=$(fm_ready_timeout_record_path "$state" "$id")
  detail=$(printf '%s' "$7" | tr '\n\r' '  ')
  tmp=$(mktemp "$state/.ready-timeout-$id.XXXXXX") || return 1
  if ! printf 'v=1\nresult=%s\nspawn_gen=%s\nat=%s\ntimeout=%s\npr=%s\ndetail=%s\n' \
      "$3" "$4" "$(date +%s)" "$6" "$5" "$detail" > "$tmp" \
    || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
}

# 0 iff the task's current incarnation was stopped by the ready-session
# timeout: a `stopped` record exists and names the spawn_gen its task record
# still carries.
fm_ready_timeout_parked() {  # <state-dir> <task-id>
  local state=$1 id=$2 record meta
  record=$(fm_ready_timeout_record_path "$state" "$id")
  [ -f "$record" ] || return 1
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1
  [ "$(fm_ready_timeout_field "$record" result)" = stopped ] || return 1
  [ "$(fm_ready_timeout_field "$record" spawn_gen)" = "$(fm_ready_timeout_field "$meta" spawn_gen)" ]
}

_fm_ready_timeout_mtime() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# Seconds since the task last showed any sign of life the timeout counts as
# activity. Prints nothing and returns 1 when no activity file is readable.
fm_ready_timeout_activity_age() {  # <state-dir> <task-id>
  local state=$1 id=$2 f m newest='' now
  for f in "$state/$id.status" "$state/$id.turn-ended" "$state/$id.progress" \
    "$state/$id.meta" "$state/$id.pr-poll-registration" \
    "$state/$id.inbox" "$state/$id.inbox/handled"; do
    [ -e "$f" ] || continue
    m=$(_fm_ready_timeout_mtime "$f") || continue
    case "$m" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$newest" ] || [ "$m" -gt "$newest" ]; then
      newest=$m
    fi
  done
  [ -n "$newest" ] || return 1
  now=$(date +%s)
  if [ "$newest" -ge "$now" ]; then
    printf '0'
  else
    printf '%s' "$(( now - newest ))"
  fi
}

# 0 iff the task's steering inbox holds any unacknowledged record.
fm_ready_timeout_inbox_pending() {  # <state-dir> <task-id>
  local f
  for f in "$1/$2.inbox"/*.msg; do
    [ -e "$f" ] && return 0
  done
  return 1
}
