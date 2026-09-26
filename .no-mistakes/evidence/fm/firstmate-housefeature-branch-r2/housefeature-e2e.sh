#!/usr/bin/env bash
# End-to-end drive of the house-feature lifecycle against a local bare "fork".
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
W=$(mktemp -d); trap 'rm -rf "$LAB" "$W"' EXIT
fork=$W/fork.git; seed=$W/seed; work=$W/work; fb=$W/bin; mkdir -p $fb
# gh-axi stand-in for GitHub's create-ref API: create-only on the bare fork.
cat > $fb/gh-axi <<'F'
#!/usr/bin/env bash
ref=${5#ref=}; sha=${7#sha=}
git --git-dir="$FORK" update-ref "$ref" "$sha" 0000000000000000000000000000000000000000
F
chmod +x $fb/gh-axi; export FORK=$fork PATH="$fb:$PATH"
g(){ git -c user.name=T -c user.email=t@x.invalid "$@"; }
git init -q -b main $seed; echo base>$seed/base.txt; g -C $seed add .; g -C $seed commit -qm base
git clone -q --bare $seed $fork; git -C $seed remote add origin $fork
g -C $seed checkout -qb house; echo house>$seed/house.txt; g -C $seed add .; g -C $seed commit -qm house-only-commit; g -C $seed push -q origin house
git --git-dir=$fork symbolic-ref HEAD refs/heads/house
git clone -q $fork $work; git -C $work config remote.origin.url https://github.com/jazz127/firstmate.git
git -C $work config url.file://$fork.insteadOf https://github.com/jazz127/firstmate.git
git -C $work checkout -q --detach origin/house
echo "### 1. firstmate scaffolds a main-based house-feature brief"
FM_HOME=$LAB "$ROOT/bin/fm-brief.sh" demo-r1 firstmate --mode no-mistakes --house-feature demo --branch-base main
brief=$LAB/data/demo-r1/brief.md
grep -nE 'First action|House feature intake|setup command|durable|merge commit|integration|torn down' $brief
cmd=$(sed -n 's/^1\. First action: prepare your branch: `\([^`]*\)`.*/\1/p' $brief)
echo; echo "### 2. worker runs the brief's first action: $cmd"
(cd $work && eval "$cmd"); echo rc=$?
echo "remote housefeature/demo = $(git --git-dir=$fork rev-parse --short refs/heads/housefeature/demo); fork main = $(git --git-dir=$fork rev-parse --short main)"
echo "worker branch: $(git -C $work branch --show-current) at $(git -C $work rev-parse --short HEAD); house-only file present? $([ -e $work/house.txt ] && echo yes || echo no)"
echo; echo "### 3. worker commits the first real work on fm/demo-r1 and it lands in housefeature/demo as a merge commit"
echo feature>$work/feature.txt; g -C $work add .; g -C $work commit -qm 'feature work'; git -C $work push -q origin fm/demo-r1
g -C $seed fetch -q origin; g -C $seed checkout -qB housefeature/demo origin/housefeature/demo; g -C $seed merge -q --no-ff -m 'Merge PR fm/demo-r1 into housefeature/demo' origin/fm/demo-r1; g -C $seed push -q origin housefeature/demo
git --git-dir=$fork log --oneline --graph housefeature/demo
git --git-dir=$fork merge-base --is-ancestor main housefeature/demo && echo "housefeature/demo contains fork main: yes"
echo; echo "### 4. integration PR housefeature/demo -> house merges; durable branch survives"
g -C $seed checkout -q house; g -C $seed merge -q --no-ff -m 'Merge PR housefeature/demo into house' origin/housefeature/demo 2>/dev/null || g -C $seed merge -q --no-ff -m 'Merge PR housefeature/demo into house' housefeature/demo; g -C $seed push -q origin house
echo "cut workflow classify for that merged PR: $(HF_MERGED=true HF_BASE_REF=house HF_HEAD_REF=housefeature/demo HF_HEAD_REPO=jazz127/firstmate HF_BASE_REPO=jazz127/firstmate "$ROOT/bin/fm-housefeature-cut.sh" classify)"; echo "control (ordinary fm/other -> house): $(HF_MERGED=true HF_BASE_REF=house HF_HEAD_REF=fm/other HF_HEAD_REPO=jazz127/firstmate HF_BASE_REPO=jazz127/firstmate "$ROOT/bin/fm-housefeature-cut.sh" classify)"
echo "remote heads after integration:"; git --git-dir=$fork for-each-ref --format='  %(refname:short)' refs/heads
echo; echo "### 5. next round: main moves ahead; new fm/demo-r2 is cut from the durable head, no automatic main merge"
g -C $seed checkout -q main; echo up>$seed/upstream.txt; g -C $seed add .; g -C $seed commit -qm upstream-move; g -C $seed push -q origin main
git -C $work checkout -q --detach
FM_HOME=$LAB "$ROOT/bin/fm-brief.sh" demo-r2 firstmate --mode direct-PR --house-feature demo --branch-base main >/dev/null
cmd=$(sed -n 's/^1\. First action: prepare your branch: `\([^`]*\)`.*/\1/p' $LAB/data/demo-r2/brief.md)
before=$(git --git-dir=$fork rev-parse refs/heads/housefeature/demo)
(cd $work && eval "$cmd"); echo rc=$?
echo "worker at durable head: $([ "$(git -C $work rev-parse HEAD)" = "$before" ] && echo yes || echo no); durable head unchanged: $([ "$(git --git-dir=$fork rev-parse refs/heads/housefeature/demo)" = "$before" ] && echo yes || echo no); upstream.txt auto-merged: $([ -e $work/upstream.txt ] && echo yes || echo no)"
grep -n 'pass `--base housefeature/demo`' $LAB/data/demo-r2/brief.md
echo; echo "### 6. house-only feature: durable branch cut from house, label instruction"
git -C $work checkout -q --detach
FM_HOME=$LAB "$ROOT/bin/fm-brief.sh" solo-r1 firstmate --mode direct-PR --house-feature solo --branch-base house >/dev/null
grep -n 'house-only' $LAB/data/solo-r1/brief.md
cmd=$(sed -n 's/^1\. First action: prepare your branch: `\([^`]*\)`.*/\1/p' $LAB/data/solo-r1/brief.md); (cd $work && eval "$cmd")
echo "housefeature/solo == house: $([ "$(git --git-dir=$fork rev-parse housefeature/solo)" = "$(git --git-dir=$fork rev-parse house)" ] && echo yes || echo no)"
echo; echo "### 7. adversarial refusals"
for a in "--house-feature x" "--branch-base main" "--branch-prefix housefeature/" "--house-feature a/b --branch-base main" "--house-feature x --branch-base upstream"; do
  echo "\$ fm-brief.sh bad firstmate --mode direct-PR $a"; FM_HOME=$LAB "$ROOT/bin/fm-brief.sh" bad firstmate --mode direct-PR $a 2>&1; echo "  rc=$?"; done
echo "\$ fm-brief.sh bad firstmate --mode local-only --house-feature x --branch-base main"; FM_HOME=$LAB "$ROOT/bin/fm-brief.sh" bad firstmate --mode local-only --house-feature x --branch-base main 2>&1; echo "  rc=$?"
echo "\$ (dirty worktree) fm-housefeature-start.sh demo main fm/dirty"; git -C $work checkout -q --detach; echo x>$work/dirt; (cd $work && "$ROOT/bin/fm-housefeature-start.sh" demo main fm/dirty 2>&1); echo "  rc=$?"; rm $work/dirt
echo "\$ fm-housefeature-start.sh demo main housefeature/demo"; (cd $work && "$ROOT/bin/fm-housefeature-start.sh" demo main housefeature/demo 2>&1); echo "  rc=$?"
echo "final remote heads (nothing deleted):"; git --git-dir=$fork for-each-ref --format='  %(refname:short)' refs/heads
