$ErrorActionPreference = "Stop"

function Assert-Exit {
  param([string]$Step)
  if ($LASTEXITCODE -ne 0) {
    Write-Error "$Step failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
  }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Get-MbtiFiles {
  @(
    Get-ChildItem -Path $root -Recurse -Filter "pkg.generated.mbti" |
      Where-Object { $_.FullName -notmatch "\\_build\\" } |
      Sort-Object FullName
  )
}

function Get-MbtiSnapshot {
  param([string[]]$Paths)
  $lines = foreach ($path in $Paths) {
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    "$hash  $path"
  }
  return ($lines -join "`n")
}

# Snapshot the interfaces before anything can regenerate them. `moon check`
# also updates pkg.generated.mbti, so a later snapshot would silently hide a
# manual edit or a stale interface.
$initialMbtiFiles = Get-MbtiFiles
$initialMbti = Get-MbtiSnapshot -Paths ($initialMbtiFiles | ForEach-Object { $_.FullName })

Write-Host "== MoonBit version =="
moon version --all
Assert-Exit "moon version"

Write-Host "== dependency direction =="
node tools/check-deps.mjs
Assert-Exit "dependency check"

Write-Host "== formatting =="
moon fmt --check
Assert-Exit "moon fmt --check"

Write-Host "== check: native =="
moon check --target native --deny-warn
Assert-Exit "moon check --target native"

Write-Host "== check: wasm =="
moon check --target wasm --deny-warn
Assert-Exit "moon check --target wasm"

Write-Host "== test: native =="
moon test --target native --deny-warn
Assert-Exit "moon test --target native"

Write-Host "== test: wasm =="
moon test --target wasm --deny-warn
Assert-Exit "moon test --target wasm"

Write-Host "== public interface =="
$backup = Join-Path ([System.IO.Path]::GetTempPath()) ("moonfmi-mbti-" + [guid]::NewGuid().ToString("N"))
foreach ($file in $initialMbtiFiles) {
  $rel = $file.FullName.Substring($root.Length).TrimStart("\", "/")
  $dest = Join-Path $backup $rel
  New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
  Copy-Item -LiteralPath $file.FullName -Destination $dest
}
foreach ($file in (Get-MbtiFiles)) {
  Remove-Item -LiteralPath $file.FullName
}

moon info
if ($LASTEXITCODE -ne 0) {
  foreach ($file in $initialMbtiFiles) {
    $rel = $file.FullName.Substring($root.Length).TrimStart("\", "/")
    Copy-Item -LiteralPath (Join-Path $backup $rel) -Destination $file.FullName
  }
  Remove-Item -Recurse -Force $backup
  Write-Error "moon info failed; restored the previous .mbti files"
  exit 1
}

$finalMbtiFiles = Get-MbtiFiles
$finalMbti = Get-MbtiSnapshot -Paths ($finalMbtiFiles | ForEach-Object { $_.FullName })
Remove-Item -Recurse -Force $backup

if ($initialMbti -ne $finalMbti) {
  Write-Error "pkg.generated.mbti was stale or hand-edited; review the regenerated files and commit them"
  exit 1
}

Write-Host "== XSD cross-check (optional) =="
$powershell = Get-Command powershell -ErrorAction SilentlyContinue
if ($null -eq $powershell) {
  Write-Host "skipped: no PowerShell validator found"
} else {
  powershell -NoProfile -ExecutionPolicy Bypass -File tests/data/validate-xsd.ps1
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "XSD cross-check failed; this is optional for P0."
  }
}
