# Automatic context refresh

Firstmate can replace a long-running Claude primary conversation at an explicitly configured token threshold.
The refresh is a deliberate durable handoff, not compaction and not restoration of the old conversation.
[`configuration.md`](configuration.md#context-restart-budget-configcontext-restart-budget) owns the threshold setting; `bin/fm-context-restart-lib.sh` owns exact validation and transcript accounting.

## Turn-boundary detection

`.claude/settings.json` registers `bin/fm-context-restart-claude-hook.sh` as a synchronous Claude `Stop` hook with a 15-second host bound.
Claude supplies a trusted payload containing the session id and transcript path after an assistant turn has completed.
The hook streams the transcript to find the latest assistant usage, computes the current context total as the latest assistant usage's input, cache creation, cache read, and output token counts, and compares it with the validated budget.
It never checks during a model turn, tool call, or captain input.

Below threshold the hook prints nothing, exits successfully, writes no ordinary crossing state, and spends no model tokens.
Malformed hook payload, transcript JSON, latest usage, or configuration cannot trigger a restart.
Malformed configuration is reported separately by locked session-start bootstrap rather than guessed at inside a Stop hook.

The first observation at or above threshold atomically publishes one home-local crossing record, then returns one typed `context-refresh` operational directive through Claude's normal Stop feedback continuation.
Later Stop firings for the same crossing see that record and stay silent.
If the context later falls below threshold before handoff, the detector rearms, so a later rise is a new crossing and can produce one new directive.

## Durable handoff

The directive tells the running Firstmate to invoke the internal `/stow` skill before doing new work.
That pass captures durable knowledge, corrects the open work records held in conversation, enforces startup-memory budgets, and cascades to registered secondmates under the skill's existing contract.
The session proceeds to exit only when the receipt says it is reset-safe.
If stow exposes an unresolved exception or captain decision, the old session remains available and the durable crossing remains retryable.

After a reset-safe receipt, Firstmate runs the exact `bin/fm-context-restart.sh handoff --session <id> --reset-safe` command carried by the directive.
The command verifies that the caller still owns the home session lock and that the durable crossing belongs to the current Claude session.
It advances the crossing to a reset-safe ready sentinel.
For an automatic handoff, it then waits for the wrapper-owned supervisor to commit replacement before reporting success.
If that transfer does not commit, the command reports failure so the caller keeps the current session running.
Repeating the command against the same session and wrapper generation is idempotent.

## Automatic successor

`bin/fm-primary.sh` is the selected automatic successor owner.
It remains as the terminal parent while Claude runs, gives each child generation a private token, and forwards the chosen Claude options.
Replacement requires no backend-specific terminal control.
It restarts only when the exited child left a reset-safe replacing sentinel carrying that exact token, published after the wrapper-owned supervisor transferred any needed watcher.
Preparation alone cannot turn an ordinary exit into a relaunch after a failed watcher transfer.

After the old Claude process has exited, the wrapper serializes against ordinary session-lock acquisition and removes only the lock that still names that exact dead harness owner.
It retires the completed crossing and starts a new Claude conversation in the same terminal.
The new SessionStart hook acquires the now-free lock and runs the full session-start digest without receiving or restoring the old transcript.
The wrapper then supplies one typed resume turn stating that this digest is authoritative, so the fresh process reconciles durable work and resumes what remains under way.
An initial secondmate launch instruction is deliberately delivered only to the first child and is not replayed after refresh.
If a fresh successor already exceeds the budget at its first completed turn, its detector reports that the budget is too small and inhibits another refresh.
A below-budget observation, including after raising the budget, rearms that session.
This prevents a startup context larger than the configured budget from causing a succession of reset-safe relaunches.

## Enable automatic refresh

Refresh is disabled when `config/context-restart-budget` is absent.
The ordinary `claude` launch remains the default.
To opt in, create the budget file and launch the main primary through the wrapper:

```sh
mkdir -p config
printf '400000\n' > config/context-restart-budget
bin/fm-primary.sh
```

Use any positive threshold appropriate for the selected model's context window.
The wrapper rejects conversation-restoring options while refresh is enabled.
Without a budget it executes plain Claude with the original options and initial prompt.
Remove the budget to disable detection; use an ordinary Claude launch to remove the wrapper from subsequent sessions.

Claude secondmates launched through `bin/fm-spawn.sh` use the wrapper only after a validated opt-in budget has been inherited into their receiving home.
An older secondmate home whose guarded sync could not fast-forward may still lack the wrapper; an opted-in spawn then warns once and keeps that home's existing plain-Claude launch, so automatic refresh becomes available only after a normal sync.

## Why the other successor shapes are not primary

A Stop-hook-driven relaunch was rejected because the hook is a child of the session being replaced and does not own the interactive terminal after that session exits.
Starting a successor from that hook would either overlap the live lock owner or require a detached terminal-specific process, and it would compete with the existing asynchronous watcher hook.

A plain `claude` launch remains the manual fallback.
Threshold detection and stow preparation still work, but the handoff command cannot prove a relaunch parent exists, so it preserves the ready sentinel and tells the operator to exit Claude and relaunch with `bin/fm-primary.sh`.
A fresh manual launch still resumes safely from the ordinary session-start digest, though the operator must send the first turn.

## Interruption and supervision safety

The crossing is durable before the one directive is emitted, and the ready sentinel is durable before termination is requested.
An interruption before stow leaves the existing fleet records authoritative and leaves the crossing available for inspection or retry in the old session.
An interruption during stow leaves that skill's owner-specific writes re-runnable.
An interruption after ready publication leaves a reset-safe manual launch path even if the wrapper itself disappears before starting the successor.

The context hook does not arm, stop, restart, or wait on the fleet watcher.
The automatic handoff's `bin/fm-context-restart-supervise.sh` process belongs to the terminal wrapper, outside Claude's hook process tree.
When the home needs supervision, it takes over the current arm through the existing identity-bound `fm-watch-arm.sh --take-over` interface.
After a bounded wait for the crossing publication lock, it revalidates the exact wrapper generation, session, and live session-lock owner and reestablishes a healthy bridge-owned watcher if the transferred cycle completed while it waited.
Only then does it commit replacement and request termination.
If the authorized Claude owner exits naturally after that commit, the bridge treats termination as complete and retains supervision.
It keeps watcher cycles running through successor startup until the successor's Stop auto-arm takes over the bridge-owned cycle and restores ordinary queue delivery.
An independent away daemon remains the supervision owner when present.
If watcher transfer fails, the prepared Claude session stays running and the wrapper reports the error.
Claude's existing asynchronous watcher auto-arm and synchronous turn-end guard continue to run on the same Stop event under their existing single-flight and bounded-continuation rules.
The handoff command never acknowledges or removes queued notifications.
The successor's session-start digest therefore presents the same durable queue and open decisions that any ordinary restart would present.

## Other primary harnesses

This feature installs detection and replacement only for Claude primaries.
The context budget remains inert for Codex, OpenCode, Pi, pi-signed, omp, Grok, Kimi, and Cursor primaries.
Adding an adapter later requires a verified turn-boundary context measurement, one-directive crossing deduplication, reset-safe stow handoff, clean session-lock transfer, and an owned successor transport.

## Verification

`tests/fm-context-restart.test.sh` covers exact threshold accounting, malformed transcript and usage rejection, concurrent one-directive publication, wrapper lock transfer, and handoff completion over synthetic process fixtures.
Its continuity regressions exercise a worker notification completing the transferred watcher during publication-lock contention and an authorized owner exiting naturally before termination; both require monitoring through replacement and native successor takeover without losing queued notifications.
`tests/fm-secondmate-harness.test.sh` covers opted-out and opted-in launches, inheritance, and the unsynced-home fallback.
`FM_CONTEXT_RESTART_CLAUDE_LIVE_E2E=1 tests/fm-context-restart-claude-live-e2e.test.sh` checks the installed Claude Stop payload and transcript usage with a high threshold, then exercises stow and one replacement in print mode with a low threshold.
Watcher continuity and wake retention are covered separately by synthetic process fixtures; interactive terminal replacement is not measured by that probe.
[`verification/supervision.md`](verification/supervision.md#claude-context-refresh) records the current versioned live result.
