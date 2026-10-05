Your scout task has been promoted to a ship task, mode=no-mistakes. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Preserve worktree cleanliness while collecting proof.

## Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/promote-no-mistakes` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/promote-no-mistakes --`.

4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=no-mistakes.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
This replaces the scout rule limiting outside-worktree writes to the report and status file.
Keep project edits inside this worktree; keep proof and scratch output outside it, under `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/.test-phase/tmp/fm-lab.JapAko/data/promote-no-mistakes/` or a temporary directory.
Outside the worktree, write only that task material and the status and steering-inbox records authorized below.
Leave the worktree clean before reporting done.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to the default branch. Never merge a PR.
Never end a turn on an announced next step: take it in the same turn with your tools instead of stopping on the announcement, or report `paused:`/`blocked:` with the reason.
Drive your own validation and delivery path: beyond the handoff your Definition of done names, wait for no approval you did not request through `needs-decision`.

The no-mistakes ask-user escalation below supersedes the scout rule 6 escalation shape.
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/.test-phase/tmp/fm-lab.JapAko/data/promote-no-mistakes/nm-<run>-findings.txt`, then report the gate with
   `needs-decision [at=<epoch>] [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/.test-phase/tmp/fm-lab.JapAko/data/promote-no-mistakes/nm-<run>-findings.txt`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.

# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: fm/promote-no-mistakes

The task is complete only when committed on your branch.
When you believe it is complete, append `done [at=<epoch>]: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
That first `done:` is the handoff that starts the pipeline, which owns the push; it is not a request to push from this copy.

Before committing, and again immediately before handing a commit to a pipeline or publishing it, run `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/bin/fm-pr-body-preflight.sh --scratch "$(pwd -P)"`.
It must print `scratch preflight ok`; a refusal names the scratch path to remove from the deliverable.
You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When a run targets a base with no configured check workflows, first verify that the base really has no checks, then start a new run with `--skip ci` so its CI monitor cannot wait forever.
The fork's `house` base has a real check workflow; do not skip CI there or on any other base with checks.
Reattach without flags as usual.
When starting no-mistakes, pass `--intent` as only this brief's `## Captain's intent` subsection body, not its heading, plus any later words the captain actually said.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked `[captain] `, excluding that metadata prefix; never copy its mixed `# Task` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include `## Firstmate spec`, later Firstmate build constraints, or your own decisions and tradeoffs.
The `--intent` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into `--intent` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich `--intent` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Any claim in `--intent` of live, verified, external, independently confirmed, or real-account evidence must name the artifact read, the exact command that produced it, and when it was captured; publication refuses such a claim if any of those are missing or the artifact cannot be read.
Keep each cited artifact at a path the supervising home can open, inside this worker's worktree or its task temp directory.
This boundary proves that the claim is checkable, not that it is true; Firstmate must read the artifact before relaying its evidence label.
Follow the brief's `# Evidence provenance` section for evidence claims, metadata format, and synthetic or offline labels in the PR body.
Do not hand-edit code, commit, or fix pipeline findings yourself while a run is active - the pipeline applies those fixes; the published PR description correction below is limited to that description.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call instead of sitting in one blocking hold your harness will kill, and read its return when it finishes.
Declare that wait using the brief's status-reporting rule before waiting on the backgrounded drive call.
Where a harness's own command limit is not established, assume it bounds commands and use that same backgrounded shape.
For a base with CI, only a drive call's return reports the green PR: `no-mistakes axi status` shows progress but never reports `checks-passed` while the ci step is still monitoring the PR for merge, so never wait on a status poll for the next gate or outcome.
Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - reattach at once by re-running `no-mistakes axi run` without flags, backgrounded the same way; for a base with CI, once checks are green it returns `checks-passed` immediately, and if it refuses because no run is active, read the finished outcome from `no-mistakes axi status`.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.
Before publishing or editing a PR body you author, save its complete proposed text in a draft file and run `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/bin/fm-pr-body-preflight.sh <draft-body-file> "$(pwd -P)" "/tmp/fm-promote-no-mistakes"`.
The command applies the same evidence validation used when Firstmate reads the published body; fix any refusal before sending the body, and require its `evidence preflight ok` result.
If it reports `contradictory driven-scenario results`, keep your own honest results as the single statement and correct or remove the contradicting generated line before publication; never weaken a claim to pass.
The no-mistakes PR step generates and publishes its own body, so check its exact forge readback immediately after each publication or body update and before the CI-ready `done:` report:
`/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/bin/fm-pr-body-preflight.sh --gh-url <PR URL> "/tmp/fm-promote-no-mistakes/pr-body-readback.md" "$(pwd -P)" "/tmp/fm-promote-no-mistakes"`.
That command uses `gh-axi` to read the complete published body into the task temp file and runs the same evidence validator; do not treat a passing draft-body check as proof that the published body passed.
If it refuses, correct the description only in that file while preserving the pipeline attestation comment verbatim, preflight the corrected draft with the command above without `--gh-url`, then publish only the description with `gh-axi pr edit <number> -R <owner/repo> --body-file /tmp/fm-promote-no-mistakes/pr-body-readback.md`.
Read the body back with `--gh-url` and repeat until the published text reports `evidence preflight ok`.
Do not append the CI-ready `done:` while the published body fails this check.
The pipeline has no pre-publication body hook here; this readback check is required until that separate tool gains one.
Before starting /no-mistakes for an upstream repository the fleet does not own, complete the prior-art gate. For a repository the fleet owns, skip this upstream-only preflight.
1. Run `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/bin/fm-upstream-prior-art.py scan --repo <OWNER/REPO> --title <TITLE> --summary-file <SUMMARY_FILE> --record /tmp/fm-promote-no-mistakes/prior-art.json --base <BASE>`.
2. Review every candidate, record one distinct/overlaps verdict and reason per candidate, and run `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/bin/fm-upstream-prior-art.py decide --record /tmp/fm-promote-no-mistakes/prior-art.json --decisions-file <DECISIONS_FILE>`.
3. Immediately before starting /no-mistakes, run `/Users/jarad/.no-mistakes/worktrees/119cd7a6b9a4/01M455W9R326CJ1BPJVJB6ADKS/bin/fm-upstream-prior-art.py check --repo <OWNER/REPO> --title <TITLE> --summary-file <SUMMARY_FILE> --record /tmp/fm-promote-no-mistakes/prior-art.json --base <BASE>`; do not start the run if it refuses.
The later upstream PR publication must use the same current receipt at its forge-write boundary; an automatic PR creation path that cannot perform that check must not be used.

For a base with checks, including `house`, after /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh-axi pr ready <number>`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
For a base with checks, append `done [at=<epoch>]: PR {url} checks green` and stop.
For a base verified to have no check workflows where this run used `--skip ci`, wait for the pipeline's passed-with-skips outcome, confirm the PR is not a draft, and append `done [at=<epoch>]: PR {url} ready for review (CI skipped: base has no configured check workflows)` without claiming checks are green.
You are finished.
That CI-ready `done:` is accepted only when this copy's HEAD - your latest commit - is one the /no-mistakes run pushed, so commit nothing after the run; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.

Evidence required before reporting a fix as validated:
- Name the reproduction artifact or exact command that fails before the change and passes after it through the same path users exercise.
- Each failure mode claimed in a before/after validation table must have a non-zero pre-change observation or be marked not exercised by the sample.
- State how many cases scanned and how many exhibited the defect.
- A sample that cannot exhibit the defect is not evidence for the fix; describe all-zero rows as not exercised, not as validation.
