---
name: bosun
description: >-
  Route a captain-ordered Captain's Maneuver to a matching Bosun and supervise its upstream contribution.
  Use before routing a named Captain's Maneuver upstream, recording a Bosun order, or handling that contribution's review or merge outcome.
user-invocable: false
metadata:
  internal: true
---

# Bosun

Load `secondmate-provisioning` before provisioning a Bosun home or editing the secondmate registry.
[`docs/bosun.md`](../../../docs/bosun.md) owns the role, vocabulary, provisioning, and contribution procedure.
[`docs/configuration.md`](../../../docs/configuration.md#bosun-routes-configbosun-routesjson) owns the route schema and precedence.

On an explicit captain order naming a maneuver and upstream target, resolve the target with `bin/fm-bosun.py route` in the primary home.
If no route matches, ask whether to create a Bosun; never substitute another maintainer profile.
If the route ties, hold for a captain decision instead of guessing.
Send the order to that registered secondmate through the ordinary parent channel and preserve the captain's exact words in its contribution record.
The Bosun reads current repository policy, checks accepted PR and review evidence when needed, and records only evidenced conventions as confirmed.
It extracts from the ordered `housefeature/` branch onto freshly fetched upstream, reviews the result for private or house-only material, and runs expected validation.
It runs the guard immediately before the existing no-mistakes or forge publication path and records the PR and evidence after publication.
Treat a scope change, ambiguous maintainer request, policy conflict, or consequential external decision as a `needs-decision` through the normal secondmate parent channel.
The contribution observer and existing PR poll own subsequent signals; a confirmed merge updates the maneuver record through the ordinary merge outcome path.
