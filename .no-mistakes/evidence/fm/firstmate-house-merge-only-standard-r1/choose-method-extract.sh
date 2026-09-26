github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}
github_choose_default_method() {
  local settings rules line allowed='' rule_methods method narrowed
  local branch_path api_err api_err_text refuse_hint
  FM_PR_GITHUB_DEFAULT_METHOD=
  refuse_hint='pass --squash, --merge, or --rebase after -- to choose explicitly'
  if ! settings=$(gh repo view "$PR_OWNER/$PR_REPO" \
    --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed \
    --jq '"merge=" + (.mergeCommitAllowed | tostring), "squash=" + (.squashMergeAllowed | tostring), "rebase=" + (.rebaseMergeAllowed | tostring)' \
    2>/dev/null); then
    printf 'error: refusing to merge %s: the repository merge-method settings could not be read, so no merge method was chosen; %s\n' \
      "$URL" "$refuse_hint" >&2
    return 1
  fi
  for method in merge squash rebase; do
    line=$(printf '%s\n' "$settings" | grep -x "$method=[a-z]*" | tail -1)
    case "$line" in
      "$method=true") allowed="$allowed $method" ;;
      "$method=false") ;;
      *)
        printf 'error: refusing to merge %s: the repository merge-method settings could not be read, so no merge method was chosen; %s\n' \
          "$URL" "$refuse_hint" >&2
        return 1
        ;;
    esac
  done

  branch_path=$(github_urlencode_path_segment "$FM_PR_GITHUB_BASE")
  api_err=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-method-rules.XXXXXX") || return 1
  if ! rules=$(gh api \
    --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" \
    --jq '.[] | select(.type == "pull_request") | "allowed_merge_methods=" + ((.parameters.allowed_merge_methods // ["merge", "squash", "rebase"]) | join(","))' \
    2>"$api_err"); then
    api_err_text=$(cat "$api_err" 2>/dev/null)
    rm -f "$api_err"
    case "$api_err_text" in
      *"Upgrade to GitHub Pro or make this repository public"*) rules='' ;;
      *)
        printf 'error: refusing to merge %s: the branch rules for base branch %s could not be read, so no merge method was chosen; %s\n' \
          "$URL" "$FM_PR_GITHUB_BASE" "$refuse_hint" >&2
        return 1
        ;;
    esac
  else
    rm -f "$api_err"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      allowed_merge_methods=*) rule_methods=${line#allowed_merge_methods=} ;;
      *)
        printf 'error: refusing to merge %s: the branch rules for base branch %s could not be read, so no merge method was chosen; %s\n' \
          "$URL" "$FM_PR_GITHUB_BASE" "$refuse_hint" >&2
        return 1
        ;;
    esac
    narrowed=''
    for method in $allowed; do
      case ",$rule_methods," in
        *",$method,"*) narrowed="$narrowed $method" ;;
      esac
    done
    allowed=$narrowed
  done <<RULES
$rules
RULES

  allowed=${allowed# }
  case " $allowed " in
    *" squash "*) FM_PR_GITHUB_DEFAULT_METHOD=squash ;;
    " merge ") FM_PR_GITHUB_DEFAULT_METHOD=merge ;;
    *)
      allowed=${allowed// /, }
      printf 'error: refusing to merge %s: base branch %s allows %s, so no default merge method applies; %s\n' \
        "$URL" "$FM_PR_GITHUB_BASE" "${allowed:-no merge method}" "$refuse_hint" >&2
      return 1
      ;;
  esac
}
