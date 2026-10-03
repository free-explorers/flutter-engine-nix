#!/usr/bin/env bash
# Usage: bash import-release.sh COMMIT nix-engine-RUNTIME_HASH engine refs/heads/main --trust-github-release
set -euo pipefail
export LC_ALL=C
export GH_HOST=github.com
commit=${1:?Expected trusted full source commit}
tag=${2:?Expected nix-engine-RUNTIME_HASH release tag}
kind=${3:?Expected engine}
ref=${4:?Expected refs/heads/main}
[[ $# == 5 && $5 == --trust-github-release ]] || {
  echo 'Root import requires explicit --trust-github-release consent.' >&2; exit 1;
}
[[ $commit =~ ^[0-9a-f]{40}$ && $tag =~ ^nix-engine-([0-9a-z]{32})$ ]]
runtime_hash=${BASH_REMATCH[1]}
[[ $kind == engine && $ref == refs/heads/main ]]
repo=free-explorers/flutter-engine-nix
directory=$(mktemp -d)
trap 'rm -rf "$directory"' EXIT
gh release view "$tag" --repo "$repo" --json targetCommitish > "$directory/release.json"
jq -e --arg commit "$commit" '.targetCommitish == $commit' "$directory/release.json" >/dev/null
gh release download "$tag" --repo "$repo" --dir "$directory" --pattern engine-SHA256SUMS
gh attestation verify "$directory/engine-SHA256SUMS" --repo "$repo" \
  --cert-identity "https://github.com/$repo/.github/workflows/release.yml@$ref" \
  --source-ref "$ref" --source-digest "$commit" --deny-self-hosted-runners
names=()
while IFS= read -r line || [[ -n $line ]]; do
  [[ $line =~ ^[0-9a-f]{64}\ \ (engine-metadata\.json|engine-export\.part-[0-9]{4})$ ]]
  names+=("${BASH_REMATCH[1]}")
done < "$directory/engine-SHA256SUMS"
(( ${#names[@]} >= 2 )) && [[ ${names[0]} == engine-metadata.json ]]
for (( i=1; i<${#names[@]}; i++ )); do
  printf -v expected 'engine-export.part-%04d' "$((i-1))"
  [[ ${names[i]} == "$expected" ]]
done
for name in "${names[@]}"; do
  available=$(df --output=avail -B1 "$directory" | tr -dc '0-9')
  (( available >= (1900 + 2048) * 1024 * 1024 ))
  gh release download "$tag" --repo "$repo" --dir "$directory" --pattern "$name"
done
(
  cd "$directory"
  sha256sum --strict --check engine-SHA256SUMS
)
parts_json=$(printf '%s\n' "${names[@]:1}" | jq -Rsc 'split("\n")[:-1]')
metadata="$directory/engine-metadata.json"
jq -e --arg commit "$commit" --arg ref "$ref" --arg hash "$runtime_hash" --argjson parts "$parts_json" '
  .schema == 1 and .repository == "free-explorers/flutter-engine-nix" and
  .sourceCommit == $commit and .sourceRef == $ref and .kind == "engine" and
  .system == "x86_64-linux" and .parts == $parts and
  (.runtimeOutput | startswith("/nix/store/" + $hash + "-")) and
  .rawEngineOutput == .engineOutput and .rawEngineDerivation == .engineDerivation and
  .roots == [.engineOutput, .runtimeOutput] and
  (.nixpkgsRevision | test("^[0-9a-f]{40}$")) and
  (.closure | length > 0) and
  (all(.roots[], .closure[], .engineOutput, .rawEngineOutput, .runtimeOutput;
    test("^/nix/store/[0-9a-z]{32}-[^/[:space:]]+$"))) and
  (all(.engineDerivation, .rawEngineDerivation, .runtimeDerivation;
    test("^/nix/store/[0-9a-z]{32}-[^/[:space:]]+\\.drv$"))) and
  (.closure as $closure | all(.roots[]; . as $root | $closure | index($root) != null))
  ' "$metadata" >/dev/null
if [[ -n ${EXPECTED_ENGINE_OUTPUT:-} ]]; then
  jq -e --arg engine "$EXPECTED_ENGINE_OUTPUT" --arg raw "${EXPECTED_RAW_ENGINE_OUTPUT:?}" \
    --arg runtime "${EXPECTED_RUNTIME_OUTPUT:?}" \
    '.engineOutput == $engine and .rawEngineOutput == $raw and .runtimeOutput == $runtime' "$metadata" >/dev/null
fi
# Decode the complete, attested ordered stream before invoking a root importer.
part_paths=()
for name in "${names[@]:1}"; do part_paths+=("$directory/$name"); done
available=$(df --output=avail -B1 "$directory" | tr -dc '0-9')
(( available > 2 * 1024 * 1024 * 1024 ))
(
  ulimit -f "$(( (available - 2 * 1024 * 1024 * 1024) / 1024 ))"
  cat "${part_paths[@]}" | xz -d > "$directory/closure.export"
)
archive_bytes=$(stat --format=%s "$directory/closure.export")
available=$(df --output=avail -B1 /nix/store | tr -dc '0-9')
(( available >= archive_bytes + 2 * 1024 * 1024 * 1024 ))
echo "Importing verified engine/runtime closure as root; trusting $repo at $commit ($ref)." >&2
# shellcheck disable=SC2024
sudo nix-store --import < "$directory/closure.export"
mapfile -t roots < <(jq -r '.roots[]' "$metadata")
nix-store --check-validity "${roots[@]}"
mapfile -t closure < <(jq -r '.closure[]' "$metadata")
nix-store --check-validity "${closure[@]}"
printf 'Verified roots:\n%s\n' "${roots[@]}"
