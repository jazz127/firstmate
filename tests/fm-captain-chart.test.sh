#!/usr/bin/env bash
# Behavior tests for the code-only Captain Chart renderer.
set -eu

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/projects.md" <<'EOF'
- alpha [no-mistakes] - First island (added 2026-09-01)
- beta [direct-PR dock=Review-Quay] - Second island (added 2026-09-01)
- empty [local-only] - Third island (added 2026-09-01)
EOF
cat > "$tmp/snapshot.json" <<'EOF'
{
  "schema":"fm-bearings.v1","generated":"2026-09-25T00:00:00Z",
  "in_flight":[
    {"id":"run","name":"Running task","repo":"alpha","state":"working"},
    {"id":"idle","name":"Idle task","repo":"alpha","state":"idle"},
    {"id":"pause","name":"Paused task","repo":"beta","state":"paused"},
    {"id":"fail","name":"Failed task","repo":"beta","state":"failed"},
    {"id":"block","name":"Blocked task","repo":"beta","state":"blocked"}
  ],
  "gates":[{"id":"queued","title":"Queued task"}],
  "recorded_prs":[{"id":"run","url":"https://github.com/example/repo/pull/7"}],
  "reports":[{"id":"pause","path":"data/pause/report.md"}]
}
EOF
chart="$ROOT/bin/fm-captain-chart.py"
python3 "$chart" --snapshot-file "$tmp/snapshot.json" --registry-file "$tmp/projects.md" --stdout > "$tmp/one.mmd"
python3 "$chart" --snapshot-file "$tmp/snapshot.json" --registry-file "$tmp/projects.md" --stdout > "$tmp/two.mmd"
cmp -s "$tmp/one.mmd" "$tmp/two.mmd" || fail "same fleet state changed Mermaid output"
sed 's/2026-09-25T00:00:00Z/2026-09-26T00:00:00Z/' "$tmp/snapshot.json" > "$tmp/later.json"
python3 "$chart" --snapshot-file "$tmp/later.json" --registry-file "$tmp/projects.md" --stdout > "$tmp/later.mmd"
cmp -s "$tmp/one.mmd" "$tmp/later.mmd" || fail "collection timestamp changed Mermaid output"
pass "same fleet state gives the same Mermaid document"

for island in alpha beta empty; do
  grep -F "Island: $island" "$tmp/one.mmd" >/dev/null || fail "missing registered island $island"
done
grep -F 'Running task<br/>under sail<br/>Cargo: PR https://github.com/example/repo/pull/7' "$tmp/one.mmd" >/dev/null || fail "running task did not sail with its PR"
grep -F 'Idle task<br/>moored<br/>Cargo: nothing' "$tmp/one.mmd" >/dev/null || fail "idle task or empty cargo mapped incorrectly"
grep -F 'Paused task<br/>anchored<br/>Cargo: Report data/pause/report.md' "$tmp/one.mmd" >/dev/null || fail "paused task or report mapped incorrectly"
grep -F 'Failed task<br/>sunk<br/>Cargo: nothing' "$tmp/one.mmd" >/dev/null || fail "failed task did not sink"
grep -F 'Blocked task<br/>in dry dock<br/>Cargo: nothing' "$tmp/one.mmd" >/dev/null || fail "blocked task did not enter dry dock"
grep -F 'to Review Quay' "$tmp/one.mmd" >/dev/null || fail "project dock missing"
grep -F 'to Capital city' "$tmp/one.mmd" >/dev/null || fail "capital destination missing"
if grep -F 'undefined' "$tmp/one.mmd" >/dev/null; then fail "undefined placeholder appeared"; fi
pass "islands, ship states, cargo, and docks reflect recorded facts"

python3 "$chart" --snapshot-file "$tmp/snapshot.json" --registry-file "$tmp/projects.md" --ascii > "$tmp/one.txt"
python3 "$chart" --snapshot-file "$tmp/snapshot.json" --registry-file "$tmp/projects.md" --ascii > "$tmp/two.txt"
cmp -s "$tmp/one.txt" "$tmp/two.txt" || fail "same fleet state changed ASCII map"
for island in alpha beta empty; do
  grep -F "island: $island" "$tmp/one.txt" >/dev/null || fail "ASCII map omitted island $island"
done
grep -F '◿│◣ Running task [under sail]' "$tmp/one.txt" >/dev/null || fail "ASCII map omitted sailing task"
grep -F 'o Idle task [moored]' "$tmp/one.txt" >/dev/null || fail "ASCII map sailed idle task"
grep -F 'o Paused task [anchored]' "$tmp/one.txt" >/dev/null || fail "ASCII map sailed paused task"
grep -F -- '-> Review Quay' "$tmp/one.txt" >/dev/null || fail "ASCII map omitted satellite dock"
pass "ASCII map shares fleet mapping and is deterministic"

for state in 's1|Running task|under sail|sailing|◿│◣|╲▁▁▁╱' \
  's0|Idle task|moored|resting|o|     ' \
  's4|Paused task|anchored|resting|o|     ' \
  's3|Failed task|sunk|resting|o|     ' \
  's2|Blocked task|in dry dock|resting|o|     '; do
  IFS='|' read -r ship_id name nautical class glyph hull <<EOF
$state
EOF
  grep -F "$name<br/>$nautical" "$tmp/one.mmd" >/dev/null || fail "Mermaid lost $name state"
  grep -F "class $ship_id $class" "$tmp/one.mmd" >/dev/null || fail "Mermaid lost $name sail class"
  grep -F "$glyph $name [$nautical]" "$tmp/one.txt" >/dev/null || fail "ASCII lost $name sprite"
  grep -F "$hull cargo:" "$tmp/one.txt" >/dev/null || fail "ASCII lost $name hull"
done
pass "Mermaid and ASCII consume the same ship presentation states"

if command -v mmdc >/dev/null 2>&1; then
  python3 "$chart" --snapshot-file "$tmp/snapshot.json" --registry-file "$tmp/projects.md" --output "$tmp/chart.mmd" >/dev/null
  [ -s "$tmp/chart.svg" ] || fail "mmdc did not render non-empty SVG"
  for island in alpha beta empty; do
    grep -F "Island: $island" "$tmp/chart.svg" >/dev/null || fail "SVG omitted island $island"
  done
  pass "local mmdc renders a non-empty SVG with every registered island"
else
  printf 'skip - mmdc is not installed; SVG smoke check runs where the local renderer exists\n'
fi
