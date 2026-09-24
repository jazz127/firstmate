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

The quota-axi view shows the clone's current `jazz127/house` commit and subject, the `quota-axi` executable on `PATH`, and a live read-only quota-axi report with every labelled account row.
Run `bin/fm-quota-tab.sh once` to print one frame, or `bin/fm-quota-tab.sh` (the default `loop` mode) in a terminal tab to keep the fleet's house line and provider headroom in view.
The loop refreshes every 300 seconds by default; `FM_QUOTA_TAB_INTERVAL` changes that interval.

Bring upstream changes to the fleet by merging upstream `main` into `house`.
Do not rebase `house` onto upstream: preserving merge history keeps the house integration visible, leaves upstream-bound commits extractable, and preserves the head identity used by gate attestations.

## House features

A house feature is anything we build for ourselves on our own line, whether the captain asked for it or firstmate found it.
Every house feature has a durable `housefeature/<name>` branch cut from the fork's `main`.
That branch gives the feature a stable name, keeps it findable, and makes it straightforward to offer without relying on a disposable task branch.
Task branches are working branches and may be deleted once their feature is captured on its durable branch.
A contributed house feature is a house feature the captain chose to submit and that has landed in upstream `main`.

## Contributing a house feature upstream

Keep the feature branch current by merging upstream `main` into it; never rebase it.
Validate the exact final head that will be offered.
Open an upstream pull request only when the captain asks for that house feature by name.
Only the captain contacts upstream, including opening or commenting on an upstream pull request.

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
