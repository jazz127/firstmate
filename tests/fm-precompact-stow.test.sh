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
REAL_PI=$(command -v pi 2>/dev/null || true)
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
  if [ "${1:-claude}" = pi ]; then
    out=$(python3 - "$HOOK" "$home/payload.json" "$FM_TEST_AGENT_TRACE" <<'PYPI'
import json, pathlib, subprocess, sys
proc = subprocess.Popen([sys.argv[1], "--harness", "pi"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
proc.stdin.write(pathlib.Path(sys.argv[2]).read_text().replace("\n", "") + "\n")
proc.stdin.flush()
request = json.loads(proc.stdout.readline())
snapshot = request["prompt"].split("session captured in ", 1)[1].split(". The active home", 1)[0]
pathlib.Path(sys.argv[3]).write_text("call pi-sdk\n" + pathlib.Path(snapshot).read_text())
proc.stdin.write(json.dumps({"status": 0, "output": "sdk receipt"}) + "\n")
proc.stdin.close()
assert not proc.stdout.read()
assert proc.wait() == 0
PYPI
) || status=$?
  else
    out=$("$HOOK" --harness "${1:-claude}" < "$home/payload.json") || status=$?
  fi
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
  jq '.trigger="auto" | .branch_entries=[{type:"message",message:{content:"active branch"}}]' "$home/payload.json" > "$home/changed.json"
  mv "$home/changed.json" "$home/payload.json"
  run_hook "$harness"
  if [ "$harness" = pi ]; then expected="call pi-sdk"; else expected="call .*tools/claude"; fi
  grep -q "$expected" "$FM_TEST_AGENT_TRACE" || fail "wrong harness"
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
make_primary stdin-preservation
. "$ROOT/bin/fm-timeout-lib.sh"
cat > "$home/timeout" <<'TIMEOUT'
#!/usr/bin/env bash
shift 3
exec "$@"
TIMEOUT
chmod +x "$home/timeout"
for runner in external bash default; do
  case "$runner" in
    external) actual=$(printf 'payload from caller' | fm_run_external_timeout "$home/timeout" 5 cat) ;;
    bash) actual=$(printf 'payload from caller' | fm_run_bash_timeout 5 cat) ;;
    default) actual=$(printf 'payload from caller' | fm_run_timed 5 cat) ;;
  esac
  [ "$actual" = 'payload from caller' ] || fail "$runner discarded caller stdin"
done
pass "every timed runner preserves the caller's stdin (external boundary regression)"

make_primary context-threshold
NUDGE="$ROOT/bin/fm-context-stow-nudge.sh"
mkdir -p "$home/config"
observe() { jq -nc --argjson percent "$1" '{session_id:"context-session",percent:$percent}' | "$NUDGE" --pi; }
[ -z "$(observe 69)" ] || fail "nudged below default threshold"
nudge=$(observe 70)
[ "$(printf '%s' "$nudge" | "$ROOT/bin/fm-operational-input.sh" kind)" = context-stow ] || fail "missing operational threshold nudge"
case "$nudge" in *'Run /stow now'*) ;; *) fail "nudge did not request stow" ;; esac
[ -z "$(observe 70)$(observe 90)" ] || fail "repeated nudge above threshold"
[ -z "$(observe 69)" ] || fail "nudged on downward crossing"
[ -n "$(observe 105)" ] || fail "overflow jump missed threshold crossing"
[ -z "$(observe 106)" ] || fail "overflow repeated above threshold"
[ -z "$(observe 69)" ] || fail "overflow did not rearm below threshold"
[ -n "$(observe 100.5)" ] || fail "fractional overflow missed threshold crossing"
[ -z "$(observe -1)$(observe null)$(observe '"105"')" ] || fail "invalid usage emitted nudge"
[ -z "$(observe 110)" ] || fail "invalid usage rearmed threshold"
[ -z "$(observe 69)" ] || fail "nudged on downward crossing"
[ -n "$(observe 71)" ] || fail "did not rearm after downward crossing"
printf '85\n' > "$home/config/context-stow-threshold"
[ -z "$(observe 84)" ] || fail "ignored configured threshold"
[ -n "$(observe 85)" ] || fail "configured threshold crossing missed"
for setting in 0 invalid 101; do
  printf '%s\n' "$setting" > "$home/config/context-stow-threshold"
  [ -z "$(observe 0)$(observe 100)" ] || fail "disabled/invalid threshold emitted nudge"
done
rm "$home/config/context-stow-threshold"
[ -z "$(observe null)" ] || fail "unknown usage emitted nudge"
pass "threshold default, configuration, disablement, and once-per-crossing behavior"

jq -e 'has("statusLine") | not' "$ROOT/.claude/settings.json" >/dev/null || fail "project settings override the operator status line"
prompt_command=$(jq -r '.hooks.UserPromptSubmit[-1].hooks[0].command' "$ROOT/.claude/settings.json")
tool_command=$(jq -r '.hooks.PreToolUse[-1].hooks[0].command' "$ROOT/.claude/settings.json")
export CLAUDE_PROJECT_DIR="$ROOT"
claude_transcript="$home/context-transcript.jsonl"
: > "$claude_transcript"
assistant_usage() {
  jq -nc --arg session "${5:-claude-session}" --argjson input "$1" --argjson creation "${2:-0}" --argjson cache "${3:-0}" --argjson output "${4:-0}" \
    '{type:"assistant",sessionId:$session,isSidechain:false,message:{role:"assistant",usage:{input_tokens:$input,cache_creation_input_tokens:$creation,cache_read_input_tokens:$cache,output_tokens:$output}}}' >> "$claude_transcript"
}
claude_delivery() {
  jq -nc --arg event "$1" --arg session "${2:-claude-session}" --arg file "$claude_transcript" \
    '{session_id:$session,hook_event_name:$event,transcript_path:$file}' | bash -c "$3"
}
[ -z "$(claude_delivery UserPromptSubmit claude-session "$prompt_command")" ] || fail "empty transcript emitted nudge"
assistant_usage 138000
[ -z "$(claude_delivery UserPromptSubmit claude-session "$prompt_command")" ] || fail "nudged below default threshold"
assistant_usage 190000 0 0 0 other-session
printf '%s\n' '{"type":"assistant","sessionId":"claude-session","isSidechain":true,"message":{"usage":{"input_tokens":190000}}}' >> "$claude_transcript"
[ -z "$(claude_delivery PreToolUse claude-session "$tool_command")" ] || fail "sidechain or foreign-session usage emitted nudge"
assistant_usage 2000 3000 134000 1000
[ -z "$(claude_delivery UserPromptSubmit missing-session "$prompt_command")" ] || fail "nudge leaked to another session"
printf '{"type":' >> "$claude_transcript"
out=$(claude_delivery PreToolUse claude-session "$tool_command")
printf '\n' >> "$claude_transcript"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" = PreToolUse ] || fail "wrong hook response"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | "$ROOT/bin/fm-operational-input.sh" kind)" = context-stow ] || fail "Claude ignored the 140000-token response including cached input and output"
assistant_usage 160000
[ -z "$(claude_delivery UserPromptSubmit claude-session "$prompt_command")" ] || fail "Claude repeated above threshold"
assistant_usage null
[ -z "$(claude_delivery UserPromptSubmit claude-session "$prompt_command")" ] || fail "unknown assistant usage emitted nudge"
assistant_usage 160000
[ -z "$(claude_delivery PreToolUse claude-session "$tool_command")" ] || fail "unknown usage rearmed threshold"
printf '%s\n' '{"type":"system","subtype":"compact_boundary","sessionId":"claude-session"}' >> "$claude_transcript"
[ -z "$(claude_delivery UserPromptSubmit claude-session "$prompt_command")" ] || fail "reused pre-compaction usage"
assistant_usage 40000
[ -z "$(claude_delivery PreToolUse claude-session "$tool_command")" ] || fail "Claude nudged after downward crossing"
assistant_usage 140000
[ -n "$(claude_delivery UserPromptSubmit claude-session "$prompt_command")" ] || fail "Claude did not rearm"
printf '1000000\n' > "$home/config/context-stow-window-tokens"
assistant_usage 699999
[ -z "$(claude_delivery UserPromptSubmit claude-session "$prompt_command")" ] || fail "ignored larger context capacity"
assistant_usage 700000
[ -n "$(claude_delivery PreToolUse claude-session "$tool_command")" ] || fail "missed configured 1M window crossing"
for window in 0 invalid; do
  printf '%s\n' "$window" > "$home/config/context-stow-window-tokens"
  assistant_usage 1000000
  [ -z "$(claude_delivery UserPromptSubmit claude-session "$prompt_command")" ] || fail "invalid context capacity emitted nudge"
done
rm "$home/config/context-stow-window-tokens"
assistant_usage -1
[ -z "$(claude_delivery PreToolUse claude-session "$tool_command")" ] || fail "negative usage emitted nudge"
rm "$claude_transcript"
[ -z "$(claude_delivery UserPromptSubmit claude-session "$prompt_command")" ] || fail "missing transcript emitted nudge"
pass "tracked Claude hooks sample transcript usage once per crossing without a status line"
for mode in gate foreign-owner recursion subagent foreign-host; do
  make_primary "nudge-$mode"
  input='{"session_id":"nudge-session","percent":90}'
  case "$mode" in
    gate) export NO_MISTAKES_GATE=1 ;;
    foreign-owner) printf '1\n' > "$home/state/.lock" ;;
    recursion) export FM_PRECOMPACT_STOW_ACTIVE=1 ;;
    subagent) input=$(printf '%s' "$input" | jq '.agent_id="subagent"') ;;
    foreign-host) input=$(printf '%s' "$input" | jq '.cursor_version="synthetic"') ;;
  esac
  [ -z "$(printf '%s' "$input" | "$NUDGE" --pi)" ] || fail "$mode received threshold nudge"
  unset NO_MISTAKES_GATE FM_PRECOMPACT_STOW_ACTIVE
done
pass "threshold nudge retains primary ownership and harness exclusions"

if command -v node >/dev/null 2>&1; then
  make_primary extension
  mkdir -p "$home/.pi/extensions/lib"
  cp "$ROOT/.pi/extensions/lib/fm-precompact-stow.ts" "$home/.pi/extensions/lib/"
  cp "$ROOT/.pi/extensions/lib/fm-pi-stow-worker.ts" "$home/.pi/extensions/lib/"
  cp "$ROOT/.pi/extensions/lib/fm-context-stow-nudge.ts" "$home/.pi/extensions/lib/"
  cat > "$home/bin/fm-precompact-stow.sh" <<'RECORDER'
#!/usr/bin/env bash
IFS= read -r payload
printf '%s' "$payload" > "$FM_HOME/extension-payload.json"
printf '{"role":"bounded worker","prompt":"stow snapshot","home":"%s"}\n' "$FM_HOME"
IFS= read -r receipt
printf '%s' "$receipt" > "$FM_HOME/extension-receipt.json"
exit 2
RECORDER
  chmod +x "$home/bin/fm-precompact-stow.sh"
  cp "$NUDGE" "$home/bin/"
  # The production script resolves its shared libraries from its own directory.
  for file in fm-gate-refuse-lib.sh fm-primary-scope-lib.sh fm-session-lock-lib.sh fm-hook-host-lib.sh fm-operational-input.sh fm-wake-lib.sh fm-cursor-lib.sh fm-path-lib.sh; do
    cp "$ROOT/bin/$file" "$home/bin/"
  done
  cat > "$home/extension-test.mjs" <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { registerPrecompactStow } from "./.pi/extensions/lib/fm-precompact-stow.ts";
import { createPiStowWorker } from "./.pi/extensions/lib/fm-pi-stow-worker.ts";
import { registerContextStowNudge } from "./.pi/extensions/lib/fm-context-stow-nudge.ts";
const home = process.env.FM_HOME;
let callback;
const ctx = {
  sessionManager: {
    getSessionId: () => "native-session",
    getSessionFile: () => `${home}/transcript.jsonl`,
    getBranch: () => [{id:"active-entry"}],
  }, model: {provider:"extension-only",id:"model"},
};
let workerCalls = 0;
registerPrecompactStow({on(event, handler) { assert.equal(event, "session_before_compact"); callback = handler; }}, async (request, context) => {
  assert.equal(request.prompt, "stow snapshot");
  assert.equal(context, ctx);
  workerCalls++;
  return "worker receipt";
});
for (const reason of ["manual", "threshold", "overflow"]) {
  assert.equal(await callback({reason}, ctx), undefined, "never veto compaction");
  const payload = JSON.parse(readFileSync(`${home}/extension-payload.json`));
  assert.equal(payload.trigger, reason === "manual" ? "manual" : "auto");
  assert.deepEqual(payload.branch_entries, [{id:"active-entry"}]);
  assert.deepEqual(JSON.parse(readFileSync(`${home}/extension-receipt.json`)), {status:0,output:"worker receipt"});
}
assert.equal(workerCalls, 3);

let streamed = 0, disposed = 0, registered, options, loaderOptions;
const provider = {streamSimple() { streamed++; return "custom provider receipt"; }};
const model = ctx.model;
ctx.modelRegistry = {getRegisteredProviderConfig(id) { assert.equal(id, "extension-only"); return provider; }};
const runtime = {
  registerProvider(id, config) { assert.equal(id, "extension-only"); registered = config; },
  async refresh(options) { assert.deepEqual(options, {providers:["extension-only"],allowNetwork:false}); },
  getModel(providerId, modelId) { assert.equal(providerId, "extension-only"); assert.equal(modelId, "model"); return model; },
};
const sdk = {
  getAgentDir() { return `${home}/pi-config`; },
  ModelRuntime: {async create() { return runtime; }},
  DefaultResourceLoader: class { constructor(o) { loaderOptions = o; } async reload() {} },
  SessionManager: {inMemory(cwd) { assert.equal(cwd, home); return {kind:"ephemeral"}; }},
  SettingsManager: {inMemory(settings) { assert.equal(settings.compaction.enabled, false); return settings; }},
  createBashToolDefinition(cwd, options) {
    const environment = options.spawnHook({env:{}}).env;
    assert.equal(environment.FM_PRECOMPACT_STOW_ACTIVE, "1");
    assert.equal(environment.NO_MISTAKES_GATE, "1");
    return {};
  },
  async createAgentSession(o) {
    options = o;
    return {session:{
      messages: [],
      async prompt(text) { assert.equal(text, "persist snapshot"); this.messages.push({content:registered.streamSimple()}); },
      dispose() { disposed++; },
    }};
  },
};
const output = await createPiStowWorker(sdk)({home,role:"bounded stow",prompt:"persist snapshot"}, ctx, new AbortController().signal);
assert.deepEqual(JSON.parse(output), [{content:"custom provider receipt"}]);
assert.equal(registered, provider, "provider functions must be retained by reference");
assert.equal(streamed, 1);
assert.equal(disposed, 1);
assert.equal(options.model, model);
assert.equal(options.modelRuntime, runtime);
assert.equal(loaderOptions.noExtensions, true);
assert.equal(loaderOptions.noContextFiles, true);
assert.equal(loaderOptions.agentDir, `${home}/pi-config`);
assert.equal(loaderOptions.settingsManager, options.settingsManager);
assert.equal(process.env.FM_PRECOMPACT_STOW_ACTIVE, undefined, "must not mutate main session environment");
await assert.rejects(createPiStowWorker(sdk)({home}, ctx, AbortSignal.abort()));

let usage = 69;
const events = new Map(), delivered = [];
ctx.getContextUsage = () => ({percent:usage});
registerContextStowNudge({on(event, fn) { events.set(event, fn); }, sendMessage(message, options) { delivered.push({message,options}); }});
assert.equal(await events.get("before_agent_start")({}, ctx), undefined);
usage = 105;
await events.get("turn_end")({}, ctx);
assert.equal(delivered.length, 1);
assert.equal(delivered[0].options.triggerTurn, true);
assert.match(delivered[0].message.content, /FIRSTMATE_OP: v1 context-stow:/);
await events.get("turn_end")({}, ctx);
assert.equal(delivered.length, 1);
usage = 90;
await events.get("session_compact")({}, ctx);
assert.equal(await events.get("before_agent_start")({}, ctx), undefined, "compaction alone is not a downward crossing");
usage = 20;
await events.get("session_compact")({}, ctx);
usage = 71;
assert.ok((await events.get("before_agent_start")({}, ctx)).message.content);
assert.equal(await events.get("before_agent_start")({}, ctx), undefined);
ctx.sessionManager.getSessionId = () => "replacement-session";
assert.ok((await events.get("before_agent_start")({}, ctx)).message.content, "new sessions have independent crossings");
JS
  node --experimental-strip-types "$home/extension-test.mjs" || fail "Pi extension behavior"
  pass "Pi transport, provider function preservation, isolation, and usage events"
else
  printf '# node absent: Pi extension cases not exercised\n'
fi

if [ -n "$REAL_PI" ]; then
  make_primary native-provider
  cp "$ROOT/bin/"*.sh "$home/bin/"
  mkdir -p "$home/.pi/extensions/lib" "$home/pi-config"
  cp "$ROOT/.pi/extensions/lib/fm-precompact-stow.ts" "$ROOT/.pi/extensions/lib/fm-pi-stow-worker.ts" "$home/.pi/extensions/lib/"
  cat > "$home/.pi/extensions/offline-provider.ts" <<'TS'
import * as sdk from "@earendil-works/pi-coding-agent";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import { appendFileSync, writeFileSync, readFileSync } from "node:fs";
import { registerPrecompactStow } from "./lib/fm-precompact-stow.ts";
import { createPiStowWorker } from "./lib/fm-pi-stow-worker.ts";
export default function(pi: sdk.ExtensionAPI) {
  pi.registerProvider("stow-offline", {
    baseUrl: "http://127.0.0.1/unused", apiKey: "offline-only", api: "stow-offline-api" as any,
    models: [{id:"model", name:"Offline stow", reasoning:false, input:["text"], cost:{input:0,output:0,cacheRead:0,cacheWrite:0}, contextWindow:16384,maxTokens:128}],
    streamSimple(model) {
      appendFileSync(`${process.env.FM_HOME}/provider-calls`, "custom stream invoked\n");
      const stream = createAssistantMessageEventStream();
      const output: any = {role:"assistant",content:[{type:"text",text:"offline stow receipt"}],api:model.api,provider:model.provider,model:model.id,
        usage:{input:0,output:0,cacheRead:0,cacheWrite:0,totalTokens:0,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}},stopReason:"stop",timestamp:Date.now()};
      queueMicrotask(() => {stream.push({type:"done",reason:"stop",message:output});stream.end();});
      return stream;
    },
  });
  pi.on("session_start", async (_event, ctx) => {
    const home = process.env.FM_HOME!;
    writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
    let compact: any;
    registerPrecompactStow({on(_name: any, fn: any) { compact = fn; }} as any, createPiStowWorker(sdk));
    await compact({reason:"manual"}, {...ctx, sessionManager:{
      getSessionFile: () => `${home}/transcript.jsonl`, getSessionId: () => "native-provider",
      getBranch: () => [{type:"message",message:{role:"user",content:"already established fact"}}],
    }});
    const log = readFileSync(`${home}/state/.precompact-stow-last.log`, "utf8");
    if (!log.includes("agent exit=0") || !log.includes("offline stow receipt")) throw new Error(`isolated provider failed: ${log}`);
    writeFileSync(`${home}/native-provider-ok`, "passed");
  });
}
TS
  PI_CODING_AGENT_DIR="$home/pi-config" PI_OFFLINE=1 "$REAL_PI" --approve --no-extensions     -e "$home/.pi/extensions/offline-provider.ts" --no-session --no-context-files --no-skills --no-prompt-templates     --model stow-offline/model -p 'offline control' > "$home/native-output" 2>&1 || { cat "$home/native-output" >&2; fail "native Pi offline provider"; }
  [ -f "$home/native-provider-ok" ] || { cat "$home/native-output" >&2; fail "native Pi did not finish isolated stow"; }
  [ "$(wc -l < "$home/provider-calls" | tr -d ' ')" -eq 2 ] || fail "expected isolated worker and main to each call registered provider"
  cleaned
  pass "installed Pi retains extension provider functions through the bounded isolated stow worker"
else
  printf '# Pi absent: offline native provider case not exercised\n'
fi
