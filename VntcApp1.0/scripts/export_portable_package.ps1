param(
    [string]$Version = '',
    [switch]$SkipVersionAdvance
)

$ErrorActionPreference = 'Stop'

$projectDir = Resolve-Path (Join-Path $PSScriptRoot '..')
$buildScript = Join-Path $PSScriptRoot 'build_windows.bat'
$versionFile = Join-Path $PSScriptRoot 'build_version.txt'
$versionUtils = Join-Path $PSScriptRoot 'build_version_utils.ps1'
$outputDir = Join-Path $projectDir 'output'
$releaseRoot = Join-Path $projectDir 'release'
$portableRoot = Join-Path $releaseRoot 'portable'
$currentBuildVersion = ''
$packageDir = ''
$zipPath = ''
$shaPath = ''
$vntcRustDeskMsiSource = Join-Path $projectDir 'third_party\vntcrustdesk\windows\dist\vntcrustdesk.msi'
$bootstrapScriptSource = Join-Path $projectDir 'scripts\bootstrap_vntcrustdesk.ps1'
$uninstallScriptSource = Join-Path $projectDir 'scripts\uninstall_vntcrustdesk.ps1'

function Require-Path {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label missing: $Path"
    }
}

function Remove-WithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Recurse
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop -Recurse:$Recurse
            return
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 400
        }
    }

    throw $lastError
}

function Reset-Path {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-WithRetry -Path $Path -Recurse
    }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Copy-WithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
            return
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 400
        }
    }

    throw $lastError
}

function Mirror-DirectoryWithRobocopy {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $robocopyLog = Join-Path ([System.IO.Path]::GetTempPath()) ("vnt_portable_robocopy_{0}.log" -f [guid]::NewGuid().ToString('N'))
    try {
        & robocopy $Source $Destination /MIR /R:3 /W:1 /NFL /NDL /NJH /NJS /NP /LOG:$robocopyLog | Out-Null
        if ($LASTEXITCODE -ge 8) {
            $details = ''
            if (Test-Path -LiteralPath $robocopyLog) {
                $details = (Get-Content -LiteralPath $robocopyLog -Raw -Encoding UTF8).Trim()
            }
            $message = "robocopy failed with exit code $LASTEXITCODE"
            if (-not [string]::IsNullOrWhiteSpace($details)) {
                $message += ": $details"
            }
            throw $message
        }
    } finally {
        if (Test-Path -LiteralPath $robocopyLog) {
            Remove-Item -LiteralPath $robocopyLog -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        return [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '')
    } finally {
        $stream.Dispose()
        $sha256.Dispose()
    }
}

Require-Path -Path $buildScript -Label 'Windows build script'
Require-Path -Path $versionFile -Label 'Build version file'
Require-Path -Path $versionUtils -Label 'Build version utility script'
Require-Path -Path $vntcRustDeskMsiSource -Label 'vntcrustdesk MSI artifact'
Require-Path -Path $bootstrapScriptSource -Label 'vntcrustdesk bootstrap script'
Require-Path -Path $uninstallScriptSource -Label 'vntcrustdesk uninstall script'
. $versionUtils

$currentBuildVersionInfo = Resolve-VntBuildVersion `
    -Version $Version `
    -VersionFile $versionFile
$currentBuildVersion = $currentBuildVersionInfo.Version
$packageDir = Join-Path $portableRoot "VNT_App_${currentBuildVersion}_Windows_Portable"
$zipPath = Join-Path $portableRoot "VNT_App_${currentBuildVersion}_Windows_Portable.zip"
$shaPath = Join-Path $portableRoot "VNT_App_${currentBuildVersion}_Windows_SHA256.txt"
$env:VNT_BUILD_VERSION = $currentBuildVersion

& $env:ComSpec /d /c "`"$buildScript`""
if ($LASTEXITCODE -ne 0) {
    throw "Windows build failed: $LASTEXITCODE"
}

Require-Path -Path $outputDir -Label 'Output directory'
Require-Path -Path (Join-Path $outputDir 'vnt_app.exe') -Label 'Main executable'
Require-Path -Path (Join-Path $outputDir 'rust_lib_vnt_app.dll') -Label 'Rust runtime dll'
Require-Path -Path (Join-Path $outputDir 'flutter_windows.dll') -Label 'Flutter runtime dll'
Require-Path -Path (Join-Path $outputDir 'sqlite3.dll') -Label 'SQLite runtime dll'
Require-Path -Path (Join-Path $outputDir 'wintun.dll') -Label 'Bundled wintun dll'
Require-Path -Path (Join-Path $outputDir 'data') -Label 'Output data directory'
Require-Path -Path (Join-Path $outputDir 'dlls') -Label 'Wintun dll directory'
Require-Path -Path (Join-Path $outputDir 'diagnose_portable_launch.ps1') -Label 'Portable diagnose script'
Require-Path -Path (Join-Path $outputDir 'diagnose_portable_launch.bat') -Label 'Portable diagnose bat'

if (-not (Test-Path -LiteralPath $portableRoot)) {
    New-Item -ItemType Directory -Force -Path $portableRoot | Out-Null
}
if (Test-Path -LiteralPath $zipPath) {
    Remove-WithRetry -Path $zipPath
}
if (Test-Path -LiteralPath $shaPath) {
    Remove-WithRetry -Path $shaPath
}
Reset-Path -Path $packageDir

Mirror-DirectoryWithRobocopy -Source $outputDir -Destination $packageDir

$remoteAssistArtifactDir = Join-Path $packageDir 'remote_assist\artifacts'
$scriptsDir = Join-Path $packageDir 'scripts'
New-Item -ItemType Directory -Force -Path $remoteAssistArtifactDir | Out-Null
New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
Copy-WithRetry -Source $vntcRustDeskMsiSource -Destination (Join-Path $remoteAssistArtifactDir 'vntcrustdesk.msi')
Copy-WithRetry -Source $bootstrapScriptSource -Destination (Join-Path $scriptsDir 'bootstrap_vntcrustdesk.ps1')
Copy-WithRetry -Source $uninstallScriptSource -Destination (Join-Path $scriptsDir 'uninstall_vntcrustdesk.ps1')

$requiredPaths = @(
    (Join-Path $packageDir 'vnt_app.exe'),
    (Join-Path $packageDir 'rust_lib_vnt_app.dll'),
    (Join-Path $packageDir 'flutter_windows.dll'),
    (Join-Path $packageDir 'dartjni.dll'),
    (Join-Path $packageDir 'record_windows_plugin.dll'),
    (Join-Path $packageDir 'sqlite3.dll'),
    (Join-Path $packageDir 'wintun.dll'),
    (Join-Path $packageDir 'native_assets.json'),
    (Join-Path $packageDir 'data'),
    (Join-Path $packageDir 'dlls'),
    (Join-Path $packageDir 'diagnose_portable_launch.ps1'),
    (Join-Path $packageDir 'diagnose_portable_launch.bat'),
    (Join-Path $packageDir 'remote_assist\artifacts\vntcrustdesk.msi'),
    (Join-Path $packageDir 'scripts\bootstrap_vntcrustdesk.ps1'),
    (Join-Path $packageDir 'scripts\uninstall_vntcrustdesk.ps1')
)
foreach ($path in $requiredPaths) {
    Require-Path -Path $path -Label 'Required package path'
}

Compress-Archive -LiteralPath $packageDir -DestinationPath $zipPath -CompressionLevel Optimal -Force

$zipHash = Get-FileSha256 -Path $zipPath
Set-Content -LiteralPath $shaPath -Value "$zipHash *VNT_App_${currentBuildVersion}_Windows_Portable.zip" -Encoding ASCII

if (-not $SkipVersionAdvance -and $currentBuildVersionInfo.Source -eq 'file') {
    $nextBuildVersion = Get-NextVntBuildVersion -CurrentVersion $currentBuildVersion
    Set-Content -LiteralPath $versionFile -Value $nextBuildVersion -Encoding ASCII
}

Write-Host "[OK] Portable directory: $packageDir"
Write-Host "[OK] Portable zip: $zipPath"
Write-Host "[OK] Portable SHA256 file: $shaPath"
Write-Host "[OK] ZIP SHA256: $zipHash"

$global:LASTEXITCODE = 0
