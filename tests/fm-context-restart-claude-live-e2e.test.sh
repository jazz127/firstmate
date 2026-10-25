#!/usr/bin/env bash
# Opt-in credentialed proof that the installed Claude Stop payload names a real
# transcript whose latest assistant usage matches Firstmate's context accounting.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CONTEXT_RESTART_CLAUDE_LIVE_E2E claude jq

LAB="$ROOT/.context-restart-claude-live.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/home"
RESULT="$LAB/result.json"
CLAUDE_VERSION=$(claude --version)
TRANSCRIPT=

cleanup() {
  rm -rf "$LAB"
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "tee \"$FM_HOME/state/live-context-stop-payload.json\" >> \"$FM_HOME/state/live-context-stop-payloads.jsonl\"; printf \"\\n\" >> \"$FM_HOME/state/live-context-stop-payloads.jsonl\""
          }
        ]
      }
    ]
  }
}
JSON
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf '999999999\n' > "$HOME_DIR/config/context-restart-budget"
printf 'tmux\n' > "$HOME_DIR/config/backend"
printf '7500\n' > "$HOME_DIR/config/startup-memory-budget"

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p 'Reply with exactly CONTEXT_REFRESH_LIVE_OK.' \
      --dangerously-skip-permissions --effort low --output-format json
) > "$RESULT" 2> "$LAB/claude.err" \
  || fail "Claude context-refresh live session failed: $(tail -20 "$LAB/claude.err")"

PAYLOAD="$HOME_DIR/state/live-context-stop-payload.json"
[ -f "$PAYLOAD" ] || fail "the real Claude Stop hook did not publish its payload"
TRANSCRIPT=$(jq -er '.transcript_path | select(type == "string" and length > 0)' "$PAYLOAD") \
  || fail "the real Stop payload did not carry transcript_path"
SESSION_ID=$(jq -er '.session_id | select(type == "string" and length > 0)' "$PAYLOAD") \
  || fail "the real Stop payload did not carry session_id"
[ -f "$TRANSCRIPT" ] || fail "the real Stop transcript path was not readable"

COMPUTED=$(bash -c '. "$1"; fm_context_restart_transcript_tokens "$2"' \
  _ "$ROOT/bin/fm-context-restart-lib.sh" "$TRANSCRIPT") \
  || fail "Firstmate could not account for the real Claude transcript"
EXPECTED=$(jq -r '
  .usage
  | .input_tokens
    + (.cache_creation_input_tokens // 0)
    + (.cache_read_input_tokens // 0)
    + (.output_tokens // 0)
' "$RESULT") || fail "could not account for Claude's result usage"
[ "$COMPUTED" = "$EXPECTED" ] \
  || fail "transcript context $COMPUTED did not match Claude result usage $EXPECTED"
case "$COMPUTED" in ''|0|*[!0-9]*) fail "real Claude context total was not positive: $COMPUTED" ;; esac
[ ! -e "$HOME_DIR/state/.context-restart-crossing" ] \
  || fail "the high-budget live session unexpectedly published a crossing"
[ "$(jq -r '.result' "$RESULT")" = CONTEXT_REFRESH_LIVE_OK ] \
  || fail "the live fixture did not complete its one ordinary under-budget turn"

if [ -n "${FM_CONTEXT_RESTART_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$FM_CONTEXT_RESTART_EVIDENCE_DIR"
  cp "$PAYLOAD" "$FM_CONTEXT_RESTART_EVIDENCE_DIR/stop-payload.json"
  cp "$TRANSCRIPT" "$FM_CONTEXT_RESTART_EVIDENCE_DIR/transcript.jsonl"
  cp "$RESULT" "$FM_CONTEXT_RESTART_EVIDENCE_DIR/claude-result.json"
  printf '%s\n' "$CLAUDE_VERSION" > "$FM_CONTEXT_RESTART_EVIDENCE_DIR/claude-version.txt"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$FM_CONTEXT_RESTART_EVIDENCE_DIR/captured-at.txt"
fi

printf 'ok - Claude %s live Stop payload session=%s exposed transcript usage=%s and stayed inert below budget\n' \
  "$CLAUDE_VERSION" "$SESSION_ID" "$COMPUTED"

# Exercise the actual Stop continuation, full stow pass, handoff command, and
# wrapper replacement. A deliberately tiny budget also proves the fresh
# successor's baseline inhibitor rather than allowing repeated refreshes.
printf '1\n' > "$HOME_DIR/config/context-restart-budget"
rm -f "$HOME_DIR/state/live-context-stop-payloads.jsonl"
(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    "$PROJECT/bin/fm-primary.sh" \
      --firstmate-initial-prompt 'Reply with exactly CONTEXT_REFRESH_HANDOFF_PROBE. If a context refresh Stop directive arrives, follow its complete stow and handoff instructions in this isolated empty test home. There is no new fleet work.' \
      -- --dangerously-skip-permissions --effort low --model sonnet -p --max-turns 30 --output-format json
) > "$LAB/relaunch-result.json" 2> "$LAB/relaunch.err" \
  || fail "Claude wrapper replacement failed: $(tail -30 "$LAB/relaunch.err")"
if [ -n "${FM_CONTEXT_RESTART_EVIDENCE_DIR:-}" ]; then
  cp "$HOME_DIR/state/live-context-stop-payloads.jsonl" "$FM_CONTEXT_RESTART_EVIDENCE_DIR/relaunch-stop-payloads.jsonl"
  cp "$LAB/relaunch-result.json" "$FM_CONTEXT_RESTART_EVIDENCE_DIR/relaunch-result.json"
  cp "$LAB/relaunch.err" "$FM_CONTEXT_RESTART_EVIDENCE_DIR/relaunch-stderr.txt"
fi
REPLACEMENTS=$(grep -c 'starting a fresh Claude session' "$LAB/relaunch.err" || true)
[ "$REPLACEMENTS" = 1 ] || fail "expected exactly one actual Claude replacement, got $REPLACEMENTS: $(tail -30 "$LAB/relaunch.err")"
SESSIONS=$(jq -sr '[.[].session_id] | unique | length' "$HOME_DIR/state/live-context-stop-payloads.jsonl") \
  || fail "replacement Stop payloads were unreadable"
[ "$SESSIONS" = 2 ] || fail "expected two distinct Claude conversations, got $SESSIONS"
PHASE=$(bash -c '. "$1"; fm_context_restart_record_read "$2"; printf "%s\n" "$FM_CONTEXT_RESTART_RECORD_PHASE"' \
  _ "$ROOT/bin/fm-context-restart-lib.sh" "$HOME_DIR/state/.context-restart-crossing")
[ "$PHASE" = inhibited ] || fail "the real fresh successor did not inhibit an over-budget startup baseline"
if [ -n "${FM_CONTEXT_RESTART_EVIDENCE_DIR:-}" ]; then
  cp "$HOME_DIR/state/.context-restart-crossing" "$FM_CONTEXT_RESTART_EVIDENCE_DIR/successor-crossing.txt"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$FM_CONTEXT_RESTART_EVIDENCE_DIR/relaunch-captured-at.txt"
fi
printf 'ok - Claude %s print-mode Stop continuation stowed and replaced once into two distinct sessions; fresh above-budget baseline inhibited further replacement\n' "$CLAUDE_VERSION"
