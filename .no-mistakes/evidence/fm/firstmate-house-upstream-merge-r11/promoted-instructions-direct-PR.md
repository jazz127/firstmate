Your scout task has been promoted to a ship task, mode=direct-PR. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Preserve worktree cleanliness while collecting proof.

## Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/promote-direct-pr` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/promote-direct-pr --`.

4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=direct-PR.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
This replaces the scout rule limiting outside-worktree writes to the report and status file.
Keep project edits inside this worktree; keep proof and scratch output outside it, under `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/.test-phase/tmp/fm-lab.JapAko/data/promote-direct-pr/` or a temporary directory.
Outside the worktree, write only that task material and the status and steering-inbox records authorized below.
Leave the worktree clean before reporting done.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to the default branch (push only your `fm/promote-direct-pr` branch). Never merge a PR.
Never end a turn on an announced next step: take it in the same turn with your tools instead of stopping on the announcement, or report `paused:`/`blocked:` with the reason.
Drive your own validation and delivery path: beyond the handoff your Definition of done names, wait for no approval you did not request through `needs-decision`.

# Definition of done
Delivery contract: mode=direct-PR
Ship branch: fm/promote-direct-pr
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.

The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR through the applicable publication path below; it must be ready for review, not a draft.
Before committing, and again immediately before handing a commit to a pipeline or publishing it, run `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/bin/fm-pr-body-preflight.sh --scratch "$(pwd -P)"`.
It must print `scratch preflight ok`; a refusal names the scratch path to remove from the deliverable.
Before publishing or editing a PR body you author, save its complete proposed text in a draft file and run `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/bin/fm-pr-body-preflight.sh <draft-body-file> "$(pwd -P)" "/tmp/fm-promote-direct-pr"`.
The command applies the same evidence validation used when Firstmate reads the published body; fix any refusal before sending the body, and require its `evidence preflight ok` result.
If it reports `contradictory driven-scenario results`, keep your own honest results as the single statement and correct or remove the contradicting generated line before publication; never weaken a claim to pass.
For an upstream repository the fleet does not own, do not run `gh-axi pr create` directly. Use the guarded publisher:
1. Set the target repository, title, one-line summary file, target base, proposed body file, and pushed head (`OWNER:BRANCH`).
2. Run `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/bin/fm-upstream-prior-art.py scan --repo <OWNER/REPO> --title <TITLE> --summary-file <SUMMARY_FILE> --record /tmp/fm-promote-direct-pr/prior-art.json --base <BASE>`.
3. Review every recorded candidate, write one distinct/overlaps verdict and reason per candidate to a decisions JSON file, then run `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/bin/fm-upstream-prior-art.py decide --record /tmp/fm-promote-direct-pr/prior-art.json --decisions-file <DECISIONS_FILE>`.
4. Run `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/bin/fm-upstream-prior-art.py publish --repo <OWNER/REPO> --title <TITLE> --summary-file <SUMMARY_FILE> --record /tmp/fm-promote-direct-pr/prior-art.json --base <BASE> --body-file <BODY_FILE> --head <OWNER:BRANCH>`; it refuses a missing, stale, incomplete, or unresolved receipt immediately before the forge write.
For a repository the fleet owns, the ordinary `gh-axi` direct-PR path remains unchanged.
Before you report done, read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh-axi pr ready <number>`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append `done [at=<epoch>]: PR {url}` to the status file and stop.
That `done:` is accepted only when this copy's HEAD - your latest commit - is pushed to your PR branch; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.

Evidence required before reporting a fix as validated:
- Name the reproduction artifact or exact command that fails before the change and passes after it through the same path users exercise.
- Each failure mode claimed in a before/after validation table must have a non-zero pre-change observation or be marked not exercised by the sample.
- State how many cases scanned and how many exhibited the defect.
- A sample that cannot exhibit the defect is not evidence for the fix; describe all-zero rows as not exercised, not as validation.
