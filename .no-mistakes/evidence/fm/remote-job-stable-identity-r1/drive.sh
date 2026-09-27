#!/bin/bash
# Usage: drive.sh <base|target> ; drives the real fm-remote-entrypoint.sh under a drifting ps lstart.
set -u
REF=$1
mv /usr/bin/ps /usr/bin/ps.real && cp /lab/ps-drift /usr/bin/ps
useradd -m remote >/dev/null 2>&1
ROOT=/srv/fm-root; FMHOME=/srv/fm-home
mkdir -p $ROOT $FMHOME /home/remote/.local/bin
tar -xf /lab/$REF.tar -C $ROOT
cat > $ROOT/bin/fm-probe-job.sh <<'SH'
#!/bin/bash
printf 'probe ok pid=%s\n' "$$"
SH
chmod +x $ROOT/bin/fm-probe-job.sh
git -C $ROOT init -q -b main && git -C $ROOT -c user.email=t@e -c user.name=t add -A && git -C $ROOT -c user.email=t@e -c user.name=t commit -qm fixture
ln -s $ROOT/bin/fm-remote-entrypoint.sh /home/remote/.local/bin/fm-remote-entrypoint.sh
chown -R remote $ROOT $FMHOME /home/remote
git config --system --add safe.directory $ROOT
b64() { base64 -w0; }
R=$(printf '%s' $ROOT | b64); H=$(printf '%s' $FMHOME | b64); A=$(printf '%s\0' fm-probe-job.sh | b64)
call() { su remote -c "cd ~ && PATH=/home/remote/.local/bin:/usr/bin:/bin fm-remote-entrypoint.sh 1 $R $H $A" ; }
state=/home/remote/.local/state/firstmate/remote-jobs
echo "== ref=$REF kernel=$(uname -sr) drift-shim=on =="
rm -f /tmp/drift-on; touch /tmp/drift-on
ok=0; bad=0; pids=()
run_calls() { local n=$1 label=$2
for i in $(seq 1 $n); do
  t=$(date +%T)
  out=$(call 2>&1); rc=$?
  wpid=$(cat $(find /home/remote -name worker.pid 2>/dev/null | head -1) 2>/dev/null)
  lstart_now=$(ps -o lstart= -p "${wpid:-1}" 2>/dev/null)
  echo "[$t] $label call=$i rc=$rc worker.pid=${wpid:-none} ps-lstart-now='${lstart_now}' out=$(echo "$out" | tr '\n' ' ')"
  [ $rc -eq 0 ] && ok=$((ok+1)) || bad=$((bad+1))
  pids+=("${wpid:-none}")
  sleep 1.5
done
}
run_calls 6 steady
echo "== deploy new worker code (upgrade): append to fm-remote-job-worker.sh and commit =="
printf '\n# upgrade\n' >> $ROOT/bin/fm-remote-job-worker.sh; git -C $ROOT -c user.email=t@e -c user.name=t commit -qam upgrade
run_calls 5 post-upgrade
lock=$(find /home/remote -type d -name worker.lock | head -1)
echo "worker.lock/start=$(cat $lock/start 2>/dev/null)"
echo "distinct worker pids: $(printf '%s\n' "${pids[@]}" | sort -u | tr '\n' ' ')"
echo "RESULT ref=$REF ok=$ok failed=$bad"
echo "--- worker log tail ---"; tail -n 8 $(find /home/remote -name '*.log' | head -1) 2>/dev/null
