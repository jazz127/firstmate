# Live product validation

Result: all final scenarios passed. No tracked source or test changes were needed.

The public driver was `bin/fm-procevent-lavish.sh arm <artifact.html> --agent-reply-file <path>` without `--for`, together with `bin/fm-procevent.sh reconcile`, the real Lavish CLI/server, and browser interaction through `chrome-devtools-axi`.

Lavish 0.1.80 was installed only under the disposable workspace. The existing 0.1.78 CLI exercised the supported legacy poll-with-reply path. Both used the isolated real Lavish server at `127.0.0.1:18487`, with its own session store, lab homes, claim directory, and browser profile. No Lavish CLI, browser, API, reply, or feedback response was mocked in these live scenarios.

The independent oracles were the author's requested in-page conversation reply; the recorded decisions requiring completion of reconcile/keyed decision intake before reply replacement; and Lavish's published Send & End contract requiring one final result and no further poll.

For pre-commit replacement, the actual isolated runner was suspended with SIGSTOP while its real Lavish child received browser-submitted feedback. The replacement then rescued that actual staged output. For post-commit replacement, the real task-control lock was held by another live process; a competing reply remained blocked until actual decision intake could finish. The operating system denied staging unlink by making only the disposable registry directory read-only. These are real concurrency and filesystem conditions, not fake product or upstream responses.

A routing-error scenario pointed the actual adapter at an empty disposable session directory. Its diagnostic was captured and announced, the private reply remained staged, and restoring the monitor's configuration to the real server's session directory delivered that reply and received subsequent feedback.

The supplemental `bash tests/fm-procevent.test.sh --owner-replies-only` also passed. Those regressions use synthetic CLIs and filesystem-command substitutes, including 0.1.79/0.1.80 compatibility, setup/reply rejection, claim-reclamation denial, and deterministic replacement boundaries; they are supplemental offline evidence, not the basis for live passes.

Initial browser-driver setup attempts encountered sandboxed-iframe access, stale browser refs, and already-closed tab selection. The driver was corrected to interact with the actual artifact buttons through browser refs and to open the current isolated page. A publication timing assertion was corrected to wait for the actual notification. A routing recovery initially used another server state directory and was correctly refused by Lavish; recovery was corrected to use the server's own directory. Reply listeners can emit informational poll stderr, so continued-feedback checks assert the actual feedback payload and uniqueness of decision payloads rather than assuming every captured sequence contains feedback. All final scenarios below completed successfully. The full transcript retains those setup attempts.

## Final executed scenarios

- modern-conversation fresh reply, active replacement, continued feedback, missing-file and foreign-owner refusal
- modern-bound-precommit preserves reconcile and keyed decisions without replaying old requests
- modern-bound-postcommit preserves reconcile and keyed decisions without replaying old requests
- modern-terminal-precommit preserves reconcile and keyed decisions and refuses further replies/polls
- modern-terminal-postcommit preserves reconcile and keyed decisions and refuses further replies/polls
- legacy-conversation fresh reply, active replacement, continued feedback, missing-file and foreign-owner refusal
- legacy-bound-precommit preserves reconcile and keyed decisions without replaying old requests
- legacy-bound-postcommit preserves reconcile and keyed decisions without replaying old requests
- legacy-terminal-precommit preserves reconcile and keyed decisions and refuses further replies/polls
- legacy-terminal-postcommit preserves reconcile and keyed decisions and refuses further replies/polls
- modern routing failure is announced, reply is retained, and restoring real session evidence retries the reply and resumes feedback
- modern-unlink-denied retains one committed feedback result, does not replay staging on reply re-arm, and accepts subsequent feedback
- legacy-unlink-denied retains one committed feedback result, does not replay staging on reply re-arm, and accepts subsequent feedback

## Terminal persisted session contracts

[
  [
    "modern-terminal-precommit-session.json",
    "ended",
    "user"
  ],
  [
    "modern-terminal-postcommit-session.json",
    "ended",
    "user"
  ],
  [
    "legacy-terminal-precommit-session.json",
    "ended",
    "user"
  ],
  [
    "legacy-terminal-postcommit-session.json",
    "ended",
    "user"
  ]
]

Screenshots show actual in-page replies, queued final choices, successful retry, and continued feedback after denied unlink. The full product transcript, captured feedback contracts, reconcile request records, and accepted task answers accompany this report.

Cleanup completed: every disposable home sweep passed, no source claims remained, the isolated Lavish server and named browser bridge stopped, the transient workspace (including the locally installed CLI) was removed, and git status was clean.
