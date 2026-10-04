# Live supervision validation

The installed Claude Code 2.1.285 ran the production branch prompt and report commands using the existing login, with private lab homes and a private fm-lab tmux socket. No engine, report command, outcome store, drain, or current-state reader was replaced. Task records and terminal endpoints were disposable inputs.

The eight-case engine checked every task with `bin/fm-crew-state.sh`, recorded every outcome, and emptied its granted wake queue.

| Notification / action | Actual verdict | Silent |
| --- | --- | --- |
| echo | routine | true |
| scheduled | routine | true |
| declared | routine | true |
| hold | routine | true |
| changed | routine | false |
| failure | captain | false |
| finished | captain | false |
| uncertain | routine | false |
| action | routine | false |
| echo-write | routine | false |
| echo-of-branch-written-pause | routine | true |

## Real write followed by its own echo

The first turn appended the new pause under the task lease and recorded visible routine sequence 2. The resumed conversation saw its own pause unchanged and recorded silent routine sequence 3. Both rows have the same status provenance. Both granted notifications were acknowledged.

Persisted status:
```text
working: checking the release window
paused: waiting for the registered release window
```

## Action beyond an unchanged pause

The engine corrected the backlog under its backlog lease while leaving the pause terms unchanged. Its outcome is non-silent.

Persisted backlog:
```markdown
# Backlog

## In Progress

- [ ] action - Release check
  - Activity: paused
  - Pause: registered release window
```

## Lost-notification recovery

Direct append and drain calls exercised current readiness; legacy readiness repaired by drain, silent append, and visible append; missing readiness; an out-of-range readiness sequence; and a symlink readiness record. Every case preserved history, restored only non-silent coverage, surfaced uncovered completions/failures once, and left already-covered completions quiet.

First main-drain output for current readiness:
```text
STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
mixed failed: later failure has no visible outcome
silent-done done: completion has only a silent echo
silent-failed failed: failure has only a silent echo
```

Second drain:
```text
(empty)
```

Readiness after each scenario:
- current: `visible-only-v1:5`; latest visible mixed-task coverage retained, silent-only coverage absent.
- legacy-drain: `visible-only-v1:5`; latest visible mixed-task coverage retained, silent-only coverage absent.
- legacy-silent-append: `visible-only-v1:6`; latest visible mixed-task coverage retained, silent-only coverage absent.
- legacy-visible-append: `visible-only-v1:6`; latest visible mixed-task coverage retained, silent-only coverage absent.
- missing: `visible-only-v1:5`; latest visible mixed-task coverage retained, silent-only coverage absent.
- invalid: `visible-only-v1:5`; latest visible mixed-task coverage retained, silent-only coverage absent.
- symlink: `visible-only-v1:5`; latest visible mixed-task coverage retained, silent-only coverage absent.

## Recovery replay and captain guard

Startup replay emitted the visible recovery result and omitted the silent registered-pause reconfirmation:
```text
BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):
{"seq":2,"epoch":1791115292,"task":"recovered","wake":"","verdict":"routine","summary":"Pause cleared; work resumed.","silent":false,"statusEndpoint":0,"statusIdent":"-"}
```

The attempted silent captain append was rejected without changing history:
```text
error: silent outcomes must have the routine verdict
```

The valid captain completion remained unread behind the presentation barrier.

## Validation scope and cleanup

Also ran the focused wake-drain outcome-backstop regression file and the generated-prompt, silence-replay, and captain-barrier behavioral selectors from the branch-supervision tests. No full-suite run, lint, static analysis, push, or pipeline-control command ran.

Initial lab setup attempts were corrected for private file paths, trusted fixture activity provenance, and the new report-turn token on tmux resume. Final live scenarios all passed. All private tmux servers and lab homes were removed. The worktree retains no source changes. This is a CLI and model-instruction surface; the product evidence is the actual reports, persisted state, and recovery output.
