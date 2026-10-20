# Bearings validation, round 2

The real snapshot CLI was driven against disposable durable data in the run copy: nine secondmates (six local and three reached through real OpenSSH), 813 saved contributions, 813 report pointers, and 84 parent status lines per secondmate. No operator fleet data or credentials were used. The SSH wrapper only selects a private client configuration and logs calls before execing /usr/bin/ssh; it supplies no responses. The disposable Docker server runs real fm-remote-entrypoint.sh, its real remote worker, and fm-remote-file.sh.

## Result: performance target still unmet

The isolated, sequential benchmark measured base 19.105 s and target 5.300 s cold, 5.923 s warm, and 6.486 s warm. Each command exited zero. The median improvement is 69.0%, but all target observations exceeded the required five seconds. The focused test files had completed before the benchmark began. Threshold comes directly from the author's intent; no threshold was inferred from the implementation.

## Behavior preserved

With the observation clock fixed, all target fm-bearings.v1 documents exactly matched the base. Independent dataset assertions retained the 813 explicit report ids, 813 known contributions with no unreadable records, all nine structured-home rows, and one surviving keep decision per parent secondmate. Canonical CLI output was also retained.

Real SSH checks passed for fresh ledgers, freezing the actual server and selecting cached ledgers under the shared deadline, missing and malformed ledgers remaining unknown, and applying the sampling cap before SSH reads. Uncapped calls performed one real SSH request per remote home; a cap selecting two local homes performed none. No SSH collectors remained after validation.

Direct canonical CLI checks passed for cold decisions, appended captain-held resolution, rewritten status files invalidating cached prefixes, secondmate versus ship terminal behavior, UTF-8, tabs, trailing spaces, and special-character report ids.

Both focused shell test files passed: fm-classify-decision-key.test.sh and fm-bearings-snapshot.test.sh. Those tests include fake external tools and are supplemental simulated regression checks, not the evidence used to claim live product coverage. No complete repository suite, static analysis, publication, push, PR, or CI phase ran.

## Setup and cleanup

The first fresh-server probe reached its deadline while the remote worker was starting. That attempt's logs are retained with setup-attempt1 prefixes. Direct real fm-on.sh ledger reads established worker readiness, after which every functional scenario passed on re-drive. Two isolated image-build invocations completed successfully; the second build's actual exit status was read. No host packages, applications, or global configuration were changed.

The server was removed, all SSH collector processes were confirmed absent, and disposable source-tree data and test images were removed. These are CLI changes; the retained JSON documents and transcripts show the product surface. No visual UI changed, so no screenshot was required.
