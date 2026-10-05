All checks used disposable worktree-local homes. Private tmux servers and remote workers were stopped, and labs removed.

The inbox check used the actual Pi CLI (0.87.1) and fm-busy-event to seed a lost-stop-hook busy state. The real watcher queued one recovery wake after two deferrals, preserved the message, suppressed repeated escalation on restart, and cleared the budget after acknowledgement. Model reasoning was not asserted.

The worker check suspended only its serving process with SIGSTOP. Its independent heartbeat recreated readiness with mode 0600 and its serving owner identity. Its real probe passed after 12 seconds with serving still stopped.

The quota launch adapter forwarded to the installed quota-axi 0.1.55 with --profile-only --provider codex --no-credential-refresh and an empty disposable CODEX_HOME. Real missing-profile failures triggered three attempts before the terminal error; removing the launch entry produced an immediate missing-tool error. Restoring Node during the recovery attempt did not produce a successful read because the disposable profile has no credentials. This quota setup read neither operator credentials nor Keychain.

Supplemental checks passed: fm-procevent-quota, fm-task-inbox, fm-remote-job-launchagent, fm-remote-job-claim-retention, selected daemon busy-inbox cases in away/quiet modes, and the rendering/session-lifecycle selector against a local Pi 1.0.1 dependency. That selector needed local symlinks for npm-hoisted pi-tui/typebox dependencies, then passed. Pi's change is test-only and alters no runtime UI; no screenshot is required for it.

Live limits: launchctl bootstrap/bootout mutate macOS service state outside the workspace and were prohibited. The launchagent tests simulate launchd. The real Claude primary used normal login with tools/hooks disabled and a private fm-lab socket, but stopped at workspace trust. Pre-registration would change user configuration outside the workspace; no trust choice was submitted. Pi does not support the away daemon. Those paths and recovery to successful quota readings remain untested live.
