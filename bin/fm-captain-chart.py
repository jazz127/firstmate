#!/usr/bin/env python3
"""Render a deterministic Mermaid fleet chart from bearings and the project registry.

Usage: bin/fm-captain-chart.py [--snapshot-file JSON] [--registry-file PATH]
                               [--output PATH | --stdout | --ascii]

Regenerate: FM_HOME=/path/to/firstmate-home bin/fm-captain-chart.py
View in terminal: FM_HOME=/path/to/firstmate-home bin/fm-captain-chart.py --ascii

Normal operation calls fm-bearings-snapshot.sh --json with its documented --all
selectors. It never requests --include-prs. The stable output path is
FM_HOME/data/captain-chart.mmd and a rendered SVG beside it (FM_HOME defaults to
this code root). SVG rendering uses the installed local mmdc command. The optional
input files support offline tests and do not add another fleet-state reader.
An optional dock=<name> token in a project's registry brackets names a coastal
city; without it the destination is the capital. The registry is never changed.
"""

import argparse
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unicodedata


ROOT = Path(__file__).resolve().parent.parent
REGISTRY_LINE = re.compile(r"^-\s+(\S+)(?:\s+\[([^]]+)\])?\s+-\s+")
STATE_NAMES = {
    "working": "under sail",
    "running": "under sail",
    "idle": "moored",
    "parked": "moored",
    "queued": "moored",
    "paused": "anchored",
    "blocked": "in dry dock",
    "failed": "sunk",
    "done": "moored",
    "unknown": "anchored",
}
SHIP_PRESENTATION = {
    "working": {"sail": True, "glyph": "◿│◣", "hull": "╲▁▁▁╱"},
    "running": {"sail": True, "glyph": "◿│◣", "hull": "╲▁▁▁╱"},
    "idle": {"sail": False, "glyph": "o", "hull": "     "},
    "parked": {"sail": False, "glyph": "o", "hull": "     "},
    "queued": {"sail": False, "glyph": "o", "hull": "     "},
    "paused": {"sail": False, "glyph": "o", "hull": "     "},
    "blocked": {"sail": False, "glyph": "o", "hull": "     "},
    "failed": {"sail": False, "glyph": "o", "hull": "     "},
    "done": {"sail": False, "glyph": "o", "hull": "     "},
    "unknown": {"sail": False, "glyph": "o", "hull": "     "},
}


def label(value, limit=90):
    """Keep user-recorded strings inside one Mermaid quoted label."""
    clean = " ".join(str(value).split())
    if len(clean) > limit:
        clean = clean[: limit - 1] + "…"
    return html.escape(clean, quote=True).replace("|", "&#124;").replace("`", "&#96;")


def registry_projects(source):
    projects = {}
    for line in source.splitlines():
        match = REGISTRY_LINE.match(line)
        if not match:
            continue
        name, annotations = match.groups()
        dock = None
        for token in (annotations or "").split():
            if token.startswith("dock=") and len(token) > 5:
                dock = token[5:].replace("-", " ")
        projects[name] = dock
    return dict(sorted(projects.items(), key=lambda pair: pair[0].casefold()))


def fleet_model(snapshot, projects):
    if snapshot.get("schema") != "fm-bearings.v1":
        raise ValueError("expected fm-bearings.v1 snapshot")
    prs = {row["id"]: row["url"] for row in snapshot.get("recorded_prs", [])}
    reports = {row["id"]: row["path"] for row in snapshot.get("reports", [])}
    ships = {}
    for row in snapshot.get("in_flight", []):
        task_id = row["id"]
        ships[task_id] = {
            "id": task_id,
            "name": row.get("name") or task_id,
            "repo": row.get("repo"),
            "state": row.get("state") or "unknown",
        }
    for row in snapshot.get("gates", []):
        task_id = row["id"]
        if task_id.startswith("(") or task_id in ships:
            continue
        ships[task_id] = {"id": task_id, "name": row.get("title") or task_id,
                          "repo": None, "state": "queued"}
    for row in snapshot.get("decisions_open", []):
        task_id = row["id"]
        if task_id in ships:
            continue
        ships[task_id] = {"id": task_id, "name": row.get("summary") or task_id,
                          "repo": None, "state": "paused"}

    for ship in ships.values():
        ship["nautical"] = STATE_NAMES.get(ship["state"], "anchored")
        ship["presentation"] = SHIP_PRESENTATION[ship["state"]]
        ship["cargo"] = ("PR " + prs[ship["id"]] if ship["id"] in prs else
                         "Report " + reports[ship["id"]] if ship["id"] in reports else
                         "nothing")
        ship["dock"] = projects.get(ship["repo"]) if ship["repo"] in projects else None
    return {"projects": projects, "ships": sorted(ships.values(), key=lambda item: item["id"])}


def render_mermaid(model):
    projects = model["projects"]
    lines = ["flowchart LR", '  subgraph mainland["Mainland: home"]',
             '    capital["Capital city"]']
    docks = sorted({dock for dock in projects.values() if dock}, key=str.casefold)
    dock_ids = {name: f"d{i}" for i, name in enumerate(docks)}
    for name in docks:
        lines.append(f'    {dock_ids[name]}["Satellite coastal city: {label(name)}"]')
    lines.extend(['    harbor["Uncharted berth: project unassigned or unregistered"]',
                  "  end"])

    by_project = {name: [] for name in projects}
    uncharted = []
    for ship in model["ships"]:
        (by_project[ship["repo"]] if ship["repo"] in by_project else uncharted).append(ship)

    edges = []
    classes = []
    index = 0

    def add_ship(ship, dock):
        nonlocal index
        sid = f"s{index}"
        index += 1
        lines.append(f'    {sid}["Ship: {label(ship["name"], 65)}<br/>'
                     f'{label(ship["nautical"])}<br/>Cargo: {label(ship["cargo"], 105)}"]')
        destination = dock_ids[dock] if dock else "capital"
        edges.append(f'  {sid} -->|to {label(dock or "Capital city", 45)}| {destination}')
        classes.append(f'  class {sid} {"sailing" if ship["presentation"]["sail"] else "resting"}')

    for pindex, (name, dock) in enumerate(projects.items()):
        lines.append(f'  subgraph p{pindex}["Island: {label(name)}"]')
        group = sorted(by_project[name], key=lambda item: item["id"])
        if not group:
            lines.append(f'    empty{pindex}["No charted ships"]')
        for ship in group:
            add_ship(ship, dock)
        lines.append("  end")
    if uncharted:
        lines.append('  subgraph uncharted["Ships with unassigned or unregistered project"]')
        for ship in sorted(uncharted, key=lambda item: item["id"]):
            add_ship(ship, None)
        lines.append("  end")

    lines.extend(edges)
    lines.extend(['  subgraph legend["Legend"]',
                  '    key["working/running: under sail<br/>idle/parked/queued/done: moored<br/>paused/unknown: anchored<br/>blocked: in dry dock<br/>failed: sunk"]',
                  "  end",
                  "  classDef sailing fill:#d5f5e3,stroke:#1e8449",
                  "  classDef resting fill:#edf2f7,stroke:#718096"])
    lines.extend(classes)
    return "\n".join(lines) + "\n"


def render_ascii(model):
    """A compact terminal view of the same mapped fleet facts as Mermaid."""
    lines = ["THE CAPTAIN CHART", "~ mainland: Capital city ~"]
    for dock in sorted({dock for dock in model["projects"].values() if dock}, key=str.casefold):
        lines.append(f"  [dock] {dock}")
    for project, dock in model["projects"].items():
        lines.append(f"/\\ island: {project} /\\  -> {dock or 'Capital city'}")
        group = [ship for ship in model["ships"] if ship["repo"] == project]
        if not group:
            lines.append("    no charted ships")
        for ship in group:
            presentation = ship["presentation"]
            glyph = presentation["glyph"]
            hull = presentation["hull"]
            lines.append(f"  {glyph} {ship['name']} [{ship['nautical']}]")
            lines.append(f"  {hull} cargo: {ship['cargo']}")
    unknown = [ship for ship in model["ships"] if ship["repo"] not in model["projects"]]
    if unknown:
        lines.append("~ uncharted berth: project unassigned or unregistered ~")
        for ship in unknown:
            presentation = ship["presentation"]
            glyph = presentation["glyph"]
            lines.append(f"  {glyph} {ship['name']} [{ship['nautical']}] -> Capital city")
            hull = presentation["hull"]
            lines.append(f"  {hull} cargo: {ship['cargo']}")
    lines.append("~" * 24)
    def fit_cells(line):
        cells = 0
        clipped = []
        for char in line:
            width = 0 if unicodedata.combining(char) else (
                2 if unicodedata.east_asian_width(char) in "WF" else 1)
            if cells + width > 60:
                break
            clipped.append(char)
            cells += width
        return "".join(clipped)

    return "\n".join(fit_cells(line) for line in lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot-file", type=Path)
    parser.add_argument("--registry-file", type=Path)
    destination = parser.add_mutually_exclusive_group()
    destination.add_argument("--output", type=Path)
    destination.add_argument("--stdout", action="store_true")
    destination.add_argument("--ascii", action="store_true")
    args = parser.parse_args()
    home = Path(os.environ.get("FM_HOME", ROOT))
    registry = args.registry_file or home / "data/projects.md"
    if args.snapshot_file:
        snapshot = json.loads(args.snapshot_file.read_text())
    else:
        command = [str(ROOT / "bin/fm-bearings-snapshot.sh"), "--json",
                   "--all-in-flight", "--all-decisions", "--all-queued",
                   "--all-reports", "--all-recorded-prs"]
        try:
            snapshot = json.loads(subprocess.check_output(command, text=True))
        except subprocess.CalledProcessError as error:
            raise SystemExit(f"fm-captain-chart: bearings snapshot failed (exit {error.returncode})") from None
    model = fleet_model(snapshot, registry_projects(registry.read_text()))
    if args.ascii:
        sys.stdout.write(render_ascii(model))
        return
    chart = render_mermaid(model)
    if args.stdout:
        sys.stdout.write(chart)
    else:
        output = args.output or home / "data/captain-chart.mmd"
        output.parent.mkdir(parents=True, exist_ok=True)
        svg = output.with_suffix(".svg")
        with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
            source = Path(temporary) / "chart.mmd"
            rendered = Path(temporary) / "chart.svg"
            source.write_text(chart)
            subprocess.run(["mmdc", "-i", str(source), "-o", str(rendered),
                            "-b", "white"], check=True)
            if not rendered.is_file() or rendered.stat().st_size == 0:
                raise RuntimeError(f"mmdc produced no SVG for {output}")
            source.replace(output)
            rendered.replace(svg)
        print(f"{output}\n{svg}")


if __name__ == "__main__":
    main()
