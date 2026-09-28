#!/usr/bin/env bash
# load-run.sh <tree> <hogs> <drivers> <trials> <tag>: run <drivers> parallel
# term-latency drivers against <tree> while <hogs> busy loops saturate the CPUs.
EV=$(cd "$(dirname "$0")" && pwd); TREE=$1; H=$2; N=$3; T=$4; TAG=$5
Y=(); for n in $(seq "$H"); do yes > /dev/null & Y+=($!); done
D=(); for k in $(seq "$N"); do TRACE=1 "$EV/term-latency-driver.sh" "$TREE" "$T" > "/tmp/fm-$TAG-$k.txt" 2>&1 & D+=($!); done
wait "${D[@]}"; kill "${Y[@]}" 2>/dev/null
echo "# $TAG: tree=$TREE hogs=$H parallel_drivers=$N trials=$T ncpu=$(sysctl -n hw.ncpu)"
for k in $(seq "$N"); do echo "== driver $k"; grep -v '^$' "/tmp/fm-$TAG-$k.txt"; rm -f "/tmp/fm-$TAG-$k.txt"; done
