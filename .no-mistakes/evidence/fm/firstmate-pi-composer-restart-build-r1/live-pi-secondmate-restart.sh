#!/usr/bin/env bash
# Live: bin/fm-secondmate-restart.sh against a real pi 0.87.1 local secondmate in
# an isolated fm-lab Herdr session and a marked disposable lab home. The mate's
# parent-channel replies are appended by this driver (the mate's model is
# deliberately uncredentialed so no turn runs); everything else is real.
set -u
ROOT=$1; cd "$ROOT"
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pirst.XXXXXX")
SESSION=$("$LAB_HELPER" name pirestart)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rm -rf "$LAB"; bin/fm-lab-home.sh create "$LAB" >/dev/null
echo "session=$SESSION lab=$LAB"
cleanup() { "$LAB_HELPER" viewer stop "$SESSION" >/dev/null 2>&1; sleep 2; "$LAB_HELPER" teardown "$SESSION" || { sleep 4; "$LAB_HELPER" teardown "$SESSION"; }; echo "teardown rc=$?"; rm -rf "$TMP" "$LAB"; }
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION" >/dev/null || exit 1
"$LAB_HELPER" viewer start "$SESSION" >/dev/null || echo "viewer start failed"
ORIGINAL_PATH=$PATH; FAKEBIN=$TMP/bin; mkdir -p "$FAKEBIN"
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
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
# Secondmate home as a git worktree.
REPO=$TMP/repo; SMH=$TMP/sm1-home; mkdir -p "$REPO"; git -C "$REPO" init -q; git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" worktree add -q -b sm-sm1 "$SMH"; mkdir -p "$SMH/state" "$SMH/data"; echo sm1 > "$SMH/.fm-secondmate-home"; echo '# agents' > "$SMH/AGENTS.md"
mkdir -p "$LAB/data/sm1"; echo '# charter: lab secondmate' > "$LAB/data/sm1/brief.md"; echo pi > "$LAB/config/secondmate-harness"
PIDIR=$TMP/pi; mkdir -p "$PIDIR"; CAP=$TMP/capture.jsonl; : > "$CAP"
cat > "$TMP/ext.ts" <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync } from "node:fs";
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("input", (event) => { appendFileSync(process.env.FM_PI_CAPTURE_PATH!, JSON.stringify({ prompt: event.text }) + "\n"); return { action: "handled" }; });
  pi.on("before_agent_start", (_e, ctx) => { ctx.abort(); });
}
EOF
OUT=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$SMH" --label sm1 --no-focus)
WS=$(printf '%s' "$OUT" | jq -r '.result.workspace.workspace_id'); PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id')
TAB=$(printf '%s' "$OUT" | jq -r '.result.tab.tab_id // .result.root_pane.tab_id // empty')
TARGET="$SESSION:$PANE"
{ echo "window=$TARGET"; echo endpoint_task_id=sm1; echo "worktree=$SMH"; echo "project=$SMH"; echo harness=pi; echo kind=secondmate
  echo mode=secondmate; echo yolo=off; echo model=default; echo effort=default; echo "home=$SMH"; echo backend=herdr
  echo "herdr_session=$SESSION"; echo "herdr_workspace_id=$WS"; [ -n "$TAB" ] && echo "herdr_tab_id=$TAB"; echo "herdr_pane_id=$PANE"; } > "$LAB/state/sm1.meta"
start_pi() {
  "$LAB_HELPER" run "$SESSION" pane run "$PANE" "$(printf 'export PI_CODING_AGENT_DIR=%q FM_PI_CAPTURE_PATH=%q; pi -e %q --no-session --no-context-files' "$PIDIR" "$CAP" "$TMP/ext.ts")" >/dev/null
  wait_idle
}
ident() { "$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null | jq -r '.result.agent | "\(.agent) \(.agent_status)"' 2>/dev/null || echo none; }
wait_idle() { local s=0 st; for _ in $(seq 1 240); do st=$(ident); case "$st" in "pi idle"|"pi done") s=$((s+1)); [ $s -ge 6 ] && return 0;; *) s=0;; esac; sleep 0.25; done; return 1; }
pipid() { "$LAB_HELPER" run "$SESSION" pane process-info "$PANE" 2>/dev/null | jq -r '[.result.process_info.foreground_processes[]? | select((.argv|join(" "))|test("pi")) | .pid] | first // "none"'; }
. bin/backends/herdr.sh
latest_rec() { ls -t "$LAB/state/pending-replies/"* 2>/dev/null | while read -r r; do grep -q '^phase=awaiting_report' "$r" && { echo "$r"; break; }; done; }
reply() { # <delay> <verb> [corr-override]; appends to the parent status file as the mate would
  ( sleep "$1"; r=$(latest_rec); [ -n "$r" ] || { echo "[driver] no open expectation"; exit; }
    c=${3:-${r##*/}}; ps=$(sed -n 's/^parent_status=//p' "$r")
    printf '%s [corr=%s]: lab persistence reply\n' "$2" "$c" >> "$ps"; echo "[driver] appended '$2 [corr=$c]' to $(basename "$ps")" ) &
}
restart() { env FM_HOME="$LAB" FM_SECONDMATE_PERSIST_POLL=1 FM_SECONDMATE_PERSIST_WAIT="$1" bin/fm-secondmate-restart.sh sm1 2>&1; echo "restart rc=$?"; }
start_pi; echo "initial identity: $(ident) pid=$(pipid) composer=$(fm_backend_herdr_composer_state "$TARGET")"

echo; echo "===== S1: mate replies 'blocked' -> no restart, nudge"
P0=$(pipid); reply 6 blocked; restart 30; wait
echo "after: identity=$(ident) pid=$(pipid) (before $P0)"; wait_idle

echo; echo "===== S2: mate replies only 'working' (progress) -> no restart at timeout"
P0=$(pipid); reply 6 working; restart 14; wait
r=$(ls -t "$LAB/state/pending-replies/"* | while read -r f; do grep -q 'working \[' "$(sed -n 's/^parent_status=//p' "$f")" 2>/dev/null && grep -q "$(basename "$f")" "$(sed -n 's/^parent_status=//p' "$f")" && { echo "$f"; break; }; done)
echo "persist expectation phase: $(sed -n 's/^phase=//p' "$r" 2>/dev/null)"
echo "after: identity=$(ident) pid=$(pipid) (before $P0)"; wait_idle

echo; echo "===== S3: wrong-corr 'done' first, then correlated 'done' -> restart only after the correlated done"
P0=$(pipid); reply 5 done 0123456789abcdef; reply 14 done; T0=$(date +%s); restart 60; T1=$(date +%s); wait
echo "restart pass took $((T1-T0))s (correlated done appended at ~14s)"
sleep 3; echo "after: identity=$(ident) pid=$(pipid) (before $P0) composer=$(fm_backend_herdr_composer_state "$TARGET")"
echo "---- pane after S3"; fm_backend_herdr_capture "$TARGET" 60 | grep -v '^[[:space:]]*$' | tail -8 | sed 's/^/| /'
echo "---- inputs pi received (capture ext, first incarnation)"; cut -c1-160 "$CAP"
