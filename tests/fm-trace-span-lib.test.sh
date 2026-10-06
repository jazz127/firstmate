#!/usr/bin/env bash
# Behavioral tests for default-off best-effort OTLP span emission.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
for options in - e u p eu ep up eup; do
  bash -c '
    case $1 in *e*) set -e ;; *) set +e ;; esac
    case $1 in *u*) set -u ;; *) set +u ;; esac
    case $1 in *p*) set -o pipefail ;; *) set +o pipefail ;; esac
    before=$-
    . "$2/bin/fm-trace-span-lib.sh"
    [ "$-" = "$before" ] || exit 1
    FM_TRACE_EXPORT=off fm_trace_span_emit missing.meta off 1 2
    [ "$-" = "$before" ] || exit 1
    case $1 in *p*) [[ -o pipefail ]] ;; *) ! [[ -o pipefail ]] ;; esac || exit 1
    case $1 in *u*) ;; *) unset optional; [ -z "$optional" ] || exit 1 ;; esac
  ' _ "$options" "$ROOT" || fail "loading or calling emitter changed shell options ($options)"
done
pass "loading and disabled emission preserve errexit, nounset, pipefail, and unset-variable behavior"
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
chmod 600 "$HEADER"

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
        with pathlib.Path(str(capture) + ".requests").open("a", encoding="utf-8") as requests:
            requests.write(self.path + "\n")
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
    '{enabled:$enabled,endpoint:$endpoint,"auth-header-file":$header}' > "$CONFIG/trace-export.json"
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

# The JSON string contract preserves the supplied Unicode text exactly, rather
# than escaping high-bit bytes as ASCII controls (a Bash 3.2 regression).
UNICODE='café 日本語 🐟'
UNICODE_META="$STATE/unicode.meta"
printf 'traceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\nmodel=%s\n' \
  "$UNICODE" > "$UNICODE_META"
for locale in C C.UTF-8 en_US.UTF-8; do
  write_config "$BASE/unicode"
  COUNT=$(request_count)
  # Positional parameters expand in the inner shell.
  # shellcheck disable=SC2016
  LC_ALL="$locale" "$BASH" -c '
    . "$1/bin/fm-trace-span-lib.sh"
    fm_trace_span_emit "$2" "$3" 1000 2000 --root "$3=$3"
  ' _ "$ROOT" "$UNICODE_META" "$UNICODE" || fail "Unicode emission changed caller result ($locale)"
  [ "$(request_count)" -eq "$((COUNT + 1))" ] || fail "Unicode emission skipped export ($locale)"
  jq -e --arg text "$UNICODE" --arg token "Bearer $TOKEN" '
    .path == "/unicode" and .authorization == $token
    and (.body | fromjson | .resourceSpans[0] as $r
      | $r.scopeSpans[0].spans[0] as $s
      | $s.name == $text
        and $s.attributes == [{key:$text,value:{stringValue:$text}}]
        and ([$r.resource.attributes[] | select(.key == "firstmate.model")]
          == [{key:"firstmate.model",value:{stringValue:$text}}]))
  ' "$WORK/capture.json" >/dev/null || fail "Unicode span name or attributes were corrupted ($locale)"
done
pass "authenticated HTTP export preserves accented, Japanese, and emoji text in names and attributes across locales"

write_config "$BASE/child"
fm_trace_span_emit "$META" child.event 3000 2000 'firstmate.test=value' || fail "child emission changed caller result"
jq -e '
  .path == "/child" and (.body | fromjson | .resourceSpans[0].scopeSpans[0].spans[0] as $s
    | $s.parentSpanId == "00f067aa0ba902b7" and ($s.spanId | length == 16)
    and $s.startTimeUnixNano == $s.endTimeUnixNano)
' "$WORK/capture.json" >/dev/null || fail "child identity or negative-duration clamp failed"
pass "child spans link to the carrier parent and negative durations clamp to zero"

ALT_STATE="$WORK/runtime/state"
ALT_CONFIG="$WORK/alternate-config"
mkdir -p "$ALT_STATE" "$WORK/runtime/config" "$ALT_CONFIG"
cp "$STATE/.lock" "$STATE/.trace-context-effective" "$META" "$ALT_STATE/"
CONFIG="$WORK/runtime/config" write_config "$BASE/wrong-state-config"

assert_config_route() {
  local meta=$1 route=$2 count
  count=$(request_count)
  fm_trace_span_emit "$meta" config.route 1 2 ${CONFIG_MODE:+"$CONFIG_MODE"} \
    || fail "configuration resolution changed caller result ($route)"
  [ "$(request_count)" -eq "$((count + 1))" ] || fail "configuration resolution skipped export ($route)"
  jq -e --arg route "$route" --arg token "Bearer $TOKEN" \
    '.path == $route and .authorization == $token' "$WORK/capture.json" >/dev/null \
    || fail "export selected another configuration ($route)"
}
assert_config_skip() {
  local meta=$1 count
  count=$(request_count)
  fm_trace_span_emit "$meta" config.skip 1 2 ${CONFIG_MODE:+"$CONFIG_MODE"} > "$WORK/stdout" 2> "$WORK/stderr" \
    || fail "configuration rejection changed caller result"
  [ "$(request_count)" = "$count" ] || fail "configuration rejection issued a request"
  [ ! -s "$WORK/stdout" ] && [ ! -s "$WORK/stderr" ] || fail "configuration rejection emitted output"
}
for mode in root child; do
  CONFIG_MODE=''
  [ "$mode" != root ] || CONFIG_MODE=--root
  write_config "$BASE/home-config"
  CONFIG="$ALT_CONFIG" write_config "$BASE/override-config"
  FM_HOME="$HOME_FIX" assert_config_route "$META" /home-config
  FM_HOME="$HOME_FIX" FM_STATE_OVERRIDE="$ALT_STATE" \
    assert_config_route "$ALT_STATE/task-1.meta" /home-config
  FM_HOME="$HOME_FIX" FM_CONFIG_OVERRIDE="$ALT_CONFIG" \
    assert_config_route "$META" /override-config
  FM_CONFIG_OVERRIDE="$ALT_CONFIG" assert_config_route "$META" /override-config
  FM_STATE_OVERRIDE="$STATE" assert_config_route "$META" /home-config
  FM_HOME="$HOME_FIX" FM_STATE_OVERRIDE="$ALT_STATE" FM_CONFIG_OVERRIDE="$ALT_CONFIG" \
    assert_config_route "$ALT_STATE/task-1.meta" /override-config
  FM_ROOT_OVERRIDE="$HOME_FIX" assert_config_route "$META" /home-config
  FM_HOME="$HOME_FIX" FM_ROOT_OVERRIDE="$WORK/runtime" assert_config_route "$META" /home-config
  (
    cd "$WORK" || fail "relative override fixture could not change directory"
    FM_HOME=home FM_STATE_OVERRIDE=runtime/state FM_CONFIG_OVERRIDE=alternate-config \
      assert_config_route runtime/state/task-1.meta /override-config
  )
  FM_HOME="$HOME_FIX" assert_config_skip "$ALT_STATE/task-1.meta"
  FM_HOME="$HOME_FIX" FM_CONFIG_OVERRIDE="$ALT_CONFIG" assert_config_skip "$ALT_STATE/task-1.meta"
  FM_HOME="$HOME_FIX" FM_STATE_OVERRIDE="$ALT_STATE" assert_config_skip "$META"
  FM_HOME="$WORK/absent-home" assert_config_skip "$META"
  FM_HOME="$HOME_FIX" FM_CONFIG_OVERRIDE="$WORK/absent-config" assert_config_skip "$META"
  FM_HOME="$HOME_FIX" FM_STATE_OVERRIDE="$ALT_STATE" FM_CONFIG_OVERRIDE="$ALT_CONFIG" \
    FM_TRACE_EXPORT=off assert_config_skip "$ALT_STATE/task-1.meta"
done
pass "root and child exports honor directory precedence and relative overrides without crossing homes or falling back"

for mode in root child; do
  CONFIG_MODE=''
  [ "$mode" != root ] || CONFIG_MODE=--root
  for shape in two-enabled enabled-disabled disabled-enabled object-scalar array empty null malformed-tail; do
    write_config "$BASE/single-config"
    cp "$CONFIG/trace-export.json" "$WORK/valid-config.json"
    case $shape in
      two-enabled) cat "$WORK/valid-config.json" >> "$CONFIG/trace-export.json" ;;
      enabled-disabled) printf '%s\n' '{"enabled":false}' >> "$CONFIG/trace-export.json" ;;
      disabled-enabled)
        printf '%s\n' '{"enabled":false}' > "$CONFIG/trace-export.json"
        cat "$WORK/valid-config.json" >> "$CONFIG/trace-export.json"
        ;;
      object-scalar) printf '%s\n' 'null' >> "$CONFIG/trace-export.json" ;;
      array) jq -s '.' "$WORK/valid-config.json" > "$CONFIG/trace-export.json" ;;
      empty) : > "$CONFIG/trace-export.json" ;;
      null) printf '%s\n' 'null' > "$CONFIG/trace-export.json" ;;
      malformed-tail) printf '%s\n' '{bad json' >> "$CONFIG/trace-export.json" ;;
    esac
    assert_config_skip "$META"
  done
  write_config "$BASE/single-config"
  printf ' \n\t\r\n' >> "$CONFIG/trace-export.json"
  assert_config_route "$META" /single-config
done
pass "only one enabled JSON object exports; concatenated values and malformed input silently preserve success"

for span_mode in root child; do
  write_config "$BASE/decimal/$span_mode"
  for sample in \
    '01000 02000 1000000000 2000000000' \
    '1000 02000 1000000000 2000000000' \
    '01000 2000 1000000000 2000000000' \
    '08 09 8000000 9000000' \
    '09 08 9000000 9000000' \
    '000 0 0 0' \
    '0 000 0 0'; do
    IFS=' ' read -r start_ms end_ms start_ns end_ns <<< "$sample"
    COUNT=$(request_count)
    bash -c '
      set -eu
      set -o pipefail
      . "$1/bin/fm-trace-span-lib.sh"
      if [ "$5" = root ]; then
        fm_trace_span_emit "$2" decimal.time "$3" "$4" --root
      else
        fm_trace_span_emit "$2" decimal.time "$3" "$4"
      fi
      printf "%s\n" continued
    ' _ "$ROOT" "$META" "$start_ms" "$end_ms" "$span_mode" > "$WORK/caller-output" \
      || fail "decimal timestamp input terminated the caller ($sample)"
    [ "$(cat "$WORK/caller-output")" = continued ] || fail "caller did not continue after decimal emission"
    [ "$(request_count)" -eq "$((COUNT + 1))" ] || fail "decimal timestamp input skipped export"
    jq -e --arg start "$start_ns" --arg end "$end_ns" '
      .body | fromjson | .resourceSpans[0].scopeSpans[0].spans[0]
      | .name == "decimal.time" and .startTimeUnixNano == $start and .endTimeUnixNano == $end
    ' "$WORK/capture.json" >/dev/null || fail "decimal timestamps or clamp were incorrect ($sample)"
  done
done
pass "root and child spans use decimal milliseconds, including padding, 08/09, zero, and clamping"

for kind in ship scout secondmate; do
  case $kind in
    ship) project_value=/projects/private-client ;;
    scout) project_value=/projects/private-client/// ;;
    secondmate) project_value=private-client ;;
  esac
  RESOURCE_META="$STATE/resource-$kind.meta"
  for identity in explicit inferred; do
    {
      printf 'traceparent=00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\n'
      printf 'kind=%s\nproject=%s\n' "$kind" "$project_value"
      printf 'harness=codex\nmodel=test-model\neffort=high\nspawn_gen=12345\n'
      printf 'home=%s\nworktree=%s/private-checkout\n' "$HOME_FIX" "$WORK"
      [ "$identity" != explicit ] || printf 'endpoint_task_id=registered-task\n'
    } > "$RESOURCE_META"
    root_option=''
    expected_id="resource-$kind"
    if [ "$identity" = explicit ]; then
      root_option=--root
      expected_id=registered-task
    fi
    write_config "$BASE/resources/$kind/$identity"
    COUNT=$(request_count)
    fm_trace_span_emit "$RESOURCE_META" resource.metadata 1 2 ${root_option:+"$root_option"} \
      || fail "resource metadata export changed caller result"
    [ "$(request_count)" -eq "$((COUNT + 1))" ] || fail "resource metadata did not export"
    jq -e --arg id "$expected_id" --arg kind "$kind" '
      .body | fromjson | .resourceSpans[0].resource.attributes
      | map({key:.key,value:.value.stringValue}) | from_entries
      | . == {
          "service.name":"firstmate", "firstmate.task.id":$id,
          "firstmate.project":"private-client", "firstmate.task.kind":$kind,
          "firstmate.harness":"codex", "firstmate.model":"test-model", "firstmate.effort":"high"
        }
    ' "$WORK/capture.json" >/dev/null || fail "resources exported paths or extra identities ($kind/$identity)"
  done
done
pass "all task kinds export the project basename and task identity without paths or incarnation identities"

assert_invalid_invocation() {
  local before
  before=$(request_count)
  fm_trace_span_emit "$META" invalid.invocation 1 2 "$@" > "$WORK/stdout" 2> "$WORK/stderr" \
    || fail "invalid invocation changed caller result"
  [ "$(request_count)" = "$before" ] || fail "invalid invocation issued a request"
  [ ! -s "$WORK/stdout" ] && [ ! -s "$WORK/stderr" ] || fail "invalid invocation emitted output"
}
write_config "$BASE/invalid-invocation"
assert_invalid_invocation --rot
assert_invalid_invocation --
assert_invalid_invocation --root=1
assert_invalid_invocation --status
assert_invalid_invocation --status invalid
assert_invalid_invocation --status --root
assert_invalid_invocation detail=value --rot
assert_invalid_invocation detail=value --root
assert_invalid_invocation detail=value --status error
assert_invalid_invocation plain
assert_invalid_invocation '=value'
assert_invalid_invocation detail=value plain
pass "unknown options, invalid statuses, and malformed attribute arguments silently skip export"

for status in error unset; do
  write_config "$BASE/status/$status"
  COUNT=$(request_count)
  fm_trace_span_emit "$META" valid.invocation 1 2 --status "$status" --root 'detail=--rot' 'empty=' \
    || fail "documented invocation changed caller result"
  [ "$(request_count)" -eq "$((COUNT + 1))" ] || fail "documented invocation did not export"
  jq -e --arg status "$status" '
    .body | fromjson | .resourceSpans[0].scopeSpans[0].spans[0]
    | .name == "valid.invocation"
      and (if $status == "error" then .status.code == 2 else (has("status") | not) end)
      and ((.attributes | map({key:.key,value:.value.stringValue}) | from_entries)
        == {"detail":"--rot","empty":""})
  ' "$WORK/capture.json" >/dev/null || fail "documented status or attributes were incorrect"
done
pass "documented statuses and attributes remain exportable"

PRIVATE_HEADER=$HEADER
HEADER="$WORK/"'auth\header'
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$HEADER"
chmod 600 "$HEADER"
write_config "$BASE/"'literal\path'
fm_trace_span_emit "$META" literal.config 1 2 --root || fail "literal configuration changed caller result"
jq -e --arg path '/literal\path' --arg token "Bearer $TOKEN" \
  '.path == $path and .authorization == $token' "$WORK/capture.json" >/dev/null \
  || fail "backslashes in endpoint or header path were altered"
HEADER=$PRIVATE_HEADER
pass "endpoint and private header paths preserve literal backslashes through HTTP export"

for route in '{a,b}/v1/traces' '[1-2]/v1/traces'; do
  HTTP_COUNT=$(wc -l < "$WORK/capture.json.requests")
  write_config "$BASE/$route"
  fm_trace_span_emit "$META" literal.url 1 2 --root || fail "literal URL changed caller result"
  jq -e --arg path "/$route" '.path == $path' "$WORK/capture.json" >/dev/null \
    || fail "URL glob syntax was expanded"
  [ "$(wc -l < "$WORK/capture.json.requests")" -eq "$((HTTP_COUNT + 1))" ] \
    || fail "one emission produced multiple HTTP requests"
done
pass "brace and range URL syntax each produce one request to the literal endpoint"

write_config "$BASE/private-header"
COUNT=$(request_count)
for mode in 640 604 644; do
  chmod "$mode" "$HEADER"
  fm_trace_span_emit "$META" unsafe.header 1 2 --root > "$WORK/stdout" 2> "$WORK/stderr" \
    || fail "unsafe header mode changed caller result"
  [ "$(request_count)" = "$COUNT" ] || fail "readable-to-others header issued a request ($mode)"
  [ ! -s "$WORK/stdout" ] || fail "invalid header wrote to stdout"
  [ "$(cat "$WORK/stderr")" = 'firstmate: trace export skipped: invalid private bearer header file' ] \
    && [ "$(wc -l < "$WORK/stderr")" -eq 1 ] || fail "invalid header did not emit exactly one safe diagnostic"
done
chmod 600 "$HEADER"
pass "group or other readable headers skip export with one diagnostic and preserve success"

if [ "$EUID" -eq 0 ]; then
  python3 -c 'import os, sys; os.chown(sys.argv[1], 1, -1)' "$HEADER"
  fm_trace_span_emit "$META" foreign.owner 1 2 --root 2> "$WORK/stderr" \
    || fail "foreign-owned header changed caller result"
  [ "$(request_count)" = "$COUNT" ] || fail "foreign-owned header issued a request"
  [ "$(cat "$WORK/stderr")" = 'firstmate: trace export skipped: invalid private bearer header file' ] \
    && [ "$(wc -l < "$WORK/stderr")" -eq 1 ] || fail "foreign-owned header diagnostic was incorrect"
  python3 -c 'import os, sys; os.chown(sys.argv[1], 0, -1)' "$HEADER"
  pass "foreign-owned header skips export while preserving success"
else
  printf 'skip - foreign-owner fixture requires root to change file ownership\n'
fi

for extra in second-line unterminated-line blank-line nul-tail nul-token; do
  case $extra in
    second-line) printf 'Authorization: Bearer %s\nAuthorization: Bearer other\n' "$TOKEN" ;;
    unterminated-line) printf 'Authorization: Bearer %s\nAuthorization: Bearer other' "$TOKEN" ;;
    blank-line) printf 'Authorization: Bearer %s\n\n' "$TOKEN" ;;
    nul-tail) printf 'Authorization: Bearer %s\n\000' "$TOKEN" ;;
    nul-token) printf 'Authorization: Bearer %s\000' "$TOKEN" ;;
  esac > "$HEADER"
  fm_trace_span_emit "$META" extra.header 1 2 --root 2> "$WORK/stderr" \
    || fail "extra header bytes changed caller result"
  [ "$(request_count)" = "$COUNT" ] || fail "extra header bytes issued a request ($extra)"
  [ "$(cat "$WORK/stderr")" = 'firstmate: trace export skipped: invalid private bearer header file' ] \
    && [ "$(wc -l < "$WORK/stderr")" -eq 1 ] || fail "extra header bytes diagnostic was incorrect"
done
for ending in terminated unterminated; do
  if [ "$ending" = terminated ]; then
    printf 'Authorization: Bearer %s\n' "$TOKEN" > "$HEADER"
  else
    printf 'Authorization: Bearer %s' "$TOKEN" > "$HEADER"
  fi
  fm_trace_span_emit "$META" valid.header 1 2 --root 2> "$WORK/stderr" \
    || fail "single header line changed caller result"
  [ "$(request_count)" -eq "$((COUNT + 1))" ] || fail "single header line did not export ($ending)"
  [ ! -s "$WORK/stderr" ] || fail "valid header emitted a diagnostic"
  COUNT=$(request_count)
done
pass "single bearer lines export with optional newline; all extra bytes reject export"

for field in endpoint auth-header-file; do
  write_config "$BASE/nul-config"
  jq --arg field "$field" '.[$field] += "\u0000"' "$CONFIG/trace-export.json" > "$WORK/nul-config.json"
  mv "$WORK/nul-config.json" "$CONFIG/trace-export.json"
  fm_trace_span_emit "$META" nul.config 1 2 --root || fail "NUL configuration changed caller result"
  [ "$(request_count)" = "$COUNT" ] || fail "unrepresentable configuration issued a request"
done
pass "configuration rejects NUL bytes rather than changing accepted values"

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
for tool in jq grep sed head basename dirname tr od uname stat cmp; do ln -sf "$(command -v "$tool")" "$WORK/no-curl/$tool"; done
PATH="$WORK/no-curl" fm_trace_context_valid "$(PATH="$WORK/no-curl" fm_trace_context_recorded "$META")" \
  || fail "missing-curl fixture cannot read and validate the carrier"
PATH="$WORK/no-curl" fm_trace_span_header_valid "$HEADER" \
  || fail "missing-curl fixture cannot validate the private header"
if PATH="$WORK/no-curl" command -v curl >/dev/null 2>&1; then fail "missing-curl fixture contains curl"; fi
COUNT=$(request_count)
PATH="$WORK/no-curl" fm_trace_span_emit "$META" nocurl 1 2 --root \
  || fail "missing curl changed caller result"
[ "$(request_count)" = "$COUNT" ] || fail "missing-curl fixture invoked the HTTP client"
pass "malformed/stale config, missing curl, refused/slow endpoints, and HTTP 401/500 all preserve success"
