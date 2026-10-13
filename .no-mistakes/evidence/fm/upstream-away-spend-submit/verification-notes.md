Validated target bbc02c9918fba97e4817b0f96428710636e6de94 against base e5b9dddc982e546b81b4bfce754df1465270a59e.

Thirteen isolated product scenarios passed through real fm-afk-spend-count, fm-spawn, fm-afk-return, backend/control, busy and task-cleanup interfaces.
The lab used a private tmux server and 120x40 terminals, real Treehouse worktrees under the run workspace, raw shell commands, and two native Claude print requests using the existing login.
Claude's own UserPromptSubmit and Stop/SessionEnd hooks called the production generation-bound busy-event writer.
Positive endpoint liveness and native idle activity were checked independently before exercising ship and scout waiting verbs.
Admission evidence proves rejection at cap=1 and passing the cap gate at zero; the separate fresh-scout scenario proves an actual successful raw-command launch.
The private tmux server was suspended to exercise a genuinely hung presence read: count returned 1 after 5.500s and fresh admission refused after 5.871s.
The final renamed-start scenario observed foreground bash replacing Treehouse's zsh before moving the endpoint and terminating spawn; retained cleanup capacity blocked another admission and appeared in return reporting.
This is spending-capacity classification, not token metering or autonomous away-supervision proof; the lab intentionally had no watcher.

Canonical modern-Bash focused suites both passed: tests/fm-afk-spend-cap.test.sh and tests/fm-afk-return.test.sh.
These suites use synthetic tmux, Herdr, no-mistakes and other external-boundary tool responses; their completed-run and Herdr scenarios are offline evidence only.
No Herdr lifecycle command or pipeline-control command was run.
No genuine disposable attributed completed/running no-mistakes run could be minted within the gate's prohibition on starting another pipeline.

The existing test_outcomes_tool_uses_stock_execution_and_export_consumers passed with workspace-local @earendil-works/pi-coding-agent 1.2.0 after satisfying its expected nested dependency layout using real package symlinks.
This exercises real vendor execution/HTML consumers under a scripted extension API; it is not a live Pi UI or agent-session proof.
No UI code changed, and no screenshot was captured; product evidence is CLI output, while the Pi consumer check had no running rendered UI.

With Bash 3.2 actually first on PATH, both target and archived baseline fail at the same pre-existing assertion: evidence publication failure should retain catch-up (rc=1).
The baseline-confirmed and target logs retain this equal failure; the required unrelated compatibility behavior was left unchanged.
An earlier /bin/bash runner invocation still selected modern Bash for child suites; those runs were not used to establish Bash 3.2 compatibility.

Setup issues were corrected before accepting product results: the Claude print prompt needed an explicit option separator; returned away records needed re-entry before each admission snapshot; the Pi install needed the nested dependency layout expected by its test.
An initial stricter cancellation observer missed a wrapped source line and let the raw shell reach its documented conservative 30s startup timeout; the affected rename scenario was re-driven using foreground process observation and passed.
The fresh scout cleanup initially refused its missing completion inventory; its report was inventoried with --none and guarded teardown then succeeded.
No permanent source or test changes were made.
