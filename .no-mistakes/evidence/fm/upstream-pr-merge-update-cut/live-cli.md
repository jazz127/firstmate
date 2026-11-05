# Live CLI checks

Actual helper and installed GitHub CLI; no mock tools. Disposable FM_HOME under the run worktree. Only read-only GitHub access is permitted in this check.

## Reject valued update consent

`bin/fm-pr-merge.sh task-x1 https://github.com/kunchenguid/firstmate/pull/6330 --update-branch=yes`

Exit: 2; expected observation: True

```text
error: --update-branch takes no value
```

## Reject update consent on GitLab

`bin/fm-pr-merge.sh task-x1 https://gitlab.example/group/project/-/merge_requests/7 --update-branch`

Exit: 2; expected observation: True

```text
error: --update-branch applies only to GitHub
```

## Reject malformed head pin

`bin/fm-pr-merge.sh task-x1 https://github.com/kunchenguid/firstmate/pull/6330 --expected-head bad`

Exit: 2; expected observation: True

```text
error: --expected-head requires a full lowercase commit sha
```

## Live GitHub preflight refuses immutable mismatched pin

`bin/fm-pr-merge.sh task-x1 https://github.com/kunchenguid/firstmate/pull/6330 --expected-head 0000000000000000000000000000000000000000`

Exit: 1; expected observation: True

```text
armed: state/task-x1.check.sh
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: never, grace 300s).
●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
●  This is a supervision warning only; the guarded operation WILL still run.
●  repair missing watcher supervision according to the session-start block for this harness; do not use shell &.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
error: refusing to merge https://github.com/kunchenguid/firstmate/pull/6330
  - check 'Full suite' is not green
  - check 'PR must be raised via no-mistakes' is not green
  - the live head is "da0b5315ea51f705bd08bde8de97966ee205e4d7", not the expected head 0000000000000000000000000000000000000000
error: these checks are not green: Full suite, PR must be raised via no-mistakes
```

Remaining locks: []

Disposable lab removed after the command results were collected.
