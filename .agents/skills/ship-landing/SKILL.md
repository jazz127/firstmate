---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when an outside-PR closeout signal arrives, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
In no-mistakes mode the earlier `done [at=<epoch>]: {summary}` is the pipeline handoff and is not gated.
Before reporting any pull request to the captain, its published body is read back from the forge at the PR reporting boundary; task-owned PR registration and inactive reconciliation perform this check automatically, including for reports without an owning task record.
Preserve the reported PR outcome but append `evidence-validation=failed` when its body cannot be read or parsed, or when an evidence claim lacks the artifact, command, and capture time required by `bin/fm-dod-lib.sh`.
The reporting-boundary check validates published text, while the generated ship brief's PR-body preflight contract catches worker-authored bodies before publication; `bin/fm-dod-lib.sh` owns both instructions.
Preserve the validator diagnostic alongside `evidence-validation=failed` when a published attestation is bound to a different head, so the refusal names the current head, attested head, and remediation.
Those publication checks refuse contradictory driven-scenario claims, including a count that no complete scenario table with a `Live` column agrees with; the check does not apply to captain intent because a brief may quote a defective PR body while requesting its repair.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.

On a `check: contributions closeout` wake, follow the [outside-PR review-window contract](../../../docs/configuration.md#outside-pull-request-review-window-configoutside-pr-review-window-hours); `bin/fm-contributions.sh`'s header owns the wake format.
Before acting on any closeout wake, confirm that the live task is a ship and its current canonical `pr=` matches the wake's URL; disregard a stale wake for a replaced PR or retired task.
For `state=ready`, confirm that the wake's PR head is still current and the closeout conditions still hold, then run the ordinary guarded teardown; if the head changed, a closeout condition fails, or teardown refuses, leave the task in place and report the reason.
For `state=review`, `state=ci`, or `state=workspace`, leave the task in place and surface the unacknowledged feedback, check result, or workspace state.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
