#!/usr/bin/env bash
# Count ordinary task workers still able to spend in this home.
# Usage: fm-afk-spend-count.sh <state-dir>
# Missing or stopped endpoints and current terminal-ready tasks do not count.
# Unreadable endpoint state counts conservatively; a done status is excluded
# only when fm-crew-state.sh accepts its current state and named-head gate.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

STATE=${1:-}
[ -d "$STATE" ] || { echo "usage: fm-afk-spend-count.sh <state-dir>" >&2; exit 2; }

live=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
  id=${meta##*/}
  id=${id%.meta}
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || continue
  case "$backend" in
    tmux|herdr)
      endpoint_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || endpoint_state=unreadable
      case "$endpoint_state" in dead|missing) continue ;; esac
      ;;
    *)
      fm_backend_target_exists "$backend" "$target" "fm-$id" || continue
      ;;
  esac

  status="$STATE/$id.status"
  if [ -f "$status" ] && [ "$(status_line_verb "$(status_current_line "$status" "$(fm_meta_get "$meta" kind)")")" = "done" ]; then
    current=$(FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null) || current=
    case "$current" in "state: done "*) continue ;; esac
  fi
  live=$((live + 1))
done
printf '%s\n' "$live"
