# Bearings live validation

The real snapshot CLI ran on this Mac against disposable durable fleet data: nine homes (six local, three reached using real OpenSSH in a disposable Linux Docker container), 813 saved contribution records and report pointers in the primary home, and 84 status lines per secondmate. No operator fleet or production credentials were used.

Final base: **18.802 s**. Target: **6.844 s cold**, **6.369 s and 7.082 s warm**. Median improvement: **63.6%**. All three target runs exceeded the author's five-second goal. The projected JSON matched the base exactly with the observation clock fixed. Canonical output retained all 813 report ids and nine surviving keyed decisions.

Real SSH checks passed for fresh ledgers, freezing the server under the shared collection deadline and serving caches, missing and malformed ledgers remaining unknown, and enforcing the sampling cap before SSH reads. Each uncapped snapshot performed exactly one real SSH request per remote home. No SSH collectors survived the commands.

Cold, appended, and rewritten status files preserved the documented keyed-decision behavior, UTF-8, tabs and trailing spaces. A secondmate's unrelated done event retained its open decision; a ship's terminal done cleared it. Special-character report ids survived the inventory.

The targeted decision-key test file passed. Its new fan-out regression failed against the base as expected. The first full Bearings test invocation encountered fixture Git discovery escaping into its enclosing worktree; rerunning with GIT_CEILING_DIRECTORIES set to the disposable temporary directory passed the complete targeted file. No linter, formatter, full repository suite, publication, PR, or CI phase ran.

These are CLI changes, so JSON documents and CLI transcripts are the product evidence; no visual UI was changed. Temporary data, SSH server and test image were removed after validation.
