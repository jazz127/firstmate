# Live validation of 241e33a1

Acceptance oracle: ordinary ships/scouts and unlisted secondmates must spend no idle check-in turns; exact secondmate opt-in may recheck; genuine events and established stuck-run protection remain effective. Accepted R1-R6 and T1 require deferred-event delivery, gate protection, incarnation deduplication, and preservation through uncertainty without inventing execution proof.

All real-product checks below passed in this run. Drivers use the production watcher, crew-state reader and backend against private 120x40 tmux panes. Claude Code 2.1.304 used its normal login and completed actual upstream model requests. Native busy records came from real UserPromptSubmit and Stop hooks. Labs contained disposable metadata/status and git repositories; no harness, backend, state-reader or upstream fake was used in these live drivers.

| Action and observable result | Evidence |
| --- | --- |
| A paused ship stays silent even when incorrectly listed for opt-in; a completed scout stays silent after actual model output changes. | live-watcher.txt |
| An unlisted secondmate stays silent, a near-match ID stays silent, and an exact listed ID produces a declared-wait recheck. | live-watcher.txt |
| A churn-deferred bare turn-end is delivered once, then remains silent. | live-watcher.txt; live-triage.txt |
| New blocked status and loss of a paused endpoint queue actionable wakes. | live-watcher.txt |
| Freeze a genuinely busy Claude process, let the watcher establish its timer, remove the busy record: current state becomes unknown and a durable wedge alarm arrives at six seconds. | live-stuck.txt; live-active-to-unreadable-final-state.json |
| Route a queued stale event through the actual daemon while the worker is genuinely busy, then remove its busy record: the established persistence marker matures into a buffered wedge escalation at six seconds. | live-daemon-native.txt; live-daemon-native-log.txt |
| Remove native state with no prior execution timer: current state becomes unknown and stays silent without creating a timer. | live-unproven-idle.txt |
| Resume a frozen busy worker after its watcher timer is established; real Stop hook and done status prove completion: the timer is removed and no wake arrives over six beacon timestamps. | live-completion-clearing.txt |
| Loss, then an ambiguous real sleep process, then unchanged loss stays deduplicated; a positively alive Claude re-arms reporting; changed spawn_gen re-arms one successor-loss report. | live-endpoint.txt |
| Production merge poll reads real GitHub PR #242, already merged, and queues a durable merge-landed check while the worker declares a wait. This read does not claim to exercise a merge operation. | live-upstream-merge.txt; real-upstream-merge-poll-watch.txt; upstream-pr-242.txt |

## Targeted behavioral regression commands

All exited 0, with test boundaries simulated by the existing fake tmux/current-state readers:

- `FM_TEST_ONLY=test_idle_policy_regressions bash tests/fm-watch-triage.test.sh`
- `FM_TEST_ONLY=test_daemon_idle_policy_regressions bash tests/fm-daemon.test.sh`
- `FM_TEST_ONLY=test_turn_ended_churn_pending_delivery bash tests/fm-watch-triage.test.sh`

Each used `TMPDIR="$PWD/.test-tmp"`. Logs: watcher-regressions.log, daemon-regressions.log, deferred-turnend-regressions.log. These include uncertain, failed and malformed inventory reads, first-sighting/inherited gate timers, prior delivered-PR/merge-poll precedence, declared-wait clearing, busy-state disappearance before stability and during redraws, and uncertain endpoint probes.

## Live limit and result

The gate-specific scenarios remain untested live. This phase is explicitly prohibited from initializing or controlling another no-mistakes run, and from performing push/PR/CI phases. A disposable home and real worker cannot produce an authentic awaiting-worker gate or a delivered-PR-to-new-gate transition without that authority. Existing regression fixtures exercised these paths but substitute the pipeline state reader. Live proof requires the outer executor to provide a disposable real pipeline parked awaiting its worker, with permission to drive its state-read failure and post-delivery gate transitions. No pipeline lifecycle commands were run here.

Result: inconclusive for complete live acceptance, with no observed product failures. No source changes. All child results were awaited, the frozen processes resumed, private servers stopped, and disposable homes/test directories removed. CLI supervision has no changed rendered UI; terminal transcripts are the product evidence.
