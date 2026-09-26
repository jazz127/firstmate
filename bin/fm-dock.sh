#!/usr/bin/env bash
# Read-only diagnostic: fm-dock.sh resolve --seat luna --harness codex
# Reads ${FM_CONFIG_OVERRIDE:-${FM_HOME:-<repo>}/config}/dock.json.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-dock-lib.sh
. "$SCRIPT_DIR/fm-dock-lib.sh"
seat=''
harness=''
[ "${1:-}" = resolve ] || { echo 'usage: fm-dock.sh resolve --seat luna --harness codex' >&2; exit 2; }
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
  --seat) [ "$#" -ge 2 ] || exit 2; seat=$2; shift 2 ;;
  --harness) [ "$#" -ge 2 ] || exit 2; harness=$2; shift 2 ;;
  *) echo "error: unknown dock argument: $1" >&2; exit 2 ;;
  esac
done
config=${FM_CONFIG_OVERRIDE:-${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}/config}
binding=$(fm_dock_resolve "$config" "$seat" "$harness") || exit 1
IFS=$'\t' read -r seat dock home source <<< "$binding"
printf 'seat=%s\ndock=%s\ncredential_home=%s\nsource=%s\n' "$seat" "$dock" "$home" "$source"
