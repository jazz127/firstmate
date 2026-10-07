The target is the expected merge commit, with the house base as first parent and the pinned upstream main as second parent. The range contains exactly the two expected upstream commits plus the merge itself.

```
commit=db4707e18ee2c6eca92990391a1853392ac88234
parents=ecb5e0444e6402b857d22be5bb165996150d41ef 99da16d954ccee7e0dbf594d88707e6871fd0929
subject=Merge upstream main into house
db4707e1 Merge upstream main into house
99da16d9 feat(bin): add armable daily startup growth check (#6725)
e06a46fe fix(project-management): use subshell form for Initialize command (#6699)
```

The scripts-table conflict resolution adds the new startup-growth row while preserving the existing house table entries:

```diff
diff --git a/docs/scripts.md b/docs/scripts.md
index d160f5b8..fef79bbd 100644
--- a/docs/scripts.md
+++ b/docs/scripts.md
@@ -143,6 +143,7 @@ The shared no-mistakes gate lifecycle boundary is summarized in [architecture.md
 | `fm-check-unregister.sh` | Retire a custom watcher check and its trust binding by validated task id            |
 | `fm-check-lib.sh`        | Validate custom-check registrations and prepare private execution snapshots          |
 | `fm-tool-update-check.sh` | Report watched tooling with an update available, and updates installed but left inert by PATH order |
+| `fm-startup-growth-check.sh` | Daily metadata-only growth check for startup memory and tracked startup/instruction surfaces |
 | `fm-pr-lib.sh`           | Own canonical task and PR validation, published-body reads across supported forges, and private atomic PR-poll publication, merge-notification identity, and retirement |
 | `fm-pr-poll.sh`          | Provide the byte-static watcher program for validated pull-request, merge-request, and Gerrit-change poll sidecars |
 | `fm-contributions.sh`    | Observe owned publications, retain exact-head judgments, measure required actors, and wake on maintainer signals |
```

The initialization edit only puts the existing documented no-mistakes init/doctor sequence in a subshell. It changes no executable product code. Those lifecycle commands were not executed because this assigned phase cannot initialize or control a pipeline. Delivery, PR body, and CI remain the outer executor's phases.

The new monitor was driven through the real CLI, real startup-memory-budget owner, real custom-check registrar, and real watcher. Disposable instruction surfaces are byte copies of the tracked files, not executable stubs. All live homes and copies stayed inside the worktree and were removed. No upstream service is involved in the monitor's local metadata/reporting path. For due evaluations, only the disposable daily record's last_eval was dated to yesterday; the product used the actual wall clock.

The original targeted runner used a worktree-local TMPDIR. Three contribution fixtures failed because existing seeded-home validation rejects a child home inside the Firstmate repository. The targeted probe captured the precise rejection, and re-driving those three functions with the test helper's normal ephemeral temporary-directory setup passed. A base-code snapshot probe also passed. The contribution tests use fake forge responses and are supplemental simulated checks, not live upstream evidence.

The startup-growth suite reproduced the already-declined Darwin PATH_MAX fixture failure. Its permanent test was left unchanged. The live monitor's truncation scenario instead generated an oversized real budget-owner diagnostic with valid paths below 1024 bytes, verified the 1000-byte output cut and truncation marker, and verified full persisted findings still deduplicate.

The Calm suite is supplemental verification of test-only upstream edits. It runs native Pi TUI checks with synthetic providers and skips optional package-dependent cases when the legacy npm package path is absent. No rendered product implementation changed, so screenshots were not needed for the changed surface; the new product surface is CLI output and retained watcher notifications.

The original targeted runner completed. Its contribution suite reported only the three setup-related child-home failures; each passed after correcting the temporary-directory placement. The four contribution cases located after the suite's failure guard were then run separately and passed, so that early exit did not leave their checks unexercised. The changed configured/inherited budget test ran and passed in the original suite. The targeted-runner log retains its actual failing exit rather than presenting a clean full invocation.
