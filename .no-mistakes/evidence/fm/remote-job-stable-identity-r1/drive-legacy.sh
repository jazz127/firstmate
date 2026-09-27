#!/bin/bash
# Usage: drive-legacy.sh <stable|drifted|french|reused-pid>
# Starts a pre-upgrade (base) worker through the real entrypoint, deploys the target code, and calls again.
set -u
CASE=$1
mv /usr/bin/ps /usr/bin/ps.real && cp /lab/ps-drift /usr/bin/ps
useradd -m remote >/dev/null 2>&1
ROOT=/srv/fm-root; FMHOME=/srv/fm-home
mkdir -p $ROOT $FMHOME /home/remote/.local/bin
tar -xf /lab/base.tar -C $ROOT
printf '#!/bin/bash\nprintf "probe ok pid=%%s\\n" "$$"\n' > $ROOT/bin/fm-probe-job.sh; chmod +x $ROOT/bin/fm-probe-job.sh
G="git -C $ROOT -c user.email=t@e -c user.name=t"
$G init -q -b main && $G add -A && $G commit -qm base
ln -s $ROOT/bin/fm-remote-entrypoint.sh /home/remote/.local/bin/fm-remote-entrypoint.sh
chown -R remote $ROOT $FMHOME /home/remote; git config --system --add safe.directory $ROOT
b64() { base64 -w0; }
R=$(printf '%s' $ROOT | b64); H=$(printf '%s' $FMHOME | b64); A=$(printf '%s\0' fm-probe-job.sh | b64)
LANGV=C.UTF-8; [ "$CASE" = french ] && LANGV=fr_FR.UTF-8
call() { su remote -c "cd ~ && LANG=$LANGV LC_ALL=$LANGV PATH=/home/remote/.local/bin:/usr/bin:/bin fm-remote-entrypoint.sh 1 $R $H $A" 2>&1; }
S=/home/remote/.firstmate/remote-job
echo "== case=$CASE: pre-upgrade worker from base commit =="
echo "base call: rc=$(call >/tmp/o; echo $?) $(cat /tmp/o)"
OLD=$(cat $S/worker.pid); OLDPG=$(ps.real -o pgid= -p $OLD | tr -d ' ')
echo "old worker pid=$OLD pgid=$OLDPG cmd='$(ps.real -o args= -p $OLD)'"
echo "legacy worker.lock/start='$(cat $S/worker.lock/start)'"
DECOY=
if [ "$CASE" = drifted ] || [ "$CASE" = reused-pid ]; then touch -d '-30 seconds' /tmp/drift-on; fi
echo "ps lstart of old worker now='$(ps -o lstart= -p $OLD)'"
if [ "$CASE" = reused-pid ]; then
  # Stop the old worker tree, then plant legacy records naming a live decoy whose command looks like a worker lane.
  kill -KILL -- -$OLDPG; sleep 1
  mkdir -p /srv/decoy; printf '#!/bin/bash\nwhile :; do sleep 0.2; done\n' > /srv/decoy/fm-remote-job-worker.sh; chmod +x /srv/decoy/fm-remote-job-worker.sh
  su remote -c "setsid /srv/decoy/fm-remote-job-worker.sh >/dev/null 2>&1 & echo \$! > /tmp/decoy.pid"; sleep 0.5; DECOY=$(cat /tmp/decoy.pid)
  echo "decoy pid=$DECOY cmd='$(ps.real -o args= -p $DECOY)' real-lstart='$(LC_ALL=C ps.real -o lstart= -p $DECOY)'"
  LEG='Sun Sep 27 01:02:03 2026'
  printf '%s\n' $DECOY > $S/worker.lock/pid; printf '%s\n' "$LEG" > $S/worker.lock/start
  printf '%s\n' "$DECOY" > $S/worker.pid; touch -d '-5 minutes' $S/worker.ready $S/worker.lock
  JOBID=$(su -s /bin/bash remote -c "cd ~ && export HOME=/home/remote; . $ROOT/bin/fm-remote-job-lib.sh; fm_remote_job_stage /home/remote $ROOT $FMHOME fm-probe-job.sh </dev/null >/dev/null; echo \$FM_REMOTE_JOB_ID")
  [ -n "$JOBID" ] || { echo "job staging failed"; exit 1; }; J=$S/jobs/$JOBID
  su -s /bin/bash remote -c "mkdir -p $J/.claim && printf '%s\n' $DECOY > $J/.claim/owner && printf '%s\n' '$LEG' > $J/.claim/owner_start && printf '%s\n' $DECOY > $J/.claim/supervisor && printf '%s\n' '$LEG' > $J/.claim/supervisor_start && printf 'running\n' > $J/state && : > $J/stdout && : > $J/stderr"
  echo "planted running job $JOBID with legacy claim/supervisor records naming decoy $DECOY: $(ls $J/.claim | tr '\n' ' ')"
fi
echo "== deploy target commit =="
rm -rf $ROOT/bin; tar -xf /lab/target.tar -C $ROOT
printf '#!/bin/bash\nprintf "probe ok pid=%%s\\n" "$$"\n' > $ROOT/bin/fm-probe-job.sh; chmod +x $ROOT/bin/fm-probe-job.sh
$G add -A && $G commit -qm target; chown -R remote $ROOT
for i in 1 2 3; do
  echo "target call $i: rc=$(call >/tmp/o; echo $?) $(tr '\n' ' ' </tmp/o) worker.pid=$(cat $S/worker.pid)"
  sleep 1
done
NEW=$(cat $S/worker.pid)
echo "old worker $OLD alive? $(kill -0 $OLD 2>/dev/null && echo YES || echo no); old group alive? $(kill -0 -- -$OLDPG 2>/dev/null && echo YES || echo no)"
echo "new worker pid=$NEW worker.lock/start='$(cat $S/worker.lock/start)'"
if [ -n "$DECOY" ]; then
  echo "decoy $DECOY alive after upgrade? $(kill -0 $DECOY 2>/dev/null && echo YES || echo no)"
  echo "planted job state=$(cat $J/state 2>/dev/null) exit=$(cat $J/exit 2>/dev/null) claim-present=$([ -e $J/.claim ] && echo yes || echo no) stderr='$(cat $J/stderr 2>/dev/null)'"
fi
echo "--- worker log ---"; tail -n 6 $S/logs/*.log
