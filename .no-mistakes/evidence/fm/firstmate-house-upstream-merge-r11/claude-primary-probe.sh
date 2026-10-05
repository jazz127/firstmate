#!/bin/bash
set -eu
LAB=$(mktemp -d "$PWD/lXXX")
cleanup() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 110 -y 32 -c "$PWD" -e FM_HOME="$LAB" "claude --setting-sources '' --tools '' --permission-mode plan --system-prompt 'This is a disposable validation endpoint. Only acknowledge messages. Do not use tools or change any files.'"
sleep 4
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary > /Users/jarad/.no-mistakes/evidence/01M455W9R326CJ1BPJVJB6ADKS/claude-primary-probe.txt
cat /Users/jarad/.no-mistakes/evidence/01M455W9R326CJ1BPJVJB6ADKS/claude-primary-probe.txt
