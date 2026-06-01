param(
    [Parameter(Mandatory = $true)][string]$SourceMsiPath,
    [string]$SourceVersion = '',
    [string]$SourceVersionJsonPath = '',
    [string]$DestinationRoot = ''
)

$ErrorActionPreference = 'Stop'

$projectDir = Resolve-Path (Join-Path $PSScriptRoot '..')
if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
    $DestinationRoot = Join-Path $projectDir 'third_party\vntcrustdesk\windows\dist'
}

if (-not (Test-Path -LiteralPath $SourceMsiPath)) {
    throw "Source MSI missing: $SourceMsiPath"
}

if (-not (Test-Path -LiteralPath $DestinationRoot)) {
    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
}

$targetMsi = Join-Path $DestinationRoot 'vntcrustdesk.msi'
$targetVersion = Join-Path $DestinationRoot 'vntcrustdesk.version.json'

Copy-Item -LiteralPath $SourceMsiPath -Destination $targetMsi -Force

$versionPayload = [ordered]@{}
if (-not [string]::IsNullOrWhiteSpace($SourceVersionJsonPath) -and (Test-Path -LiteralPath $SourceVersionJsonPath)) {
    $rawVersionJson = Get-Content -LiteralPath $SourceVersionJsonPath -Raw -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($rawVersionJson)) {
        $parsedVersionJson = $rawVersionJson | ConvertFrom-Json
        foreach ($property in $parsedVersionJson.PSObject.Properties) {
            $versionPayload[$property.Name] = $property.Value
        }
    }
}
if (-not $versionPayload.Contains('version')) {
    $versionPayload['version'] = if ([string]::IsNullOrWhiteSpace($SourceVersion)) { 'unknown' } else { $SourceVersion }
}
$versionPayload['sourceMsiPath'] = $SourceMsiPath
$versionPayload['copiedAt'] = (Get-Date).ToString('o')
$versionPayload | ConvertTo-Json | Set-Content -LiteralPath $targetVersion -Encoding UTF8

Write-Host "[OK] MSI staged to: $targetMsi"
Write-Host "[OK] Version metadata: $targetVersion"
