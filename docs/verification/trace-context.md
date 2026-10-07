# Trace-context propagation verification

Repeatable evidence for the default-off native W3C trace-context capability.
Current behavior and rationale are owned by [`../trace-context.md`](../trace-context.md) and the configuration schema by [`../configuration.md`](../configuration.md) ("Trace context propagation"); this page records evidence only.

Date: 2026-10-07.
Shell: GNU bash 5.3.9 (macOS).
Comparison base: `housefeature/otel-task-tracing` at `d9c49ac4e495a7f37078d615a9621fa9728a78ee`.

The colocated unit suite `tests/fm-trace-context-lib.test.sh` exercises validation (valid accepted; malformed, wrong-length, uppercase, all-zero, `ff` version, and shell-metacharacter values rejected), root minting with every mint a distinct sampled root and no parent-adoption input, the recovery reuse path with the recorded carrier winning over the ambient environment, default-off omission, the enable precedence of `FM_TRACE_CONTEXT` over `config/trace-context` with unset or empty deferring to the file, normalized home-session state, atomic replacement of a read-only prior record, stale-session rejection after failed publication, missing or invalid state defaulting off, the Secondmate home-session boundary with later file state plus the per-task trace boundary, forced entropy failure omitting safely, the minted-root fixed-shape check, and first-mint-time preservation with a safe fallback for historical metadata that has no start time.

The spawn-path integration suite `tests/fm-trace-context-spawn.test.sh`, hermetic against an ambient `FM_TRACE_CONTEXT`, drives `bin/fm-spawn.sh` with a fake tmux pane and isolated git worktrees: enabled, one resolved carrier is recorded as `traceparent=` in the meta only after the identical `TRACEPARENT` export is sent before the launch literal; disabled, neither is written nor sent (`GOTMPDIR` still is); a failed carrier delivery leaves no `traceparent=` claim while the source task still launches; an unsafe delivery whose partial input cannot be cleared stops before appending the launch command and emits no span; a simulated launch-delivery rollback leaves no task record and emits no span; a successful enabled launch emits exactly one synthetic `firstmate.spawn` child; a failed metadata append removes the carrier from the launched task without aborting it; duplicate Secondmate preflight leaves inherited trace configuration unchanged; relaunch preserves the carrier and first-mint time while publishing a new generation; and spawns ignore later config and environment edits in favor of the frozen home-session decision.
The per-task boundary regression models the reviewed Secondmate scenario exactly: two unrelated tasks spawned sequentially from one home while the same fixed `TRACEPARENT` sits in the spawning environment (a persistent Secondmate's launch-time carrier) record and inject valid carriers whose trace ids differ from each other and from the ambient carrier, and a relaunch of the first task reuses its original carrier verbatim for both the meta record and the injected export.
Two further assertions drive a genuine two-level primary -> Secondmate -> worker chain, running `bin/fm-spawn.sh` twice with the exact environment the primary injects into the Secondmate, and prove the primary's effective override governs the nested worker both ways: env-on with no config file keeps the nested worker enabled while it roots its own per-task trace distinct from the Secondmate's carrier, and env-off with the file present keeps the nested worker disabled even though the `config/trace-context` file was copied into the Secondmate home.
A final assertion drives the file-decided path (`FM_TRACE_CONTEXT` unset) and proves the Secondmate's recorded/injected carrier and its delivered `FM_TRACE_CONTEXT=on|off` snapshot are always derived from one frozen decision, so a carrier is never paired with the opposite enable state.
These suites touch no real harness or live fleet.
The teardown suites `tests/fm-teardown.test.sh` and `tests/fm-gotmp.test.sh` use synthetic curl capture: refused cleanup emits no root, successful record removal emits one root, done and failed map to OK and ERROR, unknown leaves status unset, missing historical start data gets a current start, and repeated cleanup does not duplicate a root.
`tests/fm-gotmp.test.sh` refuses malformed status cursors, status-log removal, and final metadata removal for both done and failed tasks, verifies their terminal outcome survives in task metadata for a successful retry, and checks the exported task ID for records with and without an explicit endpoint ID.
It also verifies cursor and removal failures leave task records retryable with export disabled, and that repairing both failures allows cleanup without exporting a root.
The same suite captures terminal spans after plain and timestamp-tagged done/failed events followed by notes, including more than 200 notes and unterminated final lines, and checks that renewed work supersedes both logged and saved terminal outcomes while a later terminal event supplies the new outcome.
The outcome oracle is the state-transition contract in `docs/trace-context.md`, with OTLP OK and ERROR codes fixed at 1 and 2; these cases reject both notes hiding a terminal event and a stale terminal outcome surviving renewed work.
`tests/fm-backlog-atomicity.test.sh` drives backlog-enabled close and retain teardown followed by session-start recovery with malformed status cursors and refused metadata removal, for done and failed outcomes with export enabled and disabled.
Its oracle is the retirement contract in `docs/trace-context.md`: both task metadata and the pending transition must survive refusal, the backlog row must remain In flight, and a successful teardown retry must export the original outcome and task identity exactly once when enabled.
The spawn suite executes genuine enabled and disabled `--relaunch` calls, verifies obsolete terminal outcomes are cleared, and probes metadata-lock contention during fresh and relaunched exports.
The focused `tests/fm-trace-span-lib.test.sh` suite captures real authenticated HTTP exports from the lifecycle wrappers across task kinds, supported backends, fresh launches, relaunches, terminal outcomes, and forced cleanup.
Its lifecycle attribute oracle is the approved metrics scope in [`../trace-context.md`](../trace-context.md): captured span attributes must contain the current generation and omit pane/window identity, private PR URLs, and prior-generation linkage.
`tests/fm-gotmp.test.sh` also drives direct local Secondmate record retirement with no terminal status and checks an `unknown` root with status unset.
`tests/fm-session-start.test.sh` additionally proves only a lock-owning session start writes the effective state and a lock-refused read-only start leaves it unchanged.

The remote-route suite `tests/fm-remote-secondmate-trace-context.test.sh` (6 assertions) covers the Secondmate path that never reaches the local export site, driving the real chain - the parent's `bin/fm-spawn.sh`, `bin/fm-on.sh`, the real remote entrypoint, `bin/fm-remote-secondmate-control.sh`, and the remote host's own `bin/fm-spawn.sh` - over the deterministic SSH boundary with a stateful fake Herdr CLI, the backend a remote second mate always runs on, so the carrier the remote pane receives is read back from that pane's own log: disabled, the parent records no `traceparent=`, the remote pane receives no export, the remote home inherits no enablement flag, and the delivered snapshot is `FM_TRACE_CONTEXT=off` while `GOTMPDIR` still ships; enabled, the parent's recorded carrier, the remote endpoint's own record, and the exported pane value are one identical valid carrier sent after `GOTMPDIR` and before the launch command, with `FM_TRACE_CONTEXT=on` and the inherited flag delivered; a relaunch keeps that carrier verbatim in both the parent record and the pane export; a second remote route resolved from an environment holding a fixed ambient `TRACEPARENT` roots a trace id distinct from both that ambient carrier and the first route; the remote receiver accepts `config/trace-context` as ordinary declared inherited material while refusing `config/secondmate-harness`, which the primary deliberately does not propagate; and the delivery argument that carries a parent's carrier to a remote host is refused on a ship spawn, on a shell-metacharacter value, on an all-zero trace id, and on an empty value, so nothing but a strict W3C carrier on a Secondmate launch can reach a pane export.

Lifecycle-hook verification on 2026-10-07 used synthetic homes and a fake curl capture, with no Herdr lifecycle commands or real exporter endpoint: `bash tests/fm-send-inbox.test.sh` passed 16 assertions; `bash tests/fm-send-remote-delivery.test.sh` passed 16; `bash tests/fm-send-resolve-key.test.sh` passed 24; `bash tests/fm-control.test.sh` passed 44; and `bash tests/fm-control-relaunch.test.sh` passed 75.
These cases cover successful and refused inbox, remote, typed, and key delivery; message-text omission; decision keys; verified control and promotion events; and the relaunch internal-stop omission.
The same validation run passed `bash bin/fm-lint.sh` with ShellCheck 0.11.0 and actionlint 1.7.12, and `bash bin/fm-doc-audience-check.sh` reported `ok surfaces=117 local_links=736`.

```console
$ bash tests/fm-trace-context-lib.test.sh | tail -1
# fm-trace-context-lib.test.sh: all assertions passed
$ bash tests/fm-trace-context-spawn.test.sh | tail -1
# all fm-trace-context-spawn tests passed
$ bash tests/fm-teardown.test.sh | tail -1
ok - the run abort and the leaked-process reap both complete before the destructive worktree return
$ bash tests/fm-remote-secondmate-trace-context.test.sh | tail -1
ALL TESTS PASSED
```

Run the recorded commands from the repo root; each suite prints one `ok - ...` per assertion.
Refresh the additional cleanup, recovery, and lifecycle-wrapper evidence with:

```sh
bash tests/fm-gotmp.test.sh
bash tests/fm-backlog-atomicity.test.sh
bash tests/fm-trace-span-lib.test.sh
```

A single live-backend end-to-end check - a real spawn confirming the pane received the `TRACEPARENT` export before the launch line, with nothing left after teardown - is a bounded manual step, deferred here because a live agent spawn disrupts a running fleet.
