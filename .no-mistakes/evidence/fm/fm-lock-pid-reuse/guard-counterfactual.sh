#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$(mktemp -d "$PWD/.gate-lock-runtime/counterfactual.XXXXXX")
owner=
cleanup() {
  [ -z "$owner" ] || { kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true; }
  rm -rf "$LAB"
}
trap cleanup EXIT
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE STATE
bin/fm-lab-home.sh create "$LAB"
. "$ROOT/bin/fm-wake-lib.sh"
# The lock metadata is disposable persisted input. Its old start time belongs
# to an exited real process, and its PID now names another real process.
sleep 30 &
old=$!
old_start=$(LC_ALL=C ps -p "$old" -o lstart= | sed 's/^[[:space:]]*//')
kill "$old"
wait "$old" 2>/dev/null || true
sleep 1.1
sleep 30 &
owner=$!
new_start=$(LC_ALL=C ps -p "$owner" -o lstart= | sed 's/^[[:space:]]*//')
[ "$old_start" != "$new_start" ]
lock="$LAB/state/.regression.lock"
mkdir "$lock"
printf '%s\n' "$owner" > "$lock/pid"
printf '%s\n' "$old_start" > "$lock/lock-owner-start"
printf 'REGRESSION INPUT: alive PID=%s old start=%s current OS start=%s\n' "$owner" "$old_start" "$new_start"
if bash -c '. "$1"; fm_lock_acquire_wait_max "$2" 1' _ "$ROOT/bin/.gate-base-wake-lib.sh" "$lock"; then
  echo 'Unexpected pre-fix acquisition'; exit 8
fi
printf 'PRE-FIX OBSERVED: original product times out instead of recovering\n'
fm_lock_acquire_wait_max "$lock" 1 || exit 9
printf 'FIXED OBSERVED: product acquired stale lock, owner=%s start=%s\n' "$(cat "$lock/pid")" "$(cat "$lock/lock-owner-start")"
fm_lock_release "$lock"

# Remove ps from this shell's actual executable search path. Every command
# retained below is a symlink to its real binary; no response is fabricated.
lock="$LAB/state/.uncertain.lock"
FM_HOME="$LAB" bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 7; exec sleep 30' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" &
held=$!
for i in {1..100}; do [ -s "$lock/pid" ] && break; sleep .02; done
[ -s "$lock/pid" ]
known_owner=$(readlink "$lock")
mkdir "$LAB/no-ps"
for binary in cat sed readlink; do ln -s "$(command -v "$binary")" "$LAB/no-ps/$binary"; done
set +e
bash -c '
 . "$1"
 PATH=$4
 command -v ps && exit 8
 kill -0 "$3" || exit 9
 if fm_pid_start_identity "$3"; then exit 10; fi
 fm_lock_owner_alive "$2" "$3" || exit 11
 if fm_lock_recheck_stale_owner "$2" "$5" "$3"; then exit 12; fi
 printf "MISSING-PS OBSERVED: live PID=%s; actual start lookup failed; owner-alive guard keeps lock held; final stale recheck refuses reclaim\n" "$3"
' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$held" "$LAB/no-ps" "$known_owner"
rc=$?
set -e
kill "$held" 2>/dev/null || true
wait "$held" 2>/dev/null || true
[ "$rc" = 0 ]
printf 'TEARDOWN: owned processes stopped; disposable state removed\n'
