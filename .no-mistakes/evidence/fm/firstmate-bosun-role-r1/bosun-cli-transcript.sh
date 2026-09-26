#!/usr/bin/env bash
# Manual Bosun CLI walkthrough in a disposable FM_HOME with local fixtures and a fake forge.
set -u
ROOT=$1; CLI="$ROOT/bin/fm-bosun.py"
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-bosun-demo.XXXXXX"); trap 'rm -rf "$H"' EXIT
mkdir -p "$H/data" "$H/config" "$H/state"
run() { echo "\$ $*"; "$@"; echo "[exit $?]"; echo; }
b() { FM_HOME="$H" python3 "$CLI" "$@"; }
cat > "$H/config/bosun-routes.json" <<'J'
{"schema":"fm-bosun-routes.v1","routes":[
 {"bosun":"bosun-kun","forge":"github","owner":"kunchenguid","repository_pattern":"*","fork_owner":"captain","fork_repository":"sample","upstream_default_branch":"main"},
 {"bosun":"bosun-kun","forge":"github","owner":"kunchenguid","repository":"special","fork_owner":"captain","fork_repository":"special","upstream_default_branch":"main"}]}
J
echo bosun-kun > "$H/.fm-secondmate-home"
echo "== Provision Bosun-Kun role"; run b configure-home --bosun bosun-kun; cat "$H/data/bosun-role.json"; echo
echo "== Routing"
run b route --forge github --owner kunchenguid --repository no-mistakes
run b route --forge github --owner someoneelse --repository sample
echo "== Convention precedence"
run b convention --bosun bosun-kun --forge github --owner kunchenguid --repository sample --scope shared --key commits --value conventional --confirmed --evidence https://github.com/kunchenguid/sample/pull/1 --showed 'merged PR uses conventional commits' --read-at 2026-09-26T00:00:00Z
run b convention --bosun bosun-kun --forge github --owner kunchenguid --repository sample --scope repository --key commits --value 'feat(scope):' --confirmed --evidence CONTRIBUTING.md --showed 'scoped prefixes' --read-at 2026-09-26T00:00:00Z
run b convention --bosun bosun-kun --forge github --owner kunchenguid --repository sample --scope shared --key tone --value terse --evidence guess --showed guess --read-at 2026-09-26T00:00:00Z
echo '{"format":"gofmt"}' > "$H/policy.json"
run b conventions --bosun bosun-kun --forge github --owner kunchenguid --repository sample --policy "$H/policy.json"
echo '{"format":"prettier"}' > "$H/decisions.json"
run b conventions --bosun bosun-kun --forge github --owner kunchenguid --repository sample --policy "$H/policy.json" --decisions "$H/decisions.json"
echo "== Captain order for one named maneuver"
FORK="$H/fork.git"; P="$H/projects/sample"; git init --bare -q "$FORK"; mkdir -p "$P"
git -C "$P" init -q; git -C "$P" config user.email t@e; git -C "$P" config user.name t
echo base > "$P/README.md"; git -C "$P" add .; git -C "$P" commit -qm base
git -C "$P" remote add fork https://github.com/captain/sample.git; git -C "$P" remote add upstream https://github.com/kunchenguid/sample.git
git -C "$P" checkout -qb housefeature/maneuver; echo m > "$P/maneuver.txt"; git -C "$P" add .; git -C "$P" commit -qm maneuver
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$FORK.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/captain/sample.git
git -C "$P" push -q fork HEAD:refs/heads/housefeature/maneuver
C=$(git -C "$P" rev-parse HEAD)
run b order --task maneuver --bosun bosun-kun --maneuver maneuver --forge github --owner kunchenguid --repository sample --source housefeature/maneuver --branch contribution/maneuver --captain-words 'Contribute maneuver upstream' --path maneuver.txt --commit "$C"
echo "-- adversarial: re-order same task with wider scope"
run b order --task maneuver --bosun bosun-kun --maneuver maneuver --forge github --owner kunchenguid --repository sample --source housefeature/maneuver --branch contribution/maneuver --captain-words 'Contribute maneuver upstream' --path maneuver.txt --path extra.txt --commit "$C"
echo "== Registration (fake forge snapshot)"
U=https://github.com/kunchenguid/sample/pull/12; HD=0123456789012345678901234567890123456789
run b registration-check --task maneuver --url "$U" --forge github --head other/sample --base kunchenguid/sample --branch main --head-branch contribution/maneuver --pr-head $HD --validation-head $HD --validation-mode no-mistakes --upstream-base x --changed-path maneuver.txt
run b registration-check --task maneuver --url "$U" --forge github --head captain/sample --base kunchenguid/sample --branch main --head-branch contribution/maneuver --pr-head $HD --validation-head $HD --validation-mode no-mistakes --upstream-base x --changed-path secret.txt
run b registration-check --task maneuver --url "$U" --forge github --head captain/sample --base kunchenguid/sample --branch main --head-branch contribution/maneuver --pr-head $HD --validation-head $HD --validation-mode no-mistakes --upstream-base x --changed-path maneuver.txt
run b registration-check --task maneuver --url "${U%12}13" --forge github --head captain/sample --base kunchenguid/sample --branch main --head-branch contribution/maneuver --pr-head $HD --validation-head $HD --validation-mode no-mistakes --upstream-base x --changed-path maneuver.txt
echo "== Review escalation"
mkdir -p "$H/parent"; printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$H/parent" > "$H/.fm-secondmate-parent"
run b escalate --task maneuver --feedback "$U#discussion_r1" --reason scope-change --note 'maintainer asks to also refactor docs'
echo "parent status channel:"; cat "$H/parent/state/bosun-kun.status"; echo
echo "== Merge outcome hook -> Admiral's Maneuver"
run bash -c '. "$1"; fm_merge_outcome_report "$2" "$2/state" maneuver "$3" poll' _ "$ROOT/bin/fm-merge-outcome-lib.sh" "$H" "$U"
echo "== Durable record"; jq . "$H/data/maneuver/bosun-contribution.json"
