## Intent

Port OpenTelemetry task tracing from andrewesweet/firstmate into Firstmate as a small, default-off house feature that feeds aggregate fleet-work metrics. The chosen scope is metrics first: no per-task trace store or timeline viewer. This first round is the standalone span emitter, its per-home configuration, authenticated OTLP/HTTP export, and an export off switch; lifecycle hooks are deferred.

Re-cut the emitter to current Firstmate instead of cherry-picking the source branches. Keep export off unless explicitly enabled. Require an explicit endpoint and a private header file for bearer authentication; do not place credentials in worker launch environments or copy them to remote homes. Preserve the OTLP/JSON span shape and task trace identity, safely encode quoted and control characters, use nanosecond timestamps, clamp negative duration to zero, and omit absent metadata. Off means zero requests. Missing curl, HTTP 401/500, refused or slow endpoints, malformed config or carrier, and stale session state must not change the caller's result. Never put the token in argv, output, or the payload.

Credit Andrew Sweet (andrewesweet) and the MIT-licensed source commits dc36ffac632c9ff9a42c869339231607e52e59fc, 9c3e523e83ef71916faabcd2504e372593d3c991, d9f3e2fe9a33752ff10880b19b00ac3586ac2d81, ccc3e24c8a37b24979690fa9b0712d977f8ddc5c, merged as 4c9abf4e14cb7a41240abb3ea8512b9c75ffeaf5. Keep the repository's existing MIT license text. Mark this feature upstream-candidate; do not post it upstream.

## What Changed

- Add a standalone OTLP/HTTP span emitter preserving task trace identity, escaping JSON, exporting nanosecond timestamps, clamping negative durations, and omitting absent metadata.
- Keep export default-off with per-home configuration, private bearer-header authentication, and `FM_TRACE_EXPORT=off`; bound requests to one second and preserve caller success on failures.
- Document export configuration and credit Andrew Sweet’s MIT-licensed source; add behavioral tests for span payloads, authentication, configuration overrides, and failure handling.

## Risk Assessment

✅ Low: The standalone, default-off emitter is bounded and consistent with the accepted intent and recorded decisions; no material defects were substantiated.

## Testing

evidence-artifact: /tmp/fm-otel-task-tracing-impl/live-evidence-summary.json
evidence-command: python3 /Users/jarad/.no-mistakes/evidence/01M48SHPA9FD7YQ9F7T8E0CW9B/live-collector-driver.py
evidence-captured: 2026-10-06T14:36:40Z

Focused behavioral tests and all live collector scenarios passed, covering export, secrecy, isolation, aggregate metrics and bounded failures. The focused suite's foreign-owner fixture required root and was skipped. Evidence was retained and the disposable setup removed.

- Live validation: ✅ go - 7 of 7 scenarios driven live against the product

| Scenario | Result | Live | Evidence |
| --- | --- | --- | --- |
| Leave export disabled or activate the off switch; no HTTP request occurs | ✅ pass | live | live-driver.log: absent configuration, enabled=false and FM_TRACE_EXPORT=off each produced zero requests through the forwarding tap to the real collector. |
| Emit root and child spans; the collector preserves their identity, values and timing | ✅ pass | live | http-wire-evidence.json and collector-spans.jsonl: actual OTLP receiver accepted root and child identity, quoted/control/Unicode text, decimal nanoseconds, clamped duration, project basename and omitt… |
| Configure isolated homes and directory overrides; export stays within the selected home | ✅ pass | live | live-driver.log: home, root, state, configuration and code-home defaults selected the intended real collector; metadata outside effective state caused zero requests. |
| Supply invalid configuration, state or invocation data; the caller continues safely | ✅ pass | live | live-driver.log: malformed or concatenated JSON, invalid carriers, missing metadata, stale session state, invalid options and unsafe header contents skipped requests while preserving caller success. |
| Export with a private bearer header and xtrace enabled; authentication succeeds without token disclosure | ✅ pass | live | Actual authenticated collector acceptance, http-wire-evidence.json, xtrace.log and curl-process-argv.log; assertions confirmed the disposable token was absent from payload, caller output, tracing and… |
| Encounter unavailable tools, rejected requests or slow transport; export preserves caller success and remains bounded | ✅ pass | live | live-driver.log: actual collectors returned HTTP 401, 500 and 503; missing curl and refused connections preserved success. A forwarding transport delay returned in 1.219 seconds, and the real collecto… |
| Feed emitted spans into aggregate fleet metrics; counts and duration histograms appear | ✅ pass | live | fleet-metrics.prom from the official collector&#39;s span_metrics connector and Prometheus endpoint: fleet counts and duration histograms include project and task-kind dimensions without per-task identity… |

<details>
<summary>Evidence: Live emitter and collector transcript</summary>

Source: [Live emitter and collector transcript](https://github.com/jazz127/firstmate/blob/7a9a2a03d73d5d37320cc3e543e146fc069f24db/.no-mistakes/evidence/fm/otel-task-tracing-impl/live-driver.log)

```text
{"case": "official collector running", "version": "0.162.0", "receiver": 64586, "error_receiver": 64587, "prometheus": 64588, "transparent_tcp_tap": "http://127.0.0.1:64598/v1/traces", "synthetic_responses": false}
{"case": "default off without configuration", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.066}
{"case": "default off without configuration observation", "real_receiver_requests": 0}
{"case": "explicit disabled configuration", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.02}
{"case": "explicit disabled configuration observation", "real_receiver_requests": 0}
{"case": "process off override", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.013}
{"case": "process off override observation", "real_receiver_requests": 0}
{"case": "root \"quoted\" \\ slash\ncontrol\^A café 日本語 🐟", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.071}
{"case": "child clamped duration", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.069}
{"case": "minimal metadata", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.059}
{"case": "xtrace credential secrecy", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.071}
{"case": "wire and secret oracle", "exact_w3c_identity": true, "nanoseconds": true, "negative_duration_zero": true, "controls_and_unicode_preserved": true, "project_basename_only": true, "absent_metadata_omitted": true, "token_absent_from_stdout_stderr_payload_and_dedicated_xtrace": true}
{"case": "concatenated enabled objects", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.019}
{"case": "concatenated enabled objects observation", "real_receiver_requests": 0}
{"case": "malformed config", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.019}
{"case": "malformed config observation", "real_receiver_requests": 0}
{"case": "empty config", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.02}
{"case": "empty config observation", "real_receiver_requests": 0}
{"case": "array config", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.019}
{"case": "array config observation", "real_receiver_requests": 0}
{"case": "null config", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.019}
{"case": "null config observation", "real_receiver_requests": 0}
{"case": "invalid traceparent", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.025}
{"case": "invalid traceparent observation", "real_receiver_requests": 0}
{"case": "zero trace identity", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.024}
{"case": "zero trace identity observation", "real_receiver_requests": 0}
{"case": "missing metadata", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.023}
{"case": "missing metadata observation", "real_receiver_requests": 0}
{"case": "stale session-bound state", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.021}
{"case": "stale session-bound state observation", "real_receiver_requests": 0}
{"case": "invalid invocation ('--rot',)", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.013}
{"case": "invalid invocation ('--rot',) observation", "real_receiver_requests": 0}
{"case": "invalid invocation ('--status',)", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.013}
{"case": "invalid invocation ('--status',) observation", "real_receiver_requests": 0}
{"case": "invalid invocation ('--status', 'invalid')", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.013}
{"case": "invalid invocation ('--status', 'invalid') observation", "real_receiver_requests": 0}
{"case": "invalid invocation ('detail=value', '--root')", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.013}
{"case": "invalid invocation ('detail=value', '--root') observation", "real_receiver_requests": 0}
{"case": "non-private bearer header", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "firstmate: trace export skipped: invalid private bearer header file", "elapsed_seconds": 0.028}
{"case": "non-private bearer header observation", "real_receiver_requests": 0}
{"case": "header extra bytes", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "firstmate: trace export skipped: invalid private bearer header file", "elapsed_seconds": 0.033}
{"case": "header extra bytes observation", "real_receiver_requests": 0}
{"case": "state override keeps home collector", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.073}
{"case": "explicit config and state override", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.085}
{"case": "root override when home unset", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.097}
{"case": "metadata belonging to another home", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.023}
{"case": "metadata belonging to another home observation", "real_receiver_requests": 0}
{"case": "state override refuses old home metadata", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.016}
{"case": "state override refuses old home metadata observation", "real_receiver_requests": 0}
{"case": "unset home with explicit config and state", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.064}
{"case": "default configuration from library code home", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.067}
{"case": "state override retains default code-home collector", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.068}
{"case": "missing curl", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.057}
{"case": "missing curl observation", "real_receiver_requests": 0}
{"case": "actual collector rejects wrong credential", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.065}
{"case": "actual collector pipeline fails", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.067}
{"case": "actual legacy collector HTTP 500", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.072}
{"case": "connection refused", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 0.085}
{"case": "delayed collector transport", "caller_exit": 0, "caller_stdout": "caller continued; shell options preserved", "caller_stderr": "", "elapsed_seconds": 1.219}
{"case": "failure oracle", "actual_http_401": "HTTP/1.1 401 Unauthorized", "actual_http_500": "HTTP/1.1 500 Internal Server Error", "actual_http_503": "HTTP/1.1 503 Service Unavailable", "http_500_collector_version": "0.85.0", "delayed_request_later_accepted_by_real_collector": true, "timeout_elapsed_seconds": 1.219, "token_absent_from_actual_curl_argv": true}
{"case": "aggregate fleet metrics", "real_prometheus_endpoint": "http://127.0.0.1:64588/metrics", "project_dimension": "client-alpha", "per_task_identity_dimension": false, "spans_accepted": 11}
{"case": "complete", "result": "pass", "all_requests_forwarded_to_official_collector": true}
```
</details>
<details>
<summary>Evidence: Redacted HTTP requests and actual collector responses</summary>

Source: [Redacted HTTP requests and actual collector responses](https://github.com/jazz127/firstmate/blob/7a9a2a03d73d5d37320cc3e543e146fc069f24db/.no-mistakes/evidence/fm/otel-task-tracing-impl/http-wire-evidence.json)

```text
[
  {
    "request_line": "POST /v1/traces HTTP/1.1",
    "content_type": "application/json",
    "bearer_header_present": true,
    "bearer_header_matches_collector": true,
    "body": {
      "resourceSpans": [
        {
          "resource": {
            "attributes": [
              {
                "key": "service.name",
                "value": {
                  "stringValue": "firstmate"
                }
              },
              {
                "key": "firstmate.task.id",
                "value": {
                  "stringValue": "lab-task"
                }
              },
              {
                "key": "firstmate.project",
                "value": {
                  "stringValue": "client-alpha"
                }
              },
              {
                "key": "firstmate.task.kind",
                "value": {
                  "stringValue": "ship"
                }
              },
              {
                "key": "firstmate.harness",
                "value": {
                  "stringValue": "codex"
                }
              },
              {
                "key": "firstmate.model",
                "value": {
                  "stringValue": "café 日本語 🐟"
                }
              },
              {
                "key": "firstmate.effort",
                "value": {
                  "stringValue": "high"
                }
              }
            ]
          },
          "scopeSpans": [
            {
              "scope": {
                "name": "firstmate"
              },
              "spans": [
                {
                  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
                  "spanId": "00f067aa0ba902b7",
                  "name": "root \"quoted\" \\ slash\ncontrol\^A café 日本語 🐟",
                  "kind": 1,
                  "startTimeUnixNano": "1000000000",
                  "endTimeUnixNano": "2500000000",
                  "attributes": [
                    {
                      "key": "detail",
                      "value": {
                        "stringValue": "quote\" \\ newline\n\^B"
                      }
                    }
                  ],
                  "status": {
                    "code": 1
                  }
                }
              ]
            }
          ]
        }
      ]
    },
    "delay_seconds": 0,
    "actual_collector_response": "HTTP/1.1 200 OK"
  },
  {
    "request_line": "POST /v1/traces HTTP/1.1",
    "content_type": "application/json",
    "bearer_header_present": true,
    "bearer_header_matches_collector": true,
    "body": {
      "resourceSpans": [
        {
          "resource": {
            "attributes": [
              {
                "key": "service.name",
                "value": {
                  "stringValue": "firstmate"
                }
              },
              {
                "key": "firstmate.task.id",
                "value": {
                  "stringValue": "lab-task"
                }
              },
              {
                "key": "firstmate.project",
                "value": {
                  "stringValue": "client-alpha"
                }
              },
              {
                "key": "firstmate.task.kind",
                "value": {
                  "stringValue": "ship"
                }
              },
              {
                "key": "firstmate.harness",
                "value": {
                  "stringValue": "codex"
                }
              },
              {
                "key": "firstmate.model",
                "value": {
                  "stringValue": "café 日本語 🐟"
                }
              },
              {
                "key": "firstmate.effort",
                "value": {
                  "stringValue": "high"
                }
              }
            ]
          },
          "scopeSpans": [
            {
              "scope": {
                "name": "firstmate"
              },
              "spans": [
                {
                  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
                  "spanId": "2744e6c0cc4d8578",
                  "parentSpanId": "00f067aa0ba902b7",
                  "name": "child clamped duration",
                  "kind": 1,
                  "startTimeUnixNano": "9000000",
                  "endTimeUnixNano": "9000000",
                  "attributes": [],
                  "status": {
                    "code": 2
                  }
                }
              ]
            }
          ]
        }
      ]
    },
    "delay_seconds": 0,
    "actual_collector_response": "HTTP/1.1 200 OK"
  },
  {
    "request_line": "POST /v1/traces HTTP/1.1",
    "content_type": "application/json",
    "bearer_header_present": true,
    "bearer_header_matches_collector": true,
    "body": {
      "resourceSpans": [
        {
          "resource": {
            "attributes": [
              {
                "key": "service.name",
                "value": {
                  "stringValue": "firstmate"
                }
              },
              {
                "key": "firstmate.task.id",
                "value": {
                  "stringValue": "minimal"
                }
              }
            ]
          },
          "scopeSpans": [
            {
              "scope": {
                "name": "firstmate"
              },
              "spans": [
                {
                  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
                  "spanId": "00f067aa0ba902b7",
                  "name": "minimal metadata",
                  "kind": 1,
                  "startTimeUnixNano": "1000000000",
                  "endTimeUnixNano": "2000000000",
                  "attributes": []
                }
              ]
            }
          ]
        }
      ]
    },
    "delay_seconds": 0,
    "actual_collector_response": "HTTP/1.1 200 OK"
  },
  {
    "request_line": "POST /v1/traces HTTP/1.1",
    "content_type": "application/json",
    "bearer_header_present": true,
    "bearer_header_matches_collector": true,
    "body": {
      "resourceSpans": [
        {
          "resource": {
            "attributes": [
              {
                "key": "service.name",
                "value": {
                  "stringValue": "firstmate"
                }
              },
              {
                "key": "firstmate.task.id",
                "value": {
                  "stringValue": "lab-task"
                }
              },
              {
                "key": "firstmate.project",
                "value": {
                  "stringValue": "client-alpha"
                }
              },
              {
                "key": "firstmate.task.kind",
                "value": {
                  "stringValue": "ship"
                }
              },
              {
                "key": "firstmate.harness",
                "value": {
                  "stringValue": "codex"
                }
              },
              {
                "key": "firstmate.model",
                "value": {
                  "stringValue": "café 日本語 🐟"
                }
              },
              {
                "key": "firstmate.effort",
                "value": {
                  "stringValue": "high"
                }
              }
            ]
          },
          "scopeSpans": [
            {
              "scope": {
                "name": "firstmate"
              },
              "spans": [
                {
                  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
                  "spanId": "00f067aa0ba902b7",
                  "name": "xtrace credential secrecy",
                  "kind": 1,
                  "startTimeUnixNano": "1000000000",
                  "endTimeUnixNano": "2500000000",
                  "attributes": []
                }
              ]
            }
          ]
        }
      ]
    },
    "delay_seconds": 0,
    "actual_collector_response": "HTTP/1.1 200 OK"
  },
  {
    "request_line": "POST /v1/traces HTTP/1.1",
    "content_type": "

... [13126 bytes truncated] ...

ingValue": "firstmate"
                }
              },
              {
                "key": "firstmate.task.id",
                "value": {
                  "stringValue": "lab-task"
                }
              },
              {
                "key": "firstmate.project",
                "value": {
                  "stringValue": "client-alpha"
                }
              },
              {
                "key": "firstmate.task.kind",
                "value": {
                  "stringValue": "ship"
                }
              },
              {
                "key": "firstmate.harness",
                "value": {
                  "stringValue": "codex"
                }
              },
              {
                "key": "firstmate.model",
                "value": {
                  "stringValue": "café 日本語 🐟"
                }
              },
              {
                "key": "firstmate.effort",
                "value": {
                  "stringValue": "high"
                }
              }
            ]
          },
          "scopeSpans": [
            {
              "scope": {
                "name": "firstmate"
              },
              "spans": [
                {
                  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
                  "spanId": "00f067aa0ba902b7",
                  "name": "actual collector rejects wrong credential",
                  "kind": 1,
                  "startTimeUnixNano": "1000000000",
                  "endTimeUnixNano": "2500000000",
                  "attributes": []
                }
              ]
            }
          ]
        }
      ]
    },
    "delay_seconds": 0,
    "actual_collector_response": "HTTP/1.1 401 Unauthorized"
  },
  {
    "request_line": "POST /v1/traces HTTP/1.1",
    "content_type": "application/json",
    "bearer_header_present": true,
    "bearer_header_matches_collector": true,
    "body": {
      "resourceSpans": [
        {
          "resource": {
            "attributes": [
              {
                "key": "service.name",
                "value": {
                  "stringValue": "firstmate"
                }
              },
              {
                "key": "firstmate.task.id",
                "value": {
                  "stringValue": "lab-task"
                }
              },
              {
                "key": "firstmate.project",
                "value": {
                  "stringValue": "client-alpha"
                }
              },
              {
                "key": "firstmate.task.kind",
                "value": {
                  "stringValue": "ship"
                }
              },
              {
                "key": "firstmate.harness",
                "value": {
                  "stringValue": "codex"
                }
              },
              {
                "key": "firstmate.model",
                "value": {
                  "stringValue": "café 日本語 🐟"
                }
              },
              {
                "key": "firstmate.effort",
                "value": {
                  "stringValue": "high"
                }
              }
            ]
          },
          "scopeSpans": [
            {
              "scope": {
                "name": "firstmate"
              },
              "spans": [
                {
                  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
                  "spanId": "00f067aa0ba902b7",
                  "name": "actual collector pipeline fails",
                  "kind": 1,
                  "startTimeUnixNano": "1000000000",
                  "endTimeUnixNano": "2500000000",
                  "attributes": []
                }
              ]
            }
          ]
        }
      ]
    },
    "delay_seconds": 0,
    "actual_collector_response": "HTTP/1.1 503 Service Unavailable"
  },
  {
    "request_line": "POST /v1/traces HTTP/1.1",
    "content_type": "application/json",
    "bearer_header_present": true,
    "bearer_header_matches_collector": true,
    "body": {
      "resourceSpans": [
        {
          "resource": {
            "attributes": [
              {
                "key": "service.name",
                "value": {
                  "stringValue": "firstmate"
                }
              },
              {
                "key": "firstmate.task.id",
                "value": {
                  "stringValue": "lab-task"
                }
              },
              {
                "key": "firstmate.project",
                "value": {
                  "stringValue": "client-alpha"
                }
              },
              {
                "key": "firstmate.task.kind",
                "value": {
                  "stringValue": "ship"
                }
              },
              {
                "key": "firstmate.harness",
                "value": {
                  "stringValue": "codex"
                }
              },
              {
                "key": "firstmate.model",
                "value": {
                  "stringValue": "café 日本語 🐟"
                }
              },
              {
                "key": "firstmate.effort",
                "value": {
                  "stringValue": "high"
                }
              }
            ]
          },
          "scopeSpans": [
            {
              "scope": {
                "name": "firstmate"
              },
              "spans": [
                {
                  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
                  "spanId": "00f067aa0ba902b7",
                  "name": "actual legacy collector HTTP 500",
                  "kind": 1,
                  "startTimeUnixNano": "1000000000",
                  "endTimeUnixNano": "2500000000",
                  "attributes": []
                }
              ]
            }
          ]
        }
      ]
    },
    "delay_seconds": 0,
    "actual_collector_response": "HTTP/1.1 500 Internal Server Error"
  },
  {
    "request_line": "POST /v1/traces HTTP/1.1",
    "content_type": "application/json",
    "bearer_header_present": true,
    "bearer_header_matches_collector": true,
    "body": {
      "resourceSpans": [
        {
          "resource": {
            "attributes": [
              {
                "key": "service.name",
                "value": {
                  "stringValue": "firstmate"
                }
              },
              {
                "key": "firstmate.task.id",
                "value": {
                  "stringValue": "lab-task"
                }
              },
              {
                "key": "firstmate.project",
                "value": {
                  "stringValue": "client-alpha"
                }
              },
              {
                "key": "firstmate.task.kind",
                "value": {
                  "stringValue": "ship"
                }
              },
              {
                "key": "firstmate.harness",
                "value": {
                  "stringValue": "codex"
                }
              },
              {
                "key": "firstmate.model",
                "value": {
                  "stringValue": "café 日本語 🐟"
                }
              },
              {
                "key": "firstmate.effort",
                "value": {
                  "stringValue": "high"
                }
              }
            ]
          },
          "scopeSpans": [
            {
              "scope": {
                "name": "firstmate"
              },
              "spans": [
                {
                  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
                  "spanId": "00f067aa0ba902b7",
                  "name": "delayed collector transport",
                  "kind": 1,
                  "startTimeUnixNano": "1000000000",
                  "endTimeUnixNano": "2500000000",
                  "attributes": []
                }
              ]
            }
          ]
        }
      ]
    },
    "delay_seconds": 2,
    "actual_collector_response": "HTTP/1.1 200 OK"
  }
]
```
</details>

- Evidence: [Collector-decoded spans](https://github.com/jazz127/firstmate/blob/7a9a2a03d73d5d37320cc3e543e146fc069f24db/.no-mistakes/evidence/fm/otel-task-tracing-impl/collector-spans.jsonl)
- Evidence: [Aggregate fleet metrics](https://github.com/jazz127/firstmate/blob/7a9a2a03d73d5d37320cc3e543e146fc069f24db/.no-mistakes/evidence/fm/otel-task-tracing-impl/fleet-metrics.prom)

<details>
<summary>Evidence: Actual curl process arguments</summary>

Source: [Actual curl process arguments](https://github.com/jazz127/firstmate/blob/7a9a2a03d73d5d37320cc3e543e146fc069f24db/.no-mistakes/evidence/fm/otel-task-tracing-impl/curl-process-argv.log)

```text
18805 18675 curl -q --globoff -sS --max-time 1 -o /dev/null -H Content-Type: application/json -H @~/.no-mistakes/worktrees/119cd7a6b9a4/01M48SHPA9FD7YQ9F7T8E0CW9B/.tmp-otel-validation/header --data-binary @- http://127.0.0.1:64600/v1/traces
```
</details>

- Evidence: [Dedicated xtrace descriptor](https://github.com/jazz127/firstmate/blob/7a9a2a03d73d5d37320cc3e543e146fc069f24db/.no-mistakes/evidence/fm/otel-task-tracing-impl/xtrace.log)

<details>
<summary>Evidence: Focused behavioral tests using synthetic HTTP capture</summary>

Source: [Focused behavioral tests using synthetic HTTP capture](https://github.com/jazz127/firstmate/blob/7a9a2a03d73d5d37320cc3e543e146fc069f24db/.no-mistakes/evidence/fm/otel-task-tracing-impl/focused-tests.log)

```text
ok - loading and disabled emission preserve errexit, nounset, pipefail, and unset-variable behavior
ok - relative library loading with CDPATH preserves caller success and shell options
ok - unset export config is off and makes zero HTTP requests
ok - FM_TRACE_EXPORT=off makes zero HTTP requests
ok - synthetic HTTP capture confirms escaped root JSON, root identity, nanoseconds, auth header, and no token in argv/payload
ok - credential validation and authenticated exports preserve xtrace settings without leaking to a dedicated descriptor
ok - authenticated HTTP export preserves accented, Japanese, and emoji text in names and attributes across locales
ok - child spans link to the carrier parent and negative durations clamp to zero
ok - root and child exports honor directory precedence and relative overrides without crossing homes or falling back
ok - unset home uses the library code root after caller directory changes and state overrides never select another home
ok - only one enabled JSON object exports; concatenated values and malformed input silently preserve success
ok - root and child spans use decimal milliseconds, including padding, 08/09, zero, and clamping
ok - all task kinds export the project basename and task identity without paths or incarnation identities
ok - unknown options, invalid statuses, and malformed attribute arguments silently skip export
ok - documented statuses and attributes remain exportable
ok - endpoint and private header paths preserve literal backslashes through HTTP export
ok - brace and range URL syntax each produce one request to the literal endpoint
ok - group or other readable headers skip export with one diagnostic and preserve success
skip - foreign-owner fixture requires root to change file ownership
ok - single bearer lines export with optional newline; all extra bytes reject export
ok - configuration rejects NUL bytes rather than changing accepted values
ok - absent optional metadata is omitted; missing metadata and malformed carriers issue no request
ok - malformed/stale config, missing curl, refused/slow endpoints, and HTTP 401/500 all preserve success
```
</details>

- Evidence: [Live validation driver](https://github.com/jazz127/firstmate/blob/7a9a2a03d73d5d37320cc3e543e146fc069f24db/.no-mistakes/evidence/fm/otel-task-tracing-impl/live-collector-driver.py)

<details>
<summary>Evidence: Evidence summary and validation boundaries</summary>

Source: [Evidence summary and validation boundaries](https://github.com/jazz127/firstmate/blob/7a9a2a03d73d5d37320cc3e543e146fc069f24db/.no-mistakes/evidence/fm/otel-task-tracing-impl/evidence-summary.json)

```text
{
  "real_upstreams": [
    "Official otelcol-contrib 0.162.0 authenticated OTLP/HTTP receiver and span_metrics connector",
    "Official otelcol-contrib 0.85.0 with a failing OTTL processor for actual HTTP 500"
  ],
  "driver": "Public fm_trace_span_emit Bash interface, actual curl, transparent forwarding TCP observation tap",
  "substitutes": [],
  "real_upstream_responses": {
    "HTTP/1.1 200 OK": 11,
    "HTTP/1.1 401 Unauthorized": 1,
    "HTTP/1.1 503 Service Unavailable": 1,
    "HTTP/1.1 500 Internal Server Error": 1
  },
  "collector_decoded_spans": 11,
  "timing": {
    "case": "failure oracle",
    "actual_http_401": "HTTP/1.1 401 Unauthorized",
    "actual_http_500": "HTTP/1.1 500 Internal Server Error",
    "actual_http_503": "HTTP/1.1 503 Service Unavailable",
    "http_500_collector_version": "0.85.0",
    "delayed_request_later_accepted_by_real_collector": true,
    "timeout_elapsed_seconds": 1.219,
    "token_absent_from_actual_curl_argv": true
  },
  "baseline": "bash tests/fm-trace-span-lib.test.sh passed against its synthetic HTTP server; foreign-owner fixture skipped because EUID is non-root",
  "setup_repairs": "Selected an older real collector for HTTP 500 because current collectors emit 503; corrected the lab processor to trigger a runtime failure. No product changes.",
  "oracles": [
    "Published W3C traceparent test identity",
    "OTLP/JSON protocol",
    "Firstmate documented off, home resolution, caller preservation, private header and metadata contracts",
    "Real collector decoded spans and Prometheus metrics"
  ],
  "teardown": "Both collector subprocesses and every TCP listener stopped by the driver; scratch binaries, headers and homes removed after evidence verification"
}
```
</details>

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"0c161551c449ed520570ee9c277c62da9e52cbb5","steps":[{"step":"intent","status":"completed"},{"step":"rebase","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"},{"step":"lint","status":"completed"},{"step":"push","status":"completed"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}],"live_validation":{"verdict":"go","live":7,"total":7}} -->

<details>
<summary>✅ **Intent** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Rebase** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Review** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Test** - passed</summary>

✅ No issues found.
- Live validation: ✅ go - 7 of 7 scenarios driven live against the product

| Scenario | Result | Live | Evidence |
| --- | --- | --- | --- |
| Leave export disabled or activate the off switch; no HTTP request occurs | ✅ pass | live | live-driver.log: absent configuration, enabled=false and FM_TRACE_EXPORT=off each produced zero requests through the forwarding tap to the real collector. |
| Emit root and child spans; the collector preserves their identity, values and timing | ✅ pass | live | http-wire-evidence.json and collector-spans.jsonl: actual OTLP receiver accepted root and child identity, quoted/control/Unicode text, decimal nanoseconds, clamped duration, project basename and omitt… |
| Configure isolated homes and directory overrides; export stays within the selected home | ✅ pass | live | live-driver.log: home, root, state, configuration and code-home defaults selected the intended real collector; metadata outside effective state caused zero requests. |
| Supply invalid configuration, state or invocation data; the caller continues safely | ✅ pass | live | live-driver.log: malformed or concatenated JSON, invalid carriers, missing metadata, stale session state, invalid options and unsafe header contents skipped requests while preserving caller success. |
| Export with a private bearer header and xtrace enabled; authentication succeeds without token disclosure | ✅ pass | live | Actual authenticated collector acceptance, http-wire-evidence.json, xtrace.log and curl-process-argv.log; assertions confirmed the disposable token was absent from payload, caller output, tracing and… |
| Encounter unavailable tools, rejected requests or slow transport; export preserves caller success and remains bounded | ✅ pass | live | live-driver.log: actual collectors returned HTTP 401, 500 and 503; missing curl and refused connections preserved success. A forwarding transport delay returned in 1.219 seconds, and the real collecto… |
| Feed emitted spans into aggregate fleet metrics; counts and duration histograms appear | ✅ pass | live | fleet-metrics.prom from the official collector&#39;s span_metrics connector and Prometheus endpoint: fleet counts and duration histograms include project and task-kind dimensions without per-task identity… |

- `env TMPDIR="$PWD/.tmp-otel-validation/tmp" bash tests/fm-trace-span-lib.test.sh`
- <code>Downloaded and ran official workspace-local `otelcol-contrib` versions 0.162.0 and 0.85.0.</code>
- `python3 ~/.no-mistakes/evidence/01M48SHPA9FD7YQ9F7T8E0CW9B/live-collector-driver.py`
- `Verified collector-decoded spans against wire evidence and checked actual Prometheus fleet metrics.`
- `Stopped collectors and TCP listeners, removed disposable binaries, headers and homes, and confirmed a clean worktree.`
</details>

<details>
<summary>✅ **Document** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Lint** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Push** - passed</summary>

✅ No issues found.
</details>

