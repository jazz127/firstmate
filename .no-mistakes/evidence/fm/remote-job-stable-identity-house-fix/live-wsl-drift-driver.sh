#!/usr/bin/env bash
# Live WSL boot-time-drift simulation: drives the real fm-remote-entrypoint.sh
# while the kernel boot time procps sees (/proc/stat btime) shifts by seconds.
set -u
LABEL=$1
cp -a /src /work && cd /work && rm -f .git
cat > bin/fm-drift-echo.sh <<'SH'
#!/usr/bin/env bash
printf 'job-ran pid=%s args=%s\n' "$$" "$*"
SH
cat > bin/fm-drift-spawn.sh <<'SH'
#!/usr/bin/env bash
# A job that leaves a trailing-whitespace descendant tree under the worker.
exec sh -c 'sleep 600; : '
SH
chmod +x bin/fm-drift-*.sh
git init -q -b house && git -c user.email=t@t -c user.name=t add -A && git -c user.email=t@t -c user.name=t commit -qm snap
mkdir -p /tmp/fmhome
b64() { printf '%s' "$1" | base64 -w0; }
argv() { printf '%s\0' "$@" | base64 -w0; }
entry() { bin/fm-remote-entrypoint.sh 1 "$(b64 /work)" "$(b64 /tmp/fmhome)" "$(argv "$@")"; }
BT=$(awk '/^btime/ {print $2}' /proc/stat)
cp /proc/stat /tmp/fakestat && mount --bind /tmp/fakestat /proc/stat || { echo "cannot bind fake /proc/stat"; exit 2; }
drift() { awk -v b=$((BT + $1)) '/^btime/ {$0="btime " b} {print}' /proc/self/mountinfo >/dev/null; awk -v b=$((BT + $1)) '/^btime/ {print "btime " b; next} {print}' /tmp/fakestat.orig > /tmp/fakestat.new; cat /tmp/fakestat.new > /tmp/fakestat; }
cp /tmp/fakestat /tmp/fakestat.orig
STATE=/root/.firstmate/remote-job
fail=0
for d in 0 3 -5 7 -2; do
  drift "$d"
  out=$(entry fm-drift-echo.sh "drift=$d" 2>&1); rc=$?
  wpid=$(cat $STATE/worker.pid 2>/dev/null)
  echo "[$LABEL] btime drift=${d}s entrypoint rc=$rc out=[$out] worker.pid=$wpid lstart(worker)=[$(ps -o lstart= -p "$wpid" 2>/dev/null)] groups=$(ps -eo pgid=,args= | awk '$3 ~ /fm-remote-job-worker.sh$/ {g[$1]=1} END {print length(g)+0}')"
  [ "$rc" -eq 0 ] || fail=1
  [ -z "${first:-}" ] && first=$wpid
  [ "$wpid" = "$first" ] || { echo "[$LABEL] worker was replaced ($first -> $wpid)"; fail=1; }
done
drift 11
entry fm-drift-spawn.sh > /tmp/spawn.out 2>&1 & SPAWN=$!
for _ in $(seq 1 100); do pgrep -f 'sleep 600' >/dev/null && break; sleep 0.1; done
echo "[$LABEL] long job running under worker (entrypoint pid $SPAWN)"
echo "[$LABEL] processes before stop:"; ps -eo pid,ppid,pgid,lstart,args | grep -E 'fm-remote-job-worker|sleep 600' | grep -v grep
drift -9
. bin/fm-remote-job-lib.sh
tree=$(fm_remote_job_process_tree_pids "$first" "$(fm_remote_job_process_start "$first")" "$(fm_remote_job_process_command "$first")")
echo "[$LABEL] tree enumeration under drift:"; printf '%s\n' "$tree"
# stop the whole worker tree: supervisor (parent of worker.pid) downwards
sup=$(ps -o ppid= -p "$first" | tr -d ' ')
if fm_remote_job_stop_worker_tree "$sup"; then echo "[$LABEL] stop_worker_tree(supervisor $sup) rc=0"; else echo "[$LABEL] stop_worker_tree rc=$? err=${FM_REMOTE_JOB_ERROR:-}"; fail=1; fi
sleep 0.5
left=$(ps -eo pid,args | grep -E 'fm-remote-job-worker|sleep 600' | grep -v grep)
echo "[$LABEL] leftover after stop: [${left}]"
[ -z "$left" ] || fail=1
kill $SPAWN 2>/dev/null; wait $SPAWN 2>/dev/null
echo "[$LABEL] RESULT fail=$fail"
umount /proc/stat
