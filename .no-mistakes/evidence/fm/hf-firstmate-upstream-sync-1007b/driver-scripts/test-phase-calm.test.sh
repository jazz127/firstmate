#!/usr/bin/env bash
# Focused rendering, lifecycle, persistence, and interactive TUI checks for /calm.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-calm-pi-extension)
EXT="$ROOT/.pi/extensions/fm-calm.ts"
ASSISTANT_LAYOUT="$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
PRESERVATION="$ROOT/.pi/extensions/lib/fm-calm-preservation.ts"
OPERATIONAL_USER_LAYOUT="$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
PENDING_OPERATIONAL_LAYOUT="$ROOT/.pi/extensions/lib/fm-calm-pending-operational-layout.ts"
VISIBILITY="$ROOT/.pi/extensions/lib/fm-calm-visibility.ts"
WORKING_SHIP="$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts"
WORKING_SHIP_SPRITE="$ROOT/.pi/extensions/lib/fm-calm-working-ship-sprite.ts"
WATCH_EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh"
PI_OPERATIONAL_INPUT="$ROOT/.pi/extensions/lib/fm-operational-input.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
TMUX_SOCKET="fm-calm-$$"
TMUX_SESSION="fm-calm-e2e"
# Verified against Pi 0.81.1 and 0.82.0 (docs/calm-mode-feasibility.md). This is
# known-good evidence, not a support ceiling: the fixtures below run against whatever
# Pi is actually installed, and record_pi_version_evidence never rejects a newer
# version. The tracked presentation adapters probe the exact API they patch (see
# .pi/extensions/fm-calm.ts) instead of relying on version inference, so a version
# string is evidence for the record, not a gate.
record_pi_version_evidence() {
  local version=$1 context=$2
  [ -n "$version" ] || fail "$context could not determine the installed Pi version"
}

trap fm_test_cleanup EXIT
test_working_ship_geometry_and_lifecycle() {
  local fixture out status version standalone_ship
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "skip: node or npm not found for Pi Calm working-ship test"
    return 0
  fi
  if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return 0
  fi
  version=$(node -p "require('$PI_PACKAGE_DIR/package.json').version")
  record_pi_version_evidence "$version" "Pi Calm working-ship assumptions"

  # The standalone Pi Calm extension is a separate project that installs its own boat
  # in the same Pi working-row slot, so the dual-install check below reads its real
  # module when it is installed: a rename on either side then renders two boats and
  # fails there, instead of passing against a key this test invented. The pinned slot
  # contract inside the program covers a machine without that extension.
  standalone_ship=${FM_STANDALONE_CALM_SHIP:-}
  if [ -z "$standalone_ship" ] && [ -f "${HOME:-}/.pi/agent/extensions/calm/lib/working-ship.ts" ]; then
    standalone_ship=${HOME:-}/.pi/agent/extensions/calm/lib/working-ship.ts
  fi
  [ -f "$standalone_ship" ] || standalone_ship=

  fixture="$TMP_ROOT/working-ship"
  mkdir -p "$fixture/home" "$fixture/lib" "$fixture/node_modules/@earendil-works"
  cp "$EXT" "$fixture/fm-calm.ts"
  cp "$ASSISTANT_LAYOUT" "$fixture/lib/fm-calm-assistant-layout.ts"
  cp "$PRESERVATION" "$fixture/lib/fm-calm-preservation.ts"
  cp "$OPERATIONAL_USER_LAYOUT" "$fixture/lib/fm-calm-operational-user-layout.ts"
  cp "$PENDING_OPERATIONAL_LAYOUT" "$fixture/lib/fm-calm-pending-operational-layout.ts"
  cp "$VISIBILITY" "$fixture/lib/fm-calm-visibility.ts"
  cp "$WORKING_SHIP" "$fixture/lib/fm-calm-working-ship.ts"
  cp "$WORKING_SHIP_SPRITE" "$fixture/lib/fm-calm-working-ship-sprite.ts"
  cp "$PI_OPERATIONAL_INPUT" "$fixture/lib/fm-operational-input.ts"
  ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/node_modules/typebox"
  printf '%s\n' '{"type":"module"}' >"$fixture/package.json"

  out=$(cd "$fixture" && EXT="$fixture/fm-calm.ts" FM_HOME="$fixture/home" PI_PACKAGE_DIR="$PI_PACKAGE_DIR" STANDALONE_CALM_SHIP="$standalone_ship" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";

const packageRoot = process.env.PI_PACKAGE_DIR;
const [{ initTheme, theme }, { visibleWidth, setCapabilities }] = await Promise.all([
  import(pathToFileURL(`${packageRoot}/dist/modes/interactive/theme/theme.js`).href),
  import(pathToFileURL(`${packageRoot}/node_modules/@earendil-works/pi-tui/dist/index.js`).href),
]);
initTheme("dark");
setCapabilities({ images: null, trueColor: true, hyperlinks: false });

const ship = await import(
  `${pathToFileURL(`${process.cwd()}/lib/fm-calm-working-ship.ts`).href}?ship=${Date.now()}`
);
const {
  CALM_WORKING_SHIP_WIDGET_KEY,
  CALM_WORKING_SHIP_TICK_MS,
  CALM_WORKING_SHIP_TICKS_PER_MOVE,
  createCalmWorkingShipAnimation,
  createCalmWorkingShipWidget,
} = ship;

const ESC = "\u001b";
const BLUE = `${ESC}[34m`;
const YELLOW = `${ESC}[33m`;
const RESET = `${ESC}[39m`;
const SAIL = "◿│◣";
const HULL = "╲▁▁▁╱";
const WAVE_BARS = "▁▂▃▄";
const strip = (text) => text.replace(new RegExp(`${ESC}\\[[0-9;]*m`, "g"), "");
const check = (condition, message) => {
  if (!condition) throw new Error(message);
};
const sailOf = (frame) => strip(frame[0]).includes(SAIL) ? SAIL : "none";

// --- Calm cadence: the boat is materially slower than the water ------------------
{
  // The pre-revision boat moved one column every 140ms. The revised boat must be
  // plainly slower in real use while the water keeps rippling between its steps.
  const msPerColumn = CALM_WORKING_SHIP_TICK_MS * CALM_WORKING_SHIP_TICKS_PER_MOVE;
  check(msPerColumn >= 700, `boat cadence ${msPerColumn}ms per column is not materially slower`);
  check(
    CALM_WORKING_SHIP_TICKS_PER_MOVE >= 2,
    "the water cadence is not independent of and faster than the boat cadence",
  );
  check(
    CALM_WORKING_SHIP_TICK_MS < msPerColumn,
    "the water does not animate faster than the boat moves",
  );
}

// --- Water phases loop independently while the boat stays put --------------------
{
  const width = 40;
  const animation = createCalmWorkingShipAnimation();
  animation.render(width);
  const startPosition = animation.position();
  const waterRows = new Set();
  const phases = new Set();
  for (let step = 0; step < CALM_WORKING_SHIP_TICKS_PER_MOVE - 1; step += 1) {
    animation.tick();
    check(
      animation.position() === startPosition,
      `the boat moved on tick ${step + 1} instead of waiting for its own cadence`,
    );
    waterRows.add(strip(animation.render(width)[1]));
    phases.add(animation.waterPhase());
  }
  check(waterRows.size > 1, "the water did not animate while the boat was stationary");
  check(phases.size > 1, "the water phase did not advance between boat movements");
  // The boat then moves on its own cadence tick.
  animation.tick();
  check(
    animation.position() !== startPosition,
    "the boat never moved on its own cadence tick",
  );
  // Water motion alone must not change the hull column.
  const beforeHull = strip(animation.render(width)[1]).indexOf(HULL);
  animation.tick();
  const afterHull = strip(animation.render(width)[1]).indexOf(HULL);
  check(beforeHull === afterHull, "advancing only the water appeared to move the boat");
}

// --- Water phases are bounded, fixed-cell, and never change geometry -------------
{
  const width = 30;
  const animation = createCalmWorkingShipAnimation();
  const seenPhases = new Set();
  for (let step = 0; step < 64; step += 1) {
    const frame = animation.render(width);
    seenPhases.add(animation.waterPhase());
    check(frame.length === 2, `water phase ${animation.waterPhase()} changed the row count`);
    check(
      visibleWidth(frame[1]) === width,
      `water phase ${animation.waterPhase()} changed the visible width`,
    );
    animation.tick();
  }
  check(seenPhases.size > 1 && seenPhases.size <= 8, `water phase set is not bounded: ${seenPhases.size}`);
}

// --- Long low waves are smooth, deterministic, and non-repeating -----------------
{
  const first = createCalmWorkingShipAnimation();
  const second = createCalmWorkingShipAnimation();
  for (let step = 0; step < 24; step += 1) {
    const firstFrame = first.render(240);
    const secondFrame = second.render(240);
    check(
      JSON.stringify(firstFrame) === JSON.stringify(secondFrame),
      `deterministic animations diverged at step ${step}`,
    );
    const row = strip(firstFrame[1]).replace(HULL, "▁".repeat(5));
    check(/^[▁▂▃▄]+$/.test(row), `wave left its low four-glyph scale: ${row}`);
    const levels = [...row].map((cell) => WAVE_BARS.indexOf(cell));
    for (let index = 1; index < levels.length; index += 1) {
      check(
        Math.abs(levels[index] - levels[index - 1]) <= 1,
        `wave jumped from ${row[index - 1]} to ${row[index]} at column ${index}`,
      );
    }
    const sample = row.slice(24);
    for (let period = 1; period <= 18; period += 1) {
      check(
        sample.slice(0, -period) !== sample.slice(period),
        `wave collapsed into a fixed ${period}-cell cycle`,
      );
    }
    if (step === 0) {
      const crestCenters = [];
      let crestStart = -1;
      for (let index = 0; index <= row.length; index += 1) {
        if (row[index] === "▄" && crestStart < 0) crestStart = index;
        if (row[index] !== "▄" && crestStart >= 0) {
          crestCenters.push((crestStart + index - 1) / 2);
          crestStart = -1;
        }
      }
      const wavelengths = crestCenters.slice(1).map((center, index) => center - crestCenters[index]);
      check(wavelengths.length >= 6, "wide render did not expose enough wave periods");
      check(
        wavelengths.every((length) => length >= 17.5 && length <= 26.5),
        `visible wavelengths left their bounded long range: ${wavelengths.join(",")}`,
      );
      check(new Set(wavelengths).size > 1, "visible wavelengths lost deterministic variation");
    }
    first.tick();
    second.tick();
  }
}

// --- Standard ANSI colors, with resets that prevent bleed ------------------------
{
  const width = 24;
  const animation = createCalmWorkingShipAnimation();
  for (let step = 0; step < 12; step += 1) {
    const [sailRow, waterRow] = animation.render(width);

    // Standard codes only: no bright variants, no 256-color, no RGB.
    for (const row of [sailRow, waterRow]) {
      const codes = row.match(new RegExp(`${ESC}\\[[0-9;]*m`, "g")) ?? [];
      for (const code of codes) {
        check(
          code === BLUE || code === YELLOW || code === RESET,
          `non-standard ANSI escape ${JSON.stringify(code)} in ${JSON.stringify(row)}`,
        );
      }
      check(codes.length > 0, "a rendered row carried no color at all");
      // Every colored run is closed, so nothing bleeds into padding or later frames.
      check(
        codes.filter((c) => c !== RESET).length === codes.filter((c) => c === RESET).length,
        `unbalanced color/reset pairs in ${JSON.stringify(row)}`,
      );
      check(codes[codes.length - 1] === RESET, `row does not end color-reset: ${JSON.stringify(row)}`);
    }

    // Sail-row padding must be plain spaces outside any color run.
    const leading = sailRow.slice(0, sailRow.indexOf(ESC));
    check(/^ *$/.test(leading), `sail row padding was colored: ${JSON.stringify(leading)}`);

    // Both sail halves and the mast are one yellow run, so the sail never splits into
    // mismatched colors, and the hull is one yellow run whose interior is not blue.
    check(
      sailRow.includes(`${YELLOW}◿│◣${RESET}`),
      `sail was not painted as one unified yellow run: ${JSON.stringify(sailRow)}`,
    );
    check(
      visibleWidth("◿") === 1 && visibleWidth(SAIL) === 3,
      "the width-safe smaller sail broke the three-cell sprite",
    );
    check(
      waterRow.includes(`${YELLOW}╲▁▁▁╱${RESET}`),
      `hull was not painted as one unified yellow run: ${JSON.stringify(waterRow)}`,
    );
    // Every water cell outside the hull is blue whatever its height, so the swell
    // reads through glyph height alone rather than a crest-versus-trough color split.
    const waterCells = waterRow.replace(`${YELLOW}╲▁▁▁╱${RESET}`, "").match(/\u001b\[\d+m[▁▂▃▄]\u001b\[39m/g) ?? [];
    check(waterCells.length > 0, "no colored water cells surrounded the hull");
    check(
      waterCells.every((cell) => cell.startsWith(BLUE)),
      `water was not all blue: ${JSON.stringify(waterCells.filter((cell) => !cell.startsWith(BLUE)))}`,
    );
    check(
      waterCells.some((cell) => cell.includes("▃") || cell.includes("▄")),
      "the checked frame carried no crest cell, so the all-blue assertion proved nothing",
    );
    check(
      /^[▁▂▃▄╲╱]+$/.test(strip(waterRow)),
      `water row contained a non-wave glyph: ${JSON.stringify(strip(waterRow))}`,
    );
    animation.tick();
  }
}

// --- ANSI-stripped visible width is exact at every width and phase ---------------
for (let width = 1; width <= 120; width += 1) {
  const animation = createCalmWorkingShipAnimation();
  animation.render(width);
  for (let step = 0; step <= width + 8; step += 1) {
    const frame = animation.render(width);
    const expectedRows = width >= 5 ? 2 : 1;
    check(frame.length === expectedRows, `width ${width} rendered ${frame.length} rows`);
    for (const line of frame) {
      check(
        visibleWidth(line) <= width,
        `width ${width} rendered a ${visibleWidth(line)}-cell line and would wrap`,
      );
      check(
        visibleWidth(line) === strip(line).length,
        `width ${width} let ANSI bytes affect the measured geometry`,
      );
    }
    // The water row always fills the complete usable width.
    const waterRow = frame[frame.length - 1];
    check(
      visibleWidth(waterRow) === width,
      `width ${width} water row was ${visibleWidth(waterRow)} cells instead of full width`,
    );
    animation.tick();
  }
}

// --- Centered sail, broad trough, and exact bounce, including tiny spans ---------
for (const width of [40, 16, 8, 6, 5, 4, 3, 2]) {
  const animation = createCalmWorkingShipAnimation();
  animation.render(width);
  const span = width >= 5 ? width - 5 : width >= 3 ? width - 3 : 0;
  const frames = [];
  for (let step = 0; step < span * CALM_WORKING_SHIP_TICKS_PER_MOVE * 3 + 16; step += 1) {
    const frame = animation.render(width);
    const bare = frame.map(strip);
    frames.push({
      position: animation.position(),
      direction: animation.direction(),
      sail: sailOf(frame),
    });
    if (width >= 5) {
      const sailStart = bare[0].indexOf(SAIL);
      const hullStart = bare[1].indexOf(HULL);
      check(sailStart === hullStart + 1, `width ${width} sail and hull starts drifted`);
      check(sailStart + 1 === hullStart + 2, `width ${width} centers were not aligned`);
      const before = bare[1].slice(Math.max(0, hullStart - 3), hullStart);
      const after = bare[1].slice(hullStart + 5, hullStart + 8);
      check(/^[▁]*$/.test(before) && /^[▁]*$/.test(after), `width ${width} hull left its trough`);
    }
    animation.tick();
  }
  for (const frame of frames) {
    check(
      frame.position >= 0 && frame.position <= span,
      `width ${width} left the track at column ${frame.position}`,
    );
    if (width >= 3) check(frame.sail === SAIL, `width ${width} lost its fixed sail`);
  }
  if (span > 0) {
    const positions = frames.map((frame) => frame.position);
    check(Math.min(...positions) === 0, `width ${width} never reached the left edge`);
    check(Math.max(...positions) === span, `width ${width} never reached the right edge`);
    const directions = new Set(frames.map((frame) => frame.direction));
    check(directions.has(1) && directions.has(-1), `width ${width} did not reverse both ways`);
  }
}

// --- Shrink and grow resize clamping ----------------------------------------------
{
  const animation = createCalmWorkingShipAnimation();
  animation.render(80);
  while (animation.position() < 75) animation.tick();
  check(animation.position() === 75, `boat did not reach the wide right edge: ${animation.position()}`);

  const shrunk = animation.render(20);
  check(animation.position() === 15, `shrink did not clamp the track immediately: ${animation.position()}`);
  check(visibleWidth(shrunk[1]) === 20, `shrunk water row was ${visibleWidth(shrunk[1])} cells instead of 20`);
  check(visibleWidth(shrunk[0]) <= 20, "shrunk sail row would wrap");
  check(animation.direction() === -1, "the boat did not turn around after being clamped to the right edge");

  for (let step = 0; step < CALM_WORKING_SHIP_TICKS_PER_MOVE; step += 1) animation.tick();
  const afterShrink = animation.render(20);
  check(animation.position() < 15, "the boat stalled at the edge after a shrink");
  check(visibleWidth(afterShrink[1]) === 20, "motion after a shrink broke the water row width");

  const grown = animation.render(60);
  check(visibleWidth(grown[1]) === 60, `grown water row was ${visibleWidth(grown[1])} cells`);
  for (let step = 0; step < CALM_WORKING_SHIP_TICKS_PER_MOVE; step += 1) animation.tick();
  const afterGrow = animation.render(60);
  check(
    animation.position() >= 0 && animation.position() <= 55,
    `motion left the grown track: ${animation.position()}`,
  );
  check(visibleWidth(afterGrow[1]) === 60, "motion after a grow broke the water row width");
}

// --- Deterministic narrow fallbacks ------------------------------------------------
{
  const animation = createCalmWorkingShipAnimation();
  check(JSON.stringify(animation.render(0)) === "[]", "zero width rendered a line");
  for (const width of [1, 2, 3, 4]) {
    const fallback = createCalmWorkingShipAnimation();
    for (let step = 0; step < 12; step += 1) {
      const frame = fallback.render(width);
      check(frame.length === 1, `width ${width} fallback was not a single row`);
      check(visibleWidth(frame[0]) === width, `width ${width} fallback was not exactly ${width} cells`);
      const bare = strip(frame[0]);
      if (width < 3) {
        check(new RegExp(`^[${WAVE_BARS}]+$`).test(bare), `width ${width} fallback was not low water: ${bare}`);
      } else {
        check(bare.includes(SAIL), `width ${width} fallback lost the sail: ${bare}`);
      }
      fallback.tick();
    }
  }
}

// --- Freeze/resume continuity on one shared animation instance ---------------------
// Hiding the working presentation must freeze column and direction. The next widget
// bound to the same animation resumes exactly there; hidden wall time must not jump.
{
  const animation = createCalmWorkingShipAnimation();
  const tui = { requestRender() {} };
  animation.render(40);
  for (let step = 0; step < CALM_WORKING_SHIP_TICKS_PER_MOVE * 7; step += 1) animation.tick();
  animation.render(40);
  const frozenColumn = animation.position();
  const frozenDirection = animation.direction();
  const frozenPhase = animation.waterPhase();
  check(frozenColumn > 0, `continuity setup never left the left edge: ${frozenColumn}`);

  const first = createCalmWorkingShipWidget(tui, animation);
  check(first.render(40) && animation.position() === frozenColumn, "binding a widget moved the frozen boat");
  first.dispose();
  // Dispose freezes; further wall time without ticks must not change logical state.
  check(animation.position() === frozenColumn, "dispose changed the frozen column");
  check(animation.direction() === frozenDirection, "dispose changed the frozen direction");
  check(animation.waterPhase() === frozenPhase, "dispose changed the frozen water phase");

  const resumed = createCalmWorkingShipWidget(tui, animation);
  const firstFrame = resumed.render(40);
  check(
    animation.position() === frozenColumn && animation.direction() === frozenDirection,
    `resume first frame left frozen state: col=${animation.position()} dir=${animation.direction()}`,
  );
  check(sailOf(firstFrame) === SAIL, "resume first frame lost its centered sail");
  check(animation.waterPhase() === frozenPhase, "resume advanced water phase without a tick");
  // After resume, motion continues from the frozen state rather than restarting.
  for (let step = 0; step < CALM_WORKING_SHIP_TICKS_PER_MOVE; step += 1) animation.tick();
  check(
    animation.position() === frozenColumn + frozenDirection,
    `post-resume motion did not continue from frozen column: ${animation.position()}`,
  );
  resumed.dispose();

  // Hidden resize clamps without needing a live widget, and preserves a valid heading.
  animation.render(80);
  while (animation.position() < 75) animation.tick();
  animation.render(80);
  check(animation.position() === 75 && animation.direction() === -1, "endpoint setup failed before hidden resize");
  const beforeHiddenResize = { column: animation.position(), direction: animation.direction(), phase: animation.waterPhase() };
  animation.clampToWidth(20);
  check(animation.position() === 15, `hidden shrink did not clamp: ${animation.position()}`);
  check(animation.direction() === -1, "hidden shrink lost the leftward heading at the right edge");
  check(animation.waterPhase() === beforeHiddenResize.phase, "hidden clamp advanced water phase");
  // Growing while hidden must not invent motion either.
  animation.clampToWidth(60);
  check(animation.position() === 15, `hidden grow moved the boat: ${animation.position()}`);
  check(animation.direction() === -1, "hidden grow changed direction without cause");

  // Endpoint and bounce continuity: pause immediately before, at, and after each edge.
  for (const scenario of [
    { label: "before-right", setup(anim) {
      anim.reset(); anim.render(12);
      while (anim.position() < 6) anim.tick();
      check(anim.position() === 6 && anim.direction() === 1, "before-right setup");
    }},
    { label: "at-right", setup(anim) {
      anim.reset(); anim.render(12);
      while (anim.position() < 7) anim.tick();
      check(anim.position() === 7 && anim.direction() === -1, "at-right setup");
    }},
    { label: "after-right", setup(anim) {
      anim.reset(); anim.render(12);
      while (anim.position() < 7) anim.tick();
      for (let step = 0; step < CALM_WORKING_SHIP_TICKS_PER_MOVE; step += 1) anim.tick();
      check(anim.position() === 6 && anim.direction() === -1, "after-right setup");
    }},
    { label: "before-left", setup(anim) {
      anim.reset(); anim.render(12);
      while (anim.position() < 7) anim.tick();
      while (!(anim.position() === 1 && anim.direction() === -1)) anim.tick();
    }},
    { label: "at-left", setup(anim) {
      anim.reset(); anim.render(12);
      while (anim.position() < 7) anim.tick();
      while (!(anim.position() === 0 && anim.direction() === 1)) anim.tick();
    }},
    { label: "after-left", setup(anim) {
      anim.reset(); anim.render(12);
      while (anim.position() < 7) anim.tick();
      while (!(anim.position() === 0 && anim.direction() === 1)) anim.tick();
      for (let step = 0; step < CALM_WORKING_SHIP_TICKS_PER_MOVE; step += 1) anim.tick();
      check(anim.position() === 1 && anim.direction() === 1, "after-left setup");
    }},
  ]) {
    const edge = createCalmWorkingShipAnimation();
    scenario.setup(edge);
    edge.render(12);
    const frozen = { column: edge.position(), direction: edge.direction(), phase: edge.waterPhase() };
    const paused = createCalmWorkingShipWidget(tui, edge);
    paused.dispose();
    const again = createCalmWorkingShipWidget(tui, edge);
    again.render(12);
    check(
      edge.position() === frozen.column && edge.direction() === frozen.direction && edge.waterPhase() === frozen.phase,
      `${scenario.label} resume changed frozen edge state`,
    );
    for (let step = 0; step < CALM_WORKING_SHIP_TICKS_PER_MOVE; step += 1) edge.tick();
    const expectedColumn = Math.min(7, Math.max(0, frozen.column + frozen.direction));
    let expectedDirection = frozen.direction;
    if (expectedColumn >= 7) expectedDirection = -1;
    else if (expectedColumn <= 0) expectedDirection = 1;
    check(
      edge.position() === expectedColumn && edge.direction() === expectedDirection,
      `${scenario.label} post-resume bounce drifted: col=${edge.position()} dir=${edge.direction()}`,
    );
    again.dispose();
  }

  // reset() returns a genuine fresh-session initial state.
  animation.reset();
  check(
    animation.position() === 0 && animation.direction() === 1 && animation.waterPhase() === 0,
    "reset() did not restore the normal initial boat state",
  );
  animation.render(40);
  check(sailOf(animation.render(40)) === SAIL, "reset() first frame lost the centered sail");

  // Two controller instances never share motion state.
  const left = createCalmWorkingShipAnimation();
  const right = createCalmWorkingShipAnimation();
  left.render(40);
  right.render(40);
  for (let step = 0; step < CALM_WORKING_SHIP_TICKS_PER_MOVE * 3; step += 1) left.tick();
  check(left.position() === 3 && right.position() === 0, "separate animations leaked motion state");
}

{
  const realSetInterval = globalThis.setInterval;
  const realClearInterval = globalThis.clearInterval;
  const callbacks = [];
  const handles = new Set();
  globalThis.setInterval = (callback) => {
    callbacks.push(callback);
    const handle = { unref() {} };
    handles.add(handle);
    return handle;
  };
  globalThis.clearInterval = (handle) => {
    handles.delete(handle);
  };

  try {
    const tui = { renderRequests: 0, requestRender() { this.renderRequests += 1; } };
    const animation = createCalmWorkingShipAnimation();
    const first = createCalmWorkingShipWidget(tui, animation);
    first.render(40);
    callbacks[callbacks.length - 1]();
    callbacks[callbacks.length - 1]();
    check(tui.renderRequests === 2, "unpainted timer ticks did not request renders");
    first.dispose();
    check(handles.size === 0, "disposing the unpainted widget left its timer scheduled");
    check(
      animation.position() === 0 && animation.direction() === 1 && animation.waterPhase() === 0,
      "dispose retained state from unpainted timer ticks",
    );

    const resumed = createCalmWorkingShipWidget(tui, animation);
    resumed.render(40);
    for (let step = 0; step < CALM_WORKING_SHIP_TICKS_PER_MOVE; step += 1) {
      callbacks[callbacks.length - 1]();
    }
    resumed.render(40);
    check(animation.position() === 1, "unpainted ticks leaked into the resumed cadence");
    check(animation.waterPhase() === 0, "resumed cadence did not restore the rendered water phase");
    resumed.dispose();

    const committed = createCalmWorkingShipAnimation();
    const progressing = createCalmWorkingShipWidget(tui, committed);
    progressing.render(40);
    callbacks[callbacks.length - 1]();
    progressing.render(40);
    const renderedPhase = committed.waterPhase();
    callbacks[callbacks.length - 1]();
    progressing.dispose();
    check(committed.position() === 0, "dispose changed the committed column after an unpainted tick");
    check(committed.waterPhase() === renderedPhase, "dispose changed the committed phase after an unpainted tick");

    const committedResume = createCalmWorkingShipWidget(tui, committed);
    committedResume.render(40);
    for (let step = 0; step < CALM_WORKING_SHIP_TICKS_PER_MOVE - 2; step += 1) {
      callbacks[callbacks.length - 1]();
    }
    check(committed.position() === 0, "serviced render did not preserve the committed cadence");
    callbacks[callbacks.length - 1]();
    committedResume.render(40);
    check(committed.position() === 1, "serviced render did not commit progress for the next cadence");
    committedResume.dispose();

    const boundaryCases = [
      [6, 1], [7, -1], [6, -1], [1, -1], [0, 1], [1, 1],
    ];
    for (const [targetPosition, targetDirection] of boundaryCases) {
      const edge = createCalmWorkingShipAnimation();
      edge.render(12);
      let reached = false;
      for (let step = 0; step < 160; step += 1) {
        if (edge.position() === targetPosition && edge.direction() === targetDirection) {
          edge.render(12);
          reached = true;
          break;
        }
        edge.tick();
        edge.render(12);
      }
      check(reached, `could not prepare bounce state ${targetPosition}/${targetDirection}`);
      const before = { position: edge.position(), direction: edge.direction(), phase: edge.waterPhase() };
      const paused = createCalmWorkingShipWidget(tui, edge);
      paused.render(12);
      for (let step = 0; step < CALM_WORKING_SHIP_TICKS_PER_MOVE; step += 1) {
        callbacks[callbacks.length - 1]();
      }
      paused.dispose();
      check(
        edge.position() === before.position &&
          edge.direction() === before.direction &&
          edge.waterPhase() === before.phase,
        `unpainted bounce tick escaped ${targetPosition}/${targetDirection}`,
      );
      const resumedEdge = createCalmWorkingShipWidget(tui, edge);
      resumedEdge.render(12);
      check(
        edge.position() === before.position && edge.direction() === before.direction,
        `bounce state ${targetPosition}/${targetDirection} changed on resume`,
      );
      resumedEdge.dispose();
    }
  } finally {
    globalThis.setInterval = realSetInterval;
    globalThis.clearInterval = realClearInterval;
  }
}

// --- Lifecycle through the Calm extension's registered handlers --------------------
let liveTimers = 0;
const realSetInterval = globalThis.setInterval;
const realClearInterval = globalThis.clearInterval;
globalThis.setInterval = (...args) => {
  liveTimers += 1;
  return realSetInterval(...args);
};
globalThis.clearInterval = (timer) => {
  if (timer !== undefined) liveTimers -= 1;
  return realClearInterval(timer);
};

const sessionWrites = [];
const handlers = new Map();
let calmCommand;
const pi = {
  events: { emit() {}, on() {} },
  on(event, handler) {
    const existing = handlers.get(event) ?? [];
    existing.push(handler);
    handlers.set(event, existing);
  },
  registerCommand(name, command) {
    if (name === "calm") calmCommand = command;
  },
  registerEntryRenderer() {},
  registerTool() {},
  getAllTools() {
    return [];
  },
  appendEntry: (...args) => sessionWrites.push(["appendEntry", ...args]),
  sendMessage: (...args) => sessionWrites.push(["sendMessage", ...args]),
  sendUserMessage: (...args) => sessionWrites.push(["sendUserMessage", ...args]),
  setSessionName: (...args) => sessionWrites.push(["setSessionName", ...args]),
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?ship=${Date.now()}`);
extension.default(pi);
check(!!calmCommand, "Calm command was not registered");
for (const event of ["session_start", "agent_start", "agent_settled", "session_shutdown"]) {
  check(handlers.has(event), `Calm did not register a ${event} handler`);
}

let renderRequests = 0;
const tui = { requestRender: () => { renderRequests += 1; } };
const ui = {
  workingVisible: [],
  visibilityCalls: 0,
  widgetOps: [],
  widgets: new Map(),
  setWorkingVisible(visible) {
    this.visibilityCalls += 1;
    this.workingVisible.push(visible);
  },
  // Mirrors Pi's documented widget contract: the previous component under a key is
  // disposed before a replacement is installed, and clearing disposes it too.
  setWidget(key, content, options) {
    const existing = this.widgets.get(key);
    if (existing?.dispose) existing.dispose();
    this.widgets.delete(key);
    this.widgetOps.push({
      key,
      action: content === undefined ? "clear" : "set",
      placement: options?.placement,
    });
    if (content === undefined) return;
    this.widgets.set(key, typeof content === "function" ? content(tui, theme) : content);
  },
  getEditorText: () => "",
  getToolsExpanded: () => false,
  onTerminalInput: () => () => {},
  setHiddenThinkingLabel() {},
  setStatus() {},
  setToolsExpanded() {},
  notify() {},
  theme,
};
const ctx = { ui };
const fire = async (event, payload = {}) => {
  for (const handler of handlers.get(event) ?? []) await handler(payload, ctx);
};
const reset = () => {
  ui.workingVisible.length = 0;
  ui.widgetOps.length = 0;
  ui.visibilityCalls = 0;
};
const shipWidget = () => ui.widgets.get(CALM_WORKING_SHIP_WIDGET_KEY);

let standaloneDisposed = false;
const standaloneWidget = {
  render: () => ["standalone boat"],
  dispose: () => { standaloneDisposed = true; },
};
const firstmateWidget = {
  render: () => ["firstmate boat"],
  dispose: () => {},
};
// The standalone Pi Calm extension installs its boat in the same Pi working-row
// widget slot. Where that extension is installed, the slot key comes from its own
// module, so a rename on either side registers two widgets and fails here rather
// than passing against a key this test invented; the pinned slot is the shared
// contract both implementations must keep.
const STANDALONE_SLOT = "calm-working-ship";
let standaloneSlot = STANDALONE_SLOT;
if (process.env.STANDALONE_CALM_SHIP) {
  const standaloneShip = await import(
    `${pathToFileURL(process.env.STANDALONE_CALM_SHIP).href}?standalone=${Date.now()}`
  );
  standaloneSlot = standaloneShip.CALM_WORKING_SHIP_WIDGET_KEY;
}
ui.setWidget(standaloneSlot, () => standaloneWidget);
ui.setWidget(CALM_WORKING_SHIP_WIDGET_KEY, () => firstmateWidget);
const renderedDualInstallWidgets = [...ui.widgets.values()].map((widget) => widget.render(80));
check(
  standaloneDisposed &&
    renderedDualInstallWidgets.length === 1 &&
    renderedDualInstallWidgets[0][0] === "firstmate boat",
  `dual Calm install rendered ${renderedDualInstallWidgets.length} working widgets instead of one`,
);
ui.setWidget(standaloneSlot, undefined);

// --- Calm off leaves Pi's stock working behavior completely untouched -------------
await fire("session_start", { reason: "startup" });
reset();
for (const event of ["agent_start", "agent_settled", "session_shutdown"]) {
  await fire(event, { reason: "quit" });
}
check(
  ui.visibilityCalls === 0,
  `Calm off called setWorkingVisible ${ui.visibilityCalls} times from the run lifecycle`,
);
check(ui.widgetOps.length === 0, `Calm off registered a working widget: ${JSON.stringify(ui.widgetOps)}`);
check(liveTimers === 0, `Calm off started ${liveTimers} animation timers`);

// --- Turning Calm on while idle shows no boat until a run starts -------------------
reset();
await calmCommand.handler("", ctx);
check(ui.widgetOps.length === 0, "toggling Calm on while idle installed a working widget");
check(liveTimers === 0, "toggling Calm on while idle started an animation timer");

// --- Calm on plus an active run shows the boat instead of the stock row -----------
reset();
await fire("agent_start");
check(
  ui.widgetOps.length === 1 &&
    ui.widgetOps[0].key === CALM_WORKING_SHIP_WIDGET_KEY &&
    ui.widgetOps[0].action === "set",
  `Calm on did not install exactly one working widget: ${JSON.stringify(ui.widgetOps)}`,
);
check(ui.widgetOps[0].placement === undefined, "Calm working widget asked for a non-default placement");
check(
  ui.workingVisible[ui.workingVisible.length - 1] === false,
  "Calm on did not hide Pi's stock working row",
);
check(liveTimers === 1, `Calm on kept ${liveTimers} animation timers instead of one`);

const widget = shipWidget();
check(!!widget, "Calm on did not install the working-ship widget");
check(typeof widget.render === "function", "working widget has no render(width)");
check(typeof widget.invalidate === "function", "working widget has no invalidate()");
check(typeof widget.dispose === "function", "working widget has no dispose()");
// A focusable widget could steal input or swallow Escape; this one takes no keys.
check(widget.handleInput === undefined, "working widget accepts keyboard input");
check(widget.wantsKeyRelease === undefined, "working widget asked for key release events");
if (process.env.FM_CALM_RENDER_EVIDENCE) writeFileSync(process.env.FM_CALM_RENDER_EVIDENCE, "Synthetic Pi UI context; real Calm widget renderer\n" + widget.render(60).join("\n") + "\n");
check(widget.render(60).length === 2, "installed working widget did not render the two-row sprite");
check(
  widget.render(60).every((line) => visibleWidth(line) <= 60),
  "installed working widget rendered a line wider than its viewport",
);

// --- Repeated low-level starts inside one logical run never duplicate anything -----
reset();
for (let repeat = 0; repeat < 5; repeat += 1) await fire("agent_start");
check(ui.widgetOps.length === 0, `repeated starts churned the working widget: ${JSON.stringify(ui.widgetOps)}`);
check(liveTimers === 1, `repeated starts left ${liveTimers} animation timers`);
check(ui.widgets.size === 1, `repeated starts left ${ui.widgets.size} widgets`);
check(shipWidget() === widget, "repeated starts replaced the running widget");

// --- The animation drives Pi's renderer -------------------------------------------
{
  const before = renderRequests;
  await new Promise((resolve) => setTimeout(resolve, CALM_WORKING_SHIP_TICK_MS * 3));
  check(renderRequests > before, "the working animation never requested a TUI render");
}

// --- Settling removes the boat, stops the animation, and restores the stock row ----
// Drive the live widget far enough that a left-edge reset would be observable.
{
  const moving = shipWidget();
  check(!!moving, "continuity setup lost the live working widget");
  moving.render(40);
  await new Promise((resolve) => setTimeout(resolve, CALM_WORKING_SHIP_TICK_MS * CALM_WORKING_SHIP_TICKS_PER_MOVE * 5 + 40));
  moving.render(40);
}
const hullColumn = (widget) => strip(widget.render(40)[1]).indexOf(HULL);
const freezeColumn = hullColumn(shipWidget());
const freezeSail = sailOf(shipWidget().render(40));
check(freezeColumn > 0, `lifecycle continuity setup never left the left edge: ${freezeColumn}`);

reset();
await fire("agent_settled");
check(
  ui.widgetOps.length === 1 &&
    ui.widgetOps[0].key === CALM_WORKING_SHIP_WIDGET_KEY &&
    ui.widgetOps[0].action === "clear",
  `settling did not clear the working widget: ${JSON.stringify(ui.widgetOps)}`,
);
check(liveTimers === 0, `settling left ${liveTimers} animation timers`);
check(ui.widgets.size === 0, "settling left a residual widget");
check(
  ui.workingVisible[ui.workingVisible.length - 1] === true,
  "settling did not restore Pi's stock working row",
);
{
  // No stale rows survive the removal: the widget renders nothing once disposed.
  const renderRequestsAfterDispose = renderRequests;
  await new Promise((resolve) => setTimeout(resolve, CALM_WORKING_SHIP_TICK_MS * CALM_WORKING_SHIP_TICKS_PER_MOVE * 3));
  check(
    renderRequests === renderRequestsAfterDispose,
    "the animation kept running after the widget was removed",
  );
}

// --- Later working period resumes the frozen column and direction -----------------
reset();
await fire("agent_start");
check(liveTimers === 1, `resume start left ${liveTimers} animation timers instead of one`);
check(ui.widgets.size === 1, "resume start did not install exactly one working widget");
const resumedWidget = shipWidget();
const resumeColumn = hullColumn(resumedWidget);
const resumeSail = sailOf(resumedWidget.render(40));
check(
  resumeColumn === freezeColumn && resumeSail === freezeSail,
  `resume reset the boat instead of continuing: froze ${freezeColumn}/${freezeSail}, resumed ${resumeColumn}/${resumeSail}`,
);
// Repeated start/settle cycles must not duplicate scheduler or widget ownership.
for (let cycle = 0; cycle < 3; cycle += 1) {
  await fire("agent_settled");
  check(liveTimers === 0, `cycle ${cycle} settle left ${liveTimers} timers`);
  check(ui.widgets.size === 0, `cycle ${cycle} settle left a residual widget`);
  await fire("agent_start");
  check(liveTimers === 1, `cycle ${cycle} start left ${liveTimers} timers`);
  check(ui.widgets.size === 1, `cycle ${cycle} start left ${ui.widgets.size} widgets`);
  check(
    hullColumn(shipWidget()) >= freezeColumn,
    `cycle ${cycle} lost continuity after repeated settle/start`,
  );
}
await fire("agent_settled");
check(liveTimers === 0 && ui.widgets.size === 0, "repeated continuity cycles did not finish clean");

// A genuine fresh session resets to the normal initial position.
reset();
await fire("session_start", { reason: "new" });
check(liveTimers === 0 && ui.widgets.size === 0, "fresh session left a stale boat");
await fire("agent_start");
check(hullColumn(shipWidget()) === 0, "fresh session did not restart at the left edge");
check(sailOf(shipWidget().render(40)) === SAIL, "fresh session lost the centered sail");
await fire("agent_settled");

// --- Abort and failure share Pi's agent_settled path ------------------------------
// Pi emits agent_settled from a finally block, so an aborted or failed run reaches
// exactly this handler; the real-TUI regression covers the Escape abort path.
for (const outcome of ["abort", "failure"]) {
  reset();
  await fire("agent_start");
  check(liveTimers === 1, `${outcome} setup did not start the animation`);
  await fire("agent_settled");
  check(liveTimers === 0, `${outcome} left ${liveTimers} animation timers`);
  check(ui.widgets.size === 0, `${outcome} left a residual widget`);
  check(
    ui.workingVisible[ui.workingVisible.length - 1] === true,
    `${outcome} did not restore Pi's stock working row`,
  );
}

// --- Shutdown, reload, and session replacement all clean up -----------------------
for (const reason of ["quit", "reload", "new", "resume", "fork"]) {
  reset();
  await fire("agent_start");
  check(liveTimers === 1, `${reason} setup did not start the animation`);
  await fire("session_shutdown", { reason });
  check(liveTimers === 0, `session_shutdown(${reason}) left ${liveTimers} animation timers`);
  check(ui.widgets.size === 0, `session_shutdown(${reason}) left a residual widget`);
  check(
    ui.workingVisible[ui.workingVisible.length - 1] === true,
    `session_shutdown(${reason}) did not restore Pi's stock working row`,
  );
  if (reason === "quit") continue;
  reset();
  await fire("session_start", { reason });
  check(ui.widgets.size === 0, `session_start(${reason}) installed a stale widget`);
  check(liveTimers === 0, `session_start(${reason}) left ${liveTimers} animation timers`);
}

// --- Toggling Calm off during an active run restores the stock row immediately -----
await fire("session_start", { reason: "startup" });
reset();
await fire("agent_start");
check(liveTimers === 1, "active-run setup did not start the animation");
await calmCommand.handler("", ctx);
check(liveTimers === 0, "toggling Calm off during a run left the animation running");
check(ui.widgets.size === 0, "toggling Calm off during a run left the boat on screen");
check(
  ui.workingVisible[ui.workingVisible.length - 1] === true,
  "toggling Calm off during a run did not restore Pi's stock working row",
);

// Toggling Calm back on during the same run returns the boat.
reset();
await calmCommand.handler("", ctx);
check(liveTimers === 1, "toggling Calm on during a run did not return the boat");
check(
  ui.workingVisible[ui.workingVisible.length - 1] === false,
  "toggling Calm on during a run did not hide Pi's stock working row",
);
await fire("agent_settled");
check(liveTimers === 0, "the toggled-on run did not clean up");

// A run started after toggling Calm on while idle uses the boat.
reset();
await calmCommand.handler("", ctx);
await calmCommand.handler("", ctx);
await fire("agent_start");
check(liveTimers === 1, "a later run did not use the boat after an idle Calm toggle");
await fire("agent_settled");
check(liveTimers === 0, "the later run did not clean up");

await fire("agent_start");
let survivingStandaloneDisposed = false;
const survivingStandaloneWidget = {
  render: () => ["standalone boat"],
  dispose: () => { survivingStandaloneDisposed = true; },
};
ui.setWidget(standaloneSlot, () => survivingStandaloneWidget);
reset();
await calmCommand.handler("", ctx);
check(
  !survivingStandaloneDisposed &&
    ui.widgets.size === 1 &&
    ui.widgets.get(standaloneSlot) === survivingStandaloneWidget &&
    ui.widgetOps.length === 0 &&
    ui.workingVisible.length === 0,
  "turning Firstmate Calm off cleared or exposed the standalone working ship",
);
ui.setWidget(standaloneSlot, undefined);

// --- The visual-only widget never touches session, transcript, or export data ------
check(
  sessionWrites.length === 0,
  `the working presentation wrote session or transcript data: ${JSON.stringify(sessionWrites)}`,
);

globalThis.setInterval = realSetInterval;
globalThis.clearInterval = realClearInterval;
JS
)
  status=$?
  [ "$status" -eq 0 ] || fail "Pi Calm working-ship checks failed: $out"
  [ -z "$out" ] || fail "Pi Calm working-ship test printed output: $out"
  pass "Pi Calm working ship keeps its centered two-row asymmetric Unicode boat inside a deterministic long-wave trough, paints all water standard blue and the whole boat standard yellow with balanced resets, keeps ANSI-stripped width exact, reverses cleanly at both edges and every width, clamps visible and hidden resizes, falls back deterministically when narrow, freezes and resumes across settle/start without hidden-time jumps or duplicate timers, resets only on a fresh session, and leaves Calm-off visibility untouched"
  if [ -n "$standalone_ship" ]; then
    pass "Pi Calm dual-install coverage read the installed standalone Pi Calm extension's own working-ship slot from $standalone_ship"
  else
    pass "SKIP: no standalone Pi Calm extension is installed, so dual-install coverage used the pinned shared-slot contract; set FM_STANDALONE_CALM_SHIP to check one"
  fi
}


test_working_ship_geometry_and_lifecycle
