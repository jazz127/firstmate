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
import json, os, pathlib, subprocess, sys
from urllib.parse import parse_qs, urlparse
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a", encoding="utf-8") as log:
    log.write(" ".join(args[:2]) + "\n")
def count(name):
    # Per-scenario call counters let the fake mutate the forge between calls.
    path = pathlib.Path(os.environ["FAKE_LOG"] + "." + name)
    n = int(path.read_text()) + 1 if path.exists() else 1
    path.write_text(str(n))
    return n
if args[:2] == ["api", "rate_limit"]:
    import time
    data = {"resources": {"search": {"remaining": 0, "reset": int(time.time()) + int(os.environ.get("FAKE_RESET_IN", "0"))}, "core": {"remaining": 4000, "reset": int(time.time()) + 3600}}}
    print("api_response:\n  body: " + subprocess.run(["jq", "-r", args[args.index("--jq") + 1]], input=json.dumps(data), capture_output=True, text=True).stdout.strip() + "\n  truncated: false")
    sys.exit(0)
if os.environ.get("FAKE_RATE_LIMIT") and args[1].startswith("search/") and (count("ratelimit") == 1 or os.environ.get("FAKE_RESET_IN")):
    print("error: GitHub API rate limit exceeded\ncode: RATE_LIMITED")
    sys.exit(1)
if os.environ.get("FAKE_TRUNCATE_UNBOUNDED") and "--jq" in args and args[args.index("--jq") + 1] == "(.)|tojson|@base64":
    print("api_response:\n  truncated: true")
    sys.exit(0)
if args[:2] == ["pr", "create"]:
    body = pathlib.Path(args[args.index("--body-file") + 1]).read_text()
    pathlib.Path(os.environ["FAKE_PUBLISHED_BODY"]).write_text(body)
    print("https://github.com/owner/demo/pull/50")
    sys.exit(0)
if args[0] != "api" or "--jq" not in args:
    sys.exit(2)
path = args[1]
parsed = urlparse("https://fake/" + path)
params = parse_qs(parsed.query)
page = int(params.get("page", ["1"])[0])
pr = lambda n, title, state, merged=None: {
    "number": n, "html_url": f"https://github.com/owner/demo/pull/{n}",
    "user": {"login": f"author{n}"}, "title": title,
    "body": "x" * 5000 + "\nFixes #4" if n == 7 else "y" * 3000,
    "state": state, "merged_at": merged,
    "closed_at": "2026-09-20T00:00:00Z", "updated_at": "2026-09-20T00:00:00Z"}
issue = {"number": 4, "html_url": "https://github.com/owner/demo/issues/4",
         "user": {"login": "reporter"}, "title": "Stale worker detected incorrectly",
         "body": "The paused worker is stale", "state": "open"}
if parsed.path == "/repos/owner/demo/pulls" or parsed.path == "/repos/owner/demo/issues":
    print("scan paginated a full listing: " + path, file=sys.stderr)
    sys.exit(2)
if parsed.path == "/repos/owner/demo/pulls/7/files":
    data = [{"filename": "worker.py"}]
elif parsed.path == "/repos/owner/demo/pulls/8/files":
    # GitHub refuses the file list of a closed PR whose diff is gone.
    print("error: Validation error\ncode: VALIDATION_ERROR", file=sys.stderr)
    sys.exit(1)
elif parsed.path.startswith("/repos/owner/demo/pulls/") and parsed.path.endswith("/files"):
    data = [{"filename": f"unrelated/{parsed.path.split('/')[-2]}/{i:03d}.py"} for i in range(100 if os.environ.get("FAKE_FLOOD") else 60)]
elif parsed.path == "/repos/owner/demo/git/ref/heads/fix":
    data = {"object": {"sha": os.environ.get("FAKE_REMOTE_HEAD", "")}}
elif parsed.path == "/search/issues":
    q = params.get("q", [""])[0]
    hits = []
    if q == "repo:owner/demo is:pr is:open":
        total = 1368
    elif os.environ.get("FAKE_FLOOD"):
        base = 1000 + 10 * count("flood")
        hits = [dict(pr(n, f"Flood change {n}", "open"), pull_request={"url": "x"}) for n in range(base, base + 10)]
        total = 500
    else:
        closed = "is:closed is:unmerged closed:>" in q
        if any(word in q.lower() for word in ("stale", "worker")):
            hits = [dict(pr(8, "Stale worker detection fix", "closed"), pull_request={"url": "x"})] if closed else [
                dict(pr(7, "Fix paused worker marked stale", "open"), pull_request={"url": "x"}), issue]
        if os.environ.get("FAKE_SEARCH_HIT") and "pauseWorker" in q and not closed:
            hits.append(dict(pr(11, "Alternative idle classification", "open"), pull_request={"url": "x"}))
        if os.environ.get("FAKE_CHURN") and q.endswith(" stale") and not closed:
            # Maintainer triage closes a PR while the result page is being read.
            hits += [dict(pr(n, f"Unrelated open change {n} " + "z" * 150, "open"), pull_request={"url": "x"}) for n in range(100, 110)]
            if count("churn") > 1:
                hits = [row for row in hits if row["number"] != 100]
        total = len(hits)
    data = {"total_count": total, "incomplete_results": bool(os.environ.get("FAKE_INCOMPLETE")), "items": hits}
else:
    print("unexpected API path " + path, file=sys.stderr)
    sys.exit(2)
selected = subprocess.run(["jq", "-r", args[args.index("--jq") + 1]], input=json.dumps(data),
                          capture_output=True, text=True)
if selected.returncode:
    print(selected.stderr, file=sys.stderr)
    sys.exit(3)
# gh-axi truncates output beyond about 2,900 characters.
if len(selected.stdout.strip()) > 2900:
    print("api_response:\n  body: " + selected.stdout.strip()[:2900] + "...\n  truncated: true")
    sys.exit(0)
print("api_response:\n  body: " + selected.stdout.strip() + "\n  truncated: false")
PY
chmod +x "$TMP_ROOT/fakebin/gh-axi"
export PATH="$TMP_ROOT/fakebin:$PATH"
export FAKE_LOG="$TMP_ROOT/forge.log"
export FAKE_PUBLISHED_BODY="$TMP_ROOT/published.md"
export FAKE_TRUNCATE_UNBOUNDED=1
tool="$ROOT/bin/fm-upstream-prior-art.py"
cd "$TMP_ROOT/repo" || exit 1

common=(--repo owner/demo --title 'Fix stale worker detection' --summary-file "$TMP_ROOT/summary.txt" --record "$TMP_ROOT/prior-art.json" --base base)
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
assert 'search (open): pauseWorker' in c['https://github.com/owner/demo/pull/11']['reasons']
PY
pass 'changed-symbol search finds a PR with no shared file or title words'

: > "$FAKE_LOG"
FAKE_CHURN=1 FAKE_RATE_LIMIT=1 "$tool" scan "${common[@]}" > "$TMP_ROOT/out" 2>&1 || { cat "$TMP_ROOT/out"; fail 'scan failed under result churn and a search rate limit'; }
python3 - "$TMP_ROOT/prior-art.json" "$FAKE_LOG" <<'PY' || fail 'churned scan record is wrong'
import json, sys
r=json.load(open(sys.argv[1])); log=open(sys.argv[2]).read().splitlines()
c={x['url'] for x in r['candidates']}
assert r['complete'] is True and r['verdict']=='pending', r['coverage']
assert 'https://github.com/owner/demo/pull/100' not in c and 'https://github.com/owner/demo/pull/101' in c
assert 'api rate_limit' in log, 'search rate limit was not waited out'
assert not any('demo/pulls?' in line or 'demo/issues?' in line for line in log), 'scan paginated a full listing'
PY
pass 'scan tolerates PRs closing mid-read and waits out search rate limits'

if FAKE_FLOOD=1 "$tool" scan "${common[@]}" > "$TMP_ROOT/out" 2>&1; then
  fail 'scan past its request budget reported success'
fi
rg -q 'incomplete' "$TMP_ROOT/out" || fail 'budget refusal did not say the scan was incomplete'
python3 - "$TMP_ROOT/prior-art.json" "$FAKE_LOG" <<'PY' || fail 'budgeted scan record is wrong'
import json, sys
r=json.load(open(sys.argv[1]))
assert r['complete'] is False and r['verdict']=='incomplete', r['verdict']
assert r['coverage']['requests']==250 and 'request budget' in r['coverage']['stopped'], r['coverage']
assert r['coverage']['searches'] and r['candidates'], 'incomplete record lost what was covered'
PY
printf '{"verdict":"none-found","items":[]}\n' > "$TMP_ROOT/decisions.json"
if "$tool" decide --record "$TMP_ROOT/prior-art.json" --decisions-file "$TMP_ROOT/decisions.json" > "$TMP_ROOT/out" 2>&1; then
  fail 'incomplete scan accepted a verdict'
fi
if "$tool" verify --record "$TMP_ROOT/prior-art.json" --repo owner/demo --head "$(git rev-parse HEAD)" > "$TMP_ROOT/out" 2>&1; then
  fail 'incomplete scan verified as a receipt'
fi
pass 'scan stops at its request budget and records an incomplete, unpublishable receipt'

if FAKE_RATE_LIMIT=1 FAKE_RESET_IN=3600 "$tool" scan "${common[@]}" > "$TMP_ROOT/out" 2>&1; then
  fail 'scan blocked by a long rate limit reported success'
fi
python3 - "$TMP_ROOT/prior-art.json" <<'PY' || fail 'rate-limited scan record is wrong'
import json, sys
r=json.load(open(sys.argv[1]))
assert r['complete'] is False and 'rate limit' in r['coverage']['stopped'], r['coverage']
assert r['candidates']==[] and r['open_prs']['listed'] is None
PY
python3 - "$TMP_ROOT/prior-art.json" <<'PY'
import json, sys
p=sys.argv[1]; r=json.load(open(p)); r['verdict']='none-found'; open(p,'w').write(json.dumps(r))
PY
if "$tool" check "${common[@]}" > "$TMP_ROOT/out" 2>&1; then
  fail 'incomplete scan with an edited none-found verdict passed check'
fi
pass 'a truncated scan is never usable as none-found'

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
assert 'changed files unavailable' in c['https://github.com/owner/demo/pull/8']['reasons']
assert any('shared keywords' in why for why in c['https://github.com/owner/demo/issues/4']['reasons'])
assert len(r['queries'])>=3
assert r['open_prs']=={'listed': 1368, 'matched': 1}
assert c['https://github.com/owner/demo/pull/7']['kind']=='pr' and c['https://github.com/owner/demo/issues/4']['kind']=='issue'
assert r['complete'] is True and r['coverage']['requests'] <= 250
assert {s['scope'] for s in r['coverage']['searches']}=={'open','closed-unmerged'}
PY
pass 'search-driven scan records open PRs and issues plus recent closed unmerged PRs with match reasons'
pass 'real selectors pass through jq and search PR rows are recorded as PRs'
pass 'scan reads long bodies and file lists within the gh-axi output limit'

printf '{"verdict":"distinct","items":[null]}\n' > "$TMP_ROOT/decisions.json"
if "$tool" decide --record "$TMP_ROOT/prior-art.json" --decisions-file "$TMP_ROOT/decisions.json" > "$TMP_ROOT/out" 2>&1; then
  fail 'malformed decision item was accepted'
fi
! rg -q 'Traceback' "$TMP_ROOT/out" || fail 'malformed decision item crashed'
printf '{"verdict":"distinct","items":{}}\n' > "$TMP_ROOT/decisions.json"
if "$tool" decide --record "$TMP_ROOT/prior-art.json" --decisions-file "$TMP_ROOT/decisions.json" > "$TMP_ROOT/out" 2>&1; then
  fail 'non-list decisions were accepted'
fi
! rg -q 'Traceback' "$TMP_ROOT/out" || fail 'non-list decisions crashed'
cp "$TMP_ROOT/prior-art.json" "$TMP_ROOT/prior-art-good.json"
python3 - "$TMP_ROOT/prior-art.json" <<'PY'
import json, sys
p=sys.argv[1]; r=json.load(open(p)); r['candidates']=[None]; open(p,'w').write(json.dumps(r))
PY
if "$tool" decide --record "$TMP_ROOT/prior-art.json" --decisions-file "$TMP_ROOT/decisions.json" > "$TMP_ROOT/out" 2>&1; then
  fail 'malformed candidate record was accepted'
fi
! rg -q 'Traceback' "$TMP_ROOT/out" || fail 'malformed candidate record crashed'
mv "$TMP_ROOT/prior-art-good.json" "$TMP_ROOT/prior-art.json"
pass 'malformed decisions and candidate records fail cleanly'

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
cp "$TMP_ROOT/prior-art.json" "$TMP_ROOT/prior-art-good.json"
python3 - "$TMP_ROOT/prior-art.json" <<'PY'
import json, sys
p=sys.argv[1]; r=json.load(open(p)); r['captain_decision']={}; open(p,'w').write(json.dumps(r))
PY
if "$tool" publish "${common[@]}" --body-file "$TMP_ROOT/body.md" --head owner:fix > "$TMP_ROOT/out" 2>&1; then
  fail 'malformed captain decision was accepted'
fi
! rg -q 'Traceback' "$TMP_ROOT/out" || fail 'malformed captain decision crashed'
mv "$TMP_ROOT/prior-art-good.json" "$TMP_ROOT/prior-art.json"
"$tool" check "${common[@]}" > "$TMP_ROOT/out" || fail 'fresh distinct record refused'
export PUBLISHED_HEAD=$(git rev-parse HEAD)
export FAKE_REMOTE_HEAD=$PUBLISHED_HEAD
cp "$TMP_ROOT/prior-art.json" "$TMP_ROOT/published-record.json"
"$tool" publish "${common[@]}" --body-file "$TMP_ROOT/body.md" --head owner:fix > "$TMP_ROOT/out" || fail 'guarded publication failed'
export FAKE_REMOTE_HEAD=0000000000000000000000000000000000000000
if "$tool" publish "${common[@]}" --body-file "$TMP_ROOT/body.md" --head owner:fix > "$TMP_ROOT/out" 2>&1; then
  fail 'stale remote branch was published'
fi
export FAKE_REMOTE_HEAD=$(git rev-parse HEAD)
"$tool" verify --record "$TMP_ROOT/published-record.json" --repo owner/demo \
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
git remote set-url origin https://token@github.com/fork/demo.git
if printf 'refs/heads/fix %s refs/heads/main %s\n' "$(git rev-parse HEAD)" 0 \
  | "$ROOT/bin/fm-upstream-push-guard.sh" "$ROOT" "$TMP_ROOT/missing.json" origin \
      https://github.com/upstream/demo.git; then
  fail 'credentialed external push without receipt was allowed'
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
"$tool" verify --record "$TMP_ROOT/published-record.json" --repo owner/demo \
  --head "$PUBLISHED_HEAD" --published > "$TMP_ROOT/out" || fail 'published head verification refused the recorded head'
pass 'published head verification does not read back the worker checkout'

printf 'all fm-upstream-prior-art tests passed\n'
