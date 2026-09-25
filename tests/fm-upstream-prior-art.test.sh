#!/usr/bin/env bash
# Exercise the public prior-art CLI against a local branch and fake gh-axi.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-upstream-prior-art)
mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/fakebin"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.name Tester
git -C "$TMP_ROOT/repo" config user.email tester@example.invalid
printf 'original\n' > "$TMP_ROOT/repo/worker.py"
git -C "$TMP_ROOT/repo" add worker.py
git -C "$TMP_ROOT/repo" commit -qm base
git -C "$TMP_ROOT/repo" branch base
printf 'def pauseWorker():\n    return "stale"\n' > "$TMP_ROOT/repo/worker.py"
git -C "$TMP_ROOT/repo" add worker.py
git -C "$TMP_ROOT/repo" commit -qm change
printf 'Fix stale worker #4\n' > "$TMP_ROOT/summary.txt"
printf 'This change fixes stale worker detection.\n' > "$TMP_ROOT/body.md"

cat > "$TMP_ROOT/fakebin/gh-axi" <<'PY'
#!/usr/bin/env python3
import base64, json, os, pathlib, sys
from urllib.parse import parse_qs, urlparse
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a", encoding="utf-8") as log:
    log.write(" ".join(args[:2]) + "\n")
if args[:2] == ["pr", "create"] or args[:2] == ["issue", "create"]:
    body = pathlib.Path(args[args.index("--body-file") + 1]).read_text()
    pathlib.Path(os.environ["FAKE_PUBLISHED_BODY"]).write_text(body)
    print("https://github.com/owner/demo/" + ("pull" if args[0] == "pr" else "issues") + "/50")
    sys.exit(0)
if args[0] != "api" or "--jq" not in args:
    sys.exit(2)
path = args[1]
parsed = urlparse("https://fake/" + path)
params = parse_qs(parsed.query)
page = int(params.get("page", ["1"])[0])
pr = lambda n, title, state, merged=None: {
    "number": n, "html_url": f"https://github.com/owner/demo/pull/{n}",
    "user": {"login": f"author{n}"}, "title": title, "body": "Fixes #4" if n == 7 else "",
    "state": state, "merged_at": merged,
    "closed_at": "2026-09-20T00:00:00Z", "updated_at": "2026-09-20T00:00:00Z"}
issue = {"number": 4, "html_url": "https://github.com/owner/demo/issues/4",
         "user": {"login": "reporter"}, "title": "Stale worker detected incorrectly",
         "body": "The paused worker is stale", "state": "open"}
if parsed.path == "/repos/owner/demo/pulls":
    if params["state"][0] == "open":
        data = [pr(7, "Fix paused worker marked stale", "open")] if page == 1 else []
    else:
        data = [pr(8, "Stale worker detection fix", "closed"),
                pr(9, "Stale worker merge", "closed", "2026-09-20T00:00:00Z")] if page == 1 else []
elif parsed.path == "/repos/owner/demo/issues":
    data = [issue] if page == 1 else []
elif parsed.path == "/repos/owner/demo/pulls/7/files":
    data = [{"filename": "worker.py"}]
elif parsed.path == "/repos/owner/demo/pulls/8/files":
    data = [{"filename": "other.py"}]
elif parsed.path == "/repos/owner/demo/pulls/11/files":
    data = [{"filename": "unrelated.py"}]
elif parsed.path == "/search/issues":
    hit = os.environ.get("FAKE_SEARCH_HIT") and "pauseWorker" in params.get("q", [""])[0] and "is:pr" in params.get("q", [""])[0]
    data = {"total_count": 1 if hit else 0, "incomplete_results": bool(os.environ.get("FAKE_INCOMPLETE")),
            "items": [pr(11, "Alternative idle classification", "open")] if hit else []}
else:
    print("unexpected API path " + path, file=sys.stderr)
    sys.exit(2)
print("api_response:\n  body: " + base64.b64encode(json.dumps(data).encode()).decode() + "\n  truncated: false")
PY
chmod +x "$TMP_ROOT/fakebin/gh-axi"
export PATH="$TMP_ROOT/fakebin:$PATH"
export FAKE_LOG="$TMP_ROOT/forge.log"
export FAKE_PUBLISHED_BODY="$TMP_ROOT/published.md"
tool="$ROOT/bin/fm-upstream-prior-art.py"
cd "$TMP_ROOT/repo" || exit 1

common=(--repo owner/demo --kind pr --title 'Fix stale worker detection' --summary-file "$TMP_ROOT/summary.txt" --record "$TMP_ROOT/prior-art.json" --base base)
if "$tool" publish "${common[@]}" --body-file "$TMP_ROOT/body.md" --head owner:fix > "$TMP_ROOT/out" 2>&1; then
  fail 'publication succeeded without a record'
fi
[ ! -e "$FAKE_PUBLISHED_BODY" ] || fail 'missing-record refusal reached forge create'
pass 'publication refuses a missing record'

if FAKE_INCOMPLETE=1 "$tool" scan "${common[@]}" > "$TMP_ROOT/out" 2>&1; then
  fail 'incomplete forge search was accepted'
fi
[ ! -e "$TMP_ROOT/prior-art.json" ] || fail 'incomplete search wrote a scan record'
pass 'incomplete search fails closed without a record'

if ! FAKE_SEARCH_HIT=1 "$tool" scan "${common[@]}" > "$TMP_ROOT/out"; then
  fail 'symbol keyword scan failed'
fi
python3 - "$TMP_ROOT/prior-art.json" <<'PY' || fail 'symbol keyword hit was omitted'
import json,sys
r=json.load(open(sys.argv[1]))
c={x['url']:x for x in r['candidates']}
assert 'https://github.com/owner/demo/pull/11' in c
assert 'keyword search: pauseWorker' in c['https://github.com/owner/demo/pull/11']['reasons']
PY
pass 'changed-symbol search finds a PR with no shared file or title words'

"$tool" scan "${common[@]}" > "$TMP_ROOT/out" || fail 'scan failed'
python3 - "$TMP_ROOT/prior-art.json" <<'PY' || fail 'scan record is incomplete'
import json, sys
r=json.load(open(sys.argv[1]))
c={x['url']:x for x in r['candidates']}
assert r['verdict']=='pending'
assert set(c)=={'https://github.com/owner/demo/pull/7','https://github.com/owner/demo/pull/8','https://github.com/owner/demo/issues/4'}
assert c['https://github.com/owner/demo/pull/7']['author']=='author7'
assert any('shared files: worker.py' in why for why in c['https://github.com/owner/demo/pull/7']['reasons'])
assert any('linked issues: #4' in why for why in c['https://github.com/owner/demo/pull/7']['reasons'])
assert any('shared keywords' in why for why in c['https://github.com/owner/demo/pull/8']['reasons'])
assert any('shared keywords' in why for why in c['https://github.com/owner/demo/issues/4']['reasons'])
assert len(r['queries'])>=3
PY
pass 'scan records open PRs and issues plus recent closed unmerged PRs with match reasons'

if "$tool" check "${common[@]}" > "$TMP_ROOT/out" 2>&1; then fail 'pending verdict passed'; fi
cat > "$TMP_ROOT/decisions.json" <<'JSON'
{"verdict":"none-found","items":[]}
JSON
if "$tool" decide --record "$TMP_ROOT/prior-art.json" --decisions-file "$TMP_ROOT/decisions.json" > "$TMP_ROOT/out" 2>&1; then
  fail 'none-found accepted candidates'
fi
cat > "$TMP_ROOT/decisions.json" <<'JSON'
{"verdict":"distinct","items":[
 {"url":"https://github.com/owner/demo/pull/7","verdict":"distinct","reason":"Changes a different pause transition."},
 {"url":"https://github.com/owner/demo/pull/8","verdict":"distinct","reason":"Addresses only CLI output."},
 {"url":"https://github.com/owner/demo/issues/4","verdict":"distinct","reason":"Tracks the report, not this implementation."}]}
JSON
"$tool" decide --record "$TMP_ROOT/prior-art.json" --decisions-file "$TMP_ROOT/decisions.json" > "$TMP_ROOT/out" || fail 'distinct decision failed'
"$tool" check "${common[@]}" > "$TMP_ROOT/out" || fail 'fresh distinct record refused'
"$tool" publish "${common[@]}" --body-file "$TMP_ROOT/body.md" --head owner:fix > "$TMP_ROOT/out" || fail 'guarded publication failed'
"$tool" verify --record "$TMP_ROOT/prior-art.json" --repo owner/demo \
  --head "$(git rev-parse HEAD)" > "$TMP_ROOT/out" || fail 'valid receipt verification failed'
git remote add origin https://github.com/fork/demo.git
printf 'refs/heads/fix %s refs/heads/main %s\n' "$(git rev-parse HEAD)" 0 \
  | "$ROOT/bin/fm-upstream-push-guard.sh" "$ROOT" "$TMP_ROOT/missing.json" origin \
      https://github.com/fork/demo.git || fail 'owned push was blocked'
if printf 'refs/heads/fix %s refs/heads/main %s\n' "$(git rev-parse HEAD)" 0 \
  | "$ROOT/bin/fm-upstream-push-guard.sh" "$ROOT" "$TMP_ROOT/missing.json" origin \
      https://github.com/upstream/demo.git; then
  fail 'external push without receipt was allowed'
fi
printf 'refs/heads/fix %s refs/heads/main %s\n' "$(git rev-parse HEAD)" 0 \
  | "$ROOT/bin/fm-upstream-push-guard.sh" "$ROOT" "$TMP_ROOT/prior-art.json" origin \
      https://github.com/owner/demo.git || fail 'external push with receipt was blocked'
pass 'pre-push boundary gates external targets and permits owned or checked pushes'
rg -q '^## Prior art checked$' "$FAKE_PUBLISHED_BODY" || fail 'published body missed prior-art section'
rg -q 'https://github.com/owner/demo/pull/7 by @author7' "$FAKE_PUBLISHED_BODY" || fail 'published body missed author credit'
pass 'fresh distinct receipt permits publication and adds author credit'

python3 - "$TMP_ROOT/prior-art.json" <<'PY'
import json, sys
p=sys.argv[1]; r=json.load(open(p)); r['captured_at']='2020-01-01T00:00:00+00:00'; open(p,'w').write(json.dumps(r))
PY
if "$tool" publish "${common[@]}" --body-file "$TMP_ROOT/body.md" --head owner:fix > "$TMP_ROOT/out" 2>&1; then fail 'old scan published'; fi
pass 'publication refuses a scan older than the freshness window'

"$tool" scan "${common[@]}" > "$TMP_ROOT/out" || fail 'rescan failed'
cat > "$TMP_ROOT/decisions.json" <<'JSON'
{"verdict":"overlaps","items":[
 {"url":"https://github.com/owner/demo/pull/7","verdict":"overlaps","reason":"Both change pause detection."},
 {"url":"https://github.com/owner/demo/pull/8","verdict":"distinct","reason":"Addresses only CLI output."},
 {"url":"https://github.com/owner/demo/issues/4","verdict":"distinct","reason":"Tracks the report."}]}
JSON
"$tool" decide --record "$TMP_ROOT/prior-art.json" --decisions-file "$TMP_ROOT/decisions.json" > "$TMP_ROOT/out" || fail 'overlap decision failed'
if "$tool" publish "${common[@]}" --body-file "$TMP_ROOT/body.md" --head owner:fix > "$TMP_ROOT/out" 2>&1; then fail 'overlap without captain decision published'; fi
python3 - "$TMP_ROOT/decisions.json" <<'PY'
import json, sys
p=sys.argv[1]; r=json.load(open(p)); r['captain_decision']='Proceed and credit author7.'; open(p,'w').write(json.dumps(r))
PY
"$tool" decide --record "$TMP_ROOT/prior-art.json" --decisions-file "$TMP_ROOT/decisions.json" > "$TMP_ROOT/out" || fail 'captain decision record failed'
"$tool" publish "${common[@]}" --body-file "$TMP_ROOT/body.md" --head owner:fix > "$TMP_ROOT/out" || fail 'captain-approved overlap refused'
rg -q 'Captain decision: Proceed and credit author7.' "$FAKE_PUBLISHED_BODY" || fail 'captain decision absent from published body'
pass 'overlap blocks publication until a captain decision is recorded'

printf 'another change\n' >> worker.py
git add worker.py
git commit -qm followup
if "$tool" check "${common[@]}" > "$TMP_ROOT/out" 2>&1; then fail 'changed branch head passed old record'; fi
pass 'branch head movement stales the prior-art receipt'

printf 'Describe a unique widget behavior.\n' > "$TMP_ROOT/issue-summary.txt"
issue=(--repo owner/demo --kind issue --title 'Document unique widget behavior' --summary-file "$TMP_ROOT/issue-summary.txt" --record "$TMP_ROOT/issue-prior-art.json")
"$tool" scan "${issue[@]}" > "$TMP_ROOT/out" || fail 'issue scan failed'
python3 - "$TMP_ROOT/issue-prior-art.json" <<'PY' || fail 'unrelated issue scan found candidates'
import json,sys
r=json.load(open(sys.argv[1])); assert r['candidates']==[] and r['verdict']=='pending'
PY
printf '{"verdict":"none-found","items":[]}\n' > "$TMP_ROOT/issue-decisions.json"
"$tool" decide --record "$TMP_ROOT/issue-prior-art.json" --decisions-file "$TMP_ROOT/issue-decisions.json" > "$TMP_ROOT/out" || fail 'none-found issue decision failed'
"$tool" publish "${issue[@]}" --body-file "$TMP_ROOT/body.md" > "$TMP_ROOT/out" || fail 'guarded issue publication failed'
rg -q 'No matching open pull requests or issues' "$FAKE_PUBLISHED_BODY" || fail 'issue body missed prior-art result'
pass 'issue publication uses the same receipt gate and supports none-found'

printf 'all fm-upstream-prior-art tests passed\n'
