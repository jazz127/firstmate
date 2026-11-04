#!/usr/bin/env bash
set -eu
E=~/.no-mistakes/evidence/01M6HXJ76P890QKBA4DDMRGDHV
world="$PWD/.phase-tmp/r2-inactive-live"
mkdir -p "$world"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_BACKEND TMUX HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH
export FM_HC_BIN="$PWD/.phase-tmp/tools/herdr-core" FM_HC_LAB_DIR="$E/r2hi" FM_HC_LAB_SOCK_DIR="$E/r2si"
export HC_SESSION=fm-hclab-i FM_HC_SOCKET="$E/r2si/fm-hclab-i.sock"
cleanup() { rc=$?; trap - EXIT; bin/fm-hc-lab.sh teardown "$HC_SESSION" || rc=1; exit "$rc"; }
trap cleanup EXIT
bin/fm-hc-lab.sh provision "$HC_SESSION"
export XDG_STATE_HOME="$E/r2hi/$HC_SESSION/env/xdg-state" XDG_CONFIG_HOME="$E/r2hi/$HC_SESSION/env/xdg-config" XDG_DATA_HOME="$E/r2hi/$HC_SESSION/env/xdg-data"
export FM_HOME="$world/home" NM_HOME="$world/nm" FM_CREW_STATE_NO_FORGE=1
bin/fm-lab-home.sh create "$FM_HOME"
git -C "$world" init -q
printf 'base\n' > "$world/readme"
git -C "$world" add readme
git -C "$world" -c user.name=Validation -c user.email=validation@example.invalid commit -qm base
. bin/fm-backend.sh
fm_backend_source hc
reply=$(bin/fm-hc-lab.sh run "$HC_SESSION" run --bg --json --no-parent --outlive-parent --no-notify --cwd "$world" --label firstmate.task=fm-child --label "firstmate.home=$(fm_backend_hometag)" codex --no-alt-screen -c features.hooks=false)
printf '%s\n' "$reply"
address=$(printf '%s' "$reply" | jq -r .address)
for ((i=0;i<100;i++)); do
  state=$(fm_backend_agent_state hc "$HC_SESSION:$address")
  [ "$state" = alive ] && break
  sleep .1
done
[ "$state" = alive ]
epoch=$(date +%s)
printf 'window=%s:%s\nbackend=hc\nkind=scout\nharness=codex\nspawn_gen=s%s.1.1\nworktree=%s\nproject=%s\n' "$HC_SESSION" "$address" "$epoch" "$world" "$world" > "$FM_HOME/state/child.meta"
printf 'failed [at=%s]: earlier incarnation ended\n' "$((epoch-600))" > "$FM_HOME/state/child.status"
python3 - "$FM_HOME/state" <<'PY_AGE'
import os,sys,time
from pathlib import Path
for p in Path(sys.argv[1]).glob('child.*'):os.utime(p,(time.time()-600,time.time()-600))
PY_AGE
bin/fm-crew-state.sh child
bin/fm-inactive-reconcile.sh scan --startup
if [ -f "$FM_HOME/state/child.inactive-outcome" ]; then cat "$FM_HOME/state/child.inactive-outcome"; exit 1; fi
if [ -f "$FM_HOME/state/.wake-queue" ]; then ! grep -q inactive-outcome "$FM_HOME/state/.wake-queue"; fi
printf 'Live replacement agent withheld the earlier terminal outcome.\n'
fm_backend_kill hc "$HC_SESSION:$address"
printf 'After stopping the native agent: %s\n' "$(fm_backend_agent_state hc "$HC_SESSION:$address")"
bin/fm-inactive-reconcile.sh scan --startup
ls "$FM_HOME/state"/*inactive* || true
cat "$FM_HOME/state/.wake-queue"
