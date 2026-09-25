# Bosuns and upstream maneuvers

A Bosun is a persistent secondmate with a named maintainer scope, a Bosun role record, and its own evidence-backed memory.
The contribution path is **Captain's Maneuver -> matching Bosun -> upstream PR -> Admiral's Maneuver**.
A Captain's Maneuver is the existing house feature on a durable `housefeature/<name>` branch cut from the fork's untouched upstream mirror.
The older house-feature records keep their format and name.
An Admiral's Maneuver is a Captain's Maneuver whose matching upstream PR has been observed merged.

Only an explicit captain order naming one maneuver and target authorizes a Bosun to offer that maneuver upstream.
Bosuns do not select work, widen scope, or contact unrelated upstream projects.
The secondmate parent channel carries `needs-decision` requests for scope changes, ambiguous maintainer requests, current-policy conflicts, and consequential external decisions.
The usual secondmate spawn, watcher, contribution observer, PR poll, forge, and no-mistakes paths remain in force.

## Provision a Bosun

Load `secondmate-provisioning` and scaffold a normal persistent secondmate charter with `bin/fm-brief.sh <id> --secondmate <project>...`.
Put the maintainer responsibility in `FM_SECONDMATE_SCOPE` and the following Bosun-specific rules in `FM_SECONDMATE_CHARTER`, along with the maintainer name: never select work, never widen a named maneuver, never contact unrelated upstream projects, read current repository instructions and contribution policy, and use the parent channel for the four decisions above.
Seed with `bin/fm-home-seed.sh <id> <home|-> <project>...` and launch through the ordinary secondmate path.
In the primary home, add an explicit route to gitignored `config/bosun-routes.json`, then run `FM_HOME=<primary-home> bin/fm-bosun.py configure-home --bosun <id>`.
Copy that route file into the Bosun home and run `FM_HOME=<bosun-home> bin/fm-bosun.py configure-home --bosun <id>` there.
The primary role record is `data/bosuns/<id>.json`; the Bosun home's identity record is `data/bosun-role.json` beside its existing `.fm-secondmate-home` marker.
These files specialize the existing home; they do not create another lifecycle.

For Bosun-Kun, use id `bosun-kun`, scope `contributions to kunchenguid/*`, and the example route in [`bosun-routes.json`](examples/bosun-routes.json).
Provision the actual home only after this change lands.
Leave its shared Kun profile empty until current repository files or accepted PR and review artifacts provide evidence.

## Route and order

[`configuration.md`](configuration.md#bosun-routes-configbosun-routesjson) owns the route schema and precedence.
Run `FM_HOME=<primary-home> bin/fm-bosun.py route --forge github --owner kunchenguid --repository <repo>` before assigning an upstream contribution.
No match asks whether to create a Bosun; an equal-rank tie refuses.
Forward the captain's explicit words, named maneuver, and exact target to the matching secondmate.
The Bosun records the order with `fm-bosun.py order` in its own home, including the durable source branch, selected source commit IDs, allowed changed paths, and contribution branch.
Use a repeated `--deviation path=reason` only for an explicitly recorded stripped or rewritten path.
One `data/<task>/bosun-contribution.json` record links those fields to validation evidence and the eventual upstream PR.
An order record is immutable; a scope or target change needs a new captain decision rather than an in-place edit.
Run `FM_HOME=<bosun-home> bin/fm-bosun.py intake --task <task>` after recording the order to scaffold and spawn exactly one ordinary ship task through `fm-brief.sh` and `fm-spawn.sh`.
The intake fills the task with the ordered source branch, path scope, upstream-base procedure, repository-policy reading, validation, attribution, publication, and parent-channel escalation requirements.

## Read conventions

Read the target repository's current committed instructions and contribution policy first.
If conventions remain unclear, inspect relevant accepted PRs and review history.
Store confirmed learned conventions with `fm-bosun.py convention --confirmed`, naming the source URL or file, what it showed, and when it was read.
An unevidenced note may be stored without `--confirmed` and never resolves as policy.
The Bosun home keeps the shared maintainer profile under `data/bosun-memory/<id>/profile.json` and repository overlays under `data/bosun-memory/<id>/repos/<forge>/<owner>/<repo>.json`.
For a convention key, current repository policy wins over a repository overlay, which wins over the shared profile; an explicit captain decision that conflicts with current policy is a `needs-decision`, never an automatic override.
The `conventions` command accepts a key/value JSON representation of the repository policy read for this operation and optional captain decisions, and prints the resolved policy with provenance.
The source files themselves remain the authority; that JSON is a local interpretation for checking precedence, not a substitute for reading them.

## Extract and publish

Using the existing contribution and worktree machinery, start from the latest upstream default branch in a clean isolated worktree and apply only the ordered source commits and allowed paths from `housefeature/<name>`, keeping each selected commit's message and author.
Before registration, a scratch extraction cherry-picks the ordered commits onto that upstream base and requires the PR tree to match exactly except for declared deviation paths.
Review the resulting diff and commit series for house-only configuration, private context, secrets, unrelated history, and fork assumptions; a path allowlist cannot decide whether public-looking text is private.
Registration permits clean rewrites and squashed commits only when their tree matches that exact extraction or a declared deviation.
Registration rejects merge commits and unrelated intermediate history.
If adapting the maneuver to current upstream needs new content, obtain a new captain decision and order before publication.
Do not merge or rebase `house` into the contribution.
Run the repository's expected validation, using no-mistakes where configured.
The existing publication path opens the PR from the captain's fork to upstream.
`fm-pr-check.sh` reads the PR through its existing forge path and refuses registration unless the ordered Bosun, fork, upstream repository, and default branch match.
The existing PR poll and contribution observer track checks and review feedback; route scope changes, ambiguous maintainer requests, policy conflicts, and consequential decisions through the parent channel.
When the existing merge outcome reports that exact PR merged, it changes the record to `admirals-maneuver`.
A closed PR without a merge outcome leaves the maneuver unlanded.
