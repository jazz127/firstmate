#!/usr/bin/env bash
set -eu
E=~/.no-mistakes/evidence/01M6HXJ76P890QKBA4DDMRGDHV
export FM_HC_BIN="$PWD/.phase-tmp/tools/herdr-core" FM_HC_LAB_DIR="$E/h" FM_HC_LAB_SOCK_DIR="$E/s"
export HC_SESSION=fm-hclab-v1 FM_HC_SOCKET="$E/s/fm-hclab-v1.sock"
cleanup() { rc=$?; trap - EXIT; bin/fm-hc-lab.sh teardown "$HC_SESSION" || rc=1; exit "$rc"; }
trap cleanup EXIT
export XDG_STATE_HOME="$E/h/$HC_SESSION/env/xdg-state" XDG_CONFIG_HOME="$E/h/$HC_SESSION/env/xdg-config" XDG_DATA_HOME="$E/h/$HC_SESSION/env/xdg-data"
export DISABLE_AUTOUPDATER=1
[ -f "$PWD/.phase-tmp/hc-home/.fm-lab-home" ] || bin/fm-lab-home.sh create "$PWD/.phase-tmp/hc-home"
export FM_HOME="$PWD/.phase-tmp/hc-home"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE
. bin/fm-backend.sh
fm_backend_source hc
for harness in codex claude; do
  if [ "$harness" = codex ]; then
    reply=$(bin/fm-hc-lab.sh run "$HC_SESSION" run --bg --json --no-parent --outlive-parent --no-notify --cwd "$PWD" --label "firstmate.task=fm-codex" --label "firstmate.home=$(fm_backend_hometag)" codex --no-alt-screen -c features.hooks=false)
  else
    reply=$(bin/fm-hc-lab.sh run "$HC_SESSION" run --bg --json --no-parent --outlive-parent --no-notify --cwd "$PWD" --label "firstmate.task=fm-claude" --label "firstmate.home=$(fm_backend_hometag)" claude)
  fi
  printf 'launch %s: %s\n' "$harness" "$reply"
  address=$(printf '%s' "$reply" | jq -r .address)
  state=unknown
  for ((i=0;i<60;i++)); do
    state=$(fm_backend_agent_state hc "$HC_SESSION:$address")
    [ "$state" = alive ] && break
    sleep .2
  done
  printf '%s native liveness: %s\n' "$harness" "$state"
  bin/fm-hc-lab.sh run "$HC_SESSION" get --json "$address"
  bin/fm-hc-lab.sh run "$HC_SESSION" read "$address" > "$E/hc-$harness-screen.txt"
  fm_backend_kill hc "$HC_SESSION:$address"
  [ "$state" = alive ]
  printf '%s after close: %s\n' "$harness" "$(fm_backend_agent_state hc "$HC_SESSION:$address")"
done
