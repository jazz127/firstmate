#!/usr/bin/env bash
# Manual Bosun CLI transcript against a disposable FM_HOME (no network, no forge).
set -u
CLI="$PWD/bin/fm-bosun.py"
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-bosun-manual.XXXXXX"); bin/fm-lab-home.sh create "$H" >/dev/null
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-bosun-sm.XXXXXX")
for id in bosun-kun bosun-special bosun-a bosun-b; do
  printf -- '- %s - Bosun fixture (host: local; root: %s; home: %s/%s; scope: contributions; projects: ; added 2026-09-27)\n' "$id" "$PWD" "$S" "$id" >> "$H/data/secondmates.md"
done
echo "## Primary home configures Bosun-Kun role record"
cp docs/examples/bosun-routes.json "$H/config/bosun-routes.json"
FM_HOME="$H" python3 bin/fm-bosun.py configure-home --bosun bosun-kun; echo "configure-home rc=$?"
for id in bosun-special bosun-a bosun-b; do FM_HOME="$H" python3 bin/fm-bosun.py configure-home --bosun $id >/dev/null 2>&1 || true; done
run() { echo "\$ $*"; FM_HOME="$H" "$@" 2>&1; echo "[rc=$?]"; echo; }
cp docs/examples/bosun-routes.json "$H/config/bosun-routes.json"
echo "## Routing with the shipped Bosun-Kun example route"
run python3 "$CLI" route --forge github --owner kunchenguid --repository no-mistakes
run python3 "$CLI" route --forge github --owner someone-else --repository tool
run python3 "$CLI" route --forge gitlab --owner kunchenguid --repository no-mistakes
echo "## Exact repository route outranks owner pattern; equal-rank tie refuses"
cat > "$H/config/bosun-routes.json" <<'J'
{"schema":"fm-bosun-routes.v1","routes":[
 {"bosun":"bosun-kun","forge":"github","owner":"kunchenguid","repository_pattern":"*"},
 {"bosun":"bosun-special","forge":"github","owner":"kunchenguid","repository":"special"},
 {"bosun":"bosun-a","forge":"github","owner":"tie","repository":"x"},
 {"bosun":"bosun-b","forge":"github","owner":"tie","repository":"x"}]}
J
run python3 "$CLI" route --forge github --owner kunchenguid --repository special
run python3 "$CLI" route --forge github --owner kunchenguid --repository other
run python3 "$CLI" route --forge github --owner tie --repository x
echo "## Unregistered Bosun in a route is refused"
echo '{"schema":"fm-bosun-routes.v1","routes":[{"bosun":"bosun-ghost","forge":"github","owner":"ghost"}]}' > "$H/config/bosun-routes.json"
run python3 "$CLI" route --forge github --owner ghost --repository any
echo "## Evidence-backed memory and convention precedence (inside the Bosun's own secondmate home)"
H2=$H; H=$(mktemp -d "${TMPDIR:-/tmp}/fm-bosun-home.XXXXXX"); bin/fm-lab-home.sh create "$H" >/dev/null
cp docs/examples/bosun-routes.json "$H/config/bosun-routes.json"
printf '%s\n' bosun-kun > "$H/.fm-secondmate-home"
run python3 "$CLI" configure-home --bosun bosun-kun
T="--bosun bosun-kun --forge github --owner kunchenguid --repository no-mistakes"
run python3 "$CLI" convention $T --scope shared --key commit_style --value conventional --confirmed --evidence https://github.com/kunchenguid/no-mistakes/pull/1 --showed "merged PR titles use conventional commits" --read-at 2026-09-27T00:00:00Z
run python3 "$CLI" convention $T --scope shared --key commit_style --value guess --confirmed
run python3 "$CLI" convention $T --scope repository --key pr_body --value "guess-only note"
run python3 "$CLI" convention $T --scope repository --key commit_style --value "conventional+scope" --confirmed --evidence CONTRIBUTING.md --showed "scope required" --read-at 2026-09-27T00:00:00Z
echo '{}' > "$H/policy.json"
run python3 "$CLI" conventions $T --policy "$H/policy.json"
echo '{"commit_style":"from-current-AGENTS.md"}' > "$H/policy.json"
run python3 "$CLI" conventions $T --policy "$H/policy.json"
echo '{"commit_style":"captain-wants-other"}' > "$H/decisions.json"
run python3 "$CLI" conventions $T --policy "$H/policy.json" --decisions "$H/decisions.json"
echo "## Authorization boundaries without an order/published PR"
run python3 "$CLI" escalate --task nosuch --feedback https://github.com/kunchenguid/no-mistakes/pull/9#r1 --reason scope-change --note "asks for more"
run python3 "$CLI" merged --task nosuch --url https://github.com/kunchenguid/no-mistakes/pull/9
echo "## Files written in Bosun home"; (cd "$H" && find data -type f | sort); echo; cat "$H/data/bosun-memory/bosun-kun/profile.json"; echo; cat "$H/data/bosun-memory/bosun-kun/repos/github/kunchenguid/no-mistakes.json"; echo
echo "## Primary role records"; (cd "$H2" && find data/bosuns -type f | sort); cat "$H2/data/bosuns/bosun-kun.json"
rm -rf "$H" "$H2" "$S"
