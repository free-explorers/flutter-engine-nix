#!/usr/bin/env python3
"""resolve-version.py - derive the engine pin for a Flutter release version.

The engine build needs, per Flutter version, the engine source revision, its
content hash, the SwiftShader pin, and the bootstrap Dart hash. Those are a pure
function of the version, so this derives them instead of expecting them to be
maintained by hand -- the engine repository is a client of the Flutter bump.

Derived without a build:

  sourceRev       git ls-remote flutter/flutter refs/tags/<version>
  engineVersion   bin/internal/engine.version at that tag
  dartSourceRev   DEPS dart_revision at the engine revision
  swiftshaderRev  DEPS SwiftShader pin
  dartVersion     the release's dart_sdk_version

Fetched and hashed here (Nix must know them up front):

  sourceHashes    nix-prefetch-git of sourceUrl@sourceRev
  swiftshaderHash nix-prefetch-git of the SwiftShader pin
  bootstrap hash  the Dart SDK zip for dartVersion

Usage: scripts/resolve-version.py VERSION [--check]
Writes the entries into engine-source.json and bootstrap-dart.json next to this
repository root. --check verifies the existing entries match without writing.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_URL = "https://flutter.googlesource.com/mirrors/flutter"
SWIFTSHADER_URL = "https://swiftshader.googlesource.com/SwiftShader"
FLUTTER_REPO = "https://github.com/flutter/flutter"
DART_ZIP = "https://storage.googleapis.com/dart-archive/channels/stable/release/{version}/sdk/dartsdk-linux-x64-release.zip"


def fail(message: str) -> "NoReturn":  # noqa: F821
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def fetch(url: str) -> str:
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read().decode()


def tag_rev(version: str) -> str:
    refs = run("git", "ls-remote", FLUTTER_REPO, f"refs/tags/{version}", f"refs/tags/{version}^{{}}")
    for line in refs.splitlines():
        sha, ref = line.split("\t", 1)
        if ref.endswith("^{}") or ref == f"refs/tags/{version}":
            annotated = [l.split("\t")[0] for l in refs.splitlines() if l.endswith("^{}")]
            return annotated[0] if annotated else sha
    fail(f"no tag {version} in {FLUTTER_REPO}")


def engine_revision(version: str) -> str:
    value = fetch(f"https://raw.githubusercontent.com/flutter/flutter/{version}/bin/internal/engine.version").strip()
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        fail(f"engine.version at {version} is not a revision: {value!r}")
    return value


def deps_revisions(revision: str) -> tuple[str, str]:
    deps = fetch(f"https://raw.githubusercontent.com/flutter/flutter/{revision}/DEPS")
    dart = re.search(r"'dart_revision':\s*'([0-9a-f]{40})'", deps)
    swiftshader = re.search(r"SwiftShader\.git'?\s*\+\s*'@'\s*\+\s*'([0-9a-f]{40})'", deps)
    if not dart:
        fail(f"no dart_revision in DEPS at {revision}")
    if not swiftshader:
        fail(f"no SwiftShader pin in DEPS at {revision}")
    return dart.group(1), swiftshader.group(1)


def dart_version(version: str) -> str:
    releases = json.loads(fetch("https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json"))
    for release in releases["releases"]:
        if release.get("version") == version:
            dart = release.get("dart_sdk_version")
            if dart:
                return dart
            break
    fail(f"no dart_sdk_version for Flutter {version} in releases_linux.json")


def to_sri(base32: str) -> str:
    for args in (
        ["nix", "hash", "convert", "--to", "sri", "--hash-algo", "sha256", base32],
        ["nix", "hash", "to-sri", "--type", "sha256", base32],
    ):
        try:
            return run(*args).strip()
        except subprocess.CalledProcessError:
            continue
    fail(f"could not convert {base32} to SRI; update the Nix hash command")


def prefetch_git(url: str, rev: str) -> str:
    # nix-prefetch-git has no --hash-format option: it prints the SRI hash in
    # "hash" and the base32 one in "sha256", so to_sri covers older outputs.
    try:
        data = json.loads(run("nix-prefetch-git", "--url", url, "--rev", rev))
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or "").strip()
        fail(f"nix-prefetch-git failed for {url}@{rev}:\n{detail[-1500:]}")
    if data.get("hash"):
        return data["hash"]
    return to_sri(data["sha256"])


def prefetch_url(url: str) -> str:
    base32 = run("nix-prefetch-url", "--type", "sha256", "--name", "dart-sdk.zip", url).strip()
    return to_sri(base32)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("version")
    parser.add_argument("--check", action="store_true", help="verify without writing")
    args = parser.parse_args()
    version = args.version

    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        fail(f"version must be x.y.z, got {version!r}")
    for tool in ("git", "nix", "nix-prefetch-git", "nix-prefetch-url"):
        if shutil.which(tool) is None:
            fail(f"missing {tool} (run inside `nix shell nixpkgs#nix-prefetch-git`?)")

    source_rev = tag_rev(version)
    engine_version = engine_revision(version)
    dart_rev, swiftshader_rev = deps_revisions(engine_version)
    dart_ver = dart_version(version)

    entry = {
        "engineVersion": engine_version,
        "sourceRev": source_rev,
        "sourceUrl": SOURCE_URL,
        "sourceHashes": {"x86_64-linux": {"x86_64-linux": prefetch_git(SOURCE_URL, source_rev)}},
        "dartVersion": dart_ver,
        "dartSourceRev": dart_rev,
        "swiftshaderRev": swiftshader_rev,
        "swiftshaderHash": prefetch_git(SWIFTSHADER_URL, swiftshader_rev),
        "swiftshaderFetchSubmodules": False,
    }
    bootstrap = {
        "engineVersion": engine_version,
        "dartVersion": dart_ver,
        "hashes": {"x86_64-linux": prefetch_url(DART_ZIP.format(version=dart_ver))},
    }

    if args.check:
        source = json.loads((ROOT / "engine-source.json").read_text())
        boot = json.loads((ROOT / "bootstrap-dart.json").read_text())
        if source.get(version) != entry or boot.get(version) != bootstrap:
            fail(f"{version}: resolved pin differs from the committed one")
        print(f"{version}: committed pin matches")
        return 0

    for name, key, value in (("engine-source.json", version, entry), ("bootstrap-dart.json", version, bootstrap)):
        path = ROOT / name
        data = json.loads(path.read_text()) if path.is_file() else {}
        data[key] = value
        path.write_text(json.dumps(dict(sorted(data.items())), indent=2, ensure_ascii=False) + "\n")
        print(f"wrote {name}: {version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
