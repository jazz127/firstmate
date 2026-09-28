#!/bin/bash
# usage: stress.sh <testfile> <testname> <lanes> <iters> <outdir> <label>
f=$1 t=$2 lanes=$3 iters=$4 out=$5 label=$6
mkdir -p "$out"
for l in $(seq 1 $lanes); do
  ( for i in $(seq 1 $iters); do
      FM_TEST_ONLY=$t bash "$f" > "$out/$label-l$l-i$i.log" 2>&1; echo "$label lane=$l iter=$i rc=$?" >> "$out/$label-results.txt"
    done ) &
done
wait
