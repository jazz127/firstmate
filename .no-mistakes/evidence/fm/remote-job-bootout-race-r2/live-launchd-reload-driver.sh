#!/usr/bin/env bash
# Live launchd drive of fm_remote_job_reload_launchagent with a disposable label.
set -u
LIB=$1 MODE=$2   # MODE=slow (drains 2s on TERM) | stuck (ignores TERM)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
LABEL="dev.firstmate.remote-job-labtest.$$"
UIDN=$(id -u)
mkdir -p "$LAB/Library/LaunchAgents" "$LAB/Library/Logs"
cat > "$LAB/worker.sh" <<W
#!/bin/bash
if [ "$MODE" = stuck ]; then trap '' TERM; else trap 'sleep 2; exit 0' TERM; fi
while :; do sleep 1 & wait \$!; done
W
chmod +x "$LAB/worker.sh"
cat > "$LAB/Library/LaunchAgents/$LABEL.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$LAB/worker.sh</string></array>
<key>RunAtLoad</key><true/>
<key>ExitTimeOut</key><integer>12</integer>
</dict></plist>
P
. "$LIB"
FM_REMOTE_JOB_LABEL=$LABEL
launchctl bootstrap "gui/$UIDN" "$LAB/Library/LaunchAgents/$LABEL.plist"
sleep 1
echo "label=$LABEL mode=$MODE lib=$LIB"
echo "before: pid=$(launchctl print gui/$UIDN/$LABEL | awk '/^\tpid/{print $3}')"
t0=$(date +%s.%N 2>/dev/null || date +%s)
if fm_remote_job_reload_launchagent "$LAB" "$UIDN"; then rc=0; else rc=$?; fi
t1=$(date +%s)
echo "reload rc=$rc elapsed~$((t1-${t0%.*}))s error='${FM_REMOTE_JOB_ERROR:-}'"
sleep 1
launchctl print "gui/$UIDN/$LABEL" >/dev/null 2>&1 && echo "after: loaded pid=$(launchctl print gui/$UIDN/$LABEL | awk '/^\tpid/{print $3}') state=$(launchctl print gui/$UIDN/$LABEL | awk '/^\tstate/{print $3}')" || echo "after: not loaded"
# teardown
launchctl bootout "gui/$UIDN/$LABEL" >/dev/null 2>&1
for i in $(seq 1 150); do launchctl print "gui/$UIDN/$LABEL" >/dev/null 2>&1 || break; sleep 0.1; done
launchctl print "gui/$UIDN/$LABEL" >/dev/null 2>&1 && echo "TEARDOWN: still loaded" || echo "teardown: job removed"
rm -rf "$LAB"
