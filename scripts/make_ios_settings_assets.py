#!/usr/bin/env python3
"""Builds the iPad app's asset catalog for the settings-group icons, copying
the SVGs the extracted layout references straight from resources/images so the
groups carry the same icons as the desktop sidebar.

Run after scripts/extract_settings_layout.py:
    scripts/make_ios_settings_assets.py
"""

import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LAYOUT = ROOT / "ios-app/Resources/settings_layout.json"
IMAGES = ROOT / "resources/images"
CATALOG = ROOT / "ios-app/Resources/Assets.xcassets"

# Rendered as templates so the app can tint them with the Orca accent color in
# both light and dark mode.
IMAGESET_CONTENTS = {
    "images": [{"filename": None, "idiom": "universal"}],
    "info": {"author": "xcode", "version": 1},
    "properties": {"preserves-vector-representation": True,
                   "template-rendering-intent": "template"},
}


def main():
    layout = json.loads(LAYOUT.read_text())
    icons = sorted({group["icon"]
                    for pages in layout.values()
                    for page in pages
                    for group in page["groups"]
                    if group["icon"]})

    if CATALOG.exists():
        shutil.rmtree(CATALOG)
    CATALOG.mkdir(parents=True)
    (CATALOG / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))

    copied = 0
    for icon in icons:
        source = IMAGES / f"{icon}.svg"
        if not source.exists():
            print(f"skip (no svg): {icon}")
            continue
        imageset = CATALOG / f"{icon}.imageset"
        imageset.mkdir()
        shutil.copy2(source, imageset / source.name)
        contents = json.loads(json.dumps(IMAGESET_CONTENTS))
        contents["images"][0]["filename"] = source.name
        (imageset / "Contents.json").write_text(json.dumps(contents, indent=2))
        copied += 1

    print(f"{copied} icons -> {CATALOG.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
