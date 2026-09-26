#!/usr/bin/env bash
# Round-2 live driver: real pi 0.87.1 in an fm-lab Herdr session.
set -u
ROOT=$1; EV=$2
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$LAB_HELPER" name pir2) || exit 1
export HERDR_SESSION="$SESSION"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rm -rf "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-proj.XXXXXX")
cleanup() { "$LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1; rm -rf "$LAB" "$SCR"; echo "teardown session=$SESSION done"; }
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION" || exit 1
PROJ="$SCR/proj"; WT="$SCR/wt"; mkdir -p "$PROJ"
git -C "$PROJ" init -q; echo x > "$PROJ/README.md"; git -C "$PROJ" add .; git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm i
git -C "$PROJ" worktree add -q -b t1 "$WT"
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr || exit 1
CR=$(fm_backend_herdr_container_ensure "$WT") || exit 1
C=${CR%%$'\t'*}; SEED=${CR#*$'\t'}; WS=${C#*:}
read -r TAB PANE <<<"$(fm_backend_herdr_create_task "$C" fm-t1 "$WT" "$SEED")"
T="$SESSION:$PANE"
mkdir -p "$LAB/data/t1"; printf '# Task\n## Captain'"'"'s intent\nlab\n## Firstmate spec\nlab\n' > "$LAB/data/t1/brief.md"
cat > "$LAB/state/t1.meta" <<M
window=$T
endpoint_task_id=t1
worktree=$WT
project=$PROJ
harness=pi
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
M
screen() { herdr pane read "$PANE" --session "$SESSION" --source visible 2>/dev/null | sed 's/[[:space:]]*$//' | grep -v '^$' | tail -8; }
probe() { # label
  echo "### probe: $1"
  for opt in 0 1; do
    printf 'FM_BACKEND_HERDR_PI_PROMPT=%s state=%s content=[%s]\n' "$opt" \
      "$(FM_BACKEND_HERDR_PI_PROMPT=$opt fm_backend_herdr_composer_state "$T")" \
      "$(FM_BACKEND_HERDR_PI_PROMPT=$opt fm_backend_herdr_composer_content "$T")"
  done
}
agent() { herdr pane get "$PANE" --session "$SESSION" 2>/dev/null | jq -c '.result.pane | {agent,agent_status}' 2>/dev/null; }
control_exit() {
  echo "### fm-control t1 exit (default env, no PI_PROMPT opt-in)"
  env -u FM_BACKEND_HERDR_PI_PROMPT FM_HOME="$LAB" HERDR_SESSION="$SESSION" FM_CONTROL_EXIT_WAIT=15 "$ROOT/bin/fm-control.sh" t1 exit 2>&1; echo "rc=$?"
  sleep 2; echo "--- pane after:"; screen; echo "agent=$(agent)"
}
wait_idle() { for _ in $(seq 1 60); do [ "$(agent | jq -r .agent_status 2>/dev/null)" = idle ] && return 0; sleep 1; done; return 1; }

fm_backend_herdr_send_text_line "$T" "pi" || exit 1
wait_idle || { echo "pi never idle"; screen; exit 1; }
sleep 2
echo "pi=$(pi --version 2>&1|head -1) herdr=$(herdr --version) agent=$(agent)"

# S1: user-typed lone '>' on stock pi
herdr pane send-text "$PANE" '>' --session "$SESSION" >/dev/null; sleep 1.5
echo "### screen with user-typed lone '>'"; screen
probe "lone '>' draft"
control_exit
echo "### draft still intact? agent still running?"; echo "agent=$(agent)"

# S2: clear the draft and type an ordinary draft
herdr pane send-keys "$PANE" backspace --session "$SESSION" >/dev/null 2>&1 || herdr pane send-keys "$PANE" BackSpace --session "$SESSION" >/dev/null; sleep 1
herdr pane send-text "$PANE" 'hello draft' --session "$SESSION" >/dev/null; sleep 1.5
echo "### screen with draft 'hello draft'"; screen
probe "ordinary draft"
control_exit

# S3: '> >' draft
for _ in $(seq 1 12); do herdr pane send-keys "$PANE" backspace --session "$SESSION" >/dev/null 2>&1; done; sleep 1
herdr pane send-text "$PANE" '> >' --session "$SESSION" >/dev/null; sleep 1.5
echo "### screen with draft '> >'"; screen
probe "'> >' draft"
for _ in $(seq 1 5); do herdr pane send-keys "$PANE" backspace --session "$SESSION" >/dev/null 2>&1; done; sleep 1.5

# S4: proven-empty composer -> exit stops pi
echo "### screen with empty composer"; screen
probe "empty composer"
control_exit
