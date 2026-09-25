# Pi composer restart provenance

This page records where the Pi composer and restart-gate behavior in this fork came from, so credit stays attached to the people whose work it adapts.
The behavior itself is owned by [`bin/fm-composer-lib.sh`](../bin/fm-composer-lib.sh) for composer classification and by [`bin/fm-secondmate-restart.sh`](../bin/fm-secondmate-restart.sh) for the restart persist gate.
This page owns attribution only; it restates no contract.

## Why the change exists

A running local Pi-backed second mate could not be restarted, because the composer check read Pi's visibly empty input box as `unknown` or `pending` and refused to type the exit command.
Three Pi screen variants were misread: a first-row editor `>` read as a draft, a compact one-rule layout read as unreadable, and a cost-first footer below a valid two-rule composer read as a dead shell.
The restart path also treated any correlated reply to its persist request as permission to restart, including a progress or failure reply.

## Adapted contributions

Each adapted idea was rewritten against current upstream `main` rather than merged from its branch.
The commits that carry an adaptation name the contributor with a `Co-authored-by` trailer using the GitHub noreply address built from the public numeric account id.

| Contributor | Source and immutable head | What was used |
| --- | --- | --- |
| KD5694 (commit author Krzysztof) | https://github.com/kunchenguid/firstmate/pull/2612 at `98042f5f60182fe860685f45aef7e1d9d9d2c661` | The one-row minimum for a separated Pi pair and its zero-height regression case. |
| dashanlkk | https://github.com/kunchenguid/firstmate/pull/5040 at `44064a5101e7d3b9ed16c8b2b50723bacf609580` | The Pi-only first-row `>` rule, its separate Pi prompt-glyph declaration, and the continuation-row negatives. |
| dashanlkk | https://github.com/kunchenguid/firstmate/pull/5556 at `40204ced69ac268346090f86c5be0a2708c4fef3` | The Pi extraction arm, queued-message-outside-the-pair fixtures, and literal `> >` preservation. |
| tiago-peixoto (Tiago) | https://github.com/kunchenguid/firstmate/issues/5666 and upstream-merged https://github.com/kunchenguid/firstmate/pull/5683 | The cost-first footer diagnosis and reproducer; the merged furniture rule is kept from upstream `main` and narrowed here. |
| Kallas95 (Maxime) | https://github.com/kunchenguid/firstmate/pull/5473 at `bdae05774b7117195b59d5116ee69075213277c6`, https://github.com/kunchenguid/firstmate/issues/5445 | The compact Pi header, input-row, and lower-rule evidence, the reverse-video cursor-cell marker, and the classifier, adapter, and control negative matrix. |
| FocalFactotum | https://github.com/kunchenguid/firstmate/pull/5600 at `fd492412ca437e6bff0e32cd625826bd9fb646ac` | The requirement that only a correlated terminal `done` reply proves a successful persist, and its restart persist-gate cases. |
| karotkriss (Christopher McKay) | https://github.com/kunchenguid/firstmate/pull/2811, already merged upstream | The blocked-Pi safety precedent this change keeps unchanged; no new code from it. |

## Deliberate departures from the sources

The newer prompt proposal treated all four shell glyphs `>`, `$`, `%`, and `#` as first-row furniture; only Pi's `>` is supported by the recorded Pi editor observations, so the other three stay typed input.
The compact proposal stored its enabling capability in a global that leaked between calls; classification and extraction here each parse the capability from their own call.
The compact layout stays disabled by default until a real versioned capture of that layout confirms its shape.
The zero-height proposal also suppressed separated geometry whenever identity was not Pi; that wider selection change is not taken here.
The persist-gate proposal also introduced a context-handoff receipt and custody protocol; only its terminal-success requirement is taken here.

## Proposals reviewed and not adopted

These were read during the synthesis and are credited here for the review, not as co-authors of this change.
https://github.com/kunchenguid/firstmate/pull/4947 would let a working Pi authorize an empty verdict.
https://github.com/kunchenguid/firstmate/pull/4252 exempts a pi-vimmode footer inside the pair without row-role evidence.
https://github.com/kunchenguid/firstmate/pull/4906, https://github.com/kunchenguid/firstmate/pull/5581, https://github.com/kunchenguid/firstmate/pull/5185, and https://github.com/kunchenguid/firstmate/pull/5046 concern Grok title normalization, a separate companion change.
https://github.com/kunchenguid/firstmate/pull/5650, https://github.com/kunchenguid/firstmate/pull/5680, https://github.com/kunchenguid/firstmate/pull/5411, https://github.com/kunchenguid/firstmate/pull/5583, https://github.com/kunchenguid/firstmate/pull/5592, https://github.com/kunchenguid/firstmate/pull/4945, https://github.com/kunchenguid/firstmate/pull/4605, and https://github.com/kunchenguid/firstmate/pull/3850 address other harnesses or later lifecycle steps.
https://github.com/kunchenguid/firstmate/pull/5064, https://github.com/kunchenguid/firstmate/pull/5086, https://github.com/kunchenguid/firstmate/pull/2495, https://github.com/kunchenguid/firstmate/pull/4452, https://github.com/kunchenguid/firstmate/pull/2096, https://github.com/kunchenguid/firstmate/pull/4421, https://github.com/kunchenguid/firstmate/pull/2396, and https://github.com/kunchenguid/firstmate/pull/5465 change wider lifecycle, capture, or trust behavior than this fix needs.

The source review used `gh-axi` and a model-assisted synthesis; no agent is credited as a co-author.
