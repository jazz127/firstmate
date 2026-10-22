# Product validation

Oracle: the accepted issue requires bounded persistence through existing stow owners before native compaction, one operational reminder per configurable threshold crossing, and failure that lets compaction continue. The hook header additionally promises deletion of its private transcript snapshot on exit.

## Observed product behavior

- Real Claude Code 2.1.304, using its normal login and native stream-JSON interface: `/compact` ran the production hook and fresh Claude stow worker. A conversation-only UTC preference reached `data/captain.md`; a separate established RFC3339 learning reached `data/learnings.md`. See `live-claude-rich/state/.precompact-stow-last.log` and its `data/` records.
- Existing backlog item `incident-summary`: its body changed from `Implementation note pending.` to `Retain UTC audit column`, through the real markdown tasks owner. See `live-claude-backlog/before-compaction-backlog.md`, `data/backlog.md`, and worker receipt.
- Claude native `additionalContext` delivered exactly two `context-stow` envelopes over initial crossing, repeated high observations, below-threshold rearming, another crossing, and disabling. The native assistant acknowledged both deliveries. See `live-claude-rich/crossing-state.jsonl` and `stream.log`. Sampling used real assistant usage, without a status-line registration.
- Real Pi 0.87.1 with xai/grok-4.5: native `getContextUsage()` observations were 1.3284%, 1.5242%, and 1.7000% against an explicitly configured 1% threshold. Its transcript contains one operational reminder, an assistant acknowledgement, and one native compaction record. The isolated stow SDK worker used the selected xai provider and wrote the pending UTC preference. See `live-pi-grok/` and `native-pi.html`.
- A real Claude prompt observed a deliberately foreign lock owner (PID 1): no threshold envelope and no crossing record were emitted. Restoring the real primary owner allowed the next native prompt to receive the reminder. See `live-claude-ownership/foreign-owner-observation.json` and its native transcript.
- Initial Pi compaction said the session was too small. A temporary project-local setting `compaction.keepRecentTokens=200`, followed by native `/reload`, allowed the same real session to compact. That setting was removed after testing. Anthropic and OpenAI Pi attempts failed on existing expired/revoked credentials; xai provided the successful actual upstream route.

## Reproduced failure: deadline cleanup

Two native Claude `/compact` checks used the documented `FM_PRECOMPACT_STOW_TIMEOUT=1` bound. Native compaction completed, but the bounded pass left its temporary transcript snapshot and writer mutex. The repeated check waited five additional seconds after the native compaction boundary before inspecting the state.

The repeated hook's actual stderr was:

```
precompact-stow: pass incomplete (exit 124); compaction continues
```

The retained state still contained:

```
.precompact-stow-transcript.YGur6g
.precompact-stow.lock.owner.JzkZRH
.precompact-stow-last.log
.precompact-stow.lock
```

The snapshot was 184694 bytes. The surviving mutex and snapshot violate the cleanup contract even though compaction correctly continues. Successful stow passes removed both, so this is specific to terminating the real worker at its deadline. See `live-deadline-repeat-driver.log`, `live-claude-deadline-repeat/state/hook.stderr`, the retained state, and its native compact-boundary event in `stream.log`. The earlier reproduction is in `live-claude-deadline/`; its first driver incorrectly expected hook diagnostics in the stream. Repeating with native hook stderr captured independently confirmed exit 124 and the cleanup failure.

## Supplemental focused checks

`tests/fm-precompact-stow.test.sh`, `tests/fm-timeout-lib.test.sh`, and `tests/fm-operational-input.test.sh` all exited successfully. Their synthetic harness/provider cases are supplemental regression evidence, not live model validation. They cover invalid/foreign/recursive inputs, concurrency, timeout retry, caller stdin, overflow percentages above 100, native extension event handling, provider function retention, and operational encoding. No linter, static analysis, or full suite was run.

All lab primaries used private `TMUX_TMPDIR` directories and the named `fm-lab` socket. No default tmux server or active fleet was used. Driver scripts are retained in `drivers/` for reproduction. Disposable homes were removed after evidence capture.

Verdict: no-go because native timeout cleanup failed.
