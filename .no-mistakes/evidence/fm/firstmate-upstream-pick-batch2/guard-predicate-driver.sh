wait_until() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
primary_compacted() { [ "$(compact_boundaries)" -ge 1 ]; }
acked() {
  local seq marker
  seq=$(cat "$FM/state/.wake-queue.seq" 2>/dev/null) || return 1
  [ "$seq" -gt "$after_seq" ] || return 1
  marker=$(cat "$FM/state/.watcher-down" 2>/dev/null) || return 1
  case "$marker" in acked:*) ;; *) return 1 ;; esac
  [ -f "$FM/state/.wake-queue" ] && [ ! -s "$FM/state/.wake-queue" ]
}

set -eu
TMP=$(mktemp -d "$PHASE_ROOT/.test-phase-tmp/guard-predicates.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FM=$TMP/home
mkdir -p "$FM/state"
after_seq=20
printf '0\n' > "$TMP/count"
compact_boundaries() { cat "$TMP/count"; }
(sleep 0.3; echo 1 > "$TMP/count") &
writer=$!
wait_until 20 primary_compacted
wait "$writer"
printf 'delayed compaction boundary: polling observed count transition 0 -> 1\n'
printf '20\n' > "$FM/state/.wake-queue.seq"
printf 'acked:downtime:fixture\n' > "$FM/state/.watcher-down"
: > "$FM/state/.wake-queue"
if acked; then echo 'ERROR: accepted pre-injection sequence'; exit 1; fi
printf 'sequence=20, prior=20, acked marker, empty queue: refused\n'
printf '21\n' > "$FM/state/.wake-queue.seq"
printf 'pending:downtime:fixture\n' > "$FM/state/.watcher-down"
if acked; then echo 'ERROR: accepted pending marker'; exit 1; fi
printf 'sequence=21, pending marker, empty queue: refused\n'
printf 'acked:downtime:fixture\n' > "$FM/state/.watcher-down"
printf '1\t21\tcheck\tproof\tcheck: injected wake\n' > "$FM/state/.wake-queue"
if acked; then echo 'ERROR: accepted unconsumed wake'; exit 1; fi
printf 'sequence=21, acked marker, wake still queued: refused\n'
: > "$FM/state/.wake-queue"
acked
printf 'sequence=21, acked marker, wake consumed: accepted\n'
rm "$FM/state/.wake-queue"
if acked; then echo 'ERROR: accepted missing queue'; exit 1; fi
printf 'sequence=21, acked marker, missing queue: refused\n'
