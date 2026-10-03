#!/usr/bin/env bash
# Usage: bash export-release.sh engine NEW_DIRECTORY ENGINE_OUTPUT RUNTIME_OUTPUT
set -euo pipefail
export LC_ALL=C
kind=${1:?Expected engine}
directory=${2:?Expected a new export directory}
shift 2
[[ $kind == engine && $# == 2 ]]
[[ ${GITHUB_REPOSITORY:-} == free-explorers/flutter-engine-nix ]]
[[ ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ && ${GITHUB_REF:-} == refs/heads/main ]]
[[ ${NIXPKGS_REVISION:-} =~ ^[0-9a-f]{40}$ ]]
[[ $1 == "${ENGINE_OUTPUT:?}" && $2 == "${RUNTIME_OUTPUT:?}" ]]
[[ ${RAW_ENGINE_OUTPUT:?} == "$ENGINE_OUTPUT" ]]
[[ ! -e $directory ]]
roots=("$@")
for root in "${roots[@]}"; do
  [[ $root =~ ^/nix/store/[0-9a-z]{32}-[^/[:space:]]+$ ]]
  nix-store --check-validity "$root"
done
# Require the declared roots and revision to match this standalone entry point.
engine_derivation=$(nix-instantiate --eval --strict --json default.nix -A engine.drvPath | jq -r .)
runtime_derivation=$(nix-instantiate --eval --strict --json default.nix -A runtime.drvPath | jq -r .)
[[ $(nix-instantiate --eval --strict --json default.nix -A engine.outPath | jq -r .) == "$ENGINE_OUTPUT" ]]
[[ $(nix-instantiate --eval --strict --json default.nix -A runtime.outPath | jq -r .) == "$RUNTIME_OUTPUT" ]]
[[ $(nix-instantiate --eval --strict --json default.nix -A nixpkgsRevision | jq -r .) == "$NIXPKGS_REVISION" ]]
flutter_version=$(nix-instantiate --eval --strict --json default.nix -A flutterVersion | jq -r .)
mkdir -p "$directory"
directory=$(realpath "$directory")
nix-store --query --requisites "${roots[@]}" | sort -u > "$directory/closure.txt"
mapfile -t closure < "$directory/closure.txt"
(( ${#closure[@]} > 0 ))
roots_json=$(printf '%s\n' "${roots[@]}" | jq -Rsc 'split("\n")[:-1]')
closure_json=$(jq -Rsc 'split("\n")[:-1]' "$directory/closure.txt")
rm "$directory/closure.txt"
available=$(df --output=avail -B1 "$directory" | tr -dc '0-9')
(( available >= 2 * 1024 * 1024 * 1024 ))
# GitHub assets must stay below 2 GiB. Limit compression to four CPUs.
export EXPORT_PREFIX="$directory/engine-export.part-"
# shellcheck disable=SC2016
setsid bash -euo pipefail -c '
  nix-store --export "$@" | xz -T4 -1 |
    split --bytes=1900M --numeric-suffixes=0 --suffix-length=4 - "$EXPORT_PREFIX"
' _ "${closure[@]}" &
pid=$!
trap 'kill -TERM -- -"$pid" 2>/dev/null || true' EXIT INT TERM
while kill -0 "$pid" 2>/dev/null; do
  available=$(df --output=avail -B1 "$directory" | tr -dc '0-9')
  if (( available < 2 * 1024 * 1024 * 1024 )); then
    echo 'Stopping closure export: less than 2 GiB remains.' >&2
    exit 1
  fi
  sleep 5
done
wait "$pid"
trap - EXIT INT TERM
parts=()
shopt -s nullglob
for part in "$directory/engine-export.part-"*; do parts+=("$(basename "$part")"); done
(( ${#parts[@]} > 0 ))
parts_json=$(printf '%s\n' "${parts[@]}" | jq -Rsc 'split("\n")[:-1]')
jq -n --arg sourceCommit "$GITHUB_SHA" --arg sourceRef "$GITHUB_REF" \
  --arg engineOutput "$ENGINE_OUTPUT" --arg runtimeOutput "$RUNTIME_OUTPUT" \
  --arg engineDerivation "$engine_derivation" --arg runtimeDerivation "$runtime_derivation" \
  --arg nixpkgsRevision "$NIXPKGS_REVISION" --arg flutterVersion "$flutter_version" \
  --argjson roots "$roots_json" --argjson closure "$closure_json" --argjson parts "$parts_json" \
  --slurpfile enginePins engine-source.json --slurpfile bootstrapDartPins bootstrap-dart.json \
  '{schema:1,kind:"engine",repository:"free-explorers/flutter-engine-nix",system:"x86_64-linux",
    sourceCommit:$sourceCommit,sourceRef:$sourceRef,flutterVersion:$flutterVersion,
    engineOutput:$engineOutput,rawEngineOutput:$engineOutput,runtimeOutput:$runtimeOutput,
    engineDerivation:$engineDerivation,rawEngineDerivation:$engineDerivation,runtimeDerivation:$runtimeDerivation,
    nixpkgsRevision:$nixpkgsRevision,enginePins:$enginePins[0],bootstrapDartPins:$bootstrapDartPins[0],
    roots:$roots,closure:$closure,parts:$parts}' > "$directory/engine-metadata.json"
(
  cd "$directory"
  sha256sum engine-metadata.json "${parts[@]}" > engine-SHA256SUMS
)
