#!/usr/bin/env bash
set -eu
E=~/.no-mistakes/evidence/01M6HXJ76P890QKBA4DDMRGDHV
export FM_HOME="$PWD/.phase-tmp/watcher-home"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_BACKEND
bin/fm-lab-home.sh create "$FM_HOME"
cat > "$FM_HOME/state/slow.check.sh" <<'CHECK'
#!/usr/bin/env bash
printf 'partial public check output\n'
sleep 20
CHECK
chmod 700 "$FM_HOME/state/slow.check.sh"
bin/fm-check-register.sh slow
FM_CHECK_TIMEOUT=1 FM_CHECK_INTERVAL=0 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 bin/fm-watch-checkpoint.sh --seconds 15
cat "$FM_HOME/state/.wake-queue"
