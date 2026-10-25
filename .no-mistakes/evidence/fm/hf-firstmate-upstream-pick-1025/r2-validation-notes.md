# Targeted Test phase, current head

Validated target e50e0a2360bffef4a9a23ea1b0fbb4b7002af103 against acceptance context from f0dce921b129aa9e67ce033810df167a84ca45f5.
No source changes, pipeline control, GitHub writes, credential refreshes, or fleet lifecycle operations were performed.
All disposable operational homes and selectors were confined to the gate worktree and removed after their commands completed.
Every executed command below completed with exit status 0.

## Focused behavioral checks

- `TMPDIR="$PWD/.gate-test-tmp" bash tests/fm-usage-warner.test.sh` - complete scoped usage suite, including failed-delivery retry, effective directories, v1 compatibility, overlap, malformed reads and timeout behavior.
- `TMPDIR="$PWD/.gate-test-tmp" bash tests/.gate-selected-crew.sh` - existing selectors `test_ci_monitoring_no_checks_stays_working`, `test_ci_no_checks_status_log_override_stays_working`, `test_ci_monitoring_no_ci_declared_stays_working`, `test_ci_no_ci_status_log_override_stays_working`, `test_ci_no_ci_then_red_marker_is_not_ready`, `test_ci_monitoring_checks_green_surfaces_done`, `test_ci_monitoring_green_then_new_issue_stays_working`.
- `TMPDIR="$PWD/.gate-test-tmp" bash tests/.gate-selected-contributions.sh` - existing selectors `test_review_bot_inline_wake`, `test_review_bot_empty_approval_is_not_a_finding`, `test_review_bot_watching_is_opt_in`, `test_review_bot_allowlist_is_configurable`, `test_automated_reviewer_signal`, `test_automated_reviewer_configuration`, `test_author_marker_directive`.
- `TMPDIR="$PWD/.gate-test-tmp" bash tests/.gate-selected-feedback.sh` - existing `Feedback.test_no_checks_markers_never_emit_green_feedback`, `Feedback.test_no_checks_readiness_requires_current_attributed_pipeline_evidence`, `Feedback.test_pipeline_no_checks_evidence_never_overrides_pending_or_failed_checks`, `Feedback.test_unknown_no_checks_and_status_contexts_never_false_green`.
- `TMPDIR="$PWD/.gate-test-tmp" bash tests/.gate-crew-evidence.sh` - retained actual CLI status output for zero-check, no_ci, misleading worker reports, later-red and genuinely green controls.

Selectors execute existing behavioral interfaces; they make no implementation-source assertions.
The CI and offline contribution checks substitute upstream no-mistakes, tmux and/or forge boundaries and are simulated evidence.
The complete repository suite, linters, formatters and static analysis were not run.

## Live product drivers

Executed `python3 .gate-test-tmp/live-usage.py`, `live-rearm.py`, `live-usage-errors.py`, `live-contributions.py`, `live-empty-approval.py`, and `live-house-policy.py` from the worktree.
Their exact contents are retained as r2-live-*.py.txt.

Usage drivers called the actual `bin/fm-usage-warner.sh` and generated check shim with actual installed quota-axi reading Claude and actual macOS osascript.
They demonstrated unconfigured silence, tiered crossings, successful delivery de-duplication, relative directory preservation under conflicting ambient overrides, missing-notifier retry without consuming new keys, reset re-arming, missing-window retention, missing-quota error de-duplication and recovery, v1 compatibility, and disarm cleanup.
Dependency-failure cases hid only the unavailable command from the child PATH while all remaining executables were symlinks to installed tools; no reader, response or notifier was faked.
Reset/v1 scenarios seeded the documented serialized delivery state as disposable user data, then drove actual Claude reads.

Contribution drivers called actual `bin/fm-contributions.sh` poll/pending/snapshot/ack and its generated shim against actual github.com APIs for basecamp/omarchy PR 13212 and microsoft/vscode PR 344090.
They proved exact-login opt-in, substantive inline findings, fleet-only triage with no verdict/merge authority, stable shim configuration, acknowledgement without replay after toggles, suppression of empty APPROVED reviews, and independent house automated-reviewer/author-marker behavior.
The empty-approval path used real human logins in the arbitrary exact-login allowlist; the focused offline regression also exercised bot accounts.
`gh-axi api repos/microsoft/vscode/pulls/344090/reviews --jq '[.[] | select(.state == "APPROVED") | {login:.user.login,state,body,html_url}]'` retained independent upstream evidence of the empty review bodies in r2-live-approval-oracle.toon.
No upstream writes occurred.

## Remaining limits

The no-check/no_ci monitor integration remains untested live, as already accepted in the previous Test round.
No isolated monitor run was supplied; this phase explicitly forbids creating or controlling another pipeline.
Existing focused tests and the CLI evidence runner exercised those boundaries with fake no-mistakes and cannot establish a live pass.
The outer executor can provide isolated zero-check and no_ci monitor runs with disposable home/task bindings for live confirmation.
No new finding is raised for that previously accepted evidence gap.

Native notification screenshots remain unavailable: a fresh CoreGraphics CGPreflightScreenCaptureAccess check returned false.
Actual osascript accepted delivery, and delivery records and CLI output are retained, but banner appearance was not visually verified.
To enable screenshot evidence, grant the hosting terminal/agent Screen Recording permission in macOS System Settings > Privacy & Security > Screen Recording and rerun the scenario.
No permission or system configuration was changed.

All checks completed successfully; the product-validation verdict remains inconclusive solely because the accepted CI monitor integration gap has simulated evidence only.
