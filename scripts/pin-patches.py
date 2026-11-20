#!/usr/bin/env python3
"""Pin Veshell's engine patches at a revision of free-explorers/flutter-engine.

The engine patches live in that repository (patches/, named by its PATCHSET),
which also builds the prebuilt engines from them: both builds apply the same
files. This writes engine-patches.json with the revision, the patchset, and
the sha256 of every patch, which engine.nix fetches and applies.

Usage: scripts/pin-patches.py REVISION
"""

from __future__ import annotations

import base64
import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

REPOSITORY = "free-explorers/flutter-engine"
ROOT = Path(__file__).resolve().parent.parent


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "flutter-engine-nix"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def main() -> int:
    if len(sys.argv) != 2 or not re.fullmatch(r"[0-9a-f]{40}", sys.argv[1]):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        print("REVISION must be a full commit hash", file=sys.stderr)
        return 2
    revision = sys.argv[1]
    raw = f"https://raw.githubusercontent.com/{REPOSITORY}/{revision}"

    listing = json.loads(
        fetch(f"https://api.github.com/repos/{REPOSITORY}/contents/patches?ref={revision}")
    )
    names = sorted(entry["name"] for entry in listing if entry["name"].endswith(".patch"))
    if not names:
        print(f"no patches in {REPOSITORY}@{revision}", file=sys.stderr)
        return 1

    patches = []
    for name in names:
        content = fetch(f"{raw}/patches/{name}")
        digest = base64.b64encode(hashlib.sha256(content).digest()).decode()
        patches.append({"name": name, "hash": f"sha256-{digest}"})

    pin = {
        "repository": REPOSITORY,
        "revision": revision,
        "patchset": fetch(f"{raw}/PATCHSET").decode().strip(),
        "patches": patches,
    }
    (ROOT / "engine-patches.json").write_text(json.dumps(pin, indent=2) + "\n")
    print(f"pinned {len(patches)} patch(es) of {pin['patchset']} at {revision}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
