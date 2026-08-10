#!/usr/bin/env python3
"""Extracts the desktop settings-tab layout (pages -> groups -> options) from
src/slic3r/GUI/Tab.cpp into JSON, so the iPad app can render the same tabs,
group titles, icons and option ordering as OrcaSlicer.

Re-run after pulling upstream changes to Tab.cpp:
    scripts/extract_settings_layout.py > ios-app/Resources/settings_layout.json
"""

import json
import re
import sys
from pathlib import Path

TAB_CPP = Path(__file__).resolve().parent.parent / "src/slic3r/GUI/Tab.cpp"

# Build function -> tab key used by the bridge's config API.
BUILDERS = {
    "void TabPrint::build()": "process",
    "void TabFilament::build()": "filament",
    "void TabPrinter::build_fff()": "printer",
}

PAGE_RE = re.compile(r'add_options_page\(\s*L\("([^"]+)"\)\s*,\s*"([^"]*)"')
GROUP_RE = re.compile(r'new_optgroup\(\s*L\("([^"]+)"\)(?:\s*,\s*L?"([^"]*)")?')
OPTION_RE = re.compile(r'append_single_option_line\(\s*"([^"]+)"')


def function_body(lines, start_index):
    """Lines of the function starting at `start_index`, by brace balance."""
    depth = 0
    started = False
    body = []
    for line in lines[start_index:]:
        depth += line.count("{") - line.count("}")
        if not started and "{" in line:
            started = True
        body.append(line)
        if started and depth <= 0:
            break
    return body


def parse(lines, start_index):
    pages = []
    page = None
    group = None
    for line in function_body(lines, start_index):
        if (match := PAGE_RE.search(line)):
            page = {"title": match.group(1), "groups": []}
            pages.append(page)
            group = None
            continue
        if (match := GROUP_RE.search(line)):
            if page is None:
                continue
            group = {"title": match.group(1), "icon": match.group(2) or "", "keys": []}
            page["groups"].append(group)
            continue
        if (match := OPTION_RE.search(line)):
            if group is not None:
                group["keys"].append(match.group(1))
    # Drop empty scaffolding (dependencies/notes pages carry no plain options).
    for page in pages:
        page["groups"] = [g for g in page["groups"] if g["keys"]]
    return [p for p in pages if p["groups"]]


def main():
    lines = TAB_CPP.read_text(encoding="utf-8", errors="replace").splitlines()
    layout = {}
    for index, line in enumerate(lines):
        for signature, tab in BUILDERS.items():
            if line.startswith(signature):
                layout[tab] = parse(lines, index)
    missing = set(BUILDERS.values()) - set(layout)
    if missing:
        sys.exit(f"could not locate builders for: {', '.join(sorted(missing))}")
    json.dump(layout, sys.stdout, ensure_ascii=False, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
