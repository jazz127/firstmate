# Established recovery timer lost during uncertain native state

Oracle: accepted R6 requires established stuck-run timers to survive uncertainty; original intent retains genuine stuck-run protection.

Driver: `LIVE_STUCK_ONLY=1 python3 .test-live.py` (retained as `live-driver.py`). Uses actual Claude Code 2.1.304, its normal login and upstream response, genuine UserPromptSubmit/Stop busy hooks, a 120x40 pane on the private fm-lab tmux socket, and the production fm-watch.sh and fm-crew-state.sh. No backend, harness, current-state, or upstream mocks.

1. Finish a real model turn, submit a second turn, and stop only that lab Claude PID after its genuine busy hook fires.
2. The real endpoint probe reports alive and fm-crew-state reports working/source pane/claude-hook.
3. Start the watcher with BUSY_TURN_MAX_SECS=2 and STALE_ESCALATE_SECS=6. Wait for the watcher to establish its own stale timer.
4. Make the busy record unavailable by moving that lab-owned record. Real fm-crew-state now reports unknown/source pane/unknown missing.
5. No recovery wake arrives in 25 seconds. Reproduced twice. Retained final state has 13 identical-pane observations, a classified stale hash, and no stale-since timer or escalation marker.

The timer can be created while count is still 0. On the next identical capture, count is 1 and busy is now unknown, so bin/fm-watch.sh:3566 deletes the timer. Once the pane becomes stably stale, the uncertain branch at :3542 sees no prior timer and never alarms. The changed-pane reset at :3589 has the same unconditional deletion shape.

Control: `LIVE_STUCK_ONLY=1 LIVE_STUCK_CONTROL=1 python3 .test-live.py` keeps the busy record readable. The frozen endpoint remains alive, current state stays working, and the watcher exits 0 with `possible wedge, escalation 1` after six idle seconds. `live-stuck-control.txt` contains the actual control output; its shared-driver label “After state record becomes unavailable” should be read as the control re-read, since CONTROL deliberately skips the move.

All watcher subprocesses were waited, the frozen lab CLI was resumed before teardown, the private tmux server was stopped, and disposable lab homes were removed. No production source changes were made.

Other live checks passed: paused ordinary worker silence even when listed, completed scout silence after actual model output changes, deferred bare turn-end delivered exactly once, secondmate default-off/exact-ID opt-in, new blocked status delivery, endpoint loss delivery, and unchanged-loss deduplication. Focused watcher, daemon and deferred-event regression selectors all exited 0, using the existing simulated boundary fixtures.

Pipeline-gate, post-PR-delivery gate, and daemon uncertain-read regressions were exercised with fixtures only. This assigned phase is explicitly prohibited from initializing or controlling another no-mistakes pipeline or performing push/PR/CI phases, so those live upstream transitions were not manufactured.

Additional real-endpoint checks: `python3 .test-endpoint.py` (retained as `endpoint-driver.py`) passed loss → ambiguous sleep process → unchanged loss without a duplicate, proven-alive Claude rearming, and replacement Claude death rearming via changed spawn_gen with no busy-gen record. Each new incarnation reported once. See `live-endpoint.txt`. This last driver also exited 0 and removed its private server and home.
