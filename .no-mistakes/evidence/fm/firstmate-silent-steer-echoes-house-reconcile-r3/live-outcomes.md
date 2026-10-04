# Live CLI outcome and recovery evidence

The real repository CLI ran against disposable marked FM_HOME directories inside the gate worktree. No harness, outcome store, drain, or lock implementation was replaced. All disposable homes were removed.

`bin/fm-branch-outcome.sh append --task paused --verdict routine --summary Scheduled recheck: registered pause unchanged --silent true` (exit 0)

```text
1
```

`bin/fm-branch-outcome.sh append --task action --verdict routine --summary Worker recovered after restart --silent false` (exit 0)

```text
2
```

`bin/fm-branch-outcome.sh append --task release --verdict captain --summary Release checks failed; action needed --silent false` (exit 0)

```text
3
```

`bin/fm-branch-outcome.sh startup-replay` (exit 0)

```text
BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):
{"seq":2,"epoch":1791120158,"task":"action","wake":"","verdict":"routine","summary":"Worker recovered after restart","silent":false,"statusEndpoint":0,"statusIdent":"-"}
```

`bin/fm-branch-outcome.sh unread` (exit 0)

```text
{"seq":3,"epoch":1791120158,"task":"release","wake":"","verdict":"captain","summary":"Release checks failed; action needed","silent":false,"statusEndpoint":0,"statusIdent":"-"}
```

`bin/fm-branch-outcome.sh append --task release --verdict captain --summary Must stay visible --silent true` (exit 2)

```text
error: silent outcomes must have the routine verdict
```

### Silent replay is omitted; non-silent routine replay remains available; captain cannot be silent

Persisted state:
```json
{
  ".branch-outcomes-tail.jsonl": "{\"seq\":1,\"epoch\":1791120158,\"task\":\"paused\",\"wake\":\"\",\"verdict\":\"routine\",\"summary\":\"Scheduled recheck: registered pause unchanged\",\"silent\":true,\"statusEndpoint\":0,\"statusIdent\":\"-\"}\n{\"seq\":2,\"epoch\":1791120158,\"task\":\"action\",\"wake\":\"\",\"verdict\":\"routine\",\"summary\":\"Worker recovered after restart\",\"silent\":false,\"statusEndpoint\":0,\"statusIdent\":\"-\"}\n{\"seq\":3,\"epoch\":1791120158,\"task\":\"release\",\"wake\":\"\",\"verdict\":\"captain\",\"summary\":\"Release checks failed; action needed\",\"silent\":false,\"statusEndpoint\":0,\"statusIdent\":\"-\"}\n",
  ".branch-outcomes-cursor": "2\n",
  ".branch-outcome-index-ready": "visible-only-v1:3\n",
  "branch-outcomes.jsonl": "{\"seq\":1,\"epoch\":1791120158,\"task\":\"paused\",\"wake\":\"\",\"verdict\":\"routine\",\"summary\":\"Scheduled recheck: registered pause unchanged\",\"silent\":true,\"statusEndpoint\":0,\"statusIdent\":\"-\"}\n{\"seq\":2,\"epoch\":1791120158,\"task\":\"action\",\"wake\":\"\",\"verdict\":\"routine\",\"summary\":\"Worker recovered after restart\",\"silent\":false,\"statusEndpoint\":0,\"statusIdent\":\"-\"}\n{\"seq\":3,\"epoch\":1791120158,\"task\":\"release\",\"wake\":\"\",\"verdict\":\"captain\",\"summary\":\"Release checks failed; action needed\",\"silent\":false,\"statusEndpoint\":0,\"statusIdent\":\"-\"}\n"
}
```

`bin/fm-branch-outcome.sh append --task ship --verdict routine --summary Status record echoed unchanged --silent true` (exit 0)

```text
1
```

`bin/fm-wake-drain.sh ` (exit 0)

```text
STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
ship done: requested work ready for review
```

`bin/fm-wake-drain.sh ` (exit 0)

### Silent echo does not cover a lost completion; next main drain recovers it once

Persisted state:
```json
{
  "ship.status": "done: requested work ready for review\n",
  ".branch-outcomes-tail.jsonl": "{\"seq\":1,\"epoch\":1791120158,\"task\":\"ship\",\"wake\":\"\",\"verdict\":\"routine\",\"summary\":\"Status record echoed unchanged\",\"silent\":true,\"statusEndpoint\":38,\"statusIdent\":\"strong:16777231:7395402:1791120158.782538123\"}\n",
  ".branch-outcome-index-ready": "visible-only-v1:1\n",
  "branch-outcomes.jsonl": "{\"seq\":1,\"epoch\":1791120158,\"task\":\"ship\",\"wake\":\"\",\"verdict\":\"routine\",\"summary\":\"Status record echoed unchanged\",\"silent\":true,\"statusEndpoint\":38,\"statusIdent\":\"strong:16777231:7395402:1791120158.782538123\"}\n"
}
```

`bin/fm-branch-outcome.sh append --task ship --verdict captain --summary Prior completion delivered --silent false` (exit 0)

```text
1
```

`bin/fm-wake-drain.sh ` (exit 0)

`bin/fm-branch-outcome.sh append --task ship --verdict routine --summary Unchanged echo of latest record --silent true` (exit 0)

```text
2
```

`bin/fm-wake-drain.sh ` (exit 0)

```text
STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
ship failed: later attempt failed
```

### Visible coverage suppresses repeats but a later silent row cannot hide a new failure; readiness includes silent tail

Persisted state:
```json
{
  "ship.status": "done: prior completion delivered\nfailed: later attempt failed\n",
  ".branch-outcomes-tail.jsonl": "{\"seq\":1,\"epoch\":1791120160,\"task\":\"ship\",\"wake\":\"\",\"verdict\":\"captain\",\"summary\":\"Prior completion delivered\",\"silent\":false,\"statusEndpoint\":33,\"statusIdent\":\"strong:16777231:7395578:1791120160.429656146\"}\n{\"seq\":2,\"epoch\":1791120161,\"task\":\"ship\",\"wake\":\"\",\"verdict\":\"routine\",\"summary\":\"Unchanged echo of latest record\",\"silent\":true,\"statusEndpoint\":62,\"statusIdent\":\"strong:16777231:7395578:1791120160.429656146\"}\n",
  ".ship.branch-outcome-index": "fm-branch-outcome-index-v1\t1\t33\tstrong:16777231:7395578:1791120160.429656146\n",
  ".branch-outcome-index-ready": "visible-only-v1:2\n",
  "branch-outcomes.jsonl": "{\"seq\":1,\"epoch\":1791120160,\"task\":\"ship\",\"wake\":\"\",\"verdict\":\"captain\",\"summary\":\"Prior completion delivered\",\"silent\":false,\"statusEndpoint\":33,\"statusIdent\":\"strong:16777231:7395578:1791120160.429656146\"}\n{\"seq\":2,\"epoch\":1791120161,\"task\":\"ship\",\"wake\":\"\",\"verdict\":\"routine\",\"summary\":\"Unchanged echo of latest record\",\"silent\":true,\"statusEndpoint\":62,\"statusIdent\":\"strong:16777231:7395578:1791120160.429656146\"}\n"
}
```

`bin/fm-branch-outcome.sh append --task visible --verdict captain --summary Already delivered --silent false` (exit 0)

```text
1
```

`bin/fm-branch-outcome.sh append --task silent --verdict routine --summary Unchanged echo --silent true` (exit 0)

```text
2
```

`bin/fm-wake-drain.sh ` (exit 0)

```text
STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
silent failed: never delivered
```

### Legacy silent coverage migrates without changing history or legitimate coverage

Persisted state:
```json
{
  ".branch-outcomes-tail.jsonl": "{\"seq\":1,\"epoch\":1791120162,\"task\":\"visible\",\"wake\":\"\",\"verdict\":\"captain\",\"summary\":\"Already delivered\",\"silent\":false,\"statusEndpoint\":24,\"statusIdent\":\"strong:16777231:7395846:1791120162.295116111\"}\n{\"seq\":2,\"epoch\":1791120162,\"task\":\"silent\",\"wake\":\"\",\"verdict\":\"routine\",\"summary\":\"Unchanged echo\",\"silent\":true,\"statusEndpoint\":24,\"statusIdent\":\"strong:16777231:7395847:1791120162.295279486\"}\n",
  "silent.status": "failed: never delivered\n",
  "visible.status": "done: already delivered\n",
  ".visible.branch-outcome-index": "fm-branch-outcome-index-v1\t1\t24\tstrong:16777231:7395846:1791120162.295116111\n",
  ".branch-outcome-index-ready": "visible-only-v1:2\n",
  "branch-outcomes.jsonl": "{\"seq\":1,\"epoch\":1791120162,\"task\":\"visible\",\"wake\":\"\",\"verdict\":\"captain\",\"summary\":\"Already delivered\",\"silent\":false,\"statusEndpoint\":24,\"statusIdent\":\"strong:16777231:7395846:1791120162.295116111\"}\n{\"seq\":2,\"epoch\":1791120162,\"task\":\"silent\",\"wake\":\"\",\"verdict\":\"routine\",\"summary\":\"Unchanged echo\",\"silent\":true,\"statusEndpoint\":24,\"statusIdent\":\"strong:16777231:7395847:1791120162.295279486\"}\n"
}
```

`bin/fm-branch-outcome.sh append --task fleet --verdict routine --summary Unchanged review --silent true` (exit 0)

```text
1
```

`bin/fm-wake-drain.sh ` (exit 0)

```text
STATUS OUTCOME BACKSTOP SKIPPED: branch outcome history is busy; retry on the next drain.
```

`bin/fm-wake-drain.sh ` (exit 0)

```text
STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
ship done: completion waiting during contention
```

### Healthy-store lock contention skips once and subsequent drain recovers completion

Persisted state:
```json
{
  "ship.status": "done: completion waiting during contention\n",
  ".branch-outcomes-tail.jsonl": "{\"seq\":1,\"epoch\":1791120163,\"task\":\"fleet\",\"wake\":\"\",\"verdict\":\"routine\",\"summary\":\"Unchanged review\",\"silent\":true,\"statusEndpoint\":0,\"statusIdent\":\"-\"}\n",
  ".branch-outcome-index-ready": "visible-only-v1:1\n",
  "branch-outcomes.jsonl": "{\"seq\":1,\"epoch\":1791120163,\"task\":\"fleet\",\"wake\":\"\",\"verdict\":\"routine\",\"summary\":\"Unchanged review\",\"silent\":true,\"statusEndpoint\":0,\"statusIdent\":\"-\"}\n"
}
```

`bin/fm-supervision-instructions.sh --harness pi` (exit 0)

```text
================================================================================
SUPERVISION OPERATING INSTRUCTIONS - primary harness: pi
================================================================================
Current state:
- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.
- Away/quiet mode: inactive.
- X mode: inactive; use the default watcher cadence.
- Ordinary wake: the Pi extension already owns watcher continuity; do not arm another cycle.

Mode: Pi extension background wake.

When this session owns supervision, in either posture:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Confirm the Pi primary auto-loaded both project extensions (plain `pi` or `pi-signed`, after approving project trust once per clone); if not, restart the selected executable with `-e /Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M43G853WBY3DHHDZBWG396HF/.pi/extensions/fm-primary-turnend-guard.ts -e /Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M43G853WBY3DHHDZBWG396HF/.pi/extensions/fm-primary-pi-watch.ts` as a trust-free fallback.
3. Initial process cycle only: make the one required `fm_watch_arm_pi` call; if startup already owned the fleet lock, this is an ownership-based no-op.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_pi` again.
5. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live Pi process, and owns every later successor launch.
6. Ordinary same-process session replacement (`/new`, `/resume`, `/fork`, reload) retires only the prior generation; when the replacement owns the fleet lock, its `session_start` arms the new generation without a model turn or another `fm_watch_arm_pi` call.
   The generation-owner contract and in-flight actionable-close handoff live in `.pi/extensions/fm-primary-pi-watch.ts`.
7. After an actionable child close, the extension rechecks session-lock ownership and verifies one successor before it delivers the follow-up wake; its bounded fallback is defined in `docs/watcher-continuity.md`.
8. Ordinary work, turn completion, and ordinary signal, stale, check, heartbeat, or other wake handling: do not call `fm_watch_arm_pi` again because continuity is extension-owned rather than model-memory-owned.
9. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
10. Missing, failed, or unhealthy cycle only: if a later notification explicitly reports one of those repair conditions, drain queued wakes, inspect the failure text, call `fm_watch_arm_pi`, and restart the selected Pi-family executable with both extensions loaded if needed.
   A redundant call while the extension owns an arm child or scheduled retry is an ownership-based `watcher: unchanged` no-op, not an independent health claim.
11. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M43G853WBY3DHHDZBWG396HF/.pi/extensions/fm-primary-turnend-guard.ts`).

The supervision branch is default-on (docs/pi-supervision-branch.md): whenever this session owns the fleet lock, the watcher extension hands eligible task-local rows from ordinary actionable wakes, plus selected fleet-wide heartbeat reviews, to the in-process supervision branch while main-only rows remain queued for this conversation.
While the away-posture record `state/.afk-contract` exists the branch takes every row instead, this conversation receives no processing request, and main's standing authority relocates to the branch through the guarded scripts; a wake the branch cannot take and every watcher-failure alarm still reach this conversation, and the first run boundary after the record is archived presents what accumulated (docs/pi-supervision-branch.md "Postures").
Decision-owned signal and stale routing, including whole-batch precedence and the independent heartbeat exception, is owned by [docs/pi-supervision-branch.md](../pi-supervision-branch.md#components-and-their-owners).
[`bin/fm-branch-prompt.sh`](../../bin/fm-branch-prompt.sh)'s "Verdict: routine or captain" section owns routine silence eligibility, including unchanged pauses and status echoes.
Every routine outcome is durably recorded and remains invisible and turn-free in captain chat, independently of Calm and the `silent` marker.
Silent routine outcomes have no rendered routine note; non-silent routine outcomes remain available to MAIN and recovery without being displayed to the captain.
Here, "rendered" refers to non-silent outcome recording for MAIN and recovery, distinct from captain-chat display; captain outcomes are never silent.
A captain-facing outcome instead appears as one exact, sequence-keyed visible transcript entry, and while attended then arrives in this conversation as one hidden supervision processing request listing each `[seq N, recorded <age> ago] task: summary` it covers; outcomes recorded while away wait for that request until the record is archived.
That request is the one turn in which MAIN processes the outcome, starting from the task's current state because the outcome is what was true when it was recorded: give the captain a visible response where one is due, answer or escalate a decision, act on a blocker or failure, or record that no further action is needed; the reply covers only the still-open outcomes, as if the settled ones, such as a decision since answered or a PR since merged, had never been listed, with no captain-facing mention even in a recap; then call the `fm_branch_processed` tool with the highest sequence the request listed, exactly once.
Only that call closes the outcome; an unrelated, empty, or paraphrased answer leaves it open, and the current unprocessed sequence set is presented again at the next run boundary and at session start until it is acknowledged.
Where that persisted entry is in this transcript it is already the captain-visible record, so MAIN must not re-emit it verbatim merely because it appeared (an outcome carried over from before a restart or a switch of primary may have no entry here); this prevents repetition but does not replace any captain-facing outcome response required by `AGENTS.md` section 9.
Regression example - keep verbatim and never condense away: `[seq 41] claude-mod: implementation complete, ready for review` requires relaying a captain-facing outcome response, not just `Captain, shipshape.`.
A merge ask with no URL that leans on the dim anchor violates `AGENTS.md` section 9.
Before MAIN steers, controls lifecycle, or cleans up a task, claim its lease with `bin/fm-lease.sh claim <task>` and release it afterwards; a refused claim means the branch is acting on that task right now.
This conversation still receives every other fleet-wide or unresolvable wake, the branch's wakes when it is unavailable, and every watcher-failure alarm regardless of posture, so the arm and repair contract above is unchanged.
Treat the merged fleet event as already handled for fleet operations: MAIN must not re-drain, re-run, or acknowledge it.
MAIN may use routine outcomes to answer an explicit captain status request; event ownership does not prevent answering that request.
Separately, MAIN applies judgment about whether and how to surface, summarize, reference, or incorporate a merged sailboat outcome in the captain conversation; event ownership does not decide the conversational treatment.
Read the durable outcome store with the fm_branch_outcomes tool when the captain asks what happened.
Do not turn routine outcomes into unsolicited chat updates or shipshape replies.

The turn-end guard extension lives at `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M43G853WBY3DHHDZBWG396HF/.pi/extensions/fm-primary-turnend-guard.ts`.
The watcher extension lives at `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M43G853WBY3DHHDZBWG396HF/.pi/extensions/fm-primary-pi-watch.ts`.
Both are tracked, project-local `.pi/extensions/*.ts` files that Pi auto-discovers once the project is trusted; `bin/fm-session-start.sh` reports when the running Pi session has not loaded both required extensions.
```

### Primary receives emitted Pi protocol

Persisted state:
```json
{}
```
