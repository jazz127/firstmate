#!/usr/bin/env bash
# tests/fm-remote-herdr-guard.test.sh - the fm-remote launch agent's guard.
#
# Drives the real bin/fm-remote-herdr-guard.sh (and the owner library it
# sources) against a fake herdr CLI, a fake lsof that names a real holder
# process as the session-socket owner, and real holder processes whose
# environment and ancestry carry the birth markers the guard reads. It pins
# the decision table: no server -> start; an Aqua-born owner -> leave it; an
# SSH-born or unprovable owner -> stop it, wait for the socket, start. Nothing
# here touches the runner's own herdr servers, launch agents, or login
# session, and no live harness guard applies: the verdict comes from process
# environment and ancestry, which are kernel facts rather than vendor output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the guard parses herdr's JSON)"; exit 0; }
command -v mkfifo >/dev/null 2>&1 || { echo "skip: mkfifo not found (holder processes block on a fifo)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-herdr-guard)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
HOLDER_PIDS=()
HOLDER_FD=5
trap 'if [ "${#HOLDER_PIDS[@]}" -gt 0 ]; then kill "${HOLDER_PIDS[@]}" 2>/dev/null || true; fi; fm_test_cleanup || true' EXIT

GUARD="$ROOT/bin/fm-remote-herdr-guard.sh"
JQ=$(command -v jq)
HOLDER_BIN=$(command -v node 2>/dev/null || printf '%s' "$JQ")
SESSION=fm-remote

# The guard must see only the fixture and the system tools it really needs,
# so a case can also present a host with NO lsof.
TOOLS="$TMP_ROOT/tools"
mkdir -p "$TOOLS"
for tool in ps awk sed grep tr dirname basename sleep cat cp rm env bash sh id head perl; do
  real=$(command -v "$tool") || fail "test host lacks $tool"
  ln -sf "$real" "$TOOLS/$tool"
done
ln -sf "$JQ" "$TOOLS/jq"
FAKE="$TMP_ROOT/fake"
mkdir -p "$FAKE"
cat > "$FAKE/lsof" <<'SH'
#!/usr/bin/env bash
# Prints the -F pn shape for every pid listed in the owner file.
[ -f "$FM_FAKE_SOCKET_OWNER" ] || exit 0
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  printf 'p%s\n' "$pid"
  printf 'n%s\n' "$FM_FAKE_HERDR_SOCKET"
done < "$FM_FAKE_SOCKET_OWNER"
SH
cat > "$FAKE/launchctl" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = print ] || exit 0
domain=${2:-}
scope=${domain%%/*}
label=${domain#*/}
label=${label#*/}
state="$FM_FAKE_STATE/launchctl-$scope-$label"
[ -f "$state" ] || exit 113
cat "$state"
SH
cat > "$FAKE/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
running=$(cat "$FM_FAKE_HERDR_RUNNING" 2>/dev/null || printf 'false')
detached=true
[ ! -f "$FM_FAKE_STATE/not-detached" ] || detached=false
case "$*" in
  "status --json --session "*)
    if [ -f "$FM_FAKE_STATE/release-after" ]; then
      left=$(cat "$FM_FAKE_STATE/release-after")
      if [ "$left" -gt 0 ]; then
        printf '%s\n' "$((left - 1))" > "$FM_FAKE_STATE/release-after"
      else
        rm -f "$FM_FAKE_STATE/release-after"
        printf 'false\n' > "$FM_FAKE_HERDR_RUNNING"
        running=false
      fi
    fi
    if [ -f "$FM_FAKE_STATE/pre-capabilities" ]; then
      printf '{"server":{"running":%s,"socket":"%s","version":"0.9.0"},"client":{"version":"0.9.0"}}\n' \
        "$running" "$FM_FAKE_HERDR_SOCKET"
    else
      printf '{"server":{"running":%s,"socket":"%s","version":"0.9.1","capabilities":{"detached_server_daemon":%s}},"client":{"version":"0.9.1"}}\n' \
        "$running" "$FM_FAKE_HERDR_SOCKET" "$detached"
    fi
    ;;
  "server stop --session "*)
    if [ -f "$FM_FAKE_STATE/stop-ignored" ]; then
      exit 0
    elif [ -f "$FM_FAKE_STATE/stop-releases-after" ]; then
      cp "$FM_FAKE_STATE/stop-releases-after" "$FM_FAKE_STATE/release-after"
    else
      printf 'false\n' > "$FM_FAKE_HERDR_RUNNING"
    fi
    ;;
  "server --session "*)
    pgid=$(ps -p "$$" -o pgid= | tr -d ' ')
    printf 'pid=%s pgid=%s session=%s\n' "$$" "$pgid" "${3:-}" > "$FM_FAKE_STATE/started"
    ;;
esac
exit 0
SH
chmod +x "$FAKE/lsof" "$FAKE/launchctl" "$FAKE/herdr"
cp "$FAKE/lsof" "$TMP_ROOT/lsof.fake"

# hold <marker-env...> -> HOLDER_PID: a real non-platform process (node, else jq, blocked
# on a fifo this test keeps open) whose environment is exactly the markers.
hold() {
  local fifo="$TMP_ROOT/holder-$HOLDER_FD.fifo"
  rm -f "$fifo"
  mkfifo "$fifo"
  # Open read-write so this never blocks on the reader; the holder sees EOF
  # only when the descriptor closes at exit.
  eval "exec ${HOLDER_FD}<>\"\$fifo\""
  if [ "${HOLDER_BIN##*/}" = node ]; then
    env -i "$@" "$HOLDER_BIN" -e 'require("fs").readFileSync(process.argv[1])' "$fifo" &
  else
    env -i "$@" "$HOLDER_BIN" . "$fifo" &
  fi
  HOLDER_PID=$!
  HOLDER_PIDS+=("$HOLDER_PID")
  HOLDER_FD=$((HOLDER_FD + 1))
}

# hold_under <argv0> <arg...> -- : a marker-free holder whose PARENT process
# carries the given argv[0] and arguments (the ancestry the guard inspects).
hold_under() {
  local argv0=$1 fifo="$TMP_ROOT/holder-$HOLDER_FD.fifo" pidfile="$TMP_ROOT/holder-$HOLDER_FD.pid"
  shift
  rm -f "$fifo" "$pidfile"
  mkfifo "$fifo"
  eval "exec ${HOLDER_FD}<>\"\$fifo\""
  ( FM_HOLDER_JQ="$JQ" FM_HOLDER_FIFO="$fifo" FM_HOLDER_PIDFILE="$pidfile" \
    exec -a "$argv0" bash -c 'env -i FM_HOLDER=1 "$FM_HOLDER_JQ" . "$FM_HOLDER_FIFO" & printf "%s\n" "$!" > "$FM_HOLDER_PIDFILE"; wait' "$@" ) &
  HOLDER_PIDS+=("$!")
  HOLDER_FD=$((HOLDER_FD + 1))
  local i=0
  while [ ! -s "$pidfile" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$pidfile" ] || fail "holder under $argv0 did not report its pid"
  HOLDER_PID=$(cat "$pidfile")
  HOLDER_PIDS+=("$HOLDER_PID")
}

# hold_child <marker-env...> -> HOLDER_PID, HOLDER_PARENT_PID: a holder whose
# environment is exactly the markers, started by a parent process that stays
# alive, as the guard stays alive as the parent of the server it starts.
hold_child() {
  local fifo="$TMP_ROOT/holder-$HOLDER_FD.fifo" pidfile="$TMP_ROOT/holder-$HOLDER_FD.pid" reader
  rm -f "$fifo" "$pidfile"
  mkfifo "$fifo"
  eval "exec ${HOLDER_FD}<>\"\$fifo\""
  if [ "${HOLDER_BIN##*/}" = node ]; then
    reader=("$HOLDER_BIN" -e 'require("fs").readFileSync(process.argv[1])')
  else
    reader=("$HOLDER_BIN" .)
  fi
  ( FM_HOLDER_PIDFILE="$pidfile" \
    exec bash -c 'env -i "$@" & printf "%s\n" "$!" > "$FM_HOLDER_PIDFILE"; wait' holder-parent "$@" "${reader[@]}" "$fifo" ) &
  HOLDER_PARENT_PID=$!
  HOLDER_PIDS+=("$HOLDER_PARENT_PID")
  HOLDER_FD=$((HOLDER_FD + 1))
  local i=0
  while [ ! -s "$pidfile" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$pidfile" ] || fail "child holder did not report its pid"
  HOLDER_PID=$(cat "$pidfile")
  HOLDER_PIDS+=("$HOLDER_PID")
}

CASE_N=0
new_case() { # [running|stopped]
  CASE_N=$((CASE_N + 1))
  CASE_STATE="$TMP_ROOT/case$CASE_N"
  mkdir -p "$CASE_STATE"
  CASE_LOG="$CASE_STATE/herdr.log"
  : > "$CASE_LOG"
  CASE_RUNNING="$CASE_STATE/running"
  printf '%s\n' "$([ "${1:-running}" = running ] && printf true || printf false)" > "$CASE_RUNNING"
  CASE_OWNER="$CASE_STATE/socket-owner"
  CASE_SOCKET="$CASE_STATE/herdr.sock"
  CASE_PATH="$FAKE:$TOOLS"
}

load_job() { # <gui|user> <label> [pid]
  if [ -n "${3:-}" ]; then
    printf 'pid = %s\n' "$3" > "$CASE_STATE/launchctl-$1-$2"
  else
    printf 'state = running\n' > "$CASE_STATE/launchctl-$1-$2"
  fi
}

guard() { # [extra env assignments...]
  set +e
  GUARD_OUT=$(
    env -i PATH="$CASE_PATH" HOME="$TMP_ROOT" \
      FM_FAKE_STATE="$CASE_STATE" FM_FAKE_HERDR_LOG="$CASE_LOG" FM_FAKE_HERDR_RUNNING="$CASE_RUNNING" \
      FM_FAKE_SOCKET_OWNER="$CASE_OWNER" FM_FAKE_HERDR_SOCKET="$CASE_SOCKET" \
      FM_HOLDER_JQ="$JQ" \
      FM_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS=8 \
      "$@" "$GUARD" "$FAKE/herdr" "$SESSION" 2>&1
  )
  GUARD_RC=$?
  set -e
}

herdr_calls() { cat "$CASE_LOG"; }
assert_started() { # <msg>
  local pid pgid
  [ -f "$CASE_STATE/started" ] || fail "$1"
  assert_grep "session=$SESSION" "$CASE_STATE/started" "the server was started for the wrong session"
  pid=$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$CASE_STATE/started")
  pgid=$(sed -n 's/.* pgid=\([0-9]*\).*/\1/p' "$CASE_STATE/started")
  [ -n "$pid" ] && [ "$pid" = "$pgid" ] || fail "the started server was not a process-group leader: $(cat "$CASE_STATE/started")"
}
assert_not_started() { assert_absent "$CASE_STATE/started" "$1"; }
assert_stop_before_start() {
  local calls stop_line start_line
  calls=$(herdr_calls)
  stop_line=$(printf '%s\n' "$calls" | grep -n "^server stop --session $SESSION$" | head -1 | cut -d: -f1)
  start_line=$(printf '%s\n' "$calls" | grep -n "^server --session $SESSION$" | head -1 | cut -d: -f1)
  [ -n "$stop_line" ] || fail "the guard never asked the foreign server to stop"
  [ -n "$start_line" ] || fail "the guard never started its own server"
  [ "$stop_line" -lt "$start_line" ] || fail "the guard started its server before stopping the foreign one"
}

# Prove the holder construction on this host: the environment of a holder
# must be readable, or every marker case would be vacuous.
hold FM_PROBE_MARKER=1
PROBE_PID=$HOLDER_PID
sleep 0.2
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$ROOT/bin/fm-remote-herdr-owner-lib.sh"
probe_env=$(fm_remote_herdr_process_env "$PROBE_PID")
case "$probe_env" in
  *FM_PROBE_MARKER=1*) ;;
  *) fail "this host does not expose a holder's environment (macOS hides platform-binary environments; $HOLDER_BIN must be a non-platform binary): $probe_env" ;;
esac
pass "holder processes expose their environment to the owner library"

# --- no server: the guard becomes the server ---------------------------------

new_case stopped
guard
expect_code 1 "$GUARD_RC" "the guard did not ask launchd to restart after the server exited"
assert_started "the guard did not start the server when none owned the session"
assert_not_contains "$(herdr_calls)" 'server stop' "the guard stopped something when no server owned the session"
assert_contains "$GUARD_OUT" "no server owns session $SESSION" "the guard did not report the empty session"
pass "an empty session is started inside the launch agent"

# --- an Aqua-born owner is left alone ----------------------------------------

hold XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote
LAUNCHD_PID=$HOLDER_PID
hold XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote
BACKGROUND_PID=$HOLDER_PID
hold XPC_SERVICE_NAME=0
XPC_ZERO_PID=$HOLDER_PID
hold FM_REMOTE_JOB_ACTIVE=1
WORKER_PID=$HOLDER_PID
hold SSH_CONNECTION='100.102.217.78 51234 100.100.1.2 22' SSH_CLIENT='100.102.217.78 51234 22'
SSH_PID=$HOLDER_PID
hold FM_NOTHING_TO_SEE=1
UNMARKED_PID=$HOLDER_PID
hold_under herdr --session "$SESSION" remote-client-bridge
BRIDGE_CHILD_PID=$HOLDER_PID
hold_under 'sshd-session:' kunchen@notty
SSHD_CHILD_PID=$HOLDER_PID
hold_child XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote
GUARD_CHILD_PID=$HOLDER_PID
GUARD_PARENT_PID=$HOLDER_PARENT_PID
sleep 0.3

new_case running
printf '%s\n' "$LAUNCHD_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$LAUNCHD_PID"
guard
expect_code 0 "$GUARD_RC" "the guard did not exit 0 for a gui-domain launchd owner"
assert_not_started "the guard started a second server over a gui-domain launchd owner"
assert_not_contains "$(herdr_calls)" 'server stop' "the guard stopped a gui-domain launchd owner"
assert_contains "$GUARD_OUT" "pid $LAUNCHD_PID born in the Aqua login session (launchd)" \
  "the guard did not name the launchd owner"

new_case running
printf '%s\n' "$WORKER_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.remote-job
guard
expect_code 0 "$GUARD_RC" "the guard did not exit 0 for the gui-domain worker owner"
assert_not_started "the guard started a second server over a gui-domain worker owner"
assert_not_contains "$(herdr_calls)" 'server stop' "the guard stopped a gui-domain worker owner"
assert_contains "$GUARD_OUT" "pid $WORKER_PID born in the Aqua login session (worker)" \
  "the guard did not name the worker owner"
pass "launchd and worker markers require gui-domain launchctl proof"

RESTART_MARKER="$TMP_ROOT/Library/Caches/dev.firstmate.herdr.$SESSION.restart"

new_case running
printf '%s\n' "$WORKER_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.remote-job
touch "$CASE_STATE/not-detached"
guard
expect_code 0 "$GUARD_RC" "an automatic guard launch replaced a healthy worker-born server"
assert_not_started "an automatic guard launch started a second server over a worker-born owner"
assert_not_contains "$(herdr_calls)" 'server stop' "an automatic guard launch closed a worker-born server's panes"
pass "without an operator restart, an Aqua-born foreground server is left alone"

new_case running
printf '%s\n' "$WORKER_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.remote-job
touch "$CASE_STATE/not-detached"
mkdir -p "${RESTART_MARKER%/*}"
: > "$RESTART_MARKER"
guard
expect_code 1 "$GUARD_RC" "the guard did not replace an Aqua-born foreground server on operator restart"
assert_stop_before_start
assert_absent "$RESTART_MARKER" "the guard did not consume the operator restart marker"
assert_contains "$GUARD_OUT" 'born in Aqua but is not a session-leader daemon' \
  "the guard did not identify why an Aqua-born server needs replacement"
pass "an operator restart replaces an Aqua-born foreground server for saved-machine readiness"

new_case running
printf '%s\n' "$LAUNCHD_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$LAUNCHD_PID"
touch "$CASE_STATE/pre-capabilities"
guard
expect_code 0 "$GUARD_RC" "the guard replaced an Aqua-born server whose Herdr predates the session-leader capability"
assert_not_started "the guard started a second server over a pre-capability Aqua-born owner"
assert_not_contains "$(herdr_calls)" 'server stop' "the guard stopped a pre-capability Aqua-born owner"
pass "an Aqua-born server without the session-leader capability is left alone"

new_case running
printf '%s\n' "$GUARD_CHILD_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$GUARD_PARENT_PID"
load_job user dev.firstmate.herdr.fm-remote
guard
expect_code 0 "$GUARD_RC" "the guard took over the server its own launchd job started"
assert_not_started "the guard started a second server over its own launchd job's child"
assert_contains "$GUARD_OUT" "pid $GUARD_CHILD_PID born in the Aqua login session (launchd)" \
  "the guard's child was not proven launchd-born through its parent job pid"
pass "a server whose parent is the gui launchd job is proven launchd-born"

# --- a foreign owner is stopped, then the guard becomes the server -----------

new_case running
printf '%s\n' "$BACKGROUND_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote
load_job user dev.firstmate.herdr.fm-remote
guard
expect_code 1 "$GUARD_RC" "the guard failed to take over a label also loaded in the user domain"
assert_stop_before_start
assert_contains "$GUARD_OUT" "pid $BACKGROUND_PID born outside the Aqua login session (unknown)" \
  "a user-domain label was trusted as Aqua"

new_case running
printf '%s\n' "$XPC_ZERO_PID" > "$CASE_OWNER"
guard
expect_code 1 "$GUARD_RC" "the guard failed to take over an XPC_SERVICE_NAME=0 owner"
assert_stop_before_start
assert_contains "$GUARD_OUT" "pid $XPC_ZERO_PID born outside the Aqua login session (unknown)" \
  "XPC_SERVICE_NAME=0 was trusted as Aqua"

for foreign in "ssh $SSH_PID" "ssh $BRIDGE_CHILD_PID" "ssh $SSHD_CHILD_PID" "unknown $UNMARKED_PID"; do
  new_case running
  printf '%s\n' "${foreign#* }" > "$CASE_OWNER"
  guard
  expect_code 1 "$GUARD_RC" "the guard failed to take over from a ${foreign%% *} owner (pid ${foreign#* })"
  assert_stop_before_start
  assert_started "the guard did not start its own server after the ${foreign%% *} owner released the socket"
  assert_contains "$GUARD_OUT" "pid ${foreign#* } born outside the Aqua login session (${foreign%% *})" \
    "the guard did not name the foreign owner and its birth"
done
pass "background, inherited-XPC, SSH-born, SSH-descended, and unprovable owners are taken over"

# --- an owner nobody can prove is treated as foreign -------------------------

new_case running
guard
expect_code 1 "$GUARD_RC" "the guard failed when lsof listed no owner"
assert_contains "$GUARD_OUT" 'no herdr process could be proven to own' "the guard did not report the unprovable owner"
assert_stop_before_start
pass "a running session with no provable owner is taken over rather than trusted"

new_case running
printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
rm -f "$FAKE/lsof"
guard
cp "$TMP_ROOT/lsof.fake" "$FAKE/lsof"
chmod +x "$FAKE/lsof"
expect_code 1 "$GUARD_RC" "the guard failed when lsof was absent"
assert_contains "$GUARD_OUT" 'lsof does not resolve' "the guard did not report the missing lsof"
assert_stop_before_start
pass "a host without lsof cannot prove an Aqua birth, so the session is taken over"

# --- a foreign owner that keeps the socket makes the guard fail for a retry --

new_case running
printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
touch "$CASE_STATE/stop-ignored"
guard
expect_code 1 "$GUARD_RC" "the guard did not exit 1 when the foreign server kept its socket"
assert_not_started "the guard started a server while the foreign one still held the socket"
assert_contains "$(herdr_calls)" "server stop --session $SESSION" "the guard never asked the foreign server to stop"
assert_contains "$GUARD_OUT" 'did not release its socket within 8 tenths' "the guard did not report the bounded wait"
pass "a foreign server that never releases the socket yields exit 1 so launchd retries"

# --- the release wait is polled, not assumed ---------------------------------

new_case running
printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
printf '3\n' > "$CASE_STATE/stop-releases-after"
guard
expect_code 1 "$GUARD_RC" "the guard gave up on a server that released its socket after a few polls"
assert_started "the guard did not start after the delayed release"
assert_contains "$GUARD_OUT" 'released its socket after' "the guard did not report the observed release"
[ "$(grep -c "^status --json --session $SESSION$" "$CASE_LOG")" -ge 4 ] \
  || fail "the guard did not keep polling the session status until the socket was released"
pass "the guard starts as soon as the foreign server releases the socket"

# --- usage errors never touch a server ---------------------------------------

new_case running
set +e
env -i PATH="$CASE_PATH" "$GUARD" "$FAKE/herdr" >/dev/null 2>&1
rc=$?
set -e
expect_code 2 "$rc" "a missing session argument was not a usage error"
set +e
env -i PATH="$CASE_PATH" "$GUARD" "$TMP_ROOT/no-such-herdr" "$SESSION" >/dev/null 2>&1
rc=$?
set -e
expect_code 1 "$rc" "a non-executable herdr path was not refused"
[ ! -s "$CASE_LOG" ] || fail "a refused invocation still called herdr"
pass "argument errors are refused before any herdr call"
