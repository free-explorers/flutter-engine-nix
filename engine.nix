# The content-aware engineVersion is not a Git revision; sourceRev identifies
# the immutable Flutter release source matching bin/internal/engine.version.
{
  lib,
  callPackage,
  path,
  stdenv,
  fetchgit,
  dart-bin,
  autoPatchelfHook,
  patchelf,
  flutterVersion,
}:
let
  pin =
    (lib.importJSON ./engine-source.json).${flutterVersion}
      or (throw "No source engine metadata for Flutter ${flutterVersion}.");
  bootstrapPin = (lib.importJSON ./bootstrap-dart.json).${flutterVersion};
  enginePath = path + "/pkgs/development/compilers/flutter/engine";
  system = stdenv.hostPlatform.system;
  sourceHash = pin.sourceHashes.${system}.${system};
  # Bootstrap only: exported Dart is built from the engine's Dart sources.
  bootstrapDart = dart-bin.overrideAttrs (old: {
    version = pin.dartVersion;
    src = old.src.overrideAttrs (_: {
      hash = bootstrapPin.hashes.${system};
    });
  });
  sourceCleanup = ''
    find $out -name '.git' -exec rm --recursive --force {} \; || true

    rm --recursive $out/src/flutter/{buildtools,prebuilts,third_party/swiftshader,third_party/gn/.versions,third_party/dart/tools/sdks/dart-sdk}
  '';
  engine = callPackage (enginePath + "/package.nix") {
    callPackage =
      file: args:
      let
        package = callPackage file args;
      in
      if toString file == toString (enginePath + "/source.nix") then
        package.overrideAttrs (old: {
          # Prune before mv can copy between separate /build and /nix mounts.
          buildCommand =
            lib.replaceStrings
              [ "mv engine $out" sourceCleanup ]
              [
                ((lib.replaceStrings [ "$out" ] [ "engine" ] sourceCleanup) + "\n    mv engine $out")
                ""
              ]
              old.buildCommand;
        })
      else
        package;
    version = pin.engineVersion;
    inherit flutterVersion;
    dartSdkVersion = pin.dartVersion;
    dart = bootstrapDart;
    url = "${pin.sourceUrl}@${pin.sourceRev}";
    hashes.${system}.${system} =
      if sourceHash == null then
        throw "Missing verified source hash for Flutter ${flutterVersion}."
      else
        sourceHash;
    inherit (pin) swiftshaderRev swiftshaderHash;
    fetchgit =
      args:
      fetchgit (
        args
        // {
          fetchSubmodules = pin.swiftshaderFetchSubmodules;
        }
      );
    runtimeMode = "release";
    isOptimized = true;
    patches = [ ];
  };
in
assert lib.assertMsg (
  system == "x86_64-linux"
  && stdenv.buildPlatform.system == system
  && stdenv.targetPlatform.system == system
) "flutter-engine-nix supports only native x86_64-linux.";
assert lib.assertMsg (
  pin.engineVersion == bootstrapPin.engineVersion && pin.dartVersion == bootstrapPin.dartVersion
) "Bootstrap Dart metadata must match the source engine pin.";
engine.overrideAttrs (old: {
  nativeBuildInputs = old.nativeBuildInputs ++ [ autoPatchelfHook ];
  buildInputs = old.buildInputs ++ [ stdenv.cc.cc.lib ];
  # Patch before launching tools, not in the hook registered after postFixup.
  dontAutoPatchelf = true;
  configureFlags = old.configureFlags ++ [ "--gn-args=concurrent_toolchain_jobs=1" ];
  NIX_CFLAGS_COMPILE = old.NIX_CFLAGS_COMPILE ++ [ "-Wno-macro-redefined" ];
  postUnpack =
    lib.replaceStrings [ "1111111111111111111111111111111111111111" ] [ pin.engineVersion ]
      old.postUnpack;
  buildPhase =
    lib.replaceStrings
      [ "ninja -C $out/out/host_release -j$NIX_BUILD_CORES" ]
      [
        (
          "ninja -C $out/out/host_release -j$NIX_BUILD_CORES "
          + lib.concatStringsSep " " [
            "flutter/shell/platform/embedder:flutter_engine"
            "flutter/build/dart:dart_sdk"
            "flutter/flutter_frontend_server:frontend_server"
            "flutter/lib/snapshot:generate_snapshot_bins"
            "flutter/shell/platform/linux:flutter_linux_gtk"
            "flutter/shell/platform/linux:publish_headers_linux"
            "flutter/sky/packages:packages"
            "flutter/impeller/compiler:impellerc"
            "flutter/tools/font_subset:_font-subset"
            "flutter/tools/const_finder:const_finder"
          ]
        )
      ]
      old.buildPhase;
  postInstall = (old.postInstall or "") + ''
    install -Dm644 src/flutter/shell/platform/embedder/embedder.h \
      "$out/out/host_release/flutter_embedder.h"
    test -s "$out/out/host_release/flutter_patched_sdk/platform_strong.dill"
    ln -s flutter_patched_sdk "$out/out/host_release/flutter_patched_sdk_product"
    test -s "$out/out/host_release/libflutter_engine.so"
    test -x "$out/out/host_release/gen_snapshot"
    test -s "$out/out/host_release/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot"
  '';
  postFixup = (old.postFixup or "") + ''
    autoPatchelf -- "$out"
    for binary in gen_snapshot dart-sdk/bin/dart dart-sdk/bin/dartaotruntime; do
      test "$(${lib.getExe patchelf} --print-interpreter "$out/out/host_release/$binary")" \
        = ${lib.escapeShellArg stdenv.cc.bintools.dynamicLinker}
    done
    "$out/out/host_release/dart-sdk/bin/dart" --version 2>&1 | grep -F "${pin.dartVersion}"
    "$out/out/host_release/gen_snapshot" --version 2>&1 | grep -F "${pin.dartVersion}"
  '';
  passthru = (old.passthru or { }) // {
    inherit flutterVersion sourceHash;
    inherit (pin) engineVersion sourceRev;
  };
})
