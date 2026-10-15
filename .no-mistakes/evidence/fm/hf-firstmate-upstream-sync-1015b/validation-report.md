# Targeted product validation

Target: b2d498064f8ea99e0bd8025363d9623f0ef736b6.

All driven scenarios passed. No tracked source or test files changed.

- **Forgejo successful pagination:** Real tea v0.16.0 and a native Forgejo v7.0.14 source build with SQLite served a disposable repository over localhost. The public merge command read 51 successful contexts over multiple pages, accepted the upstream null terminal page, and the upstream PR record confirmed a landed merge. See `forgejo-live.log` and `forgejo-pr-0-after.json`.
- **Forgejo failure after a green page:** A transparent HTTP forwarding proxy revoked only the disposable token through the actual Forgejo API after forwarding the first status page. The next page was Forgejo's genuine HTTP 401 error object; no response was synthesized. The public merge command reported unreadable and the real PR remained unmerged. See `forgejo-live.log` and `forgejo-pr-1-after.json`.
- **Forgejo without CI:** The actual empty combined-status response refused with none; the PR stayed open. See `forgejo-pr-2-after.json`.
- **Provider-correct description readback:** A generated Forgejo brief selected its Forgejo readback command; that public command read the complete body through real tea and passed the evidence preflight. See `forgejo-generated-brief.md`, `forgejo-body-readback.md`, and `forgejo-live.log`.
- **Fork publication authority:** Real `fm-role.sh` checks in a disposable local repository with origin=jazz127/firstmate and upstream=kunchenguid/firstmate refused absent authority and parent-scoped authority, accepted fork-scoped task consent and a disposable fork maintainer grant, and left the role absent after task consent. See `local-cli-transcript.log`.
- **Normal Claude Stop:** Real authenticated Claude Code used the modified hook and settled the parent generation idle. See `claude-boundaries.log` and `claude-live-output.jsonl`.
- **Second Claude session:** With the original real Claude session still alive on its open input stream, a second real Claude session's Stop left the seeded busy generation and original lock unchanged. The input generation was seeded using the real busy-event writer. See `claude-boundaries.log`, `claude-intruder-output.json`, and `claude-live.py`.
- **Context continuation:** A real Claude transcript crossed the disposable context budget; Stop exited 2 and published busy. The test stopped after observing that boundary; it does not claim the subsequent stow/restart completed. See `claude-context-crossing.txt` and `claude-boundaries.log`.
- **Foreign-host compatibility event:** Direct JSON input to the public Stop guard left the active generation byte-identical. Executing the previous guard from ee503bf3 against the same input reproduced the erroneous idle write. See `foreign-stop-regression.json`.
- **Herdr passive captures:** A real named non-default lab used the guarded helper for provisioning, a 40x120 viewer, pane input, stop, and cleanup. Visible capture worked while running; plain and ANSI probes both refused after stop and did not restart the server. Cleanup's protected-default-session tripwire passed. See `herdr-live.log`.
- **Git configuration and attribution:** Real git commit through installed hooks preserved inherited credential-helper values in the repository's hook, retained a human co-author, and stripped the Cursor co-author. See `local-cli-transcript.log`.
- **Unsupported contribution reporting:** Real poll and snapshot commands cleared only a legacy unsupported-forge error, retained provenance and the old checked timestamp, emitted no wake, and reported unmeasured coverage without assigning fleet work. See `contribution-reporting.json`.
- **Recovery notification continuity:** Real bounded foreground checkpoints announced recovery once, retained the outstanding generation and durable notification, then returned a quiet timeout without reannouncing. See `checkpoint-live.log`.

Supplemental targeted behavior tests also passed: the self-repository role suite, the Git trailer suite, the two Stop/context regressions, and the selected Forgejo pagination/body/scratch/refusal and housefeature merge-method regressions. Forge CLI and fake-harness fixtures in those tests are supplementary offline evidence, not live upstream proofs.

The original two-parent merge remains an ancestor:

```text
1bcefa22058183e9bf91dc6d6aa72ff5ba4509f9 dd34c7ae02e81ba5c579dcbf45c861de474fbf93 24f3a6b80a4825621ac7cccb2d2cb7338b0eace2
```

Only the assigned test phase was performed. The disposable Forgejo server/proxy, private tmux server, and Herdr sessions were stopped. Reproduction drivers are archived alongside the evidence; their `.validation-tmp` locations refer to disposable directories from this run. No graphical layout changed; evidence is CLI output, native hook events, and persisted state.
