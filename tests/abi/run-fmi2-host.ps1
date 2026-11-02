# Runs the independent C reference host against BouncingBall and writes its
# JSON output. `check-host.mjs` compares that file with the checked-in
# baseline.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests/abi/run-fmi2-host.ps1 [-Output path]

param(
  [string] $Output = ""
)

$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
$root = (Resolve-Path (Join-Path $here "..\..")).Path
$fmu = Join-Path $root "tests\data\.cache\fmi2\BouncingBall.fmu"
$cache = Join-Path $here ".cache"
$work = Join-Path $cache "fmu\BouncingBall"

if (-not (Test-Path -LiteralPath $fmu)) {
  Write-Error "missing $fmu; run node tests/data/fetch-fmus.mjs first"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$entries = @("binaries/win64/BouncingBall.dll", "binaries/linux64/BouncingBall.so")
$archive = [System.IO.Compression.ZipFile]::OpenRead($fmu)
try {
  foreach ($name in $entries) {
    $entry = $archive.GetEntry($name)
    if ($null -eq $entry) {
      continue
    }
    $target = Join-Path $work ($name -replace "/", "\")
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
  }
} finally {
  $archive.Dispose()
}
New-Item -ItemType Directory -Force -Path (Join-Path $work "resources") | Out-Null

$isWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
if ($isWindows) {
  $binary = Join-Path $work "binaries\win64\BouncingBall.dll"
  $hostExe = Join-Path $cache "fmi2_host.exe"
} else {
  $binary = Join-Path $work "binaries/linux64/BouncingBall.so"
  $hostExe = Join-Path $cache "fmi2_host"
}
if (-not (Test-Path -LiteralPath $hostExe)) {
  Write-Error "missing $hostExe; run tests/abi/build-fixture.ps1 or build-fixture.sh first"
}

$resources = (Join-Path $work "resources")
$resourceUri = ([System.Uri]::new($resources)).AbsoluteUri
if (-not $resourceUri.EndsWith("/")) {
  $resourceUri += "/"
}

$json = & $hostExe $binary $resourceUri
if ($LASTEXITCODE -ne 0) {
  Write-Error "the reference host failed with exit code $LASTEXITCODE"
}

if ($Output -eq "") {
  $Output = Join-Path $cache "fmi2-host.json"
}
[System.IO.File]::WriteAllText($Output, ($json -join "`n") + "`n")
Write-Host "wrote $Output"
