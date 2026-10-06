# shellcheck shell=bash
# Minimal, default-off OTLP/HTTP span emission for Firstmate events.
#
# Adapted from andrewesweet/firstmate commits dc36ffac632c9ff9a42c869339231607e52e59fc,
# 9c3e523e83ef71916faabcd2504e372593d3c991, d9f3e2fe9a33752ff10880b19b00ac3586ac2d81,
# and ccc3e24c8a37b24979690fa9b0712d977f8ddc5c (merged as 4c9abf4e14cb7a41240abb3ea8512b9c75ffeaf5).
# The source is MIT licensed; see the repository LICENSE and the port report.
#
# Usage: . bin/fm-trace-span-lib.sh
# Public entry point: fm_trace_span_emit <meta-file> <name> <start-ms|-> <end-ms|->
#   [--root] [--status ok|error|unset] [key=value ...]
#
# Every path returns success to its caller. Export requires config/trace-export.json
# with enabled=true, a valid session-bound trace-context decision, and a valid
# traceparent in the metadata file. Export is synchronous, best-effort, and bounded
# by curl's one-second maximum transfer time. This library does not install hooks.
#
# Config schema (owned in docs/configuration.md): enabled must be true, endpoint
# must be an explicit HTTP(S) URL without query, fragment, or userinfo, and the
# auth-header-file must name a single Authorization: Bearer header file.
# Secrets stay in that file; curl reads it through -H @file. curl's implicit
# config is disabled with its first-argument -q.

_fm_trace_span_shell_flags=$-
# shellcheck source=bin/fm-trace-context-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timing-lib.sh"
case $_fm_trace_span_shell_flags in *u*) ;; *) set +u ;; esac
unset _fm_trace_span_shell_flags

fm_trace_span_json_escape() {
  local s=$1 out='' i ch code
  for ((i = 0; i < ${#s}; i++)); do
    ch=${s:i:1}
    case $ch in
      \\) out+=$ch$ch ;;
      '"') out+="\\$ch" ;;
      *)
        printf -v code '%d' "'$ch"
        if [ "$code" -ge 0 ] && [ "$code" -lt 32 ]; then printf -v ch '\\u%04x' "$code"; fi
        out+=$ch
        ;;
    esac
  done
  printf '%s' "$out"
}

fm_trace_span_attr_json() {
  local pair=$1 k v
  case $pair in *=*) k=${pair%%=*} v=${pair#*=} ;; *) return 0 ;; esac
  [ -n "$k" ] || return 0
  printf ',{"key":"%s","value":{"stringValue":"%s"}}' \
    "$(fm_trace_span_json_escape "$k")" "$(fm_trace_span_json_escape "$v")"
}

fm_trace_span_resource_json() {
  local meta=$1 kind v id key out=''
  [ -f "$meta" ] || return 0
  id=$(sed -n 's/^endpoint_task_id=//p' "$meta" 2>/dev/null | head -n 1)
  [ -n "$id" ] || id=$(basename "$meta" .meta)
  out=$(fm_trace_span_attr_json "firstmate.task.id=$id")
  v=$(sed -n 's/^project=//p' "$meta" 2>/dev/null | head -n 1)
  if [ -n "$v" ]; then
    v=$(basename "$v")
    [ "$v" = / ] || out+="$(fm_trace_span_attr_json "firstmate.project=$v")"
  fi
  kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null | head -n 1)
  [ -z "$kind" ] || out+="$(fm_trace_span_attr_json "firstmate.task.kind=$kind")"
  for key in harness model effort; do
    v=$(sed -n "s/^${key}=//p" "$meta" 2>/dev/null | head -n 1)
    [ -z "$v" ] || out+="$(fm_trace_span_attr_json "firstmate.${key}=$v")"
  done
  printf '%s\n' "$out"
}

fm_trace_span_config() {
  local file=$1 values
  command -v jq >/dev/null 2>&1 || return 1
  [ -f "$file" ] || return 1
  values=$(jq -er '
    if type == "object" and .enabled == true and (.endpoint | type == "string")
      and (.endpoint | test("^https?://[^/?#@[:space:]]+(/[^?#[:space:]]*)?$"))
      and (.endpoint | contains("\u0000") | not)
      and ((keys - ["enabled", "endpoint", "auth-header-file"]) | length == 0)
      and (.["auth-header-file"] | type == "string" and length > 0 and startswith("/")
        and (contains("\u0000") | not) and (test("[\\t\\r\\n]") | not))
    then .endpoint, .["auth-header-file"]
    else error("invalid trace export config") end
  ' "$file" 2>/dev/null) || return 1
  printf '%s\n' "$values"
}

fm_trace_span_header_valid() {
  local file=$1 line='' mode
  [ -f "$file" ] && [ -r "$file" ] && [ -O "$file" ] || return 1
  if [ "$(uname -s)" = Darwin ]; then
    mode=$(stat -L -f '%Lp' "$file" 2>/dev/null) || return 1
  else
    mode=$(stat -L -c '%a' "$file" 2>/dev/null) || return 1
  fi
  case $mode in '' | *[!0-7]*) return 1 ;; esac
  [ "$((8#$mode & 044))" -eq 0 ] || return 1
  IFS= read -r line < "$file" || [ -n "$line" ] || return 1
  case $line in 'Authorization: Bearer '*) ;; *) return 1 ;; esac
  local token=${line#Authorization: Bearer }
  [[ $token =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || return 1
  cmp -s "$file" <(printf '%s\n' "$line") || cmp -s "$file" <(printf '%s' "$line")
}

_fm_trace_span_emit_impl() {
  local meta=$1 name=$2 start_ms=$3 end_ms=$4 state_dir config_file config_values
  shift 4
  local root=0 status=unset pair
  while [ "$#" -gt 0 ]; do
    case $1 in
      --root) root=1 ;;
      --status)
        [ "$#" -ge 2 ] || return 0
        case $2 in ok | error | unset) status=$2 ;; *) return 0 ;; esac
        shift
        ;;
      --*) return 0 ;;
      *) break ;;
    esac
    shift
  done
  for pair in "$@"; do
    case $pair in --* | =*) return 0 ;; *=*) ;; *) return 0 ;; esac
  done

  [ "${FM_TRACE_EXPORT:-}" != off ] || return 0
  state_dir=${meta%/*}; [ "$state_dir" != "$meta" ] || state_dir=.
  config_file="$(dirname "$state_dir")/config/trace-export.json"
  config_values=$(fm_trace_span_config "$config_file") || return 0
  [ "$(fm_trace_context_session_effective "$state_dir/.trace-context-effective")" = on ] || return 0
  local carrier
  carrier=$(fm_trace_context_recorded "$meta")
  fm_trace_context_valid "$carrier" || return 0

  local endpoint auth_file
  { IFS= read -r endpoint; IFS= read -r auth_file; } <<<"$config_values"
  fm_trace_span_header_valid "$auth_file" || {
    printf '%s\n' 'firstmate: trace export skipped: invalid private bearer header file' >&3
    return 0
  }
  case $start_ms in '' | - | *[!0-9]*) start_ms=$(fm_timing_now_ms) ;; esac
  case $end_ms in '' | - | *[!0-9]*) end_ms=$(fm_timing_now_ms) ;; esac
  start_ms=$((10#$start_ms))
  end_ms=$((10#$end_ms))
  [ "$end_ms" -ge "$start_ms" ] || end_ms=$start_ms

  local span_id parent_id=''
  if [ "$root" = 1 ]; then span_id=${carrier:36:16}; else
    span_id=$(fm_trace_context_hex 8) || return 0
    parent_id=${carrier:36:16}
  fi

  local resource='{"key":"service.name","value":{"stringValue":"firstmate"}}'
  resource+="$(fm_trace_span_resource_json "$meta")"
  local attrs=''
  for pair in "$@"; do attrs+="$(fm_trace_span_attr_json "$pair")"; done
  local status_json=''
  case $status in ok) status_json=',"status":{"code":1}' ;; error) status_json=',"status":{"code":2}' ;; esac
  local span='{"traceId":"'"${carrier:3:32}"'","spanId":"'"$span_id"'",'
  [ -z "$parent_id" ] || span+='"parentSpanId":"'"$parent_id"'",'
  span+='"name":"'"$(fm_trace_span_json_escape "$name")"'","kind":1,'
  span+='"startTimeUnixNano":"'"$((start_ms * 1000000))"'","endTimeUnixNano":"'"$((end_ms * 1000000))"'",'
  span+='"attributes":['"${attrs#,}"']'"$status_json"
  span+='}'
  command -v curl >/dev/null 2>&1 || return 0
  local body
  body='{"resourceSpans":[{"resource":{"attributes":['"$resource"']},"scopeSpans":[{"scope":{"name":"firstmate"},"spans":['"$span"']}]}]}'
  printf '%s' "$body" | curl -q --globoff -sS --max-time 1 -o /dev/null \
    -H 'Content-Type: application/json' -H "@$auth_file" --data-binary @- "$endpoint" >/dev/null 2>&1 || true
  return 0
}

fm_trace_span_emit() {
  local restore_errexit=0
  case $- in *e*) restore_errexit=1 ;; esac
  set +e
  [ "$#" -ge 4 ] && _fm_trace_span_emit_impl "$@" 3>&2 >/dev/null 2>&1 || :
  [ "$restore_errexit" -eq 0 ] || set -e
  return 0
}
