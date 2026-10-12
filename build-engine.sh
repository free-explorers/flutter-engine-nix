#!/usr/bin/env bash
# Bounded native build with a disk guard; run from the repository root.
set -euo pipefail
started=$(date +%s)
# An empty FLUTTER_VERSION means "use the repository default in default.json".
# Otherwise build the version the caller asked for: the consuming project always
# selects one explicitly, so caching anything else would never be substituted.
nix_args=()
if [[ -n "${FLUTTER_VERSION:-}" ]]; then
  nix_args+=(--argstr flutterVersion "$FLUTTER_VERSION")
fi
setsid /usr/bin/time --verbose timeout --signal=INT --kill-after=60s "${ENGINE_BUILD_TIMEOUT:-240m}" \
  nix-build default.nix "${nix_args[@]}" -A engine --no-out-link --max-jobs 1 --cores 4 &
pid=$!
trap 'kill -TERM -- -"$pid" 2>/dev/null || true' EXIT INT TERM
while kill -0 "$pid" 2>/dev/null; do
  free -h
  df -h / /nix/store
  available=$(df --output=avail -B1 /nix/store | tr -dc '0-9')
  if (( available < 2 * 1024 * 1024 * 1024 )); then
    echo 'Stopping engine build: less than 2 GiB remains.' >&2
    exit 1
  fi
  sleep 30
done
wait "$pid"
trap - EXIT INT TERM
engine=$(nix-build default.nix "${nix_args[@]}" -A engine --no-out-link --max-jobs 1 --cores 4)
bash check-engine.sh "$engine"
echo "Engine build and diagnostics completed in $(( $(date +%s) - started )) seconds." \
  >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
