#!/usr/bin/env bash
# Reads the real lab Claude pane through the merged tmux composer adapter.
LAB=$1; ROOT=$2
export TMUX_TMPDIR="$LAB/tmux"
tmux() { command tmux -L fm-lab "$@"; }
. "$ROOT/bin/fm-tmux-lib.sh"
printf 'composer_state=%s\n' "$(fm_tmux_composer_state primary)"
