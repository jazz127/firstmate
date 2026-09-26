#!/usr/bin/env bash
# Payload and filter behavior through the public house-board build and rendered page.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-house-board)
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
command -v node >/dev/null 2>&1 || { echo 'skip: node not found'; exit 0; }
mkdir -p "$TMP_ROOT/data" "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/data/house-line.md" <<'EOF'
# House lines
## demo
- Fork `jazz127/demo` (default branch `house`); upstream `owner/demo`.
- On `house` (merged; commit, pull request, branch):
  - **Alpha feature** (`aaaaaaa1`, PR 2, `housefeature/alpha`) — Alpha description.
  - Missing feature (`ccccccc3`, PR 3, `housefeature/missing`) — Missing description.
- Offered upstream on `owner/demo`:
  - `housefeature/alpha` (`aaaaaaa1`) — Alpha PR 247, still open.
EOF
cat > "$TMP_ROOT/fakebin/gh-axi" <<'PY'
#!/usr/bin/env python3
import base64, json, os, re, sys
path = sys.argv[2]
sha = lambda x: {"sha": x}
calls = {
 "repos/jazz127/demo/branches/main": sha("mainfork"),
 "repos/owner/demo/branches/main": sha("mainupstream"),
 "repos/jazz127/demo/branches/house": sha("housetip"),
 "repos/jazz127/demo/branches?per_page=8&page=1": [{"name":"main","sha":"mainfork"},{"name":"house","sha":"housetip"},{"name":"fm/one","sha":"x"},{"name":"fm/two","sha":"x"},{"name":"fm/three","sha":"x"},{"name":"fm/four","sha":"x"},{"name":"fm/five","sha":"x"},{"name":"housefeature/alpha","sha":"aaaaaaa1111111111111111111111111111111111"}],
 "repos/jazz127/demo/branches?per_page=8&page=2": [{"name":"housefeature/extra","sha":"bbbbbbb2222222222222222222222222222222"}],
 "repos/jazz127/demo/pulls?state=all&per_page=8&page=1": [{"number":2,"title":"Alpha","state":"closed","merged_at":"2026-09-20T00:00:00Z","created_at":"2026-09-01T00:00:00Z","head":"fm/alpha","labels":[],"html_url":"https://github.com/jazz127/demo/pull/2"},{"number":3,"title":"Missing","state":"closed","merged_at":"2026-09-12T00:00:00Z","created_at":"2026-09-05T00:00:00Z","head":"fm/missing","labels":[],"html_url":"https://github.com/jazz127/demo/pull/3"},{"number":4,"title":"Gone","state":"closed","merged_at":None,"created_at":"2026-09-06T00:00:00Z","head":"fm/gone","labels":[],"html_url":"https://github.com/jazz127/demo/pull/4"}],
 "repos/jazz127/demo/compare/aaaaaaa1111111111111111111111111111111111...housetip": {"behind_by":0},
 "repos/jazz127/demo/compare/bbbbbbb2222222222222222222222222222222...housetip": {"behind_by":1},
 "repos/jazz127/demo/commits/aaaaaaa1111111111111111111111111111111111": {"date":"2026-09-01T00:00:00Z"},
 "repos/jazz127/demo/commits/bbbbbbb2222222222222222222222222222222": {"date":"2026-09-10T00:00:00Z"},
 "repos/jazz127/demo/commits/ccccccc3": {"date":"2026-09-05T00:00:00Z"},
 "repos/owner/demo/pulls/247": {"number":247,"state":"open","merged_at":None,"created_at":"2026-09-02T00:00:00Z","html_url":"https://github.com/owner/demo/pull/247","head":"housefeature/alpha"},
 "repos/owner/demo/pulls?state=all&head=jazz127%3Ahousefeature/missing&per_page=20": [],
 "repos/owner/demo/pulls?state=all&head=jazz127%3Ahousefeature/gone&per_page=20": [],
 "repos/owner/demo/pulls?state=all&head=jazz127%3Ahousefeature/shipped&per_page=20": [{"number":249,"state":"closed","merged_at":"2026-09-15T00:00:00Z","created_at":"2026-09-03T00:00:00Z","html_url":"https://github.com/owner/demo/pull/249","head":"housefeature/shipped"}],
 "repos/owner/demo/pulls?state=all&head=jazz127%3Ahousefeature/extra&per_page=20": [{"number":248,"state":"open","merged_at":None,"created_at":"2026-09-11T00:00:00Z","html_url":"https://github.com/owner/demo/pull/248","head":"housefeature/extra"}],
}
# The house comparison pages its commit list; FAKE_AHEAD sizes it, the last
# commit is the register's ccccccc3, and FAKE_SHORT drops one listed commit.
compare = re.fullmatch(r"repos/jazz127/demo/compare/mainupstream\.\.\.housetip\?per_page=(\d+)&page=(\d+)", path)
if compare:
 ahead = int(os.environ.get("FAKE_AHEAD", "2"))
 listed = ["aaaaaaa1111111111111111111111111111111111"] + ["%040x" % i for i in range(1, ahead)]
 if ahead > 2:
  listed[-1] = "ccccccc3333333333333333333333333333333333"
 if os.environ.get("FAKE_SHORT"):
  listed = listed[:-1]
 size, page = int(compare.group(1)), int(compare.group(2))
 if size == 1:
  calls[path] = {"status":"diverged","ahead_by":ahead,"behind_by":1,"commits":listed[:1]}
 else:
  calls[path] = listed[(page - 1) * size:page * size]
  with open(os.environ["FM_HOME"] + "/compare-pages", "a") as log:
   log.write(str(page) + "\n")
if path not in calls:
 print("unknown endpoint: " + path, file=sys.stderr)
 sys.exit(1)
raw = json.dumps(calls[path], separators=(",", ":")).encode()
print("api_response:\n  body: " + base64.b64encode(raw).decode() + "\n  truncated: false")
PY
chmod +x "$TMP_ROOT/fakebin/gh-axi"
cat > "$TMP_ROOT/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 0 ]; then
  printf 'sessions[1]{file,status,url,pending_prompts}:\n  %s,open,"http://localhost/session/test",0\n' "$(cat "$FM_HOME/served-path")"
elif [ "${1-}" = poll ]; then
  echo 'unexpected poll' >&2
  exit 1
else
  printf '%s\n' "$1" > "$FM_HOME/served-path"
  printf 'session:\n  status: opened\n'
fi
SH
chmod +x "$TMP_ROOT/fakebin/lavish-axi"
PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$TMP_ROOT" \
  "$ROOT/bin/fm-house-board.sh" build > "$TMP_ROOT/build.out" || fail 'house board build failed'
[ "$(cat "$TMP_ROOT/served-path")" = "$TMP_ROOT/.lavish/house-board.html" ] || fail 'Lavish did not open the rendered page'

python3 - "$TMP_ROOT/.lavish/house-board.json" <<'PY' || fail 'payload facts differ from live fixture'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['schema']=='fm-house-board.v1'
assert p['projects'][0]['mirror_equal'] is False
assert (p['projects'][0]['ahead'],p['projects'][0]['behind'])==(2,1)
r={row['branch']:row for row in p['features']}
assert len(r)==3
assert r['housefeature/alpha']['landed'] is True
assert r['housefeature/alpha']['state']=='offered'
assert r['housefeature/alpha']['upstream_pr']['html_url']=='https://github.com/owner/demo/pull/247'
assert len(r['housefeature/alpha']['commits'])==1
assert r['housefeature/missing']['presence']=='register only' and not r['housefeature/missing']['landed']
assert r['housefeature/extra']['presence']=='fork only' and not r['housefeature/extra']['landed']
assert r['housefeature/extra']['upstream_pr']['html_url']=='https://github.com/owner/demo/pull/248'
assert r['housefeature/extra']['age_days'] is not None
PY

node "$ROOT/tests/assets/house-board-render-harness.mjs" "$TMP_ROOT/.lavish/house-board.html" \
  project=demo posture=mismatch age=7 sort=age > "$TMP_ROOT/filter.json" || fail 'rendered filters failed'
python3 - "$TMP_ROOT/filter.json" <<'PY' || fail 'combined filters differ from expected behavior'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['count']=='2 matching features'
assert p['names']==['Missing feature','Extra']
assert p['visibleProjects']==['demo']
assert '2 / 3Showing' in p['stats']
assert p['empty'] is False
PY

node "$ROOT/tests/assets/house-board-render-harness.mjs" "$TMP_ROOT/.lavish/house-board.html" \
  search=Alpha label=upstream-offered posture=offered > "$TMP_ROOT/search.json" || fail 'search filters failed'
python3 - "$TMP_ROOT/search.json" <<'PY' || fail 'search result differs from expected behavior'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['names']==['Alpha feature']
assert any('Upstream · open' in row for row in p['rows'])
PY

mkdir -p "$TMP_ROOT/deep/data"
sed '/Missing feature/a\
  - Gone feature (`eeeeeee5`, PR 4, `housefeature/gone`) — Closed without merging.\
  - Shipped feature (`fffffff6`, `housefeature/shipped`) — Contributed upstream.
' "$TMP_ROOT/data/house-line.md" > "$TMP_ROOT/deep/data/house-line.md"
PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$TMP_ROOT/deep" FM_HOUSE_BOARD_NO_SERVE=1 FAKE_AHEAD=65 \
  "$ROOT/bin/fm-house-board.sh" build > "$TMP_ROOT/deep.out" 2>&1 || fail "multi-page house comparison failed: $(cat "$TMP_ROOT/deep.out")"
[ "$(sort -n "$TMP_ROOT/deep/compare-pages" | uniq | tr '\n' ' ')" = '1 2 3 ' ] || fail 'house comparison did not read every commit page'
python3 - "$TMP_ROOT/deep/.lavish/house-board.json" <<'PY' || fail 'multi-page house comparison lost commits'
import json,sys
p=json.load(open(sys.argv[1]))
assert (p['projects'][0]['ahead'],p['projects'][0]['behind'])==(65,1)
r={row['branch']:row for row in p['features']}
assert r['housefeature/missing']['landed'] is True, 'commit on the last page was not collected'
assert {branch: row['on_house'] for branch, row in r.items()} == {
    'housefeature/alpha': 'yes', 'housefeature/missing': 'yes', 'housefeature/extra': 'no',
    'housefeature/gone': 'n/a', 'housefeature/shipped': 'n/a'}
assert r['housefeature/shipped']['state'] == 'contributed'
PY
node "$ROOT/tests/assets/house-board-render-harness.mjs" "$TMP_ROOT/deep/.lavish/house-board.html" \
  sort=project > "$TMP_ROOT/deep.json" || fail 'multi-page board did not render'
python3 - "$TMP_ROOT/deep.json" <<'PY' || fail 'On house column differs from expected behavior'
import json,sys
p=json.load(open(sys.argv[1]))
rows=dict(zip(p['names'],p['rows']))
for name in ('Gone feature','Shipped feature'):
    assert 'N/A' in rows[name], rows[name]
assert 'N/A' not in rows['Extra'] and 'N/A' not in rows['Alpha feature']
assert '2On house' in p['stats'], p['stats']
PY

mkdir -p "$TMP_ROOT/short/data"
cp "$TMP_ROOT/data/house-line.md" "$TMP_ROOT/short/data/"
if PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$TMP_ROOT/short" FM_HOUSE_BOARD_NO_SERVE=1 FAKE_AHEAD=65 FAKE_SHORT=1 \
  "$ROOT/bin/fm-house-board.sh" build > "$TMP_ROOT/short.out" 2>&1; then
  fail 'short house comparison rendered a partial board'
fi
grep -q 'listed 64 of 65 house commits' "$TMP_ROOT/short.out" || fail "short house comparison error unclear: $(cat "$TMP_ROOT/short.out")"
[ ! -e "$TMP_ROOT/short/.lavish/house-board.json" ] || fail 'short house comparison wrote a payload'

pass 'house board payload, mismatches, and combined page filters'
