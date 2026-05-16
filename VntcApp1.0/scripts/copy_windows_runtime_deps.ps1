param(
    [string[]]$TargetDirs
)

$ErrorActionPreference = "Stop"

function Resolve-TargetDirs {
    param([string[]]$RawPaths)

    $resolved = @()
    foreach ($rawPath in $RawPaths) {
        if ([string]::IsNullOrWhiteSpace($rawPath)) {
            continue
        }

        $resolved += ($rawPath -split ",") |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    }

    return $resolved
}

function Get-LatestDirectory {
    param([string[]]$Patterns)

    $matches = @()
    foreach ($pattern in $Patterns) {
        $matches += Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue
    }

    if ($matches.Count -eq 0) {
        return $null
    }

    return ($matches | Sort-Object FullName -Descending | Select-Object -First 1).FullName
}

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Resolve-PackageRootPath {
    param(
        [string]$PackageConfigPath,
        [string]$PackageName
    )

    if (-not (Test-Path -LiteralPath $PackageConfigPath)) {
        return $null
    }

    $packageConfig = Get-Content -LiteralPath $PackageConfigPath -Raw | ConvertFrom-Json
    foreach ($package in $packageConfig.packages) {
        if ($package.name -ne $PackageName) {
            continue
        }

        $rootUri = [string]$package.rootUri
        if ([string]::IsNullOrWhiteSpace($rootUri)) {
            continue
        }

        $packageConfigDir = Split-Path -Parent $PackageConfigPath
        $baseUri = [System.Uri]::new(($packageConfigDir.TrimEnd('\') + '\'))
        $resolvedUri = [System.Uri]::new($baseUri, $rootUri)
        return $resolvedUri.LocalPath
    }

    return $null
}

$resolvedTargetDirs = @(Resolve-TargetDirs -RawPaths $TargetDirs | Select-Object -Unique)
if ($resolvedTargetDirs.Count -eq 0) {
    throw "No target directories were provided."
}

$vcRedistDir = Get-LatestDirectory -Patterns @(
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT",
    "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT"
)
if (-not $vcRedistDir) {
    throw "Unable to locate Visual C++ x64 redistributable directory."
}

$ucrtRedistDir = Get-LatestDirectory -Patterns @(
    "C:\Program Files (x86)\Windows Kits\10\Redist\*\ucrt\DLLs\x64",
    "C:\Program Files (x86)\Windows Kits\10\Redist\ucrt\DLLs\x64"
)
if (-not $ucrtRedistDir) {
    throw "Unable to locate UCRT x64 redistributable directory."
}

$runtimeFiles = @()
$runtimeFiles += Get-ChildItem -LiteralPath $vcRedistDir -File -ErrorAction Stop
$runtimeFiles += Get-ChildItem -LiteralPath $ucrtRedistDir -File -ErrorAction Stop |
    Where-Object {
        $_.Name -eq "ucrtbase.dll" -or $_.Name -like "api-ms-win-crt-*.dll"
    }

$projectDir = Split-Path -Parent $PSScriptRoot
$packageConfigPath = Join-Path $projectDir ".dart_tool\package_config.json"
$sqfliteRoot = Resolve-PackageRootPath -PackageConfigPath $packageConfigPath -PackageName "sqflite_common_ffi"
if (-not [string]::IsNullOrWhiteSpace($sqfliteRoot)) {
    $sqliteDllPath = Join-Path $sqfliteRoot "lib\src\windows\sqlite3.dll"
    if (Test-Path -LiteralPath $sqliteDllPath) {
        $runtimeFiles += Get-Item -LiteralPath $sqliteDllPath
    }
}

$runtimeFiles = @($runtimeFiles | Sort-Object FullName -Unique)
if ($runtimeFiles.Count -eq 0) {
    throw "No runtime dependency files were collected."
}

foreach ($targetDir in $resolvedTargetDirs) {
    Ensure-Directory -Path $targetDir
    foreach ($file in $runtimeFiles) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $targetDir $file.Name) -Force
    }
    Write-Host "[Runtime] Bundled $($runtimeFiles.Count) files into $targetDir"
}

Write-Host "[Runtime] VC redist source: $vcRedistDir"
Write-Host "[Runtime] UCRT redist source: $ucrtRedistDir"
if (-not [string]::IsNullOrWhiteSpace($sqfliteRoot)) {
    Write-Host "[Runtime] sqflite_common_ffi source: $sqfliteRoot"
}
