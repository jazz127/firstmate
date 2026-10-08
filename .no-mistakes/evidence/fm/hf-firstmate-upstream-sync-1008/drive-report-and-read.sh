#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$(mktemp -d "$PWD/.gate-validation/report-read.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
for name in parent alpha beta; do
  "$ROOT/bin/fm-lab-home.sh" create "$LAB/$name" >/dev/null
done
for name in alpha beta; do
  printf '%s\n' "$name" > "$LAB/$name/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB/parent" > "$LAB/$name/.fm-secondmate-parent"
done
export FM_HOME="$LAB/parent"
. "$ROOT/bin/fm-marker-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
state="$LAB/parent/state"
alpha=$(fm_pending_reply_create "$LAB/parent" "$state" alpha 'Disposable report-channel check')
beta=$(fm_pending_reply_create "$LAB/parent" "$state" beta 'Disposable report-channel check')
# The initial delivered requests are disposable input records. No transport or
# model-delivery claim is made; the exercised surface is local report writing
# and resolution from those actual parent-channel files.
fm_pending_reply_mark_delivered "$state" "$alpha"
fm_pending_reply_mark_delivered "$state" "$beta"
phase() { fm_pending_reply_get "$(fm_pending_reply_path "$state" "$1")" phase; }
FM_HOME="$LAB/beta" "$ROOT/bin/fm-secondmate-report.sh" done "$beta" "Beta answered; alpha still owes corr=$alpha"
if fm_pending_reply_try_resolve "$state" "$alpha" "$state/beta.status"; then
  echo 'ERROR: wrong-task report resolved alpha'; exit 1
fi
[ "$(phase "$alpha")" = awaiting_report ]
printf 'After beta quotes alpha: alpha.phase=%s\n' "$(phase "$alpha")"
cat "$state/beta.status"
fm_pending_reply_try_resolve "$state" "$beta" "$state/beta.status"
[ "$(phase "$beta")" = resolved ]
printf 'After beta reports: beta.phase=%s\n' "$(phase "$beta")"
printf 'done xcorr=%s: prefixed token\ndone corr=%sff: suffixed token\n' "$alpha" "$alpha" > "$state/alpha.status"
if fm_pending_reply_try_resolve "$state" "$alpha"; then
  echo 'ERROR: partial token resolved alpha'; exit 1
fi
[ "$(phase "$alpha")" = awaiting_report ]
printf 'After partial tokens: alpha.phase=%s\n' "$(phase "$alpha")"
FM_HOME="$LAB/alpha" "$ROOT/bin/fm-secondmate-report.sh" done "$alpha" 'Alpha answered on its own channel'
fm_pending_reply_try_resolve "$state" "$alpha" "$state/alpha.status"
[ "$(phase "$alpha")" = resolved ]
printf 'After alpha reports: alpha.phase=%s\n' "$(phase "$alpha")"
cat "$state/alpha.status"
cat "$(fm_pending_reply_path "$state" "$alpha")"

printf '\nSIMULATED Lavish upstream captures; real adapter read command\n'
for ended in no yes; do
  {
    printf 'session:\n  file: /disposable-review.html\n  status: feedback\n'
    if [ "$ended" = yes ]; then printf '  session_ended: true\n'; fi
    cat <<'EOF'
prompts[4]{uid,prompt,selector,tag,text}:
  "el-a","","aside.sidebar",note,"Sidebar note"
  "","first comment","",message,"Freeform message"
  "","second comment","",message,"Freeform message"
  "","third comment","",message,"Freeform message"
EOF
  } > "$LAB/capture"
  printf '\nCaptured session ended=%s\n' "$ended"
  out=$("$ROOT/bin/fm-procevent-lavish.sh" read "$LAB/capture")
  printf '%s\n' "$out"
  if [ "$ended" = yes ]; then
    case "$out" in *'session_ending_message_count: 3'*) ;; *) exit 1 ;; esac
    case "$out" in *'captain_message_count:'*) exit 1 ;; esac
  else
    case "$out" in *'captain_message_count: 3'*) ;; *) exit 1 ;; esac
    case "$out" in *'session_ending_message_count:'*) exit 1 ;; esac
  fi
  case "$out" in *'annotation_count: 1'*) ;; *) exit 1 ;; esac
done
