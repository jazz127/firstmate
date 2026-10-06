# Disposable house register
## firstmate
- Fork `jazz127/firstmate` (default branch `house`); upstream `kunchenguid/firstmate`.
- On `house`:
  - **Offer closeout** (PR 192, `housefeature/offer-closeout`) — Configurable review window for outside PRs (two-hour default, zero for immediate closeout); signals guarded cleanup only when CI is ready, feedback is acknowledged, and the workspace is clean, and keeps monitoring the PR after cleanup.
  - **Lock PID reuse** (PR 188, `housefeature/fm-lock-pid-reuse`) — Reclaims stale locks whose recorded PID was reused by an unrelated process after the owner exited.
