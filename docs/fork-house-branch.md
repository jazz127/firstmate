# Fork house branch

This guide describes the operator workflow for running a Firstmate fork with a private house delta.
The [`updatefirstmate` skill](../.agents/skills/updatefirstmate/SKILL.md) owns the update procedure, and [configuration.md](configuration.md#firstmate-runtime-branch-git-config-firstmateruntimebranch) owns runtime-branch resolution.

## Branch layout

Keep the fork's `main` as a straight mirror of upstream `main`.
Keep the fork's `main` identical to upstream `main`, with no house changes or other fork-owned commits on the mirror.
The fork's GitHub default branch is `house`, so new pull requests default to the fleet integration line rather than the upstream mirror.
The `house` branch is the line the fleet runs, with local operator changes layered on top.
Configure the primary checkout's local `house` branch to track `jazz127/house`, and set `firstmate.runtimeBranch=house` in that repository's Git config.
The setting selects the primary runtime branch; its branch tracking configuration supplies the update remote and merge ref.

## Watching the quota-axi house line

The quota-axi view uses quota-axi's read-only TUI report as its body, with the fleet's `jazz127/house` commit and subject, the `quota-axi` executable on `PATH`, and the refresh time and interval in a closing block.
Run `bin/fm-quota-tab.sh once` to print one frame, or `bin/fm-quota-tab.sh` (the default `loop` mode) in a terminal tab to keep the fleet's house line and provider headroom in view.
The loop refreshes every 300 seconds by default; `FM_QUOTA_TAB_INTERVAL` changes that interval.

Bring upstream changes to the fleet by merging upstream `main` into `house`.
Do not rebase `house` onto upstream: preserving merge history keeps the house integration visible, leaves upstream-bound commits extractable, and preserves the head identity used by gate attestations.

## House features

A house feature is anything we build for ourselves on our own line, whether the captain asked for it or firstmate found it.
Every house feature has a durable `housefeature/<name>` branch cut from the fork's `main`.
The [`housefeature-cut.yml`](../.github/workflows/housefeature-cut.yml) workflow cuts that branch automatically when a pull request merges into `house`, capturing the merged pull request head instead when the change does not apply cleanly to `main`.
That branch gives the feature a stable name, keeps it findable, and makes it straightforward to offer without relying on a disposable task branch.
Task branches are working branches and may be deleted once their feature is captured on its durable branch.
A contributed house feature is a house feature the captain chose to submit and that has landed in upstream `main`.

## House board

Run `bin/fm-house-board.sh build` from the Firstmate home to regenerate the read-only house board in one command.
Set `FM_HOME` when the operating home differs from the code checkout, for example `FM_HOME=/Users/jarad/firstmate bin/fm-house-board.sh build`.
The command reads `data/house-line.md` in that home and current GitHub facts through `gh-axi`, writes `.lavish/house-board.json` and `.lavish/house-board.html`, and opens the page with Lavish.
It does not label, push, comment, submit, or register an answer source.
The page filters immediately by project, label, state, landing or offering posture, historical status, register mismatch, age, and name or description text; it sorts by project, age, or state.
The counts update with the visible features.
Each project card compares the current fork `house` tip with upstream `main`, reports the ahead and behind counts, and flags a fork `main` tip that differs from upstream.
Each feature row shows its durable branch, commits, current house membership, label, pull request states, and age.
House membership comes from live commit ancestry or a fork pull request merge commit still reachable from today's `house` tip, never from the register's merged heading alone.
Rows marked `register only` or `fork only` expose a disagreement between the two sources for reconciliation.
The board is a snapshot until the next build; filters do not make network requests.

## Contributing a house feature upstream

Firstmate house-feature tasks should be spawned from the fork-origin run clone at `/Users/jarad/fm-fork-runs/firstmate`, whose `origin` is `jazz127/firstmate` and whose checked-out default branch is `house`.
That clone has upstream as a second remote for refreshing from upstream `main`, and its pipeline runs open pull requests against the fork's `house`.
The primary home's checkout keeps `origin` at upstream and serves upstream candidates, whose pipeline runs open pull requests against upstream.
Before the fork-origin run clone existed, Firstmate house features shipped without the pipeline because an upstream-origin run could not target the fork-only `house` branch.

Before directing any lane to change a pull request branch, read that pull request's current head ref and head commit from the forge, and check its head repository before choosing a remote.
The branch name in fleet records, a previous fork copy, or an older note is not authority; if it differs from the forge, correct the assignment before work starts.
Check the pipeline's own status and the lanes already assigned to that branch before steering another lane.
An existing pipeline run or lane keeps ownership until it is explicitly handed over through the supported pipeline flow; never edit ownership records or hand-edit the branch to escape a blocked state.

An upstream contribution branch must remain a clean diff from upstream `main`.
Never merge `house` or another fork-only line into a branch that backs an upstream pull request, even to fix conflicts on a fork pull request.
The fork and upstream pull requests can share one head branch while targeting different bases, so a merge from `house` into that shared head would carry fork-only commits into the upstream contribution.
Keep our delivery on its durable `housefeature/<name>` branch and its own fork pull request, with the upstream contribution reviewed against upstream `main`.

Refresh a contribution branch only by merging upstream `main` into it, including when conflicts or CI prompt a refresh; never rebase it.
Rebasing rewrites the attested head, which upstream's gate rejects.
Validate the exact final head that will be offered with one pipeline run to renew a stale attestation, and never hand-edit the attestation.
Open an upstream pull request only when the captain asks for that house feature by name.
Only the captain contacts upstream, including opening or commenting on an upstream pull request.
Before opening an upstream pull request in a repository the fleet does not own, run the prior-art scan in `bin/fm-upstream-prior-art.py`, review every candidate, and record an explicit verdict.
The scan uses forge search for open pull requests and issues and recent closed unmerged pull requests, driven by linked issues and keywords from the title, summary, and changed symbols, and checks changed-file overlap only on the returned candidates.
It reads the most relevant hits for each query within a fixed request and time budget; a scan that reaches either bound is recorded as incomplete and cannot be decided or published.
Queries beyond the per-scan query cap and hits beyond the most relevant page are not read; the receipt discloses that truncation with read and total counts and any dropped queries, `decide` refuses a record without that disclosure, and the published `Prior art checked` section states that search coverage was bounded.
A duplicate with different wording or files can evade those keyword, changed-file, and linked-issue matches.
A `none-found` verdict requires no candidates; a `distinct` verdict requires a one-line reason for each candidate; an `overlaps` verdict requires the captain's recorded decision before publication.
Use that command's `publish` operation for upstream creation so its receipt check is immediately before the forge write and the generated pull request body credits overlapping authors in a `Prior art checked` section.
It refuses missing receipts, a changed branch head or diff, a changed title or summary, scans over one hour old, and unresolved overlaps.
The one-hour limit applies before the push and the forge write; the post-publication registration and done checks verify the published head without it, and accept a published head equal to the scanned head or one the forge reports as strictly ahead of it, so pipeline auto-fix commits pass while a force-push or rewrite is refused.
The command's `check` operation is the reusable gate for a Bosun workflow; it does not depend on Bosun's code.
An automatic PR creation path that bypasses this gate must not be used for an upstream target.
The task worktree's pre-push hook refuses a push to a different GitHub repository without a fresh receipt matching the repository, pushed head, and diff.
The no-mistakes pipeline pushes from a separate checkout that is not covered by that hook, so its registration and ready-signal receipt checks remain post-publication backstops.
Direct PR creation after a fork push can also bypass the worker pre-push hook, leaving those same registration and ready-signal checks as post-publication backstops.
An upstream repository is contacted only on the captain's explicit order, which is the primary control for that accepted containment.
The command header owns its invocation and receipt format.

On the fork's pull requests, use these labels to record a house feature's progression: `upstream-candidate`, `upstream-offered`, `contributed-house-feature`, `house-only`, and `historical`.
The private house-feature register maintained with the operator's fleet records is the current source of truth for the features and their disposition.

## Rebuilding the house line

The `house` branch consists of upstream `main` plus the house-feature merges we chose to include.
To rebuild it, record its exact previous tip, reset `house` to `main`, and merge back only the wanted `housefeature/` branches.
Push the rebuilt branch with `--force-with-lease` against that exact previous tip.
A dropped feature remains recoverable while its durable branch or commits still exist.

Nothing polls house-feature branches, and no recurring check watches upstream.
A house feature may remain historical indefinitely without becoming debt.

## Inspecting the private delta

Fetch the fork's `jazz127` remote and prune stale remote refs, then inspect the commits on the house line beyond the upstream mirror:

```sh
git fetch origin jazz127 --prune
git log --oneline origin/main..jazz127/house
```

The live list of personal commits is kept privately with the operator's fleet records.

Secondmates follow the primary's exact commit during update convergence.
Dirty or diverged secondmate homes are skipped and reported for reconciliation under the [`updatefirstmate` contract](../.agents/skills/updatefirstmate/SKILL.md).
