#!/bin/bash
set -eu
home="$PWD/.validation-tmp/checkpoint-home"
bin/fm-lab-home.sh create "$home"
export FM_HOME="$home" TMPDIR="$PWD/.validation-tmp/tmp"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
. bin/fm-wake-lib.sh
fm_wake_append check buried 'check: unacknowledged durable wake'
rc=0
bin/fm-watch-checkpoint.sh --seconds 5 || rc=$?
[ "$rc" -eq 0 ]
marker=$(cat "$home/state/.watcher-down")
printf 'Recorded recovery after first notification: %s\n' "$marker"
case "$marker" in announced:downtime:*) ;; *) exit 1 ;; esac
rc=0
bin/fm-watch-checkpoint.sh --seconds 1 || rc=$?
printf 'Second checkpoint exit=%s marker=%s\n' "$rc" "$(cat "$home/state/.watcher-down")"
[ "$rc" -eq 124 ]
[ "$(cat "$home/state/.watcher-down")" = "$marker" ]
printf 'Retained durable notification: '; cat "$home/state/.wake-queue"
