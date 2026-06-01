param(
    [string]$ProjectDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$TargetDir
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($TargetDir)) {
    throw 'TargetDir is required.'
}

$packageConfigPath = Join-Path $ProjectDir '.dart_tool\package_config.json'
if (-not (Test-Path -LiteralPath $packageConfigPath)) {
    throw "package_config.json not found: $packageConfigPath"
}

$packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$sqflitePackage = $packageConfig.packages | Where-Object { $_.name -eq 'sqflite_common_ffi' } | Select-Object -First 1
if ($null -eq $sqflitePackage) {
    throw 'sqflite_common_ffi package not found in package_config.json.'
}

$rootUri = [string]$sqflitePackage.rootUri
$packagePath = if ($rootUri.StartsWith('file:/')) {
    ([Uri]$rootUri).LocalPath
} else {
    $dartToolDir = Split-Path -Parent $packageConfigPath
    $relativeRoot = if ($rootUri.StartsWith('..')) { $rootUri.Substring(1) } else { $rootUri }
    [System.IO.Path]::GetFullPath((Join-Path $dartToolDir $relativeRoot))
}

$sourceDllPath = Join-Path $packagePath 'lib\src\windows\sqlite3.dll'
if (-not (Test-Path -LiteralPath $sourceDllPath)) {
    throw "sqlite3.dll not found in sqflite_common_ffi package: $sourceDllPath"
}

if (-not (Test-Path -LiteralPath $TargetDir)) {
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
}

$targetDllPath = Join-Path $TargetDir 'sqlite3.dll'
Copy-Item -LiteralPath $sourceDllPath -Destination $targetDllPath -Force

Write-Host "[OK] SQLite runtime copied: $targetDllPath"
