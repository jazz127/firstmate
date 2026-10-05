# Round 2 targeted validation

All three requested executable regression selectors passed at f46c74d2:
- test_returned_head_restarts_closeout_window uses actual disposable local Git pushes A→B→A and fake GitHub responses; each observed head receives a fresh two-hour window.
- test_ci_lane_disappearing_after_ready_holds_closeout first establishes readiness, removes a previously observed lane, and checks a single CI hold, retained task/worktree, and persisted absent lane.
- test_permission_lookup_failure_after_readable_observation establishes READ permission, fails only the simulated GraphQL permission request, confirms no cleanup authorization or repeated diagnostic, then restores permission.

The independent oracles are the supplied intent and docs/configuration.md. Assertions exercise CLI output, durable records, wake queue entries, and task/worktree retention. No source-text assertions establish behavior.

A fresh live-boundaries run used the real contribution observer, GitHub REST/GraphQL, existing login, and disposable marked homes. ADMIN and WRITE remained merge-based; failed and absent CI held closeout; supported metadata allowed readiness; a retained PR whose URL differed from current task metadata did not emit closeout; genuine failed GitHub reads reported once and retained the task. No upstream writes were made. The failed-read probe used an invalid token only in that process environment, without changing any credential store.

Earlier product evidence in this same validation run remains applicable: live-closeout.log covers the default/configured timing boundaries, feedback acknowledgement, dirty/unpushed refusals, safe teardown, and retained observation; primary-completion.txt covers an actual Codex primary consuming the ready wake and performing guarded cleanup. This round changes tests only and does not repeat that primary token expenditure.

The three transition scenarios remain simulation-only for product validation. A local Git remote cannot supply the observer's real api.github.com PR head/check/permission transitions. Live proof needs an explicitly authorized disposable upstream PR/branch and check-management authority; permission-only failure needs control over that upstream failure or a dedicated restricted test identity. The phase boundary excludes upstream creation/push/CI and production credential mutation. Existing regression evidence satisfies the specifically requested test additions but cannot be relabelled live.

No new product failure was found. Verdict remains inconclusive for full live coverage. No repeated decision finding is raised. CLI/state transcripts are the relevant user surface; no visual layout change requires a screenshot. No lint/static analysis, broad suite, pipeline control, push, PR, or CI phase ran. Every disposable home and transient runner was removed; source worktree stayed unchanged.
