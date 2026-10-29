#!/usr/bin/env bash
set -eu
root=${1:?repository root required}
. "${2:-$root/bin/fm-composer-lib.sh}"
caps=$'styled=1\ncursor=0\nidentity=1\nrows=20'
head=$'────────────────────────── Firstmate ──\n❯'
close=$'\n───────────────────────────────────────'
footer=$'\n  → repo git:(main) | Opus 5\n  ⏵⏵ bypass permissions on'
prior=$'────────\nold output\n────────\n'
failed=0
check() {
  local name=$1 want=$2 screen=$3 identity=$4 want_content=${5-__skip__} got content
  got=$(fm_composer_classify_screen "$caps" "$screen" '' "$identity")
  printf '\nCASE %s\nINPUT SCREEN:\n%s\nIDENTITY %s\nEXPECTED %s; OBSERVED %s\n' "$name" "$screen" "$identity" "$want" "$got"
  [ "$got" = "$want" ] || failed=1
  if [ "$want_content" != __skip__ ]; then
    if content=$(fm_composer_extract_selected_content "$caps" "$screen"); then
      printf 'EXTRACTED <%s>; EXPECTED <%s>\n' "$content" "$want_content"
      [ "$content" = "$want_content" ] || failed=1
    else
      printf 'EXTRACTION refused\n'
      [ "$want_content" = __refuse__ ] || failed=1
    fi
  fi
}
printf 'Synthetic public-classifier replay. No harness, Herdr server, or upstream service is substituted for live evidence. This is OFFLINE evidence only.\nOracle: author intent plus recorded R1/R2 decisions; Pi spinner preservation is the existing native-working contract.\n'
for locale_name in en_US.UTF-8 C; do
  export LC_ALL=$locale_name
  printf '\nLOCALE %s\n' "$LC_ALL"
  check 'ASCII idle title' empty "$head$close" $'claude\tidle' ''
  check 'ASCII one-line draft' pending "$head message$close" $'claude\tidle' message
  check 'ASCII wrapped draft' pending "$head message"$'\ncontinuation row'"$close" $'claude\tidle' 'message continuation row'
  check 'ASCII idle with arrow footer' empty "$head$close$footer" $'claude\tidle' ''
  check 'ASCII wrapped draft with arrow footer' pending "$head message"$'\ncontinuation row'"$close$footer" $'claude\tidle' 'message continuation row'
  check 'Non-ASCII title defers' unknown "${head/Firstmate/Fïrstmate}$close" $'claude\tidle' __refuse__
  check 'Titled blank pane cannot prove Pi identity' unknown "${head/❯/}$close" $'pi\tidle' __refuse__
  check 'Prior transcript pair cannot rescue non-ASCII title' unknown "$prior${head/Firstmate/Fïrstmate}$close" $'claude\tidle' __refuse__
  check 'Prior transcript pair cannot rescue wrong-width title' unknown "$prior${head/Firstmate/Firstmates}$close" $'claude\tidle' __refuse__
  check 'Prior transcript pair cannot rescue title without glyph' unknown "$prior${head/❯/}$close" $'claude\tidle' __refuse__
  check 'Prior transcript pair cannot rescue incomplete title' unknown "${prior}────────────────────────── Fïrstmate ──" $'claude\tidle' __refuse__
  check 'Valid newer envelope replaces prior transcript pair' pending "$prior$head message"$'\ncontinuation row'"$close" $'claude\tidle' 'message continuation row'
  check 'Pi native working spinner stays supported' empty $'transcript\n── ⠏ Working ───────────────\n\n────────────────────────\n footer' $'pi\tworking'
  check 'Pi spinner with idle identity defers' unknown $'transcript\n── ⠏ Working ───────────────\n\n────────────────────────\n footer' $'pi\tidle'
done
exit "$failed"
