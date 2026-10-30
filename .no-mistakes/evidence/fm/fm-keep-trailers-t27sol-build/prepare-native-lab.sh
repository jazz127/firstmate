#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB="$ROOT/.test-live/native-lab"
mkdir -p "$LAB"
bash bin/fm-lab-home.sh create "$LAB/fmhome"
SOCKET_DIR=$(bash bin/fm-lab-home.sh tmux-dir "$LAB/fmhome")
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
mkdir -p "$LAB/home" "$LAB/project" "$LAB/config" "$LAB/data" "$LAB/state" "$LAB/cache"
git -C "$LAB/project" init -q -b main
git -C "$LAB/project" -c user.name=Validation -c user.email=validation@example.invalid commit -q --allow-empty -m 'chore: isolated project'
git clone -q --bare "$LAB/project" "$LAB/origin.git"
git -C "$LAB/project" remote add origin git@github.com:t27sol/isolated-attribution.git
git -C "$LAB/project" config "url.file://$LAB/origin.git.insteadOf" git@github.com:t27sol/isolated-attribution.git
cat > "$LAB/project/treehouse.toml" <<EOF
root = "$LAB/pool"
EOF
mkdir -p "$LAB/fmhome/data/native"; touch "$LAB/fmhome/state/.last-watcher-beat"
cat > "$LAB/fmhome/data/native/brief.md" <<'EOF'
# Task
## Captain's intent
Validate commit attribution in a disposable repository.
## Firstmate spec
This is an isolated lab check. Do not contact any external service or modify any files. Wait for the lab driver.
EOF
cat > "$LAB/drive-spawn.sh" <<EOF
#!/bin/bash
cd '$ROOT'
export FM_HOME='$LAB/fmhome' HOME='$LAB/home' TMPDIR='$LAB' TREEHOUSE_ROOT='$LAB/pool'
export XDG_CONFIG_HOME='$LAB/config' XDG_DATA_HOME='$LAB/data' XDG_STATE_HOME='$LAB/state' XDG_CACHE_HOME='$LAB/cache'
export OPENCODE_DB='$LAB/native.db' OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1
export PATH='$ROOT/.test-live/opencode-v2':\$PATH
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR CODEX_THREAD_ID OPENCODE_SESSION_ID
bash '$ROOT/bin/fm-spawn.sh' native '$LAB/project' --mode local-only --yolo off --backend tmux --harness opencode > '$LAB/spawn.log' 2>&1
rc=\$?
printf '%s\n' \$rc > '$LAB/spawn.exit'
exec /bin/bash
EOF
chmod +x "$LAB/drive-spawn.sh"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab new-session -d -s primary -x 140 -y 45 -c "$ROOT" -e FM_HOME="$LAB/fmhome" "$LAB/drive-spawn.sh"
printf '%s\n' "$SOCKET_DIR"
