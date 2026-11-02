#!/usr/bin/env sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cache="$here/.cache"
fixture="$cache/libmoonfmi_fixture.so"
dependency="$cache/libmoonfmi_dependency.so"
broken="$cache/libmoonfmi_broken.so"

mkdir -p "$cache"
rm -f "$dependency"

if ! command -v clang >/dev/null 2>&1; then
  echo "clang was not found; install the MoonBit toolchain or put clang on PATH" >&2
  exit 1
fi

clang -shared -fPIC -O2 "$here/fixture.c" -o "$fixture"
clang -shared -fPIC -O2 "$here/dependency.c" -o "$dependency"
clang -shared -fPIC -O2 "$here/broken.c" -L"$cache" -lmoonfmi_dependency \
  -Wl,-rpath,'$ORIGIN' -o "$broken"

# The broken library must stay broken: the dependency is not shipped with it.
rm -f "$dependency"

clang -O2 "$here/probe.c" -o "$cache/probe"
clang -shared -fPIC -O2 "$here/logging_fmu.c" -pthread \
  -o "$cache/libmoonfmi_logging_fmu.so"
clang -O2 "$here/fmi2_host.c" -o "$cache/fmi2_host"

echo "built $fixture"
echo "built $broken (dependency intentionally absent)"
echo "built $cache/probe"
echo "built $cache/libmoonfmi_logging_fmu.so"
echo "built $cache/fmi2_host"
