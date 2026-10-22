#!/usr/bin/env bash
# Synthetic behavior tests through the production hook executable and native
# extension API: scope/ownership, transcript capture, bounds, retry, and silence.
set -u
if [ "${FM_PRECOMPACT_TEST_HARNESS:-0}" != 1 ]; then
  fixture=$(mktemp -d "${TMPDIR:-/tmp}/fm-precompact-harness.XXXXXX") || exit 1
  ln -s /bin/bash "$fixture/pi"
  FM_PRECOMPACT_TEST_HARNESS=1 "$fixture/pi" -c \
    'export FM_TEST_OWNER_PID=$$; "$@"; rc=$?; :; exit "$rc"' _ bash "$0" "$@"
  rc=$?
  rm -rf "$fixture"
  exit "$rc"
fi
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset NO_MISTAKES_GATE CLAUDE_PID CLAUDE_CODE_SESSION_ID GROK_AGENT GROK_HOOK_EVENT
TMP_ROOT=$(fm_test_tmproot fm-precompact-stow)
HOOK="$ROOT/bin/fm-precompact-stow.sh"
export FM_GATE_REFUSE_BYPASS=0
export FM_PRECOMPACT_STOW_TIMEOUT=10
export FM_TEST_AGENT_TRACE="$TMP_ROOT/agent.trace"
export FM_TEST_AGENT_BIN="$TMP_ROOT/tools"
mkdir -p "$FM_TEST_AGENT_BIN"
cat > "$FM_TEST_AGENT_BIN/claude" <<'MOCK'
#!/usr/bin/env bash
printf 'call %s\n' "$0" >> "$FM_TEST_AGENT_TRACE"
printf '%s\n' "$@" >> "$FM_TEST_AGENT_TRACE"
[ "${NO_MISTAKES_GATE:-}" = 1 ] || exit 9
[ "${FM_PRECOMPACT_STOW_ACTIVE:-}" = 1 ] || exit 9
prompt=${!#}
snapshot=${prompt#*session captured in }
snapshot=${snapshot%%. The active home*}
cat "$snapshot" >> "$FM_TEST_AGENT_TRACE"
printf '%s\n' '{"decision":"block","continue":false}'
if [ "${FM_TEST_AGENT_SLOW:-0}" = 1 ]; then
  sleep 30 &
  printf '%s\n' "$!" > "$FM_TEST_AGENT_TRACE.child"
  wait
fi
exit "${FM_TEST_AGENT_EXIT:-0}"
MOCK
chmod +x "$FM_TEST_AGENT_BIN/claude"
cp "$FM_TEST_AGENT_BIN/claude" "$FM_TEST_AGENT_BIN/pi"
export PATH="$FM_TEST_AGENT_BIN:$PATH"
make_primary() {
  home="$TMP_ROOT/$1"
  fm_git_init_commit "$home"
  mkdir -p "$home/bin" "$home/state" "$home/.agents/skills/stow"
  : > "$home/AGENTS.md"
  cp "$ROOT/.agents/skills/stow/SKILL.md" "$home/.agents/skills/stow/SKILL.md"
  printf '%s\n' "$FM_TEST_OWNER_PID" > "$home/state/.lock"
  printf '%s\n' '{"type":"user","message":{"content":"An established pending preference"}}' > "$home/transcript.jsonl"
  jq -n --arg file "$home/transcript.jsonl" '{hook_event_name:"PreCompact",session_id:"test-session",transcript_path:$file,trigger:"manual"}' > "$home/payload.json"
  export FM_HOME="$home" FM_ROOT_OVERRIDE="$home"
  unset FM_STATE_OVERRIDE FM_PRECOMPACT_STOW_ACTIVE FM_TEST_AGENT_SLOW FM_TEST_AGENT_EXIT
  : > "$FM_TEST_AGENT_TRACE"
  rm -f "$FM_TEST_AGENT_TRACE.child"
}
run_hook() {
  local out status=0
  out=$("$HOOK" --harness "${1:-claude}" < "$home/payload.json") || status=$?
  expect_code 0 "$status" "hook always succeeds"
  [ -z "$out" ] || fail "agent output reached hook stdout: $out"
}
no_agent() { [ ! -s "$FM_TEST_AGENT_TRACE" ] || fail "$1 launched an agent"; }
cleaned() {
  [ ! -e "$home/state/.precompact-stow.lock" ] || fail "pass left its mutex"
  [ -z "$(find "$home/state" -name '.precompact-stow-transcript.*' -print)" ] || fail "pass left a snapshot"
}
make_primary normal
run_hook
grep -q 'An established pending preference' "$FM_TEST_AGENT_TRACE" || fail "missing precompact transcript"
grep -q 'agent exit=0' "$home/state/.precompact-stow-last.log" || fail "no attempt outcome"
cleaned
pass "PreCompact snapshots the session, dispatches existing stow, and suppresses blocking output"
for harness in claude pi; do
  make_primary "adapter-$harness"
  jq '.trigger="auto" | .provider="synthetic" | .model="model" | .branch_entries=[{type:"message",message:{content:"active branch"}}]' "$home/payload.json" > "$home/changed.json"
  mv "$home/changed.json" "$home/payload.json"
  run_hook "$harness"
  grep -q "call .*tools/$harness" "$FM_TEST_AGENT_TRACE" || fail "wrong harness"
  if [ "$harness" = pi ]; then
    grep -q 'active branch' "$FM_TEST_AGENT_TRACE" || fail "missing active branch"
    ! grep -q 'An established pending preference' "$FM_TEST_AGENT_TRACE" || fail "read off-branch history"
  fi
  cleaned
done
pass "manual/auto events retain their harness; Pi uses the native active branch"
for mode in gate foreign-owner missing-lock recursion foreign-host invalid-trigger missing-transcript subagent missing-skill; do
  make_primary "$mode"
  case "$mode" in
    gate) export NO_MISTAKES_GATE=1 ;;
    foreign-owner) printf '%s\n' 1 > "$home/state/.lock" ;;
    missing-lock) rm "$home/state/.lock" ;;
    recursion) export FM_PRECOMPACT_STOW_ACTIVE=1 ;;
    foreign-host) jq '.cursor_version="synthetic"' "$home/payload.json" > "$home/changed.json"; mv "$home/changed.json" "$home/payload.json" ;;
    invalid-trigger) jq '.trigger="unknown"' "$home/payload.json" > "$home/changed.json"; mv "$home/changed.json" "$home/payload.json" ;;
    missing-transcript) rm "$home/transcript.jsonl" ;;
    subagent) jq '.agent_id="subagent"' "$home/payload.json" > "$home/changed.json"; mv "$home/changed.json" "$home/payload.json" ;;
    missing-skill) rm "$home/.agents/skills/stow/SKILL.md" ;;
  esac
  run_hook
  no_agent "$mode"
  unset NO_MISTAKES_GATE
done
pass "ineligible, foreign, recursive, malformed, and missing-input hooks stand down"
make_primary linked
# Build a linked layout only inside this synthetic fixture repository.
mv "$home/.git" "$home/common.git"
mkdir -p "$home/task.git"
cp "$home/common.git/HEAD" "$home/task.git/HEAD"
printf '../common.git\n' > "$home/task.git/commondir"
printf 'gitdir: %s\n' "$home/task.git" > "$home/.git"
run_hook
no_agent "linked worker"
printf 'secondmate-test\n' > "$home/.fm-secondmate-home"
run_hook
grep -q '^call ' "$FM_TEST_AGENT_TRACE" || fail "marked secondmate stood down"
pass "worker-shaped checkout is excluded; a marked lock-owning secondmate is included"
make_primary failure
export FM_TEST_AGENT_EXIT=2
run_hook
grep -q 'agent exit=2' "$home/state/.precompact-stow-last.log" || fail "failure hidden"
unset FM_TEST_AGENT_EXIT
run_hook
[ "$(grep -c '^call ' "$FM_TEST_AGENT_TRACE")" -eq 2 ] || fail "failure prevented retry"
cleaned
pass "agent failures never block compaction and retry on the next event"
make_primary deadline
export FM_TEST_AGENT_SLOW=1 FM_PRECOMPACT_STOW_TIMEOUT=3
run_hook 2> "$home/timeout.stderr"
grep -q 'exit 124' "$home/timeout.stderr" || fail "timeout not diagnosed"
child=$(cat "$FM_TEST_AGENT_TRACE.child")
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$child" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$child" 2>/dev/null; then
  [ "$(ps -o stat= -p "$child" | tr -d ' ')" = Z ] || fail "timeout leaked descendant $child"
fi
unset FM_TEST_AGENT_SLOW
export FM_PRECOMPACT_STOW_TIMEOUT=10
run_hook
[ "$(grep -c '^call ' "$FM_TEST_AGENT_TRACE")" -eq 2 ] || fail "timeout blocked retry"
cleaned
pass "deadline kills the pass process group and permits the next attempt"
make_primary concurrent
export FM_TEST_AGENT_SLOW=1 FM_PRECOMPACT_STOW_TIMEOUT=3
"$HOOK" --harness claude < "$home/payload.json" > "$home/first.out" 2> "$home/first.err" &
first=$!
for _ in $(seq 1 100); do [ -s "$FM_TEST_AGENT_TRACE.child" ] && break; sleep 0.1; done
[ -s "$FM_TEST_AGENT_TRACE.child" ] || fail "first pass never entered agent"
run_hook
[ "$(grep -c '^call ' "$FM_TEST_AGENT_TRACE")" -eq 1 ] || fail "concurrent pass stacked"
wait "$first" || fail "first hook failed"
unset FM_TEST_AGENT_SLOW
pass "concurrent native events do not stack stow writers"
make_primary stdin-bound
export FM_PRECOMPACT_STOW_TIMEOUT=3
mkfifo "$home/held-stdin"
(sleep 10) > "$home/held-stdin" &
writer=$!
status=0
"$HOOK" --harness claude < "$home/held-stdin" > "$home/stdout" 2> "$home/stderr" || status=$?
kill "$writer" 2>/dev/null || true
wait "$writer" 2>/dev/null || true
expect_code 0 "$status" "blocked input cannot block compaction"
grep -q 'exit 124' "$home/stderr" || fail "stdin outside deadline"
no_agent "blocked input"
pass "the whole-pass deadline includes a hook payload that never reaches EOF"
if command -v node >/dev/null 2>&1; then
  make_primary extension
  mkdir -p "$home/.pi/extensions/lib"
  cp "$ROOT/.pi/extensions/lib/fm-precompact-stow.ts" "$home/.pi/extensions/lib/"
  cp "$ROOT/.pi/extensions/fm-precompact-stow.ts" "$home/.pi/extensions/"
  cat > "$home/bin/fm-precompact-stow.sh" <<'RECORDER'
#!/usr/bin/env bash
cat > "$FM_HOME/extension-payload.json"
printf '{"cancel":true}\n'
exit 2
RECORDER
  chmod +x "$home/bin/fm-precompact-stow.sh"
  cat > "$home/extension-test.mjs" <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
{
  const { default: register } = await import("./.pi/extensions/fm-precompact-stow.ts");
  let callback;
  register({on(event, handler) { assert.equal(event, "session_before_compact"); callback = handler; }});
  for (const reason of ["manual", "threshold", "overflow"]) {
    const result = await callback({reason}, {
      sessionManager: {
        getSessionId: () => "native-session",
        getSessionFile: () => `${process.env.FM_HOME}/transcript.jsonl`,
        getBranch: () => [{id:"active-entry"}],
      }, model: {provider:"synthetic",id:"model"},
    });
    assert.equal(result, undefined, "extension must not return a compaction decision");
    const payload = JSON.parse(readFileSync(`${process.env.FM_HOME}/extension-payload.json`));
    assert.equal(payload.trigger, reason === "manual" ? "manual" : "auto");
    assert.equal(payload.session_id, "native-session");
    assert.deepEqual(payload.branch_entries, [{id:"active-entry"}]);
    assert.equal(payload.provider, "synthetic");
  }
}
JS
  node --experimental-strip-types "$home/extension-test.mjs" || fail "native extension transport"
  pass "Pi native extension transport preserves the branch and never returns a compaction veto"
else
  printf '# node absent: Pi extension transport case not exercised\n'
fi
