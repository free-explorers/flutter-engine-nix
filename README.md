# flutter-engine-nix

Independent, pinned Nix source build of the Flutter release engine for **native
x86_64-linux only**. No cross compilation or other platform support is claimed.
The standalone Flutter version default lives only in `default.json`; callers
can explicitly select a supported `flutterVersion` from `engine-source.json`.
`bootstrap-dart.json` pins only the matching bootstrap Dart download and versions,
not Flutter SDK tooling or prebuilt engine artifacts. The exported Dart SDK is
built from the pinned engine's Dart sources.

## API

```nix
let
  release = import /home/nixos/flutter-engine-nix {
    flutterVersion = projectFlutterVersion; # Supply the consuming project's pin.
    system = "x86_64-linux";
  };
in {
  inherit (release) engine rawEngine runtime aot nixpkgsRevision;
}
```

`default.nix` exports `flutterVersion`, `nixpkgsRevision`, and these derivations:

| Attribute | Contract |
| --- | --- |
| `engine` | Full source-built local-engine/toolchain root, with artifacts in `out/host_release` |
| `rawEngine` | Exact alias of `engine`, not a second adapter or runtime |
| `runtime` | Independent copy: `lib/libflutter_engine.so`, `include/flutter_embedder.h`, `share/flutter/icudtl.dat`, and `lib/icudtl.dat` as a relative symlink to that copy |
| `aot` | Synthetic `dart:ui` frontend compilation, `gen_snapshot` AOT ELF creation, and runtime `FlutterEngineCreateAOTData`/collect check |

The engine retains matching Dart, frontend-server snapshot, product kernel,
`gen_snapshot`, sky packages, GTK Linux embedding and headers, Impeller compiler,
shader library, font subset and const-finder tooling. The current Flutter
`build linux` pipeline needs GTK even for a custom embedder. The source-supported
snapshot group is retained; only the explicit tessellator shared target is
removed. This is not a runtime-only engine build.

Use `--local-engine-src-path=${engine}`, `--local-engine=host_release`, and
`--local-engine-host=host_release` with a matching Flutter SDK. SDK provisioning,
consumer adapters, application bundles, Rust binaries, Flutter pub/tool locks,
graphical sessions and full application integration are outside this repository.
No successful full integration is claimed.

The runtime copies rather than links the library from the full output, removes
its old RPATH, and resolves runtime dependencies independently. It must not
reference the engine, its compiler/toolchain, or GTK. Building it still requires
the engine as a build-time dependency; importing or deploying its runtime closure
does not require the full engine closure. This separation is enforced by Nix
`disallowedRequisites`, but the actual closure still needs verification in the
first successful build.

## Local Verification

```bash
# Evaluate/instantiate only; does not compile the engine.
nix-instantiate default.nix -A engine -A runtime -A aot

# These commands DO build. Opt in deliberately.
bash build-engine.sh
nix-build default.nix -A runtime -A aot --no-out-link --max-jobs 1 --cores 4
bash check-engine.sh "$(nix-build default.nix -A engine --no-out-link)"
```

The diagnostic script checks required artifacts, executability and shared
library resolution. The synthetic AOT check loads and collects AOT data; it
does not start the Flutter engine, render a frame, or exercise a real application.

## Releases And Trust

`.github/workflows/release.yml` is **workflow_dispatch only**, restricted to
`free-explorers/flutter-engine-nix` at `refs/heads/main`. It uses a standard
`ubuntu-24.04` runner, pinned actions, one build/four compilation jobs, a 240-minute
engine timeout, serial LTO links and a 2 GiB disk reserve. It requires runtime
construction and the synthetic AOT check before exporting or publishing. If that
check fails, no release is published, even if the engine build succeeded. Existing
releases are verified and restored, never overwritten or silently repaired.

Tags are **`nix-engine-<runtime-output-store-hash>`**, where the hash is the first
32 characters after `/nix/store/` in `runtime.outPath`, not `engine.outPath`.
Consumers must use this same rule. Releases are prereleases with `--latest=false`.
Free GitHub release downloads carry the combined engine/toolchain and runtime
closures as `engine-export.part-0000`, etc., plus `engine-metadata.json` and an
attested `engine-SHA256SUMS`. No paid cache service is required.

Metadata schema 1 uses `kind: "engine"`; `engineOutput == rawEngineOutput` and
`engineDerivation == rawEngineDerivation`. `runtimeOutput` and `runtimeDerivation`
identify the independent runtime. `roots` is exactly `[engineOutput,
runtimeOutput]`; `closure` is their full union. Metadata also records the source
commit/ref, repository, system, Flutter version, nixpkgs revision, minimal source
and bootstrap pins, and the ordered asset parts. The AOT check is a publication
gate, not an exported root.

```bash
# Run from the checkout. COMMIT must be the release's full source commit.
bash import-release.sh COMMIT nix-engine-RUNTIME_HASH engine refs/heads/main --trust-github-release
```

Import requires `gh`, `jq`, Nix, `xz`, coreutils, sufficient temporary/store space,
and `sudo`. It verifies the GitHub attestation against the exact identity
`https://github.com/free-explorers/flutter-engine-nix/.github/workflows/release.yml@refs/heads/main`,
the trusted source digest/ref, manifest names, checksums, ordered parts and root
metadata before invoking the root importer. Optional `EXPECTED_ENGINE_OUTPUT`,
`EXPECTED_RAW_ENGINE_OUTPUT`, and `EXPECTED_RUNTIME_OUTPUT` together require exact
locally predicted outputs. This is explicit trust in GitHub's attestation and the
named repository/workflow/source, **not** a claim of reproducible binary equality
or a substitute for reviewing that source. Import downloads the combined closure;
runtime-only deployment can then copy the closure rooted at `runtimeOutput`.

For publication, `export-release.sh engine NEW_DIRECTORY ENGINE_OUTPUT
RUNTIME_OUTPUT` requires `GITHUB_REPOSITORY`, `GITHUB_SHA`, `GITHUB_REF`,
`ENGINE_OUTPUT`, `RAW_ENGINE_OUTPUT`, `RUNTIME_OUTPUT`, and `NIXPKGS_REVISION`.
It checks those against `default.nix` and exports only the two declared roots.
