#!/usr/bin/env bash
# Isolated real-Herdr E2E coverage for per-project task spaces
# (config/herdr-presentation-spaces = project; docs/herdr-backend.md
# "Project spaces").
# The test drives the real spawn and teardown scripts and a real Treehouse pool
# against one guarded named lab session: every Herdr call the production code
# makes is routed through bin/fm-herdr-lab.sh, which supplies the lab session
# flag and verifies the default fleet session is unchanged after teardown.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
REAL_TREEHOUSE=$(command -v treehouse)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-project-spaces.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HERDR_CALL_LOG="$TMP_ROOT/herdr-calls.log"
mkdir -p "$FAKEBIN"
: > "$HERDR_CALL_LOG"
export REAL_HERDR HERDR_CALL_LOG HERDR_ORIGINAL_PATH HERDR_LAB_HELPER

# Log every production-adapter call, remove its already-validated trailing
# session flag, and send the operation through the lab helper so that helper
# remains the sole process which appends the real trailing session flag.
# The adapter's deliberately session-independent version read cannot pass the
# helper's leading-option guard, so the wrapper sends only that read straight
# to the absolute real binary with the same explicit trailing lab session.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$HERDR_CALL_LOG"
args=("$@")
last_index=$((${#args[@]} - 1))
flag_index=$((last_index - 1))
if [ "${#args[@]}" -ge 2 ] \
   && [ "${args[$flag_index]}" = --session ] \
   && [ "${args[$last_index]}" = "${HERDR_LAB_SESSION:?}" ]; then
  unset "args[$last_index]" "args[$flag_index]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in
    --session|--session=*)
      echo "test wrapper: unexpected caller-supplied session flag" >&2
      exit 1
      ;;
  esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$PATH"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity.
herdr_forget_inherited_pane

HERDR_LAB_SESSION=$(PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" name fm-herdr-project-spaces)
export HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_LAB_SESSION
LAB_READY=0
RECORDED_WORKTREES=""
CLEANED=0
cleanup_all() {
  local wt status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    "$REAL_TREEHOUSE" return --force "$wt" >/dev/null 2>&1 || true
  done <<EOF
$RECORDED_WORKTREES
EOF
  if [ "$LAB_READY" -eq 1 ]; then
    PATH="$HERDR_ORIGINAL_PATH" \
      "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || status=$?
    LAB_READY=0
  fi
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT

PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab"
LAB_READY=1

lab() {
  PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

make_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# Herdr project spaces E2E fixture\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

write_ship_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Herdr project spaces fixture $2.

## Firstmate spec
Verify per-project workspace placement for $2.
EOF
}

spawn_task() {  # <id> <project-dir>
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$2" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr \
    > "$TMP_ROOT/$1.out" 2> "$TMP_ROOT/$1.err" \
    || fail "spawn of $1 failed: $(cat "$TMP_ROOT/$1.err")"
  remember_meta_worktree "$HOME_DIR/state/$1.meta"
}

teardown_task() {  # <id>
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-teardown.sh" "$1" --force > "$TMP_ROOT/td-$1.out" 2> "$TMP_ROOT/td-$1.err" \
    || fail "teardown of $1 failed: $(cat "$TMP_ROOT/td-$1.err")"
}

remember_meta_worktree() {  # <meta>
  local wt
  wt=$(grep '^worktree=' "$1" 2>/dev/null | cut -d= -f2-)
  [ -n "$wt" ] || fail "metadata $1 did not record a worktree"
  RECORDED_WORKTREES="${RECORDED_WORKTREES}${wt}"$'\n'
}

meta_field() {  # <id> <key>
  grep "^$2=" "$HOME_DIR/state/$1.meta" | cut -d= -f2-
}

workspace_label() {  # <workspace-id>
  lab workspace list | jq -r --arg w "$1" '.result.workspaces[]? | select(.workspace_id == $w) | .label'
}

workspace_tab_labels() {  # <workspace-id>
  lab tab list --workspace "$1" | jq -r '[.result.tabs[]?.label] | sort | join(",")'
}

focused_tab() {
  lab workspace list | jq -r '[.result.workspaces[]? | select(.focused == true) | .active_tab_id][0] // empty'
}

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
touch "$HOME_DIR/state/.last-watcher-beat"
printf 'project\n' > "$HOME_DIR/config/herdr-presentation-spaces"
for id in alpha-one alpha-two alpha-three beta-one alpha-four; do
  write_ship_brief "$HOME_DIR" "$id"
done
ALPHA_DIR="$TMP_ROOT/alpha"
BETA_DIR="$TMP_ROOT/beta"
make_project "$ALPHA_DIR"
make_project "$BETA_DIR"

# A focused captain workspace wearing the exact alpha project-space label, with
# a task-shaped tab, proves placement never adopts a workspace by its label and
# never takes the captain's focus.
CAPTAIN_OUT=$(lab workspace create --cwd "$TMP_ROOT" --label "▸ alpha" --focus) \
  || fail "could not create the captain decoy workspace"
CAPTAIN_WSID=$(printf '%s' "$CAPTAIN_OUT" | jq -r '.result.workspace.workspace_id // empty')
lab tab create --workspace "$CAPTAIN_WSID" --cwd "$TMP_ROOT" --label fm-captain --no-focus >/dev/null \
  || fail "could not create the captain decoy tab"
CAPTAIN_TAB=$(focused_tab)
[ -n "$CAPTAIN_WSID" ] && [ -n "$CAPTAIN_TAB" ] || fail "captain decoy fixture returned incomplete ids"
CAPTAIN_TABS_BEFORE=$(workspace_tab_labels "$CAPTAIN_WSID")

spawn_task alpha-one "$ALPHA_DIR"
ALPHA_WSID=$(meta_field alpha-one herdr_workspace_id)
[ -n "$ALPHA_WSID" ] && [ "$ALPHA_WSID" != "$CAPTAIN_WSID" ] \
  || fail "the first alpha task adopted the captain's same-labelled workspace"
[ "$(workspace_label "$ALPHA_WSID")" = "▸ alpha" ] \
  || fail "the alpha project space carries an unexpected label: $(workspace_label "$ALPHA_WSID")"
[ "$(workspace_tab_labels "$ALPHA_WSID")" = fm-alpha-one ] \
  || fail "a new project space must hold only its task tab: $(workspace_tab_labels "$ALPHA_WSID")"
[ ! -e "$HOME_DIR/state/alpha-one.herdr-presentation" ] \
  || fail "a project-space task must not publish a one-task presentation journal"

spawn_task alpha-two "$ALPHA_DIR"
[ "$(meta_field alpha-two herdr_workspace_id)" = "$ALPHA_WSID" ] \
  || fail "the second alpha task did not reuse the alpha project space"
[ "$(workspace_tab_labels "$ALPHA_WSID")" = fm-alpha-one,fm-alpha-two ] \
  || fail "the alpha project space does not hold both alpha tasks: $(workspace_tab_labels "$ALPHA_WSID")"

spawn_task beta-one "$BETA_DIR"
BETA_WSID=$(meta_field beta-one herdr_workspace_id)
[ -n "$BETA_WSID" ] && [ "$BETA_WSID" != "$ALPHA_WSID" ] && [ "$BETA_WSID" != "$CAPTAIN_WSID" ] \
  || fail "the beta task did not get its own project space"
[ "$(workspace_label "$BETA_WSID")" = "▸ beta" ] || fail "the beta project space carries an unexpected label"
[ "$(focused_tab)" = "$CAPTAIN_TAB" ] || fail "project-space placement took the captain's focus"
[ "$(workspace_tab_labels "$CAPTAIN_WSID")" = "$CAPTAIN_TABS_BEFORE" ] || fail "the captain decoy workspace was mutated"
pass "real Herdr lab: tasks of one project share one labelled workspace, another project gets its own, and a same-labelled captain workspace keeps its focus and contents"

teardown_task alpha-one
[ "$(workspace_label "$ALPHA_WSID")" = "▸ alpha" ] \
  || fail "cleaning up one of two alpha tasks removed the alpha project space"
[ "$(workspace_tab_labels "$ALPHA_WSID")" = fm-alpha-two ] \
  || fail "the alpha project space lost the wrong task: $(workspace_tab_labels "$ALPHA_WSID")"
spawn_task alpha-three "$ALPHA_DIR"
[ "$(meta_field alpha-three herdr_workspace_id)" = "$ALPHA_WSID" ] \
  || fail "an alpha task placed while alpha still had a task did not reuse the space"
teardown_task alpha-two
[ -n "$(workspace_label "$ALPHA_WSID")" ] || fail "the alpha project space vanished while alpha-three still ran in it"
teardown_task alpha-three
[ -z "$(workspace_label "$ALPHA_WSID")" ] || fail "cleaning up the last alpha task left the alpha project space behind"
[ -n "$(workspace_label "$BETA_WSID")" ] || fail "alpha cleanup removed the beta project space"
[ "$(focused_tab)" = "$CAPTAIN_TAB" ] || fail "project-space cleanup took the captain's focus"
pass "real Herdr lab: a project space outlives every task but its last, and its removal keeps the captain's focus"

spawn_task alpha-four "$ALPHA_DIR"
ALPHA_NEW_WSID=$(meta_field alpha-four herdr_workspace_id)
[ -n "$ALPHA_NEW_WSID" ] && [ "$ALPHA_NEW_WSID" != "$CAPTAIN_WSID" ] \
  || fail "the next alpha task adopted the captain's same-labelled workspace after removal"
[ "$(workspace_label "$ALPHA_NEW_WSID")" = "▸ alpha" ] || fail "the reopened alpha space carries an unexpected label"
teardown_task alpha-four
teardown_task beta-one
[ -z "$(workspace_label "$ALPHA_NEW_WSID")" ] && [ -z "$(workspace_label "$BETA_WSID")" ] \
  || fail "cleanup left a project space behind"
[ "$(workspace_tab_labels "$CAPTAIN_WSID")" = "$CAPTAIN_TABS_BEFORE" ] || fail "the captain decoy workspace was mutated"
[ "$(focused_tab)" = "$CAPTAIN_TAB" ] || fail "project-space reopen or cleanup took the captain's focus"
pass "real Herdr lab: after its last task a project reopens a fresh space and every space is removed with its last task"

STATUS_JSON=$(lab status --json)
HERDR_VERSION=$(printf '%s' "$STATUS_JSON" | jq -r '.client.version // "unknown"')
PATH="$HERDR_ORIGINAL_PATH" \
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" \
  || fail "guarded Herdr lab teardown or default-session tripwire verification failed"
LAB_READY=0
pass "real Herdr lab validation completed on Herdr $HERDR_VERSION with the default-session tripwire intact"

cleanup_all
trap - EXIT
