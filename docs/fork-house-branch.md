# Fork house branch

This guide describes the operator workflow for running a Firstmate fork with a private house delta.
The [`updatefirstmate` skill](../.agents/skills/updatefirstmate/SKILL.md) owns the update procedure, and [configuration.md](configuration.md#firstmate-runtime-branch-git-config-firstmateruntimebranch) owns runtime-branch resolution.

## Branch layout

Keep the fork's `main` as a straight mirror of upstream `main`.
The `house` branch is the line the fleet runs, with local operator changes layered on top.
Configure the primary checkout's local `house` branch to track `jazz127/house`, and set `firstmate.runtimeBranch=house` in that repository's Git config.
The setting selects the primary runtime branch; its branch tracking configuration supplies the update remote and merge ref.

Bring upstream changes to the fleet by merging upstream `main` into `house`.
Do not rebase `house` onto upstream: preserving merge history keeps the house integration visible, leaves upstream-bound commits extractable, and preserves the head identity used by gate attestations.

## Contributing a change upstream

Prepare an upstream contribution on a separate branch created from a fresh upstream `main`.
Cherry-pick only the intended commits from `house`, validate the exact final head, and obtain explicit approval before opening an upstream pull request or making any upstream comment or other contact.
The fork workflow does not authorize upstream contact.

## Inspecting the private delta

Fetch the fork's `jazz127` remote and prune stale remote refs, then inspect the commits on the house line beyond the upstream mirror:

```sh
git fetch origin jazz127 --prune
git log --oneline origin/main..jazz127/house
```

The live list of personal commits is kept privately with the operator's fleet records.

Secondmates follow the primary's exact commit during update convergence.
Dirty or diverged secondmate homes are skipped and reported for reconciliation under the [`updatefirstmate` contract](../.agents/skills/updatefirstmate/SKILL.md).
