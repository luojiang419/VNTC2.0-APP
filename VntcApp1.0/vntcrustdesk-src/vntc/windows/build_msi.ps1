[CmdletBinding()]
param(
    [string]$ToolRoot = "D:\Myproject\vnt2.0\toolchains\vntcrustdesk",
    [string]$FlutterRoot = "D:\APPdata\flutter",
    [string]$OutputDir = "",
    [string]$PublicSourceUrl = "https://github.com/luojiang419/vntcrustdesk",
    [switch]$SkipPrepare
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Invoke-ExternalCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

function Ensure-CargoBinary {
    param(
        [string]$BinaryName,
        [string[]]$InstallArguments
    )
    $existingCommand = Get-Command $BinaryName -ErrorAction SilentlyContinue
    if ($existingCommand) {
        return
    }
    Write-Step "Installing $BinaryName"
    $commandArguments = @(
        "run",
        "1.75.0-x86_64-pc-windows-msvc",
        "cargo"
    ) + $InstallArguments
    Invoke-ExternalCommand -FilePath "rustup" -Arguments $commandArguments
}

function Invoke-Download {
    param(
        [string]$Uri,
        [string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Destination)) {
        Write-Step "Downloading $Uri"
        Invoke-WebRequest -Uri $Uri -OutFile $Destination
    }
}

function Copy-DirectoryContents {
    param(
        [string]$Source,
        [string]$Destination
    )
    Ensure-Directory $Destination
    Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

function Sync-FlutterWindowsReleaseHeaders {
    param(
        [string]$EngineRoot
    )

    $sdkHeaderRoot = Join-Path $EngineRoot "windows-x64"
    $releaseHeaderRoot = Join-Path $EngineRoot "windows-x64-release"
    $sdkFlutterWindowsHeader = Join-Path $sdkHeaderRoot "flutter_windows.h"
    $releaseFlutterWindowsHeader = Join-Path $releaseHeaderRoot "flutter_windows.h"

    if (-not (Test-Path -LiteralPath $sdkFlutterWindowsHeader) -or -not (Test-Path -LiteralPath $releaseFlutterWindowsHeader)) {
        return
    }

    $sdkHeaderContent = Get-Content -LiteralPath $sdkFlutterWindowsHeader -Raw
    $releaseHeaderContent = Get-Content -LiteralPath $releaseFlutterWindowsHeader -Raw
    $sdkHasNewEngineFields = $sdkHeaderContent -match "gpu_preference" -and $sdkHeaderContent -match "ui_thread_policy"
    $releaseMissingNewEngineFields = $releaseHeaderContent -notmatch "gpu_preference" -or $releaseHeaderContent -notmatch "ui_thread_policy"

    if (-not $sdkHasNewEngineFields -or -not $releaseMissingNewEngineFields) {
        return
    }

    Write-Step "Synchronizing Flutter Windows release headers with SDK wrapper API"
    Get-ChildItem -LiteralPath $sdkHeaderRoot -Filter "*.h" | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $releaseHeaderRoot $_.Name) -Force
    }
}

function Import-BatchEnvironment {
    param(
        [string]$BatchFile,
        [string[]]$Arguments = @()
    )
    $escapedBatch = '"' + $BatchFile + '"'
    $argLine = if ($Arguments.Count -gt 0) { " " + ($Arguments -join " ") } else { "" }
    cmd /c "$escapedBatch$argLine && set" | ForEach-Object {
        if ($_ -match "^(.*?)=(.*)$") {
            Set-Item -Path "env:$($matches[1])" -Value $matches[2]
        }
    }
}

function Get-PreferredVisualStudioPath {
    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath "C:\VS2022BuildTools\MSBuild\Current\Bin\MSBuild.exe") {
        return "C:\VS2022BuildTools"
    }
    $preferred = & $vswhere -latest -products * -version "[17.0,18.0)" -requires Microsoft.Component.MSBuild -property installationPath
    if ($preferred) {
        return $preferred
    }
    $fallback = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
    if ($fallback) {
        return $fallback
    }
    throw "Visual Studio with MSBuild was not found."
}

function Get-PreferredPlatformToolset {
    param(
        [string]$VsInstallPath
    )

    $toolsetRoot = Join-Path $VsInstallPath "MSBuild\Microsoft\VC\v180\Platforms\x64\PlatformToolsets"
    if (-not (Test-Path -LiteralPath $toolsetRoot)) {
        throw "PlatformToolsets directory not found under $VsInstallPath."
    }

    $toolset = Get-ChildItem -LiteralPath $toolsetRoot -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1 -ExpandProperty Name
    if (-not $toolset) {
        throw "No PlatformToolset was found under $toolsetRoot."
    }

    return $toolset
}

function Get-FlutterFrameworkVersion {
    param(
        [string]$FlutterExecutable
    )

    $rawVersion = & $FlutterExecutable "--version" "--machine" 2>$null
    if ([string]::IsNullOrWhiteSpace($rawVersion)) {
        return ""
    }

    try {
        $versionInfo = ConvertFrom-Json $rawVersion
        if ($null -eq $versionInfo -or [string]::IsNullOrWhiteSpace($versionInfo.frameworkVersion)) {
            return ""
        }
        return $versionInfo.frameworkVersion.Trim()
    } catch {
        return ""
    }
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$toolRoot = (Resolve-Path -LiteralPath (New-Item -ItemType Directory -Force -Path $ToolRoot)).Path
$downloadRoot = Join-Path $toolRoot "downloads"
$flutterRoot = if ($FlutterRoot -and (Test-Path -LiteralPath $FlutterRoot)) {
    (Resolve-Path -LiteralPath $FlutterRoot).Path
} else {
    Join-Path $toolRoot "flutter-3.24.5"
}
$llvmRoot = Join-Path $toolRoot "llvm-15.0.6"
$vcpkgRoot = Join-Path $toolRoot "vcpkg"
$nugetExe = Join-Path $toolRoot "nuget\nuget.exe"
$bundleDir = Join-Path $repoRoot "vntcrustdesk"
$localOutputDir = if ($OutputDir) { $OutputDir } else { Join-Path $repoRoot "artifacts\windows" }
Ensure-Directory $downloadRoot
Ensure-Directory $localOutputDir

if (-not $SkipPrepare) {
    & (Join-Path $PSScriptRoot "prepare_windows_toolchain.ps1") -ToolRoot $toolRoot | Out-Host
}

$vsInstallPath = Get-PreferredVisualStudioPath
$platformToolset = Get-PreferredPlatformToolset -VsInstallPath $vsInstallPath
$msbuild = Join-Path $vsInstallPath "MSBuild\Current\Bin\MSBuild.exe"
if (-not (Test-Path -LiteralPath $msbuild)) {
    throw "MSBuild.exe not found under $vsInstallPath."
}
$vcvars64 = Join-Path $vsInstallPath "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path -LiteralPath $vcvars64)) {
    throw "vcvars64.bat not found under $vsInstallPath."
}
Import-BatchEnvironment -BatchFile $vcvars64

$env:VCPKG_ROOT = $vcpkgRoot
$env:VCPKG_VISUAL_STUDIO_PATH = $vsInstallPath
$env:LIBCLANG_PATH = Join-Path $llvmRoot "bin"
$env:VCPKG_DEFAULT_HOST_TRIPLET = "x64-windows-static"
$env:RUSTUP_TOOLCHAIN = "1.75.0-x86_64-pc-windows-msvc"
$env:RUST_LOG = if ($env:RUST_LOG -in @("debug", "info")) { $env:RUST_LOG } else { "info" }
$env:CMAKE_GENERATOR = "Visual Studio 17 2022"
$env:CMAKE_GENERATOR_INSTANCE = $vsInstallPath
$env:PATH = "$($flutterRoot)\bin;$env:PATH"
$flutterExe = Join-Path $flutterRoot "bin\flutter.bat"
$flutterFrameworkVersion = Get-FlutterFrameworkVersion -FlutterExecutable $flutterExe
$useRustDeskCustomEngine = $flutterFrameworkVersion -eq "3.24.5" -or $flutterRoot -match 'flutter-3\.24\.5'

Push-Location $repoRoot
try {
    Ensure-CargoBinary -BinaryName "cargo-expand" -InstallArguments @(
        "install",
        "cargo-expand",
        "--version",
        "1.0.121",
        "--locked"
    )
    Ensure-CargoBinary -BinaryName "flutter_rust_bridge_codegen" -InstallArguments @(
        "install",
        "flutter_rust_bridge_codegen",
        "--version",
        "1.80.1",
        "--features",
        "uuid",
        "--locked"
    )

    Invoke-ExternalCommand -FilePath $flutterExe -Arguments @("precache", "--windows")
    Push-Location (Join-Path $repoRoot "flutter")
    try {
        Invoke-ExternalCommand -FilePath $flutterExe -Arguments @("pub", "get")
    } finally {
        Pop-Location
    }

    Write-Step "Generating Flutter bridge bindings"
    Invoke-ExternalCommand -FilePath "rustup" -Arguments @(
        "run",
        "1.75.0-x86_64-pc-windows-msvc",
        "flutter_rust_bridge_codegen",
        "--rust-input",
        ".\\src\\flutter_ffi.rs",
        "--dart-output",
        ".\\flutter\\lib\\generated_bridge.dart",
        "--c-output",
        ".\\flutter\\macos\\Runner\\bridge_generated.h",
        "--llvm-path",
        $llvmRoot
    )
    Copy-Item -LiteralPath (Join-Path $repoRoot "flutter\\macos\\Runner\\bridge_generated.h") -Destination (Join-Path $repoRoot "flutter\\ios\\Runner\\bridge_generated.h") -Force

    $flutterWindowsBuildDir = Join-Path $repoRoot "flutter\\build\\windows"
    if (Test-Path -LiteralPath $flutterWindowsBuildDir) {
        Write-Step "Removing stale Flutter Windows build cache"
        Remove-Item -LiteralPath $flutterWindowsBuildDir -Recurse -Force
    }
    $rootWindowsBuildDir = Join-Path $repoRoot "build\\windows"
    if (Test-Path -LiteralPath $rootWindowsBuildDir) {
        Remove-Item -LiteralPath $rootWindowsBuildDir -Recurse -Force
    }

    if ($useRustDeskCustomEngine) {
        Write-Step "Using RustDesk custom Flutter engine for Flutter $flutterFrameworkVersion"
        $engineZip = Join-Path $downloadRoot "windows-x64-release.zip"
        $engineTemp = Join-Path $toolRoot "windows-x64-release.unpack"
        $engineCache = Join-Path $flutterRoot "bin\cache\artifacts\engine\windows-x64-release"
        Ensure-Directory $engineCache
        Invoke-Download -Uri "https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip" -Destination $engineZip
        if (Test-Path -LiteralPath $engineTemp) {
            Remove-Item -LiteralPath $engineTemp -Recurse -Force
        }
        Expand-Archive -Path $engineZip -DestinationPath $engineTemp -Force
        Copy-DirectoryContents -Source $engineTemp -Destination $engineCache
        Remove-Item -LiteralPath $engineTemp -Recurse -Force
        Sync-FlutterWindowsReleaseHeaders -EngineRoot (Join-Path $flutterRoot "bin\cache\artifacts\engine")
    } else {
        Write-Step "Skipping RustDesk custom Flutter engine for Flutter $flutterFrameworkVersion"
    }

    Invoke-ExternalCommand -FilePath (Join-Path $vcpkgRoot "vcpkg.exe") -Arguments @(
        "install",
        "--triplet", "x64-windows-static",
        "--x-install-root=$vcpkgRoot\installed"
    )

    Write-Step "Building Flutter Windows release bundle"
    Invoke-ExternalCommand -FilePath "python" -Arguments @(
        "build.py",
        "--portable",
        "--hwcodec",
        "--flutter",
        "--vram",
        "--skip-portable-pack"
    )

    $releaseDir = Join-Path $repoRoot "flutter\build\windows\x64\runner\Release"
    $mainExe = Join-Path $releaseDir "vntcrustdesk.exe"
    if (-not (Test-Path -LiteralPath $mainExe)) {
        throw "Expected build output not found: $mainExe"
    }

    if (Test-Path -LiteralPath $bundleDir) {
        Remove-Item -LiteralPath $bundleDir -Recurse -Force
    }
    Copy-Item -LiteralPath $releaseDir -Destination $bundleDir -Recurse -Force

    $usbZip = Join-Path $downloadRoot "usbmmidd_v2.zip"
    $usbTemp = Join-Path $toolRoot "usbmmidd_v2.unpack"
    Invoke-Download -Uri "https://github.com/rustdesk-org/rdev/releases/download/usbmmidd_v2/usbmmidd_v2.zip" -Destination $usbZip
    if (Test-Path -LiteralPath $usbTemp) {
        Remove-Item -LiteralPath $usbTemp -Recurse -Force
    }
    Expand-Archive -Path $usbZip -DestinationPath $usbTemp -Force
    $usbSource = Join-Path $usbTemp "usbmmidd_v2"
    Remove-Item -LiteralPath (Join-Path $usbSource "Win32") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $usbSource "deviceinstaller64.exe") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $usbSource "deviceinstaller.exe") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $usbSource "usbmmidd.bat") -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $usbSource -Destination (Join-Path $bundleDir "usbmmidd_v2") -Recurse -Force
    Remove-Item -LiteralPath $usbTemp -Recurse -Force

    try {
        $driverZip = Join-Path $downloadRoot "rustdesk_printer_driver_v4-1.4.zip"
        $adapterZip = Join-Path $downloadRoot "printer_driver_adapter.zip"
        $checksumFile = Join-Path $downloadRoot "sha256sums"
        Invoke-Download -Uri "https://github.com/rustdesk/hbb_common/releases/download/driver/rustdesk_printer_driver_v4-1.4.zip" -Destination $driverZip
        Invoke-Download -Uri "https://github.com/rustdesk/hbb_common/releases/download/driver/printer_driver_adapter.zip" -Destination $adapterZip
        Invoke-Download -Uri "https://github.com/rustdesk/hbb_common/releases/download/driver/sha256sums" -Destination $checksumFile

        $checksumDriver = (Select-String -Path $checksumFile -Pattern '^([a-fA-F0-9]{64}) \*rustdesk_printer_driver_v4-1.4\.zip$').Matches.Groups[1].Value
        $checksumAdapter = (Select-String -Path $checksumFile -Pattern '^([a-fA-F0-9]{64}) \*printer_driver_adapter\.zip$').Matches.Groups[1].Value
        $downloadsumDriver = (Get-FileHash -Path $driverZip -Algorithm SHA256).Hash
        $downloadsumAdapter = (Get-FileHash -Path $adapterZip -Algorithm SHA256).Hash
        if ($checksumDriver -eq $downloadsumDriver -and $checksumAdapter -eq $downloadsumAdapter) {
            $driverTemp = Join-Path $toolRoot "printer-driver.unpack"
            $adapterTemp = Join-Path $toolRoot "printer-adapter.unpack"
            if (Test-Path -LiteralPath $driverTemp) {
                Remove-Item -LiteralPath $driverTemp -Recurse -Force
            }
            if (Test-Path -LiteralPath $adapterTemp) {
                Remove-Item -LiteralPath $adapterTemp -Recurse -Force
            }
            Expand-Archive -Path $driverZip -DestinationPath $driverTemp -Force
            Expand-Archive -Path $adapterZip -DestinationPath $adapterTemp -Force
            Ensure-Directory (Join-Path $bundleDir "drivers")
            Copy-Item -LiteralPath (Join-Path $driverTemp "rustdesk_printer_driver_v4-1.4") -Destination (Join-Path $bundleDir "drivers\RustDeskPrinterDriver") -Recurse -Force
            Copy-Item -LiteralPath (Join-Path $adapterTemp "printer_driver_adapter.dll") -Destination (Join-Path $bundleDir "printer_driver_adapter.dll") -Force
            Remove-Item -LiteralPath $driverTemp -Recurse -Force
            Remove-Item -LiteralPath $adapterTemp -Recurse -Force
        }
    } catch {
        Write-Warning "Skipping printer driver bundling: $($_.Exception.Message)"
    }

    Push-Location (Join-Path $repoRoot "res\msi")
    try {
        Invoke-ExternalCommand -FilePath "python" -Arguments @(
            "preprocess.py",
            "--arp",
            "-d", "../../vntcrustdesk",
            "--app-name", "VNTC RustDesk",
            "--app-id", "vntcrustdesk",
            "--exe-name", "vntcrustdesk",
            "--service-name", "vntcrustdesk",
            "--install-dir-name", "VNTC RustDesk",
            "--config-name", "VNTC RustDesk",
            "--manufacturer", "VNTC"
        )
        Invoke-ExternalCommand -FilePath $nugetExe -Arguments @("restore", "msi.sln")
        Invoke-ExternalCommand -FilePath $msbuild -Arguments @(
            "msi.sln",
            "-p:Configuration=Release",
            "-p:Platform=x64",
            "/p:PlatformToolset=$platformToolset",
            "/p:TargetVersion=Windows10"
        )
    } finally {
        Pop-Location
    }

    $msiPath = Join-Path $repoRoot "res\msi\Package\bin\x64\Release\en-us\Package.msi"
    if (-not (Test-Path -LiteralPath $msiPath)) {
        $msiPath = (Get-ChildItem -Path (Join-Path $repoRoot "res\msi\Package\bin") -Filter Package.msi -Recurse | Select-Object -First 1 -ExpandProperty FullName)
    }
    if (-not $msiPath) {
        throw "Package.msi was not produced."
    }

    $outputMsi = Join-Path $localOutputDir "vntcrustdesk.msi"
    Copy-Item -LiteralPath $msiPath -Destination $outputMsi -Force

    $mainExeInfo = (Get-Item -LiteralPath $mainExe).VersionInfo
    $builtVersion = $mainExeInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($builtVersion)) {
        $builtVersion = $mainExeInfo.FileVersion
    }
    if ([string]::IsNullOrWhiteSpace($builtVersion)) {
        throw "Unable to determine product version from $mainExe"
    }
    $sourceCommit = (& git rev-parse HEAD).Trim()
    $sourceTag = ""
    try {
        $sourceTag = (& git describe --tags --exact-match HEAD 2>$null).Trim()
    } catch {
        $sourceTag = ""
    }
    $versionJsonPath = Join-Path $localOutputDir "vntcrustdesk.version.json"
    [ordered]@{
        version = $builtVersion
        sourceCommit = $sourceCommit
        sourceTag = $sourceTag
        builtAt = (Get-Date).ToUniversalTime().ToString("o")
        publicSourceUrl = $PublicSourceUrl
    } | ConvertTo-Json | Set-Content -LiteralPath $versionJsonPath -Encoding UTF8

    Write-Step "Artifacts created"
    Write-Host $outputMsi
    Write-Host $versionJsonPath
} finally {
    Pop-Location
}
