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

  bootstrap hash  the Dart SDK zip for dartVersion; dart-bin fetches it flat

Probed with a real build, because no prefetch tool can predict them:

  sourceHashes    nixpkgs fetches the engine source with `gclient sync`
                  (depot_tools plus the DEPS submodules), not a plain git fetch
  swiftshaderHash the SwiftShader fetch deletes third_party/llvm-project in its
                  postFetch, so the hash covers the pruned tree

Those two are seeded with lib.fakeHash, built, and read back out of the hash
mismatch -- the same probe the application uses for its own Nix pins. The build
is the only authority for a fixed-output hash.

Usage: scripts/resolve-version.py VERSION [--check]
Writes the entries into engine-source.json and bootstrap-dart.json next to this
repository root. --check verifies the fields derivable without a build.
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
FLUTTER_REPO = "https://github.com/flutter/flutter"
DART_ZIP = "https://storage.googleapis.com/dart-archive/channels/stable/release/{version}/sdk/dartsdk-linux-x64-release.zip"
# lib.fakeHash: the probe seeds this and reads the real value out of the mismatch.
FAKE = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="


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


def load_document(name: str) -> dict:
    path = ROOT / name
    return json.loads(path.read_text()) if path.is_file() else {}


def write_document(name: str, document: dict) -> None:
    (ROOT / name).write_text(
        json.dumps(dict(sorted(document.items())), indent=2, ensure_ascii=False) + "\n"
    )


def dig(document: dict, path: list[str]):
    for key in path:
        document = document[key]
    return document


def plant(document: dict, path: list[str], value: str) -> None:
    for key in path[:-1]:
        document = document.setdefault(key, {})
    document[path[-1]] = value


def nix_build_engine(version: str) -> subprocess.CompletedProcess:
    # With a fake fixed-output hash this fails at the offending derivation and
    # prints the real hash.
    return subprocess.run(
        ["nix-build", "default.nix", "--argstr", "flutterVersion", version,
         "-A", "engine", "--no-out-link", "--max-jobs", "1", "--cores", "4"],
        cwd=ROOT, capture_output=True, text=True,
    )


def mismatched_hash(result: subprocess.CompletedProcess, matcher: str | None) -> str | None:
    for block in re.finditer(
        r"hash mismatch in fixed-output derivation '([^']+)':(.{0,600}?)got:\s+(sha256-[A-Za-z0-9+/=]+)",
        (result.stderr or "") + (result.stdout or ""),
        re.S,
    ):
        if matcher is None or matcher in block.group(1):
            return block.group(3)
    return None


def probe(version: str, label: str, filename: str, path: list[str], matcher: str | None) -> None:
    for _ in range(3):
        document = load_document(filename)
        if dig(document, [version] + path) != FAKE:
            print(f"  {label}: resolved")
            return
        result = nix_build_engine(version)
        value = mismatched_hash(result, matcher)
        if value is None:
            output = ((result.stderr or "") + (result.stdout or ""))[-2000:]
            fail(f"{label}: the build reported no usable hash mismatch\n{output}")
        plant(document, [version] + path, value)
        write_document(filename, document)
        print(f"  {label}: {value}")
    fail(f"{label}: still unresolved after 3 attempts")


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
    for tool in ("git", "nix", "nix-build", "nix-prefetch-url"):
        if shutil.which(tool) is None:
            fail(f"missing {tool}")

    source_rev = tag_rev(version)
    engine_version = engine_revision(version)
    dart_rev, swiftshader_rev = deps_revisions(engine_version)
    dart_ver = dart_version(version)

    # The two probed hashes start fake; probe() fills them from a real build.
    entry = {
        "engineVersion": engine_version,
        "sourceRev": source_rev,
        "sourceUrl": SOURCE_URL,
        "sourceHashes": {"x86_64-linux": {"x86_64-linux": FAKE}},
        "dartVersion": dart_ver,
        "dartSourceRev": dart_rev,
        "swiftshaderRev": swiftshader_rev,
        "swiftshaderHash": FAKE,
        "swiftshaderFetchSubmodules": False,
    }
    bootstrap = {
        "engineVersion": engine_version,
        "dartVersion": dart_ver,
        "hashes": {"x86_64-linux": prefetch_url(DART_ZIP.format(version=dart_ver))},
    }

    if args.check:
        source = load_document("engine-source.json").get(version, {})
        boot = load_document("bootstrap-dart.json").get(version, {})
        derived = {k: v for k, v in entry.items() if k not in ("sourceHashes", "swiftshaderHash")}
        if {k: source.get(k) for k in derived} != derived:
            fail(f"{version}: derived fields differ from the committed pin")
        if boot != bootstrap:
            fail(f"{version}: bootstrap pin differs from the committed one")
        print(f"{version}: derived fields and bootstrap pin match (probed hashes not checked)")
        return 0

    document = load_document("engine-source.json")
    document[version] = entry
    write_document("engine-source.json", document)
    print(f"wrote engine-source.json: {version}")

    boot_document = load_document("bootstrap-dart.json")
    boot_document[version] = bootstrap
    write_document("bootstrap-dart.json", boot_document)
    print(f"wrote bootstrap-dart.json: {version}")

    print("probing the engine's fixed-output hashes")
    probe(version, "sourceHashes", "engine-source.json",
          ["sourceHashes", "x86_64-linux", "x86_64-linux"], "-source-")
    # Only swiftshaderHash is still fake, so any mismatch now is that one.
    probe(version, "swiftshaderHash", "engine-source.json", ["swiftshaderHash"], None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
