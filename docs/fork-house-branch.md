# Fork house branch

This guide describes the operator workflow for running a Firstmate fork with a private house delta.
The [`updatefirstmate` skill](../.agents/skills/updatefirstmate/SKILL.md) owns the update procedure, and [configuration.md](configuration.md#firstmate-runtime-branch-git-config-firstmateruntimebranch) owns runtime-branch resolution.

## Branch layout

Keep the fork's `main` as a straight mirror of upstream `main`.
Keep the fork's `main` identical to upstream `main`, with no house changes or other fork-owned commits on the mirror.
The fork's GitHub default branch is `house`, so new pull requests default to the fleet integration line rather than the upstream mirror.
The `house` branch is the line the fleet runs, with local operator changes layered on top.
Each house feature has a durable `housefeature/<name>` integration branch, and each work round starts on a separate `fm/<task>` branch from it.
The work round first merges into `housefeature/<name>` through a pull request; a separate pull request then merges that durable branch into `house`.
The normal feature branch starts at the fork's `main`; a feature marked `house-only` at intake may start at `house`.
Configure the primary checkout's local `house` branch to track `jazz127/house`, and set `firstmate.runtimeBranch=house` in that repository's Git config.
The setting selects the primary runtime branch; its branch tracking configuration supplies the update remote and merge ref.

## Merging into house

Every pull request into `house`, upstream syncs and house features alike, lands as a true merge commit, never a squash or a rebase.
A merge commit keeps upstream's commits as ancestors of `house`, so later upstream syncs and house-feature merges only carry what is new.
A squash drops that ancestry, and every branch cut from upstream then carries already-integrated upstream commits back into `house` as conflicts.

Each fork with a `house` branch carries an active branch ruleset on `refs/heads/house` that enforces this: a `pull_request` rule whose `allowed_merge_methods` is `["merge"]`, plus `non_fast_forward` and `deletion` rules.
GitHub then refuses a squash or rebase merge, a direct push, a force push, and deletion of `house`.
Apply it to a new house fork once, replacing `<owner>/<repo>`:

```sh
gh api -X POST repos/<owner>/<repo>/rulesets --input - <<'JSON'
{"name": "house: merge commits only", "target": "branch", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["refs/heads/house"], "exclude": []}},
 "rules": [
  {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"],
   "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false,
   "require_code_owner_review": false, "require_last_push_approval": false,
   "required_review_thread_resolution": false}},
  {"type": "non_fast_forward"},
  {"type": "deletion"}]}
JSON
```

Every pull request into a durable `housefeature/<name>` branch also lands as a merge commit, so the branch keeps `main` as an ancestor and later syncs and contributions carry only the feature.
Apply the matching ruleset on `refs/heads/housefeature/**` once per house fork; besides merge-commits-only, it refuses deletion and force pushes of every durable branch:

```sh
gh api -X POST repos/<owner>/<repo>/rulesets --input - <<'JSON'
{"name": "housefeature: merge commits only, never delete", "target": "branch", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["refs/heads/housefeature/**"], "exclude": []}},
 "rules": [
  {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"],
   "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false,
   "require_code_owner_review": false, "require_last_push_approval": false,
   "required_review_thread_resolution": false}},
  {"type": "non_fast_forward"},
  {"type": "deletion"}]}
JSON
```

`bin/fm-pr-merge.sh` reads the base branch's allowed methods when no method is named, so it merges into `house` with a merge commit; into a `housefeature/*` base it always passes `--merge` and refuses a caller-named squash or rebase; its header owns that choice.
Merge a pull request into either base by hand only with `--merge`.

## Watching the quota-axi house line

The quota-axi view uses quota-axi's read-only TUI report as its body, with the fleet's `jazz127/house` commit and subject, the `quota-axi` executable on `PATH`, and the refresh time and interval in a closing block.
Run `bin/fm-quota-tab.sh once` to print one frame, or `bin/fm-quota-tab.sh` (the default `loop` mode) in a terminal tab to keep the fleet's house line and provider headroom in view.
The [script header](../bin/fm-quota-tab.sh) owns clone selection, including the fallback when `FM_HOME` is unset, and refresh settings.

Bring upstream changes to the fleet by merging upstream `main` into `house` through a pull request that lands as a merge commit (see [Merging into house](#merging-into-house)).
Do not rebase `house` onto upstream: preserving merge history keeps the house integration visible, leaves upstream-bound commits extractable, and preserves the head identity used by gate attestations.

## House features

A house feature is anything we build for ourselves on our own line, whether the captain asked for it or firstmate found it.
Choose a stable feature name at intake and scaffold each ship brief with `--house-feature <name> --branch-base main`, keeping the worker's ordinary `fm/<task>` branch prefix.
The generated first action uses `bin/fm-housefeature-start.sh` in the fork-origin worktree: it fetches the fork's `main`, creates `housefeature/<name>` at that commit only when absent, and checks out `fm/<task>` from the durable branch.
The GitHub create-ref call carries an existing base commit and refuses if another task has already created the durable branch; it cannot replace an existing head.
When that branch already exists, the same command fetches it and starts a new `fm/<task>` branch from its current head; it never merges `main`.
Use a new round-suffixed task id such as `<name>-r2` for follow-up work and pass the same stable `<name>` to `--house-feature`; the task id and durable branch name serve different purposes.
The worker's first pull request targets `housefeature/<name>` (`no-mistakes axi run --base-branch housefeature/<name>` or `gh-axi pr create --base housefeature/<name>`) and merges with `--merge`.
After it merges, firstmate steers the same live worker, without a new pipeline run, to open the integration pull request with `gh-axi pr create --base house --head housefeature/<name>` from the fork checkout.
The worker reports that pull request with a `done` line, and firstmate does not tear the task down until it is open.
The fork's House CI workflow checks pull requests into `house` and into a `housefeature/*` base that already contains that workflow, such as a house-only branch cut from `house`.
A main-based feature cut from upstream `main` may have no workflow configured for its first pull request; verify the target branch's workflows and use the delivery pipeline's documented no-check path when none apply.
Repeat that pair of pull requests for a later work round when the feature should enter `house` again.
Keep a main-based feature clean for possible contribution and never merge `house` into the durable branch or its worker branch.
Refreshing from `main` is an explicit, deliberate step: when a round needs newer upstream code, merge the fork's `main` into its worker branch with `git merge origin/main` and resolve any conflict there before delivery.
If the pull request from `housefeature/<name>` conflicts with `house`, reconcile the conflicting house code in a separate pull request based on `house`, then merge the original feature pull request when it becomes mergeable.
When the captain marks a feature as never to be contributed, record that choice in the intake brief; the worker applies the existing `house-only` label to the integration pull request it opens from the durable branch into `house`.
For that exception, scaffold with `--house-feature <name> --branch-base house`; its first durable branch may depend on other house features, while later rounds still reuse that branch and refresh from `main` only by that explicit step.
Never delete or force-push a `housefeature/*` head after either pull request merges: the fork ruleset blocks both operations on `refs/heads/housefeature/**`, automatic branch deletion on merge is off, `fm-pr-merge.sh` refuses branch-deletion flags by default, and task teardown removes the worker worktree rather than the remote durable branch.
The [`housefeature-cut.yml`](../.github/workflows/housefeature-cut.yml) workflow remains a safety net for merged `house` pull requests whose heads still use other branch names; it leaves an existing durable branch untouched and skips a pull request already headed by `housefeature/<name>`.
The [`ship-landing` skill](../.agents/skills/ship-landing/SKILL.md) owns post-merge registration in the private house-feature register, including safety-net feature branches and the exclusion of plumbing.
A contributed house feature is a house feature the captain chose to submit and that has landed in upstream `main`.
The [Bosun guide](bosun.md) defines when an ordered Captain's Maneuver becomes an Admiral's Maneuver.

## House board

Run `bin/fm-house-board.sh build` from the Firstmate home to regenerate the read-only house board in one command.
Set `FM_HOME` when the operating home differs from the code checkout, for example `FM_HOME=/Users/jarad/firstmate bin/fm-house-board.sh build`.
The command reads `data/house-line.md` in that home and current GitHub facts through `gh-axi`, writes `.lavish/house-board.json` and `.lavish/house-board.html`, and opens the page with Lavish.
It does not label, push, comment, submit, or register an answer source.
The page filters immediately by project, label, state, landing or offering posture, historical status, register mismatch, age, and name or description text; it sorts by project, age, or state.
The counts update with the visible features.
The board separates plumbing from features using the helper-branch name patterns owned by [`bin/fm-house-board.py`](../bin/fm-house-board.py); pull request titles do not determine that classification.
Recognized plumbing appears in a separate expandable ledger, outside the feature filters, counts, and register-mismatch rows.
Each project card compares the current fork `house` tip with upstream `main`, reports the ahead and behind counts, and flags a fork `main` tip that differs from upstream.
Each feature row shows its durable branch, commits, current house membership, label, pull request states, and age.
House membership comes from live commit ancestry or a fork pull request merge commit still reachable from today's `house` tip, never from the register's merged heading alone.
House membership reads N/A for a feature contributed upstream, a historical one, or one whose fork pull request closed without merging and never landed.
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

The main-based `housefeature/<name>` branch is also the branch for a later upstream contribution and must remain a clean diff from upstream `main`.
Never merge `house` or another fork-only line into that branch, even to fix conflicts on its fork pull request; reconcile the conflict on the `house` side as described above.
The fork and upstream pull requests can share one head branch while targeting different bases, so a merge from `house` into that shared head would carry fork-only commits into the upstream contribution.
Keep our delivery on its durable `housefeature/<name>` branch and its own pull request into `house`, with the upstream contribution reviewed against upstream `main`.
The `house-only` branch is excluded from this path because it can start at `house` and carry other house features.

Refresh a contribution branch only by merging upstream `main` into it, including when conflicts or CI prompt a refresh; never rebase it.
Rebasing rewrites the attested head, which upstream's gate rejects.
Validate the exact final head that will be offered with one pipeline run to renew a stale attestation, and never hand-edit the attestation.
Open an upstream pull request only when the captain asks for that house feature by name.
The matching Bosun may open and maintain that one pull request under the captain's explicit order, following [`bosun.md`](bosun.md); otherwise upstream contact remains the captain's act.
Before opening an upstream pull request in a repository the fleet does not own, run the prior-art scan in `bin/fm-upstream-prior-art.py`, review every candidate, and record an explicit verdict.
The scan uses forge search for open pull requests and issues and recent closed unmerged pull requests, driven by linked issues and keywords from the title, summary, and changed symbols, and checks changed-file overlap only on the returned candidates.
It reads the most relevant hits for each query within a fixed request and time budget; a scan that reaches either bound is recorded as incomplete and cannot be decided or published.
Queries beyond the per-scan query cap and hits beyond the most relevant page are not read; the receipt discloses that truncation with read and total counts and any dropped queries, `decide` refuses a record without that disclosure, and the published `Prior art checked` section states that search coverage was bounded.
A duplicate with different wording or files can evade those keyword, changed-file, and linked-issue matches.
A `none-found` verdict requires no candidates; a `distinct` verdict requires a one-line reason for each candidate; an `overlaps` verdict requires the captain's recorded decision before publication.
Use that command's `publish` operation for upstream creation so its receipt check is immediately before the forge write and the generated `Prior art checked` section summarizes the search, names the closest matches, and credits authors of overlapping work.
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
Merge main-based feature branches directly; merge house-only branches only when their required house features are also included, in dependency order.
Resolve any rebuild conflict on the new `house` integration line, leaving each main-based feature branch free of `house` commits.
Push the rebuilt branch with `--force-with-lease` against that exact previous tip.
The house ruleset refuses that force push, so a rebuild needs the captain to disable the ruleset for the push and restore it to active immediately afterwards.
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
