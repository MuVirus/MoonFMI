#!/usr/bin/env bash
set -euo pipefail

if ! command -v moon >/dev/null 2>&1 && [ -d "$HOME/.moon/bin" ]; then
  export PATH="$HOME/.moon/bin:$PATH"
fi

if ! command -v moon >/dev/null 2>&1 && command -v moon.exe >/dev/null 2>&1; then
  moon() { moon.exe "$@"; }
fi

if ! command -v node >/dev/null 2>&1 && command -v node.exe >/dev/null 2>&1; then
  node() { node.exe "$@"; }
fi

if ! command -v moon >/dev/null 2>&1; then
  echo "moon is not on PATH; install MoonBit or add ~/.moon/bin to PATH" >&2
  exit 1
fi

mbti_files() {
  find . -name 'pkg.generated.mbti' -not -path './_build/*' | sort
}

snapshot_mbti() {
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  printf '%s\n' "$@" | xargs -r sha256sum
}

# Snapshot the interfaces before anything can regenerate them. `moon check`
# also updates pkg.generated.mbti, so a later snapshot would silently hide a
# manual edit or a stale interface.
mapfile -t initial_mbti_files < <(mbti_files)
initial_mbti="$(snapshot_mbti "${initial_mbti_files[@]}")"

echo "== MoonBit version =="
moon version --all

echo "== dependency direction =="
node tools/check-deps.mjs

echo "== formatting =="
moon fmt --check

echo "== check: native =="
moon check --target native --deny-warn

echo "== check: wasm =="
moon check --target wasm --deny-warn

echo "== test: native =="
moon test --target native --deny-warn

echo "== test: wasm =="
moon test --target wasm --deny-warn

echo "== public interface =="
backup_dir="$(mktemp -d)"
for file in "${initial_mbti_files[@]}"; do
  mkdir -p "$backup_dir/$(dirname "$file")"
  cp -- "$file" "$backup_dir/$file"
done

mapfile -t current_files < <(mbti_files)
for file in "${current_files[@]}"; do
  rm -f -- "$file"
done

if ! moon info; then
  for file in "${initial_mbti_files[@]}"; do
    cp -- "$backup_dir/$file" "$file"
  done
  rm -rf "$backup_dir"
  echo "moon info failed; restored the previous .mbti files" >&2
  exit 1
fi

mapfile -t final_mbti_files < <(mbti_files)
final_mbti="$(snapshot_mbti "${final_mbti_files[@]}")"
rm -rf "$backup_dir"

if [ "$initial_mbti" != "$final_mbti" ]; then
  echo "pkg.generated.mbti was stale or hand-edited" >&2
  echo "review the regenerated files and commit them" >&2
  exit 1
fi

echo "== XSD cross-check (optional) =="
run_xsd() {
  if command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -File tests/data/validate-xsd.ps1
  elif command -v pwsh.exe >/dev/null 2>&1; then
    pwsh.exe -NoProfile -File tests/data/validate-xsd.ps1
  elif command -v powershell >/dev/null 2>&1; then
    powershell -NoProfile -ExecutionPolicy Bypass -File tests/data/validate-xsd.ps1
  elif command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/data/validate-xsd.ps1
  else
    echo "skipped: no PowerShell validator found"
    return 0
  fi
}

if ! run_xsd; then
  echo "warning: XSD cross-check failed; this is optional for P0." >&2
fi
