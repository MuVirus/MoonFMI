$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
$cache = Join-Path $here ".cache"
$fixture = Join-Path $cache "libmoonfmi_fixture.dll"
$dependency = Join-Path $cache "libmoonfmi_dependency.dll"
$implib = Join-Path $cache "moonfmi_dependency.lib"
$broken = Join-Path $cache "libmoonfmi_broken.dll"

New-Item -ItemType Directory -Force -Path $cache | Out-Null
Remove-Item -LiteralPath $dependency -Force -ErrorAction SilentlyContinue

$clang = Get-Command clang -ErrorAction SilentlyContinue
if ($null -eq $clang) {
  $fallback = Join-Path $HOME ".moon/bin/clang.exe"
  if (Test-Path $fallback) {
    $clang = Get-Item $fallback
  }
}
if ($null -eq $clang) {
  Write-Error "clang was not found; install the MoonBit toolchain or put clang on PATH"
}

& $clang.Source -shared -O2 (Join-Path $here "fixture.c") -o $fixture
if ($LASTEXITCODE -ne 0) {
  Write-Error "building the fixture library failed with exit code $LASTEXITCODE"
}

& $clang.Source -shared -O2 (Join-Path $here "dependency.c") "-Wl,/implib:$implib" -o $dependency
if ($LASTEXITCODE -ne 0) {
  Write-Error "building the dependency library failed with exit code $LASTEXITCODE"
}

& $clang.Source -shared -O2 (Join-Path $here "broken.c") $implib -o $broken
if ($LASTEXITCODE -ne 0) {
  Write-Error "building the broken library failed with exit code $LASTEXITCODE"
}

# The broken library must stay broken: the dependency is not shipped with it.
Remove-Item -LiteralPath $dependency -Force

Write-Host "built $fixture"
Write-Host "built $broken (dependency intentionally absent)"
