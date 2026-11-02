#!/usr/bin/env sh
set -eu

# Linux/macOS counterpart of run-fmi2-host.ps1 for machines without pwsh.
# CI uses the PowerShell version, which runs on both Windows and Linux.

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
fmu="$root/tests/data/.cache/fmi2/BouncingBall.fmu"
cache="$here/.cache"
work="$cache/fmu/BouncingBall"
out="${1:-$cache/fmi2-host.json}"

if [ ! -f "$fmu" ]; then
  echo "missing $fmu; run node tests/data/fetch-fmus.mjs first" >&2
  exit 1
fi
if ! command -v unzip >/dev/null 2>&1; then
  echo "unzip is required to unpack the FMU" >&2
  exit 1
fi

mkdir -p "$work"
unzip -o -q "$fmu" "binaries/linux64/BouncingBall.so" -d "$work"
mkdir -p "$work/resources"

if [ ! -x "$cache/fmi2_host" ]; then
  echo "missing $cache/fmi2_host; run tests/abi/build-fixture.sh first" >&2
  exit 1
fi

"$cache/fmi2_host" "$work/binaries/linux64/BouncingBall.so" \
  "file://$work/resources/" >"$out"

echo "wrote $out"
