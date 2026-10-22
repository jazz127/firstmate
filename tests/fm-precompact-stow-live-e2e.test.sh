#!/usr/bin/env bash
# Opt-in native manual compaction guard for every installed PreCompact adapter.
# Uses disposable homes and real installed harnesses/accounts, including the
# production headless stow invocation. No mock writer or resumed active session.
# Run: FM_PRECOMPACT_STOW_LIVE_E2E=1 bash tests/fm-precompact-stow-live-e2e.test.sh
# The ordinary suite skips this token-spending guard. Absent adapters are named;
# a run that exercises no installed harness refuses to pass.
# FM_PRECOMPACT_STOW_EVIDENCE_DIR optionally preserves disposable-home outputs.
# FM_PRECOMPACT_STOW_NATIVE_HARNESSES may select a diagnostic subset (comma-separated);
# omitted means all installed adapters. Subset output is not an all-adapter verdict.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_PRECOMPACT_STOW_LIVE_E2E tmux jq
unset NO_MISTAKES_GATE CLAUDECODE CLAUDE_PID CLAUDE_CODE_SESSION_ID
LAB=$(fm_test_tmproot fm-precompact-native)
SOCKET="fm-precompact-$$"
CHECKED=0
printf '# native guard lab=%s socket=%s\n' "$LAB" "$SOCKET"
tmux -L "$SOCKET" new-session -d -s keeper 'sleep 900'
tmux -L "$SOCKET" set-option -g remain-on-exit on
cleanup() {
  if [ -n "${FM_PRECOMPACT_STOW_EVIDENCE_DIR:-}" ]; then
    mkdir -p "$FM_PRECOMPACT_STOW_EVIDENCE_DIR"
    for adapter in claude pi; do
      [ -d "$LAB/$adapter" ] || continue
      mkdir -p "$FM_PRECOMPACT_STOW_EVIDENCE_DIR/$adapter"
      cp -R "$LAB/$adapter/state" "$LAB/$adapter/data" "$FM_PRECOMPACT_STOW_EVIDENCE_DIR/$adapter/"
      capture "$adapter" > "$FM_PRECOMPACT_STOW_EVIDENCE_DIR/$adapter/pane.txt"
      cp "$LAB/$adapter/native-errors.log" "$FM_PRECOMPACT_STOW_EVIDENCE_DIR/$adapter/" 2>/dev/null || true
    done
  fi
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
}
trap 'cleanup; fm_test_cleanup' EXIT
capture() { tmux -L "$SOCKET" capture-pane -p -t "$1" -S -250 2>/dev/null || true; }
send_line() {
  tmux -L "$SOCKET" send-keys -t "$1" -l "$2"
  sleep 1
  tmux -L "$SOCKET" send-keys -t "$1" Enter
}
for harness in claude pi; do
  case ",${FM_PRECOMPACT_STOW_NATIVE_HARNESSES:-claude,pi}," in
    *",$harness,"*) ;;
    *) printf '# not selected: %s (diagnostic subset)\n' "$harness"; continue ;;
  esac
  executable=$(command -v "$harness" 2>/dev/null || true)
  if [ -z "$executable" ]; then printf '# absent: %s\n' "$harness"; continue; fi
  version=$("$executable" --version 2>&1 | head -n 1)
  home="$LAB/$harness"
  fm_git_init_commit "$home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/.agents/skills/stow"
  cp -R "$ROOT/bin" "$home/bin"
  cp "$ROOT/.agents/skills/stow/SKILL.md" "$home/.agents/skills/stow/"
  printf '# Disposable precompact test session\nFollow the test prompt only.\n' > "$home/AGENTS.md"
  printf '7500\n' > "$home/config/startup-memory-budget"
  printf '<!-- memory tiers: see the stow skill -->\n' > "$home/data/captain.md"
  # Capture the actual hook payload and claim only this disposable home.
  cat > "$home/bin/live-start.sh" <<'START'
#!/usr/bin/env bash
payload=$(cat)
root=${FM_HOME:?}
. "$root/bin/fm-session-lock-lib.sh"
pid=$(fm_session_lock_anchor_pid) || exit 0
printf '%s\n' "$pid" > "$root/state/.lock"
session=$(printf '%s' "$payload" | jq -r '.session_id // empty')
printf '%s\n' "$session" > "$root/state/.lock-session"
printf '%s' "$payload" | jq -r '.transcript_path // empty' > "$root/state/.live-transcript"
START
  chmod +x "$home/bin/live-start.sh"
  args=()
  case "$harness" in
    claude)
      mkdir -p "$home/.claude"
      jq '{hooks:{SessionStart:[{hooks:[{type:"command",command:"bash \"$FM_HOME/bin/live-start.sh\"",timeout:10}]}],PreCompact:.hooks.PreCompact}}' \
        "$ROOT/.claude/settings.json" > "$home/.claude/settings.json"
      args=(--permission-mode dontAsk --effort low)
      ;;
    pi)
      mkdir -p "$home/.pi/extensions/lib"
      cp "$ROOT/.pi/extensions/lib/fm-precompact-stow.ts" "$home/.pi/extensions/lib/"
      cp "$ROOT/.pi/extensions/fm-precompact-stow.ts" "$home/.pi/extensions/"
      cat > "$home/.pi/extensions/live-start.ts" <<'START'
import { writeFileSync } from "node:fs";
export default function (api: any) {
  api.on("session_start", (_: unknown, ctx: any) => {
    const home = process.env.FM_HOME!;
    writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
    writeFileSync(`${home}/state/.live-transcript`, `${ctx.sessionManager.getSessionFile()}\n`);
  });
}
START
      printf '%s\n' '{"compaction":{"keepRecentTokens":200}}' > "$home/.pi/settings.json"
      args=(--tui-mode regular --thinking low)
      ;;
  esac
  # Preserve spaces in executable paths and flags without interpreting them.
  printf -v launch '%q ' "$executable" "${args[@]}"
  tmux -L "$SOCKET" new-session -d -s "$harness" -c "$home" -x 180 -y 45 \
    -e FM_HOME="$home" -e FM_ROOT_OVERRIDE="$home" -e DISABLE_AUTOUPDATER=1 \
    "env -u CLAUDECODE -u NO_MISTAKES_GATE $launch 2>native-errors.log" || fail "$harness $version: launch"
  for _ in $(seq 1 80); do
    [ -s "$home/state/.live-transcript" ] && break
    if capture "$harness" | grep -qiE 'trust (this|the|parent)?[[:space:]]*(folder|project)'; then
      if capture "$harness" | grep -qE '^[[:space:]]*❯[[:space:]]+No, exit'; then
        tmux -L "$SOCKET" send-keys -t "$harness" Down
      fi
      tmux -L "$SOCKET" send-keys -t "$harness" Enter
    fi
    if capture "$harness" | grep -q 'Update available'; then
      tmux -L "$SOCKET" send-keys -t "$harness" Escape
    fi
    sleep 1
  done
  [ -s "$home/state/.live-transcript" ] || { capture "$harness" >&2; cat "$home/native-errors.log" >&2; fail "$harness $version: native startup not reached"; }
  sleep 3
  send_line "$harness" 'For this test session, my established standing preference is UTC timestamps in status reports. Hold that preference in context for the next stow; do not write any file now. Reply with 1200 words about time zones and finish with the word READY.'
  for _ in $(seq 1 120); do
    transcript=$(cat "$home/state/.live-transcript" 2>/dev/null || true)
    if [ -r "$transcript" ] && jq -es 'any(.[]; (.message.role? == "assistant") and (tostring | contains("READY")))' "$transcript" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  jq -es 'any(.[]; (.message.role? == "assistant") and (tostring | contains("READY")))' "$transcript" >/dev/null 2>&1 \
    || { capture "$harness" >&2; fail "$harness $version: initial assistant turn not completed"; }
  send_line "$harness" /compact
  for _ in $(seq 1 100); do
    [ -s "$home/state/.precompact-stow-last.log" ] && grep -q 'agent exit=' "$home/state/.precompact-stow-last.log" && break
    sleep 1
  done
  [ -r "$home/state/.precompact-stow-last.log" ] || { capture "$harness" >&2; fail "$harness $version: native precompaction pass did not start"; }
  grep -q 'agent exit=0' "$home/state/.precompact-stow-last.log" \
    || { cat "$home/state/.precompact-stow-last.log" >&2; fail "$harness $version: production stow did not finish within its bound"; }
  grep -q 'UTC' "$home/data/captain.md" \
    || { cat "$home/state/.precompact-stow-last.log" >&2; fail "$harness $version: established preference was not persisted"; }
  [ ! -e "$home/state/.precompact-stow.lock" ] || fail "$harness $version: writer mutex retained"
  printf 'ok - %s %s: native /compact persisted UTC preference through existing stow within its bound\n' "$harness" "$version"
  CHECKED=$((CHECKED + 1))
  tmux -L "$SOCKET" kill-session -t "$harness" >/dev/null 2>&1 || true
done
[ "$CHECKED" -gt 0 ] || fail "no installed precompaction adapter was exercised"
printf 'ok - native precompaction adapters checked=%s\n' "$CHECKED"
