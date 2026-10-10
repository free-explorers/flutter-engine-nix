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
snapshot group is retained. The explicit tessellator shared target and the
unused GLFW embedding/header targets are excluded. This is not a runtime-only
engine build.

Use `--local-engine-src-path=${engine}`, `--local-engine=host_release`, and
`--local-engine-host=host_release` with a matching Flutter SDK. SDK provisioning,
consumer adapters, application bundles, Rust binaries, Flutter pub/tool locks,
graphical sessions and full application integration are outside this repository.
No successful full integration is claimed.

The runtime copies rather than links the library from the full output, removes
its old RPATH, and resolves runtime dependencies independently. It must not
reference the engine, its compiler/toolchain, or GTK. Building it still requires
the engine as a build-time dependency; substituting or deploying its runtime
closure does not require the full engine closure. This separation is enforced by Nix
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
library resolution using Nix's loader, not the runner's host `ldd`. The synthetic
AOT check loads and collects AOT data; it
does not start the Flutter engine, render a frame, or exercise a real application.

## Binary cache

`.github/workflows/release.yml` is **workflow_dispatch only**, restricted to
`free-explorers/flutter-engine-nix` at `refs/heads/main`. It uses a standard
`ubuntu-24.04` runner, one build/four compilation jobs, a 240-minute engine
timeout, serial LTO links and a 2 GiB disk reserve. It requires the synthetic AOT
check before publishing: if that check fails, nothing is pushed. It then pushes
the `engine`, `runtime` and `aot` closures to the `veshell` Cachix cache.

Consumers — the Veshell flake and its release workflow — substitute those store
paths instead of building them. The engine derivation depends only on this
repository's pinned nixpkgs, the Flutter version and the system, so it is the
same derivation wherever it is evaluated, and there is no closure export, import
or attestation step.
