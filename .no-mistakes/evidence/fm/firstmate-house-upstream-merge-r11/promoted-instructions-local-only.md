Your scout task has been promoted to a ship task, mode=local-only. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Preserve worktree cleanliness while collecting proof.

## Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/promote-local-only` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/promote-local-only --`.

4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=local-only.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
This replaces the scout rule limiting outside-worktree writes to the report and status file.
Keep project edits inside this worktree; keep proof and scratch output outside it, under `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/.test-phase/tmp/fm-lab.JapAko/data/promote-local-only/` or a temporary directory.
Outside the worktree, write only that task material and the status and steering-inbox records authorized below.
Leave the worktree clean before reporting done.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to any remote and never open a PR. Work only on your `fm/promote-local-only` branch; firstmate handles the merge into local `main`.
Never end a turn on an announced next step: take it in the same turn with your tools instead of stopping on the announcement, or report `paused:`/`blocked:` with the reason.
Drive your own validation and delivery path: beyond the handoff your Definition of done names, wait for no approval you did not request through `needs-decision`.

# Definition of done
Delivery contract: mode=local-only
Ship branch: fm/promote-local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/promote-local-only`. Do NOT push, do NOT open a PR, do NOT merge.
A `done:` is accepted when the named head is on this project's shared local branch, not only on a detached copy; the check tests that head, not merely that a branch moved.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done [at=<epoch>]: ready in branch fm/promote-local-only` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.
Before committing, and again immediately before handing a commit to a pipeline or publishing it, run `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/bin/fm-pr-body-preflight.sh --scratch "$(pwd -P)"`.
It must print `scratch preflight ok`; a refusal names the scratch path to remove from the deliverable.

Evidence required before reporting a fix as validated:
- Name the reproduction artifact or exact command that fails before the change and passes after it through the same path users exercise.
- Each failure mode claimed in a before/after validation table must have a non-zero pre-change observation or be marked not exercised by the sample.
- State how many cases scanned and how many exhibited the defect.
- A sample that cannot exhibit the defect is not evidence for the fix; describe all-zero rows as not exercised, not as validation.
