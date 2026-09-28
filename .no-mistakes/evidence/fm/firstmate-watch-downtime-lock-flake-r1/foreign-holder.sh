#!/bin/bash
# Waits for the held-marker-lock case's watcher to finish a poll cycle (its
# beat file changes mtime), then races to hold that state's .watcher-down.lock
# for 25s so the fixture's bounded 10s wait must give up.
lib=$1 tmpbase=$2
for i in $(seq 1 600); do
  st=$(ls -d "$tmpbase"/fm-watch-triage-tests.*/*term-held-marker-lock*/state 2>/dev/null | head -1)
  [ -n "$st" ] && [ -e "$st/.last-watcher-beat" ] && break
  sleep 0.02
done
[ -e "$st/.last-watcher-beat" ] || { echo "no beat"; exit 1; }
first=$(stat -f %m "$st/.last-watcher-beat")
while [ "$(stat -f %m "$st/.last-watcher-beat" 2>/dev/null)" = "$first" ]; do sleep 0.01; done
. "$lib"
until fm_lock_try_acquire "$st/.watcher-down.lock"; do sleep 0.005; done
echo "foreign holder pid=$$ took $st/.watcher-down.lock"
sleep 25
fm_lock_release "$st/.watcher-down.lock"
