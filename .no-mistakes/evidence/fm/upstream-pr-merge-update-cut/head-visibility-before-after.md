# Delayed head visibility regression

Synthetic/offline: actual merge-helper CLI with fake gh/gh-axi; no GitHub writes. Oracle: required immediate draft refusal, no check-retry advice, and released locks. Before: dc5eedcf; after: 8bdac6b5.

## before

`bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/6190 --update-branch`

Initial snapshot: green BEHIND PR; accepted bound update; old SHA remains visible with draft=true and ci pending.

Exit: 1; full preflights: 1; task-control lock remains: False; away-authority lock remains: False

### stdout

```text
armed: state/task-x1.check.sh
{"message":"Updating pull request branch."}
```

### stderr

```text
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: never, grace 300s).
●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
●  This is a supervision warning only; the guarded operation WILL still run.
●  repair missing watcher supervision according to the session-start block for this harness; do not use shell &.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
verified: https://github.com/example/repo/pull/6190 is open and mergeable, with every unwaived required check reported and every unwaived check green at head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
error: https://github.com/example/repo/pull/6190 was updated but its new head is not visible yet; run the merge again once its checks pass
```

### Synthetic GitHub command transcript

```text
pr view https://github.com/example/repo/pull/6190 --json headRefOid -q .headRefOid
pr view https://github.com/example/repo/pull/6190 --json state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup
api repos/example/repo/branches/main
api --paginate repos/example/repo/rules/branches/main
api --method PUT repos/example/repo/pulls/6190/update-branch -f expected_head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
pr view https://github.com/example/repo/pull/6190 --json headRefOid -q .headRefOid
pr view https://github.com/example/repo/pull/6190 --json headRefOid -q .headRefOid
pr view https://github.com/example/repo/pull/6190 --json headRefOid -q .headRefOid
pr view https://github.com/example/repo/pull/6190 --json headRefOid -q .headRefOid
pr view https://github.com/example/repo/pull/6190 --json headRefOid -q .headRefOid
```

## after

`bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/6190 --update-branch`

Initial snapshot: green BEHIND PR; accepted bound update; old SHA remains visible with draft=true and ci pending.

Exit: 1; full preflights: 2; task-control lock remains: False; away-authority lock remains: False

### stdout

```text
armed: state/task-x1.check.sh
{"message":"Updating pull request branch."}
```

### stderr

```text
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no watcher has a fresh beacon (last beat: never, grace 300s).
●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.
●  This is a supervision warning only; the guarded operation WILL still run.
●  repair missing watcher supervision according to the session-start block for this harness; do not use shell &.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
verified: https://github.com/example/repo/pull/6190 is open and mergeable, with every unwaived required check reported and every unwaived check green at head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
error: refusing to merge https://github.com/example/repo/pull/6190
  - the pull request is a draft
  - check 'ci' is not green
error: these checks are not green: ci
```

### Synthetic GitHub command transcript

```text
pr view https://github.com/example/repo/pull/6190 --json headRefOid -q .headRefOid
pr view https://github.com/example/repo/pull/6190 --json state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup
api repos/example/repo/branches/main
api --paginate repos/example/repo/rules/branches/main
api --method PUT repos/example/repo/pulls/6190/update-branch -f expected_head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
pr view https://github.com/example/repo/pull/6190 --json state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup
api repos/example/repo/branches/main
api --paginate repos/example/repo/rules/branches/main
```
