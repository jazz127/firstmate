# Snapshot live validation

The real snapshot, saved-contribution, and wake-drain CLIs ran with disposable marked FM_HOME directories inside the worktree, with real jq, tasks-axi, and tmux, and no shims.
The read-only saved-record snapshot interface makes no forge requests.
Real tmux queries addressed a private absent socket; no default session or fleet pane was accessed.

## Saved-record output

523 valid persisted records across three batches returned exactly the independently specified pending tokens, tasks, URLs, Unicode summaries, and ordering.
The valid snapshot reported known=523, checked=523, unreadable_records=0, complete=true.
A file of exactly 1,048,576 bytes was accepted.
The oversized file, task mismatch, unknown schema, malformed JSON, empty file, two JSON values, symlink file, symlink directory, and directory in place of a file were each rejected.
The mixed projection reported known=524, checked=524, unreadable_records=9, complete=false.
Removing the three parse failures reduced unreadable_records to six without changing accepted rows.
The pending command returned exit 1 while rejected records existed.

## Decision output

See decision-transitions.json for the actual returned key/verb/summary sets at each transition.
Each matched a manually specified expected set across cold/warm reads, keyed resolution and reopening, partial-line completion, captain-held transfer, longer rewrite, equal-size edit, truncation, inode replacement, and corrupt-cache recovery.
The separate wake cursor remained byte-identical.

## Unread-status output

First drain after a snapshot:

```text
UNREAD STATUS (new since last drain, not re-printed after this presentation):
task1 note: captain said use REST not RPC
```

The second drain produced no output.
After a follow-up append and another snapshot, the next drain returned:

```text
UNREAD STATUS (new since last drain, not re-printed after this presentation):
task1 note: follow-up answer
```

## Load timings

| Load | Baseline | Changed cold | Changed warm |
| --- | ---: | ---: | ---: |
| 523 saved files, 23 tasks, 1,009 status lines each | 12.435s | 6.106s | 4.785s |

The complete three JSON outputs matched after normalizing only roots.fm_root, which names the different code directories.
The observation clock and operational home were identical.
The baseline ran from an in-worktree git archive of b062eb94c50a68dd4467fba25346a7d7b4083288.
The initial comparison driver normalized the wrong field, roots.root; its only difference was roots.fm_root.
That setup error was corrected and the whole driver rerun with exit 0.
These timings establish improvement on the disposable load, not on the operator's original home.

## Supplemental checks and cleanup

The focused contribution selectors, focused snapshot selectors, and tests/fm-wake-drain-unread-status.test.sh exited 0.
The first-drain regression requested in the recorded decision passed.
Existing fixture-based checks supplement the separate real CLI evidence above.
No full-suite, linter, formatter, other gate phase, or pipeline control ran.
The changed surface is CLI JSON and text; visual UI evidence is not applicable.
Disposable homes, baseline export, and temporary test runners were removed.
