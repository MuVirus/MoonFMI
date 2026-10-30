param(
  [string]$Case
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$cases = Get-Content (Join-Path $PSScriptRoot "xsd-cases.json") -Raw | ConvertFrom-Json

if ($Case) {
  $cases = @($cases | Where-Object { $_.id -eq $Case })
  if ($cases.Count -eq 0) {
    Write-Error "unknown XSD case: $Case"
    exit 2
  }
}

function Test-ModelDescription {
  param($Item)

  $schemaPath = Join-Path $root $Item.schema
  $xmlPath = Join-Path $root $Item.file
  $errors = New-Object System.Collections.Generic.List[string]

  if (-not (Test-Path -LiteralPath $schemaPath)) {
    $errors.Add("schema not found: $schemaPath")
    return $errors
  }
  if (-not (Test-Path -LiteralPath $xmlPath)) {
    $errors.Add("xml not found: $xmlPath")
    return $errors
  }

  try {
    $schemas = New-Object System.Xml.Schema.XmlSchemaSet
    # Schemas are bundled and trusted; instance documents still use a null
    # resolver and DTD is prohibited below.
    $schemas.XmlResolver = New-Object System.Xml.XmlUrlResolver
    $null = $schemas.Add($null, $schemaPath)

    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.ValidationType = [System.Xml.ValidationType]::Schema
    $settings.Schemas = $schemas
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersFromEntities = 0
    $settings.MaxCharactersInDocument = 32MB
    $settings.ValidationFlags = [System.Xml.Schema.XmlSchemaValidationFlags]::ReportValidationWarnings

    $handler = [System.Xml.Schema.ValidationEventHandler] {
      param($sender, $eventArgs)
      $errors.Add($eventArgs.Message)
    }
    $settings.add_ValidationEventHandler($handler)

    $reader = [System.Xml.XmlReader]::Create($xmlPath, $settings)
    try {
      while ($reader.Read()) {
      }
    }
    finally {
      $reader.Dispose()
    }
  }
  catch {
    $errors.Add($_.Exception.Message)
  }

  return $errors
}

$failed = 0

foreach ($item in $cases) {
  $errors = Test-ModelDescription $item
  $actual = if ($errors.Count -eq 0) { "pass" } else { "fail" }
  $ok = $actual -eq $item.expect

  if ($ok) {
    Write-Host ("PASS  {0}  (expected {1})" -f $item.id, $item.expect)
  }
  else {
    $failed++
    Write-Host ("FAIL  {0}  (expected {1}, got {2})" -f $item.id, $item.expect, $actual)
  }

  if ($errors.Count -gt 0) {
    $limit = [Math]::Min(3, $errors.Count)
    for ($i = 0; $i -lt $limit; $i++) {
      Write-Host ("      {0}" -f $errors[$i])
    }
  }
}

if ($failed -gt 0) {
  Write-Host ("{0} XSD case(s) failed" -f $failed)
  exit 1
}

Write-Host ("all {0} XSD cases behaved as expected" -f $cases.Count)
