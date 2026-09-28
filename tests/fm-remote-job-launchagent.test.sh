#!/usr/bin/env bash
# Behavior tests for safely replacing the remote-job Aqua LaunchAgent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-job-launchagent)
FAKE_BIN="$TMP_ROOT/bin"
STATE="$TMP_ROOT/state"
ACCOUNT_HOME="$TMP_ROOT/account"
mkdir -p "$FAKE_BIN" "$STATE" "$ACCOUNT_HOME/Library/LaunchAgents"
export FM_FAKE_LAUNCHCTL_STATE="$STATE"
export PATH="$FAKE_BIN:$PATH"
cat > "$FAKE_BIN/launchctl" <<'SH'
#!/usr/bin/env bash
set -u
command=${1:-}
target=${2:-}
printf '%s\n' "$command $target" >> "$FM_FAKE_LAUNCHCTL_STATE/calls"
label=${target##*/}
loaded="$FM_FAKE_LAUNCHCTL_STATE/$label.loaded"
case "$command" in
  bootout)
    if [ -f "$FM_FAKE_LAUNCHCTL_STATE/bootout-stays-loaded" ]; then
      printf '%s\n' "${FM_FAKE_LAUNCHCTL_DELAY:-3}" > "$FM_FAKE_LAUNCHCTL_STATE/remaining"
    else
      rm -f "$loaded"
    fi
    ;;
  print)
    if [ -f "$loaded" ]; then
      if [ -f "$FM_FAKE_LAUNCHCTL_STATE/remaining" ]; then
        remaining=$(cat "$FM_FAKE_LAUNCHCTL_STATE/remaining")
        if [ "$remaining" = forever ]; then
          printf 'old job still loaded\n'
          exit 0
        fi
        if [ "$remaining" -gt 0 ]; then
          printf '%s\n' "$((remaining - 1))" > "$FM_FAKE_LAUNCHCTL_STATE/remaining"
          printf 'old job still loaded\n'
          exit 0
        fi
        rm -f "$loaded" "$FM_FAKE_LAUNCHCTL_STATE/remaining"
      else
        printf 'job loaded\n'
        exit 0
      fi
    fi
    exit 113
    ;;
  bootstrap)
    plist=${3:-}
    label=${plist##*/}
    label=${label%.plist}
    loaded="$FM_FAKE_LAUNCHCTL_STATE/$label.loaded"
    [ ! -f "$loaded" ] || { printf 'bootstrap refused while old job is visible\n' >&2; exit 5; }
    : > "$loaded"
    ;;
  kickstart)
    ;;
esac
SH
chmod +x "$FAKE_BIN/launchctl"

# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

FM_REMOTE_JOB_LABEL=dev.firstmate.remote-job
FM_REMOTE_JOB_LAUNCH_AGENT_PLIST="$ACCOUNT_HOME/Library/LaunchAgents/$FM_REMOTE_JOB_LABEL.plist"
: > "$FM_REMOTE_JOB_LAUNCH_AGENT_PLIST"
touch "$STATE/$FM_REMOTE_JOB_LABEL.loaded" "$STATE/bootout-stays-loaded"
export FM_FAKE_LAUNCHCTL_DELAY=3
fm_remote_job_reload_launchagent "$ACCOUNT_HOME" 501 || fail "reload failed while bootout was draining: $FM_REMOTE_JOB_ERROR"
[ -f "$STATE/$FM_REMOTE_JOB_LABEL.loaded" ] || fail "reload did not bootstrap the replacement"
[ ! -f "$STATE/remaining" ] || fail "reload bootstrapped before the old job disappeared"
pass "reload waits for asynchronous bootout before bootstrapping"

touch "$STATE/bootout-stays-loaded"
export FM_FAKE_LAUNCHCTL_DELAY=forever
if fm_remote_job_reload_launchagent "$ACCOUNT_HOME" 501; then
  fail "reload succeeded while the old job remained loaded"
fi
assert_contains "$FM_REMOTE_JOB_ERROR" 'remained loaded after bootout' "the unload timeout was not reported"
[ "$(rg -c '^bootstrap ' "$STATE/calls")" -eq 1 ] || fail "reload tried to bootstrap after the unload timeout"
pass "reload reports a bounded unload timeout without bootstrapping"
