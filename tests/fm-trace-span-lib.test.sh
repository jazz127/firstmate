#!/usr/bin/env bash
# Behavioral tests for default-off best-effort OTLP span emission.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-span-lib.sh"

WORK=$(fm_test_tmproot fm-trace-span)
HOME_FIX="$WORK/home"
STATE="$HOME_FIX/state"
CONFIG="$HOME_FIX/config"
mkdir -p "$STATE" "$CONFIG" "$WORK/wrapper" "$WORK/no-curl"
printf '101\n' > "$STATE/.lock"
printf '101 on\n' > "$STATE/.trace-context-effective"
META="$STATE/task-1.meta"
cat > "$META" <<'META'
traceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
kind=ship
META
TOKEN='never-put-this-token-in-output-argv-or-body'
HEADER="$WORK/auth-header"
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$HEADER"

cat > "$WORK/server.py" <<'PY'
import http.server
import json
import pathlib
import sys
import time

capture = pathlib.Path(sys.argv[1])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        capture.write_text(json.dumps({
            "path": self.path,
            "authorization": self.headers.get("Authorization"),
            "content_type": self.headers.get("Content-Type"),
            "body": body.decode("utf-8"),
        }), encoding="utf-8")
        if self.path == "/slow":
            time.sleep(1.3)
        self.send_response({"/unauthorized": 401, "/failure": 500}.get(self.path, 200))
        self.end_headers()

    def log_message(self, *_args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(str(capture) + ".port").write_text(str(server.server_port), encoding="ascii")
server.serve_forever()
PY
python3 "$WORK/server.py" "$WORK/capture.json" >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT
for _ in {1..100}; do [ -s "$WORK/capture.json.port" ] && break; sleep 0.02; done
[ -s "$WORK/capture.json.port" ] || fail "synthetic HTTP capture server did not start"
PORT=$(cat "$WORK/capture.json.port")
BASE="http://127.0.0.1:$PORT"

REAL_CURL=$(command -v curl)
cat > "$WORK/wrapper/curl" <<'CURL'
#!/usr/bin/env bash
for arg in "$@"; do
  case $arg in *never-put-this-token*) printf 'secret leaked in curl argv\n' >> "$FM_TRACE_TEST_ARGV" ;; esac
done
printf '%s\n' "$*" >> "$FM_TRACE_TEST_ARGV"
exec "$FM_TRACE_TEST_REAL_CURL" "$@"
CURL
chmod +x "$WORK/wrapper/curl"
export FM_TRACE_TEST_REAL_CURL=$REAL_CURL FM_TRACE_TEST_ARGV="$WORK/curl-argv"
export PATH="$WORK/wrapper:$PATH"

write_config() {
  local endpoint=$1 enabled=${2:-true}
  jq -n --arg endpoint "$endpoint" --arg header "$HEADER" --argjson enabled "$enabled" \
    '{enabled:$enabled,endpoint:$endpoint,"auth-header-file":$header,"home-label":"test-home"}' > "$CONFIG/trace-export.json"
}
request_count() { wc -l < "$WORK/curl-argv" 2>/dev/null | tr -d ' '; }

# Missing config is the default-off contract and performs no HTTP request.
rm -f "$CONFIG/trace-export.json" "$WORK/curl-argv"
fm_trace_span_emit "$META" firstmate.test 1000 2000 --root || fail "off emitter changed caller result"
[ ! -e "$WORK/curl-argv" ] || fail "unset export config invoked curl"
pass "unset export config is off and makes zero HTTP requests"

# Explicit off override wins over enabled configuration.
write_config "$BASE/ignored"
FM_TRACE_EXPORT=off fm_trace_span_emit "$META" firstmate.test 1000 2000 --root \
  || fail "off override changed caller result"
[ ! -e "$WORK/curl-argv" ] || fail "off override invoked curl"
pass "FM_TRACE_EXPORT=off makes zero HTTP requests"

# Root and child identity, JSON escaping, timestamps, authentication, and secrecy.
unset FM_TRACE_EXPORT
SPECIAL=$'root "quoted" \\ slash\ncontrol\001'
ATTR=$'quote" slash\\ newline\n'
write_config "$BASE/root"
fm_trace_span_emit "$META" "$SPECIAL" 1000 2500 --root --status ok "detail=$ATTR" \
  || fail "root emission changed caller result"
if ! jq -e --arg token "Bearer $TOKEN" --arg name "$SPECIAL" --arg attr "$ATTR" '
  .path == "/root" and .authorization == $token and .content_type == "application/json"
  and (.body | fromjson | .resourceSpans[0].scopeSpans[0].spans[0] as $s
    | $s.name == $name and $s.traceId == "4bf92f3577b34da6a3ce929d0e0e4736"
    and $s.spanId == "00f067aa0ba902b7" and ($s | has("parentSpanId") | not)
    and $s.startTimeUnixNano == "1000000000" and $s.endTimeUnixNano == "2500000000"
    and $s.status.code == 1 and $s.attributes[0].value.stringValue == $attr)
' "$WORK/capture.json" >/dev/null; then
  jq 'del(.authorization) | .body = (.body | fromjson)' "$WORK/capture.json" >&2
  fail "captured root span was malformed or incorrect"
fi
if grep -Fq "$TOKEN" "$WORK/curl-argv" || jq -r '.body' "$WORK/capture.json" | grep -Fq "$TOKEN"; then
  fail "bearer token leaked to argv or payload"
fi
pass "synthetic HTTP capture confirms escaped root JSON, root identity, nanoseconds, auth header, and no token in argv/payload"

write_config "$BASE/child"
fm_trace_span_emit "$META" child.event 3000 2000 'firstmate.test=value' || fail "child emission changed caller result"
jq -e '
  .path == "/child" and (.body | fromjson | .resourceSpans[0].scopeSpans[0].spans[0] as $s
    | $s.parentSpanId == "00f067aa0ba902b7" and ($s.spanId | length == 16)
    and $s.startTimeUnixNano == $s.endTimeUnixNano)
' "$WORK/capture.json" >/dev/null || fail "child identity or negative-duration clamp failed"
pass "child spans link to the carrier parent and negative durations clamp to zero"

# A metadata file with no optional fields remains exportable without phantom values;
# an absent file and invalid carrier are safe no-ops.
MINIMAL="$STATE/minimal.meta"
printf 'traceparent=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01\n' > "$MINIMAL"
write_config "$BASE/minimal"
fm_trace_span_emit "$MINIMAL" minimal 1 2 --root || fail "minimal metadata emission failed"
jq -e '.path == "/minimal" and (.body | fromjson | .resourceSpans[0].resource.attributes | map(.key) | index("firstmate.project") == null)' \
  "$WORK/capture.json" >/dev/null || fail "absent optional metadata produced resource attributes"
COUNT=$(request_count)
fm_trace_span_emit "$STATE/absent.meta" absent 1 2 --root || fail "absent metadata changed caller result"
printf 'traceparent=invalid\n' > "$STATE/invalid.meta"
fm_trace_span_emit "$STATE/invalid.meta" invalid 1 2 --root || fail "invalid carrier changed caller result"
[ "$(request_count)" = "$COUNT" ] || fail "absent metadata or malformed carrier issued a request"
pass "absent optional metadata is omitted; missing metadata and malformed carriers issue no request"

# Malformed config, stale session, absent curl, and all HTTP outcomes preserve success.
printf '{bad json\n' > "$CONFIG/trace-export.json"
fm_trace_span_emit "$META" malformed 1 2 --root || fail "malformed config changed caller result"
[ "$(request_count)" = "$COUNT" ] || fail "malformed config issued a request"
write_config "$BASE/stale"
printf '202 off\n' > "$STATE/.trace-context-effective"
fm_trace_span_emit "$META" stale 1 2 --root || fail "stale session changed caller result"
[ "$(request_count)" = "$COUNT" ] || fail "stale session issued a request"
printf '101 on\n' > "$STATE/.trace-context-effective"

for route in unauthorized failure; do
  write_config "$BASE/$route"
  fm_trace_span_emit "$META" "$route" 1 2 --root || fail "$route response changed caller result"
done
write_config "http://127.0.0.1:1/refused"
fm_trace_span_emit "$META" refused 1 2 --root || fail "refused endpoint changed caller result"
write_config "$BASE/slow"
start=$(date +%s)
fm_trace_span_emit "$META" slow 1 2 --root || fail "slow endpoint changed caller result"
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 3 ] || fail "slow endpoint exceeded bounded export time ($elapsed seconds)"

# A PATH containing jq and the standard helpers but no curl simulates a missing client.
for tool in jq sed head basename dirname tail tr od; do ln -sf "$(command -v "$tool")" "$WORK/no-curl/$tool"; done
PATH="$WORK/no-curl" fm_trace_span_emit "$META" nocurl 1 2 --root \
  || fail "missing curl changed caller result"
pass "malformed/stale config, missing curl, refused/slow endpoints, and HTTP 401/500 all preserve success"
