#!/usr/bin/env bash
# Live drive pass 2: named Bosun registered in the lab primary via bin/fm-home-seed.sh
set -u
CLI=$1 P=$2 GH=$3 LAB=$4 WT=$5
run() { echo "\$ FM_HOME=$1 fm-bosun.py ${*:2}"; local h=$1; shift; env -u NO_MISTAKES_GATE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$GH/fork.git.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/captain/sample.git \
  FM_HOME="$h" python3 "$CLI" "$@"; echo "[exit=$?]"; }
echo "== provision named bosun-kun in lab primary through fm-home-seed.sh"
(cd "$WT" && env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE FM_HOME="$P" FM_SECONDMATE_CHARTER='Bosun-Kun: contributions to kunchenguid/*' FM_SECONDMATE_SCOPE='contributions to kunchenguid/*' bin/fm-home-seed.sh bosun-kun "$LAB/kun" --no-projects 2>&1 | tail -1)
run "$P" configure-home --bosun bosun-kun
run "$P" configure-home --bosun bosun-general
echo "== S2: named Bosun wins for its upstreams; unmatched upstreams resolve to bosun-general"
run "$P" route --forge github --owner kunchenguid --repository sample
run "$P" route --forge github --owner KunChenGuid --repository Anything
run "$P" route --forge github --owner someorg --repository widget
run "$P" route --forge github --owner kunchenguid-fork --repository sample
echo "== S4: order for an unrouted upstream (someorg/sample) accepted and recorded for bosun-general"
proj="$GH/projects/sample"; git -C "$proj" remote set-url upstream https://github.com/someorg/sample.git
C=$(git --git-dir "$GH/fork.git" rev-parse refs/heads/housefeature/general)
run "$GH" order --task gen1 --bosun bosun-general --maneuver general --forge github --owner someorg --repository sample --source housefeature/general --branch contribution/gen1 --captain-words 'Contribute general to someorg' --path general.txt --fork-owner captain --default-branch main --commit "$C"
jq -c '{task,bosun,state,maneuver,target,captain_order}' "$GH/data/gen1/bosun-contribution.json"
echo "== S4b: even when the project clone targets kunchenguid, general order for kunchenguid still refuses on named route"
run "$GH" order --task gen-kun --bosun bosun-general --maneuver general --forge github --owner kunchenguid --repository sample --source housefeature/general --branch contribution/gen-kun --captain-words x --path general.txt --fork-owner captain --default-branch main --commit "$C"
echo "== S4c: general Bosun cannot order without Captain words / maneuver (explicit-order guard)"
run "$GH" order --task gen-noorder --bosun bosun-general --forge github --owner someorg --repository sample --source housefeature/general --branch contribution/x --path general.txt --fork-owner captain --default-branch main --commit "$C" 2>&1 | tail -2
echo "== S6: evidence under the maneuver task id; another maneuver cannot read it"
run "$GH" convention --bosun bosun-general --forge github --owner someorg --repository sample --scope repository --task gen1 --key commits --value squash --confirmed --evidence CONTRIBUTING.md --showed 'requires squash' --read-at 2026-09-28T00:00:00Z
echo '{}' > "$GH/policy.json"
echo "-- same maneuver (gen1):"; run "$GH" conventions --bosun bosun-general --forge github --owner someorg --repository sample --task gen1 --policy "$GH/policy.json"
echo "-- different maneuver (gen2):"; run "$GH" conventions --bosun bosun-general --forge github --owner someorg --repository sample --task gen2 --policy "$GH/policy.json"
echo "== S7: intake of general contribution builds the ship brief via real fm-brief.sh (spawn stubbed) naming the contribution task for evidence"
echo "\$ FM_HOME=$GH FM_ROOT_OVERRIDE=<lab copy of HEAD with fm-spawn.sh stub> fm-bosun.py intake --task gen1"
env -u NO_MISTAKES_GATE FM_HOME="$GH" FM_ROOT_OVERRIDE="$LAB/root" python3 "$CLI" intake --task gen1; echo "[exit=$?]"
jq -c '{state,task_mode,task_worktree}' "$GH/data/gen1/bosun-contribution.json"
echo "-- brief excerpt:"; grep -n "general Bosun\|convention --bosun\|authorized only for Bosun\|Captain's exact order" "$GH/data/gen1/brief.md"
