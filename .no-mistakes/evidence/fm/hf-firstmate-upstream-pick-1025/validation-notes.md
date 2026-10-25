# Targeted validation

All final targeted checks exited 0. No tracked files changed; all disposable homes were removed.

## Existing focused regression commands

- `TMPDIR="$PWD/.gate-test-tmp" bash tests/fm-usage-warner.test.sh`
- `TMPDIR="$PWD/.gate-test-tmp" bash tests/.gate-selected-crew.sh`: loaded existing definitions and selected only `test_ci_monitoring_no_checks_stays_working`, `test_ci_no_checks_status_log_override_stays_working`, `test_ci_monitoring_no_ci_declared_stays_working`, `test_ci_no_ci_status_log_override_stays_working`, `test_ci_no_ci_then_red_marker_is_not_ready`, `test_ci_monitoring_checks_green_surfaces_done`, and `test_ci_monitoring_green_then_new_issue_stays_working`.
- `TMPDIR="$PWD/.gate-test-tmp" bash tests/.gate-selected-contributions.sh`: selected existing `test_review_bot_inline_wake`, `test_review_bot_empty_approval_is_not_a_finding`, `test_review_bot_watching_is_opt_in`, `test_review_bot_allowlist_is_configurable`, `test_automated_reviewer_signal`, `test_automated_reviewer_configuration`, and `test_author_marker_directive`.
- `TMPDIR="$PWD/.gate-test-tmp" bash tests/.gate-crew-evidence.sh`: actual crew-state outputs against fake no-mistakes/tmux/GitHub tools. This is simulated evidence, not live validation.

These runners execute existing behavioral interfaces; they do not assert implementation text. Temporary selector runners were removed after completion.

## Live drivers

Ran `python3 .gate-test-tmp/live-usage.py`, `python3 .gate-test-tmp/live-contributions.py`, `python3 .gate-test-tmp/live-empty-approval.py`, and `python3 .gate-test-tmp/live-rearm.py`.
Their exact driver text is retained beside this note as `.py.txt` evidence, and each driver retains observable product output in its corresponding log.
All use disposable operational homes under the worktree, real installed tools, and actual upstream reads; no GitHub mutations, credential refreshes, fleet lifecycle, or pipeline control commands ran.
The usage retry scenario temporarily removes osascript from the child PATH while exposing symlinks to the other installed real executables; it does not replace the notifier or quota API with a fake.
Its initial setup attempts omitted basename and then ln from that PATH, so they never reached notification delivery. The PATH was corrected and the whole scenario re-driven successfully.
The rearm check seeds the owned serialized de-duplication record as disposable user data, then verifies a real below-threshold quota read removes the delivered key while a missing window retains its key.
The empty-approval live check uses real public human approvals from dmitrivMS and alexdima in the exact-login allowlist; the substantive real Copilot bot review remains admitted. The focused simulated regression separately covers empty approvals from bot accounts.

## Limits

No-CI monitor checks require an existing isolated no-mistakes CI-monitor run or authority to initialize one. No such isolated run was supplied, and this assigned test phase explicitly forbids initializing or controlling another pipeline. Focused execution uses fake no-mistakes and cannot prove that upstream integration live. The outer executor must arrange isolated zero-check and no_ci runs for live confirmation, or explicitly accept the remaining evidence gap.

The CoreGraphics Screen Capture preflight returned `screen_capture_authorized=false` (exit 0). Actual osascript accepted notifications and the warner persisted delivery keys, but no banner screenshot is available. To capture native visual evidence, grant Screen Recording permission to the hosting terminal/agent in macOS System Settings > Privacy & Security > Screen Recording, then re-run the notification scenario. No permission or global configuration was changed.

## House policy live confirmation

A final inline Python driver created a disposable `.gate-policy-*` operational home under the worktree and ran real `bash bin/fm-contributions.sh poll` and `pending` twice against basecamp/omarchy PR 13212. With no new review-bot allowlist, the default house automated-reviewer policy admitted actual Greptile findings and excluded author comments. Setting only the existing `config/contributions-author-marker` to `Agreed` then admitted the actual author inline reply with `directive:true`. Existing bot findings remained admitted, and the persisted verdict remained null. The driver exited 0 and removed the home. See `house-policy-live.log`. Final `git status --short` was empty.
