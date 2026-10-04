#!/usr/bin/env bash
# Usage: bash check-engine.sh /nix/store/...-flutter-engine-release-...
set -euo pipefail
engine=${1:?Expected standalone engine output}
output="$engine/out/host_release"
for artifact in \
  libflutter_engine.so flutter_embedder.h gen_snapshot dart-sdk/bin/dart \
  dart-sdk/bin/dartaotruntime dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot \
  flutter_patched_sdk/platform_strong.dill flutter_patched_sdk_product/platform_strong.dill \
  icudtl.dat libflutter_linux_gtk.so gen/const_finder.dart.snapshot \
  impellerc font-subset; do
  echo "Checking artifact: $output/$artifact"
  test -s "$output/$artifact" || { ls -la "$output"; exit 1; }
done
for executable in gen_snapshot dart-sdk/bin/dart dart-sdk/bin/dartaotruntime impellerc font-subset; do
  test -x "$output/$executable"
done
test -d "$output/flutter_linux"
test -s "$output/shader_lib/flutter/runtime_effect.glsl"
test -s "$output/gen/dart-pkg/sky_engine/pubspec.yaml"
"$output/gen_snapshot" --version
"$output/dart-sdk/bin/dart" --version
# Host ldd uses Ubuntu's loader for shared libraries without PT_INTERP.
# Use the same Nix loader as the patched tools and production runtime.
loader=$(nix-instantiate --eval --strict --json default.nix -A dynamicLinker | jq -r .)
for binary in libflutter_engine.so libflutter_linux_gtk.so gen_snapshot \
  dart-sdk/bin/dart dart-sdk/bin/dartaotruntime impellerc font-subset; do
  dependencies=$("$loader" --list "$output/$binary")
  echo "$dependencies"
  [[ $dependencies != *'not found'* ]]
done
echo 'Engine tooling verified; no application startup or rendering test claimed.'
