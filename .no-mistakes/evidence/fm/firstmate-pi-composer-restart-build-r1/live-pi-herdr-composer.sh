#!/usr/bin/env bash
# Live: real pi 0.87.1 in an isolated fm-lab Herdr session; composer verdicts from
# the herdr adapter, then bin/fm-control.sh exit against a disposable lab home.
set -u
ROOT=$1; MODE=${2:-real}   # real = user's Pi login (cost footer), isolated = empty agent dir
cd "$ROOT"
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-picomp.XXXXXX")
SESSION=$("$LAB_HELPER" name picomp)
echo "session=$SESSION mode=$MODE"
cleanup() { "$LAB_HELPER" viewer stop "$SESSION" >/dev/null 2>&1; sleep 2; "$LAB_HELPER" teardown "$SESSION" || { sleep 3; "$LAB_HELPER" teardown "$SESSION"; }; echo "teardown rc=$?"; rm -rf "$TMP"; }
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION" >/dev/null || exit 1
"$LAB_HELPER" viewer start "$SESSION" >/dev/null || echo "viewer start failed"
ORIGINAL_PATH=$PATH
FAKEBIN=$TMP/bin; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
args=("\$@"); n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo 'wrapper refused foreign session' >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "$SESSION" ] || { echo 'wrapper requires isolated session' >&2; exit 98; }
fi
PATH="$ORIGINAL_PATH" exec "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$PATH" HERDR_SESSION="$SESSION"
PROJ=$TMP/proj; mkdir -p "$PROJ"; git -C "$PROJ" init -q
OUT=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJ" --label pi-lab --no-focus)
WS=$(printf '%s' "$OUT" | jq -r '.result.workspace.workspace_id')
TAB=$(printf '%s' "$OUT" | jq -r '.result.tab.tab_id // .result.root_pane.tab_id // empty')
PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id')
TARGET="$SESSION:$PANE"
if [ "$MODE" = isolated ]; then
  mkdir -p "$TMP/pi"; PI_CMD=$(printf 'env PI_CODING_AGENT_DIR=%q pi --no-session --no-context-files' "$TMP/pi")
else
  PI_CMD="pi --no-session --no-context-files ${PI_MODEL:+--model $PI_MODEL}"
fi
"$LAB_HELPER" run "$SESSION" pane run "$PANE" "$PI_CMD" >/dev/null
st=''; stable=0
for _ in $(seq 1 240); do
  st=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null | jq -r '.result.agent | "\(.agent) \(.agent_status)"' 2>/dev/null)
  case "$st" in "pi idle"|"pi done") stable=$((stable+1)); [ $stable -ge 6 ] && break ;; *) stable=0 ;; esac
  sleep 0.25
done
echo "identity: $st"
sleep 1
. bin/backends/herdr.sh
show() { # label
  echo "---- $1: plain capture (bottom 12 rows)"
  fm_backend_herdr_capture "$TARGET" 60 | grep -v '^[[:space:]]*$' | tail -12 | sed 's/^/| /'
  echo "---- $1: styled bottom rows (cat -v)"
  fm_backend_herdr_capture_ansi "$TARGET" 60 | grep -v '^[[:space:]]*$' | tail -6 | cat -v | LC_ALL=C cut -c1-240 | sed 's/^/| /'
  printf 'composer_state=%s\n' "$(fm_backend_herdr_composer_state "$TARGET")"
  printf 'composer_content=[%s]\n' "$(fm_backend_herdr_composer_content "$TARGET")"
  printf 'composer_state(again, after content)=%s\n' "$(fm_backend_herdr_composer_state "$TARGET")"
}
show idle
# Draft: type literal text without Enter.
fm_backend_herdr_send_literal "$TARGET" 'lab draft keep me'; sleep 1
show draft
# Lab home + Pi task pointing at the pane, then exit must refuse with the draft present.
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rm -rf "$LAB"; bin/fm-lab-home.sh create "$LAB" >/dev/null
WT=$TMP/wt; git -C "$PROJ" commit -q --allow-empty -m init; git -C "$PROJ" worktree add -q -b task-t1 "$WT"
mkdir -p "$LAB/data/t1"; echo '# brief' > "$LAB/data/t1/brief.md"
{ echo "window=$TARGET"; echo endpoint_task_id=t1; echo "worktree=$WT"; echo "project=$PROJ"; echo harness=pi; echo kind=ship
  echo mode=no-mistakes; echo yolo=off; echo model=default; echo effort=default; echo backend=herdr
  echo "herdr_session=$SESSION"; echo "herdr_workspace_id=$WS"; [ -n "$TAB" ] && echo "herdr_tab_id=$TAB"; echo "herdr_pane_id=$PANE"; } > "$LAB/state/t1.meta"
ctl() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" bin/fm-control.sh t1 exit 2>&1; }
echo "==== fm-control t1 exit WITH draft"; o=$(ctl); echo "rc=$? $o"
show after-refused-exit
fm_backend_herdr_send_key "$TARGET" C-u; sleep 1
show cleared
echo "==== fm-control t1 exit on EMPTY composer"; o=$(ctl); echo "rc=$? $o"
sleep 2
echo "identity after exit: $("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>&1 | jq -c '.result.agent // .error' 2>/dev/null)"
echo "---- pane after exit"; fm_backend_herdr_capture "$TARGET" 60 | grep -v '^[[:space:]]*$' | tail -6 | sed 's/^/| /'
rm -rf "$LAB"
