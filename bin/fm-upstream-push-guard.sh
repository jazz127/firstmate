#!/usr/bin/env bash
set -eu

ROOT=${1:?missing Firstmate root}
RECORD=${2:?missing prior-art record}
REMOTE_URL=${4:?missing push URL}

github_repo() {
  local url=$1 rest path
  case "$url" in
    https://github.com/*)
      rest=${url#https://}
      rest=${rest#*@}
      case "$rest" in
        github.com/*) path=${rest#github.com/} ;;
        *) return 1 ;;
      esac
      path=${path%%\?*} ;;
    ssh://git@github.com/*) path=${url#ssh://git@github.com/} ;;
    git@github.com:*) path=${url#git@github.com:} ;;
    *) return 1 ;;
  esac
  path=${path%.git}
  [[ "$path" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s\n' "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
}

target=$(github_repo "$REMOTE_URL" 2>/dev/null || true)
[ -n "$target" ] || exit 0
origin=$(git config --get remote.origin.url 2>/dev/null || true)
origin_repo=$(github_repo "$origin" 2>/dev/null || true)
[ -n "$origin_repo" ] || exit 0
[ "$target" = "$origin_repo" ] && exit 0

while read -r _ local_sha _ _; do
  case "$local_sha" in
    ''|0000000000000000000000000000000000000000) continue ;;
  esac
  (cd "$(git rev-parse --show-toplevel)" && python3 "$ROOT/bin/fm-upstream-prior-art.py" verify \
    --record "$RECORD" --repo "$target" --head "$local_sha") || {
    printf '%s\n' "upstream push refused: prior-art receipt does not match $target@$local_sha" >&2
    exit 1
  }
done
