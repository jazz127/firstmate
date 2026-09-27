#!/usr/bin/env bash
# Live drive of bin/fm-bosun.py against a disposable lab primary + a bosun-general home seeded by bin/fm-home-seed.sh
set -u
CLI=$1 P=$2 GH=$3
run() { echo "\$ FM_HOME=$1 fm-bosun.py ${*:2}"; local h=$1; shift; env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$GH/fork.git.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/captain/sample.git \
  FM_HOME="$h" python3 "$CLI" "$@"; echo "[exit=$?]"; }
echo "== S1: primary with no routes file -> any upstream routes to general Bosun"
run "$P" route --forge github --owner someorg --repository widget
echo "== configure roles (primary: bosun-kun + bosun-general; general home: own role)"
cat > "$P/config/bosun-routes.json" <<'EOF'
{"schema":"fm-bosun-routes.v1","routes":[
 {"bosun":"bosun-kun","forge":"github","owner":"kunchenguid","repository_pattern":"*","fork_owner":"captain","fork_repository":"sample","upstream_default_branch":"main"}]}
EOF
run "$P" configure-role --bosun bosun-kun --scope 'contributions to kunchenguid/*' 2>&1 | tail -2
run "$GH" configure-home --bosun bosun-general
echo "== S2: named route wins over general; unmatched upstream falls back to general"
run "$P" route --forge github --owner kunchenguid --repository sample
run "$P" route --forge github --owner KunChenGuid --repository Anything
run "$P" route --forge github --owner someorg --repository widget
echo "== S2b: equal-rank tie still refuses (no silent general fallback)"
cp "$P/config/bosun-routes.json" "$P/config/routes.bak"
cat > "$P/config/bosun-routes.json" <<'EOF'
{"schema":"fm-bosun-routes.v1","routes":[{"bosun":"bosun-kun","owner":"tie"},{"bosun":"bosun-other","owner":"tie"}]}
EOF
run "$P" route --forge github --owner tie --repository x
mv "$P/config/routes.bak" "$P/config/bosun-routes.json"
# project fixture inside general home
proj="$GH/projects/sample"; git init --bare -q "$GH/fork.git"; mkdir -p "$proj"
git -C "$proj" init -q; git -C "$proj" config user.email t@e; git -C "$proj" config user.name t
echo fixture > "$proj/README.md"; git -C "$proj" add README.md; git -C "$proj" commit -qm fixture
git -C "$proj" remote add fork https://github.com/captain/sample.git; git -C "$proj" remote add upstream https://github.com/kunchenguid/sample.git
base=$(git -C "$proj" rev-parse --abbrev-ref HEAD); git -C "$proj" checkout -qb housefeature/general
echo g > "$proj/general.txt"; git -C "$proj" add general.txt; git -C "$proj" commit -qm general
git -C "$proj" -c "url.file://$GH/fork.git.insteadOf=https://github.com/captain/sample.git" push -q fork HEAD:refs/heads/housefeature/general; git -C "$proj" checkout -q "$base"
C=$(git --git-dir "$GH/fork.git" rev-parse refs/heads/housefeature/general)
ord() { run "$GH" order --task "$1" --bosun bosun-general --maneuver general --forge github --owner "$2" --repository sample --source housefeature/general --branch "contribution/$1" --captain-words 'Contribute general' --path general.txt --fork-owner captain --default-branch main --commit "$C"; }
echo "== S3 (adversarial): general home has NO routes file; order for a kunchenguid target (owned by bosun-kun in primary) must refuse"
ls "$GH/config/bosun-routes.json" 2>&1
ord named kunchenguid 2>&1; ls "$GH/data/named/bosun-contribution.json" 2>&1
echo "== S3b (adversarial): stale copied routes in general home that lack the named row still cannot bypass"
echo '{"schema":"fm-bosun-routes.v1","routes":[]}' > "$GH/config/bosun-routes.json"
ord named2 kunchenguid 2>&1
echo "== S4: order for an unrouted upstream (someorg) is accepted and recorded for bosun-general"
ord gen1 someorg 2>&1; jq -c '{task,bosun,target:.target}' "$GH/data/gen1/bosun-contribution.json" 2>&1 || cat "$GH/data/gen1/bosun-contribution.json"
echo "== S5 (adversarial): parent binding points at a moved/missing primary -> fail closed"
cp "$GH/.fm-secondmate-parent" "$GH/parent.bak"
sed -i '' "s|^parent_home=.*|parent_home=$P-moved|" "$GH/.fm-secondmate-parent"; ord moved someorg 2>&1
echo "== S5b: parent binding route=remote -> fail closed"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=example\n' > "$GH/.fm-secondmate-parent"; ord remote someorg 2>&1
echo "== S5c: parent binding removed -> fail closed"
rm "$GH/.fm-secondmate-parent"; ord nobind someorg 2>&1
mv "$GH/parent.bak" "$GH/.fm-secondmate-parent"
echo "== S6: general evidence is maneuver-scoped; shared memory refused; other maneuvers can't read it"
run "$GH" convention --bosun bosun-general --forge github --owner someorg --repository sample --scope shared --key commits --value squash 2>&1
run "$GH" convention --bosun bosun-general --forge github --owner someorg --repository sample --scope repository --key commits --value squash 2>&1
run "$GH" convention --bosun bosun-general --forge github --owner someorg --repository sample --scope repository --task gen1 --key commits --value squash --confirmed --evidence CONTRIBUTING.md --showed 'requires squash' --read-at 2026-09-28T00:00:00Z
find "$GH/data" -path '*bosun-evidence*' -type f; ls "$GH/data/bosun-memory" 2>&1
echo '{"commits":"merge"}' > "$GH/policy.json"
echo "-- same maneuver (gen1):"; run "$GH" conventions --bosun bosun-general --forge github --owner someorg --repository sample --task gen1 --policy "$GH/policy.json"
echo "-- different maneuver (gen2):"; run "$GH" conventions --bosun bosun-general --forge github --owner someorg --repository sample --task gen2 --policy "$GH/policy.json"
