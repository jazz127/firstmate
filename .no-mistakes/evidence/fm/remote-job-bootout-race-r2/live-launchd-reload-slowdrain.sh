#!/usr/bin/env bash
# Live launchd harness: drives fm_remote_job_reload_launchagent against the real
# macOS launchd gui/<uid> domain using a disposable label and a worker that takes
# ~3s to exit after SIGTERM (like the real remote-job worker draining).
# Usage: live-launchd-reload.sh <lib-path> <tag>
set -u
LIB=$1; TAG=$2
UIDN=$(id -u)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-launchd.XXXXXX")
. "$LIB"
FM_REMOTE_JOB_LABEL="dev.firstmate.nmtest.$TAG.$$"
fm_remote_job_launchagent_paths "$TMP"
mkdir -p "$FM_REMOTE_JOB_LAUNCH_AGENT_DIR"
cat > "$TMP/worker.sh" <<'W'
#!/bin/bash
trap 'echo "$(date +%T) TERM received, draining 9s" >> "$0.log"; sleep 9; echo "$(date +%T) exit" >> "$0.log"; exit 0' TERM
echo "$(date +%T) worker start pid $$" >> "$0.log"
while :; do sleep 1; done
W
chmod +x "$TMP/worker.sh"
cat > "$FM_REMOTE_JOB_LAUNCH_AGENT_PLIST" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$FM_REMOTE_JOB_LABEL</string>
<key>ProgramArguments</key><array><string>$TMP/worker.sh</string></array>
<key>KeepAlive</key><true/>
</dict></plist>
P
cleanup() { launchctl bootout "gui/$UIDN/$FM_REMOTE_JOB_LABEL" >/dev/null 2>&1; for i in $(seq 1 60); do launchctl print "gui/$UIDN/$FM_REMOTE_JOB_LABEL" >/dev/null 2>&1 || break; sleep 0.2; done; rm -rf "$TMP"; }
trap cleanup EXIT
echo "== [$TAG] label gui/$UIDN/$FM_REMOTE_JOB_LABEL"
launchctl bootstrap "gui/$UIDN" "$FM_REMOTE_JOB_LAUNCH_AGENT_PLIST" || { echo "initial bootstrap failed"; exit 2; }
sleep 1.5
echo "old job state: $(launchctl print "gui/$UIDN/$FM_REMOTE_JOB_LABEL" | awk '/^\tstate =|^\tpid =/{printf "%s ", $0}')"
start=$(date +%s)
if fm_remote_job_reload_launchagent "$TMP" "$UIDN"; then rc=0; else rc=1; fi
end=$(date +%s)
echo "reload rc=$rc elapsed=$((end-start))s error='${FM_REMOTE_JOB_ERROR:-}'"
sleep 1.5
echo "new job state: $(launchctl print "gui/$UIDN/$FM_REMOTE_JOB_LABEL" 2>&1 | awk '/^\tstate =|^\tpid =|Could not find/{printf "%s ", $0}')"
echo "worker log:"; sed 's/^/  /' "$TMP/worker.sh.log"
exit $rc
