#!/usr/bin/env bash
# fm-house-board.sh - rebuild the read-only house feature board from the private register and live GitHub.
#
# Usage: bin/fm-house-board.sh build
#        bin/fm-house-board.sh path
#
# build reads $FM_HOME/data/house-line.md, fetches fork and upstream facts with
# gh-axi, and atomically writes $FM_HOME/.lavish/house-board.json and .html.
# It opens the HTML with Lavish but never registers or polls an answer source.
# FM_HOUSE_BOARD_TEMPLATE and FM_HOUSE_BOARD_NO_SERVE are test-only overrides.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

case "${1-}" in
  build)
    [ "$#" -eq 1 ] || exit 2
    exec python3 "$SCRIPT_DIR/fm-house-board.py" build
    ;;
  path)
    [ "$#" -eq 1 ] || exit 2
    printf '%s/.lavish/house-board.html\n' "$FM_HOME"
    ;;
  -h|--help|help)
    sed -n '2,/^set -eu/p' "$0" | sed '$d;s/^# \?//'
    ;;
  *)
    printf 'usage: %s build|path\n' "$0" >&2
    exit 2
    ;;
esac
