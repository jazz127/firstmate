#!/usr/bin/env bash
set -eu
E=~/.no-mistakes/evidence/01M6HXJ76P890QKBA4DDMRGDHV
LAB=$(mktemp -d "$E/r2l.XXXXXX")
cleanup() {
  rc=$?; trap - EXIT
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server >/dev/null 2>&1 || true
  python3 - "$LAB" <<'PY'
import shutil,sys
from pathlib import Path
p=Path(sys.argv[1]);assert p.parent==Path('~/.no-mistakes/evidence/01M6HXJ76P890QKBA4DDMRGDHV') and p.name.startswith('r2l.')
shutil.rmtree(p)
PY
  exit "$rc"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
touch "$LAB/config/codex-stop-park"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" codex
sleep 3
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t primary Escape
sleep 4
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary > "$E/r2-codex-primary-screen.txt"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-panes -t primary -F 'grid=#{pane_width}x#{pane_height} command=#{pane_current_command}'
cat "$E/r2-codex-primary-screen.txt"
[ ! -f "$LAB/state/.codex-park-session" ] || cat "$LAB/state/.codex-park-session"
