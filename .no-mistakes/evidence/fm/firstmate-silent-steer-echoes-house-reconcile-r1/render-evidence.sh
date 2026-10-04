#!/usr/bin/env bash
set -eu
export CHROME_DEVTOOLS_AXI_SESSION=gate-01m4372-replay
export CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$PWD/.gate-test-tmp/chrome-profile"
export CHROME_DEVTOOLS_AXI_BRIDGE_TIMEOUT_MS=20000
unset CHROME_DEVTOOLS_AXI_AUTO_CONNECT CHROME_DEVTOOLS_AXI_BROWSER_URL CHROME_DEVTOOLS_AXI_HEADED
cleanup() { chrome-devtools-axi stop >/dev/null 2>&1 || true; }
trap cleanup EXIT
chrome-devtools-axi open file:///Users/jarad/.no-mistakes/evidence/01M4372PFF3JWKYX618ESNHJ6Q/live-pi-replay.html
chrome-devtools-axi resize 1200 800
chrome-devtools-axi screenshot /Users/jarad/.no-mistakes/evidence/01M4372PFF3JWKYX618ESNHJ6Q/live-pi-replay.png
chrome-devtools-axi eval '() => { const text = document.querySelector("main").innerText; const summaries = ["The pause cleared and worker resumed", "The worker recovered after the registered pause", "The existing captain hold is unchanged"]; return { visibleProbe: text.includes("Live Pi replay check"), routineNotesVisibleInTranscript: summaries.some(summary => text.includes(summary)) }; }' 
