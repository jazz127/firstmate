# House board missing-merge live validation

Validated target d872f4e1f0ab3d8e4f6b949ec73df7191735721d against base 7be45250723b416926ed285732cb1491fa688c2c.

All three product scenarios passed using real `gh-axi` calls to GitHub, with a disposable register and FM_HOME inside the run worktree. The generated page was opened and searched in a dedicated Chrome session/profile. `FM_HOUSE_BOARD_NO_SERVE=1` skipped Lavish publication; there were no substituted GitHub responses in these product scenarios.

| Scenario | Independent oracle and observed result | Evidence |
| --- | --- | --- |
| Build and open a board with PR 7's deleted merge commit | Author intent requires the missing merge SHA to be not landed. GitHub reports PR 7 merged, but its merge comparison returns 404. Base builder exits 1 at that comparison. Target builder exits 0, warns, and emits `landed: false`. Its real `historical` PR label retains documented historical/N/A display; browser search finds the row and actual PR link. | [Before fix](baseline-build.txt), [after fix](live-build.txt), [API 404](missing-compare.txt), [observed rows](observed-rows.json), [screenshot](missing-merge.png) |
| Keep a valid house ancestor landed in the same build | GitHub independently reports `behind_by: 0` and matching base/merge-base SHA db425f21 for housefeature/afk-return-sc2031. Generated row remains `landed: true`, `on_house: yes`; browser displays Yes and landed. | [GitHub ancestry](valid-ancestry.txt), [observed rows](observed-rows.json), [screenshot](valid-ancestor.png) |
| Refuse an unrelated missing upstream without overwriting a published board | A nonexistent upstream repository produces a real GitHub 404 outside merge comparison. Build exits 1 and existing HTML/JSON remain byte-for-byte unchanged. This rejects swallowing arbitrary 404 errors. | [Build transcript and preservation check](unrelated-404-build.txt) |

Full public output: [generated HTML](house-board.html), [generated JSON](house-board.json). The build completed after 478.5 seconds. Screenshots were captured from the actual generated page and visually inspected for the regression row; browser assertions also checked both rows and the PR 7 link.

Supplemental targeted check: `bash tests/fm-house-board.test.sh` exited 0. This check uses fake gh-axi/Lavish and the repository's Node rendering harness; it is supplemental simulated regression coverage, not the basis for the live result. No full suite, linters, formatters, pipeline control, publication, or fleet lifecycle operations were run.

Driver corrections: the initial full build exceeded a 240-second driver deadline; it was re-driven with a 900-second deadline and completed. The first post-build assertion incorrectly expected unlanded/No for a historically labelled PR; it was corrected to the author-required `landed: false` plus the historical/N/A contract documented in docs/fork-house-branch.md and verified from the actual PR labels. Corrected row and browser assertions exited 0. See [timeout note](first-build-timeout.txt), [actual labels](pr7-labels.txt), and [corrected assertions](row-validation.txt).

The isolated Chrome session was stopped successfully and its worktree-local profile, register, baseline copy, and disposable homes were removed. No tracked files were changed.
