# shellcheck shell=bash
# Dock-local seat binding. docs/configuration.md owns the operator schema.
# fm_dock_resolve <config-dir> <seat> <harness> prints
# seat<TAB>dock-id<TAB>physical-credential-home<TAB>source.
# Seat names come only from the local record; an absent or invalid record refuses.
# Shared by the shell and jq validators; callers supply their anchor syntax.
FM_DOCK_SEAT_NAME_RE='[a-z0-9][a-z0-9-]{0,63}'

fm_dock_seat_valid() {
  local LC_ALL=C
  [[ $1 =~ ^${FM_DOCK_SEAT_NAME_RE}$ ]]
}
fm_dock_resolve() {
  local seat=$2 harness=$3 file="$1/dock.json" id path physical source
  if ! fm_dock_seat_valid "$seat" || [ "$harness" != codex ]; then
    echo "error: unknown or unsupported dock seat '$seat' for harness '$harness' (expected a safe name on codex); launch refused, no ambient account selected" >&2
    return 1
  fi
  if [ -e "$file" ] || [ -L "$file" ]; then
    if [ ! -f "$file" ] || [ ! -r "$file" ] || [ -L "$file" ]; then
      echo "error: dock record must be an ordinary readable JSON file: $file; launch refused, no ambient account selected" >&2
      return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
      echo "error: jq is required to read dock record $file; launch refused, no ambient account selected" >&2
      return 1
    fi
    if ! jq -e --arg seat "$seat" --arg harness "$harness" --arg seat_re "^${FM_DOCK_SEAT_NAME_RE}\\z" '
      def safe: type == "string" and (test("[\u0000-\u001f\u007f]") | not);
      type == "object" and (keys == ["id", "seats", "version"]) and .version == 1 and
      (.id | safe and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
      (.seats | type == "object" and all(keys[]; test($seat_re)) and has($seat)) and
      (.seats[$seat] | type == "object" and (keys == ["credential_home", "harness"]) and
        .harness == $harness and (.credential_home | safe and startswith("/")))
    ' "$file" >/dev/null 2>&1; then
      echo "error: dock record $file is malformed, unsupported, or does not bind seat $seat to $harness; launch refused, no ambient account selected" >&2
      return 1
    fi
    id=$(jq -r .id "$file") || return 1
    path=$(jq -r --arg seat "$seat" '.seats[$seat].credential_home' "$file") || return 1
    source=dock.json
  else
    echo "error: dock record $file is absent; configure seat $seat on this host; launch refused, no ambient account selected" >&2
    return 1
  fi
  if [ ! -d "$path" ] || [ ! -r "$path" ] || [ ! -x "$path" ]; then
    echo "error: dock $id: seat $seat ($harness) resolves to $path, which is missing or unreadable; configure $file and provision this seat on this host; launch refused, no ambient account selected" >&2
    return 1
  fi
  physical=$(cd -P -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: dock $id: seat $seat ($harness) directory cannot be resolved: $path; launch refused, no ambient account selected" >&2
    return 1
  }
  printf '%s\t%s\t%s\t%s\n' "$seat" "$id" "$physical" "$source"
}
