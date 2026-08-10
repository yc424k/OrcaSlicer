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

# Build functions, in page order, mapped to the tab key used by the bridge's
# config API. The printer tab is split across two functions: build_fff() and
# build_unregular_pages(), which adds Motion ability and the extruder pages.
BUILDERS = [
    ("void TabPrint::build()", "process"),
    ("void TabFilament::build()", "filament"),
    ("void TabPrinter::build_fff()", "printer"),
    ("void TabPrinter::build_unregular_pages(", "printer"),
]

PAGE_RE = re.compile(r'add_options_page\(\s*L\("([^"]+)"\)\s*,\s*"([^"]*)"')
# The extruder pages are built in a loop with a formatted title
# ("Extruder %d"), so they carry a variable instead of an L("…") literal.
PAGE_VAR_RE = re.compile(r'add_options_page\(\s*page_name\b')
# Group titles are sometimes plain strings, sometimes empty.
GROUP_RE = re.compile(r'new_optgroup\(\s*(?:L\()?"([^"]*)"\)?')
# The icon is the second argument, after the (possibly L("…")) title.
ICON_RE = re.compile(r'new_optgroup\(\s*(?:L\()?"[^"]*"\)?\s*,\s*L?"([^"]+)"')
OPTION_RE = re.compile(r'append_single_option_line\(\s*"([^"]+)"')
# Custom-gcode and extruder rows go through an Option object first:
#   option = optgroup->get_option("machine_start_gcode");
#   optgroup->append_single_option_line(option);
GET_OPTION_RE = re.compile(r'get_option\(\s*"([^"]+)"')
OPTION_VAR_RE = re.compile(r'append_single_option_line\(\s*option\b')


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
    pending_option = None  # key most recently fetched via get_option()
    for line in function_body(lines, start_index):
        if (match := PAGE_RE.search(line)):
            page = {"title": match.group(1), "groups": []}
            pages.append(page)
            group = None
            continue
        if PAGE_VAR_RE.search(line):
            page = {"title": "Extruder", "groups": []}
            pages.append(page)
            group = None
            continue
        if (match := GROUP_RE.search(line)):
            if page is None:
                continue
            icon = ICON_RE.search(line)
            group = {"title": match.group(1), "icon": icon.group(1) if icon else "", "keys": []}
            page["groups"].append(group)
            continue
        if (match := GET_OPTION_RE.search(line)):
            pending_option = match.group(1)
            continue
        if (match := OPTION_RE.search(line)):
            if group is not None:
                group["keys"].append(match.group(1))
            continue
        if OPTION_VAR_RE.search(line):
            if group is not None and pending_option:
                group["keys"].append(pending_option)
            pending_option = None
    # Drop empty scaffolding (dependencies/notes pages carry no plain options).
    for page in pages:
        page["groups"] = [g for g in page["groups"] if g["keys"]]
    return [p for p in pages if p["groups"]]


def main():
    lines = TAB_CPP.read_text(encoding="utf-8", errors="replace").splitlines()
    layout = {}
    found = set()
    for index, line in enumerate(lines):
        for signature, tab in BUILDERS:
            if line.startswith(signature):
                found.add(signature)
                layout.setdefault(tab, []).extend(parse(lines, index))
    missing = {signature for signature, _ in BUILDERS} - found
    if missing:
        sys.exit(f"could not locate builders: {', '.join(sorted(missing))}")
    json.dump(layout, sys.stdout, ensure_ascii=False, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
