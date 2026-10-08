## Summary

Carries [upstream Firstmate PR 6023](https://github.com/kunchenguid/firstmate/pull/6023) unchanged into the fork's house feature branch. The three upstream commits were cherry-picked with their original authorship; each stable patch ID matches its upstream commit. This brings the fix for upstream issue 5545 to the house line now.

## Local validation

- `shellcheck --norc --exclude=SC1091,SC2034,SC2153,SC2329 bin/fm-brief.sh bin/fm-promote.sh tests/fm-brief.test.sh tests/fm-task-delivery.test.sh` passed.
- `bash bin/fm-test-run.sh tests/fm-brief.test.sh tests/fm-task-delivery.test.sh` passed (2 suites).
- `bash bin/fm-lint.sh` and `git diff --check origin/housefeature/brief-anti-stall...HEAD` passed.

evidence-artifact: /tmp/fm-hf-brief-antistall-pick/upstream-pr-6023.txt
evidence-command: gh-axi pr view 6023 -R kunchenguid/firstmate --full
evidence-captured: 2026-10-01T06:49:40Z
