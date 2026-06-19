[CmdletBinding()]
param(
    [string]$ToolRoot = "D:\Myproject\vnt2.0\toolchains\vntcrustdesk",
    [string]$VcpkgCommit = "120deac3062162151622ca4860575a33844ba10b",
    [switch]$PersistUserEnv = $true
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

function Update-TextFile {
    param(
        [string]$Path,
        [string]$Before,
        [string]$After
    )
    $content = Get-Content -LiteralPath $Path -Raw
    if ($content.Contains($After)) {
        return $false
    }
    if (-not $content.Contains($Before)) {
        throw "Expected text was not found in $Path"
    }
    $updated = $content.Replace($Before, $After)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $updated, $encoding)
    return $true
}

function Get-PreferredVisualStudioPath {
    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath "C:\VS2022BuildTools\MSBuild\Current\Bin\MSBuild.exe") {
        return "C:\VS2022BuildTools"
    }
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw "vswhere.exe not found."
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

$toolRoot = (Resolve-Path -LiteralPath (New-Item -ItemType Directory -Force -Path $ToolRoot)).Path
$downloadRoot = Join-Path $toolRoot "downloads"
$nugetRoot = Join-Path $toolRoot "nuget"
$flutterRoot = Join-Path $toolRoot "flutter-3.24.5"
$llvmRoot = Join-Path $toolRoot "llvm-15.0.6"
$vcpkgRoot = Join-Path $toolRoot "vcpkg"

Ensure-Directory $downloadRoot
Ensure-Directory $nugetRoot

$vsInstallPath = Get-PreferredVisualStudioPath
$msbuild = Join-Path $vsInstallPath "MSBuild\Current\Bin\MSBuild.exe"
if (-not (Test-Path -LiteralPath $msbuild)) {
    throw "MSBuild.exe not found under $vsInstallPath."
}

$nugetExe = Join-Path $nugetRoot "nuget.exe"
Invoke-Download -Uri "https://dist.nuget.org/win-x86-commandline/v6.13.2/nuget.exe" -Destination $nugetExe

if (-not (Test-Path -LiteralPath (Join-Path $flutterRoot "bin\flutter.bat"))) {
    $flutterZip = Join-Path $downloadRoot "flutter_windows_3.24.5-stable.zip"
    $flutterTemp = Join-Path $toolRoot "flutter-3.24.5.unpack"
    Invoke-Download -Uri "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.24.5-stable.zip" -Destination $flutterZip
    if (Test-Path -LiteralPath $flutterTemp) {
        Remove-Item -LiteralPath $flutterTemp -Recurse -Force
    }
    Expand-Archive -Path $flutterZip -DestinationPath $flutterTemp -Force
    if (Test-Path -LiteralPath $flutterRoot) {
        Remove-Item -LiteralPath $flutterRoot -Recurse -Force
    }
    Move-Item -LiteralPath (Join-Path $flutterTemp "flutter") -Destination $flutterRoot
    Remove-Item -LiteralPath $flutterTemp -Recurse -Force
}

$visualStudioDart = Join-Path $flutterRoot "packages\flutter_tools\lib\src\windows\visual_studio.dart"
$visualStudioBefore = @"
    final List<String> minimumVersionArguments = <String>[
      _vswhereMinVersionArgument,
      _minimumSupportedVersion.toString(),
    ];
    for (final bool checkForPrerelease in <bool>[false, true]) {
      for (final String requiredWorkload in _requiredWorkloads) {
        final VswhereDetails? result = _visualStudioDetails(
          validateRequirements: true,
          additionalArguments: checkForPrerelease
              ? <String>[...minimumVersionArguments, _vswherePrereleaseArgument]
              : minimumVersionArguments,
          requiredWorkload: requiredWorkload);

          if (result != null) {
            return result;
          }
      }
    }
"@
$visualStudioAfter = @"
    final List<String> preferredVersionArguments = <String>[
      _vswhereMinVersionArgument,
      '[17.0,18.0)',
    ];
    final List<String> minimumVersionArguments = <String>[
      _vswhereMinVersionArgument,
      _minimumSupportedVersion.toString(),
    ];
    for (final bool checkForPrerelease in <bool>[false, true]) {
      for (final String requiredWorkload in _requiredWorkloads) {
        final VswhereDetails? result = _visualStudioDetails(
          validateRequirements: true,
          additionalArguments: checkForPrerelease
              ? <String>[...preferredVersionArguments, _vswherePrereleaseArgument]
              : preferredVersionArguments,
          requiredWorkload: requiredWorkload,
        );

        if (result != null) {
          return result;
        }
      }
    }
    for (final bool checkForPrerelease in <bool>[false, true]) {
      for (final String requiredWorkload in _requiredWorkloads) {
        final VswhereDetails? result = _visualStudioDetails(
          validateRequirements: true,
          additionalArguments: checkForPrerelease
              ? <String>[...minimumVersionArguments, _vswherePrereleaseArgument]
              : minimumVersionArguments,
          requiredWorkload: requiredWorkload);

          if (result != null) {
            return result;
          }
      }
    }
"@
if (Update-TextFile -Path $visualStudioDart -Before $visualStudioBefore -After $visualStudioAfter) {
    Remove-Item -LiteralPath (Join-Path $flutterRoot "bin\cache\flutter_tools.snapshot") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $flutterRoot "bin\cache\flutter_tools.stamp") -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath (Join-Path $llvmRoot "bin\libclang.dll"))) {
    $llvmInstaller = Join-Path $downloadRoot "LLVM-15.0.6-win64.exe"
    Invoke-Download -Uri "https://github.com/llvm/llvm-project/releases/download/llvmorg-15.0.6/LLVM-15.0.6-win64.exe" -Destination $llvmInstaller
    Start-Process -FilePath $llvmInstaller -ArgumentList "/S", "/D=$llvmRoot" -Wait -WindowStyle Hidden
}

if (-not (Test-Path -LiteralPath (Join-Path $vcpkgRoot ".git"))) {
    git clone https://github.com/microsoft/vcpkg $vcpkgRoot
}
git -C $vcpkgRoot fetch --all --tags
git -C $vcpkgRoot checkout $VcpkgCommit
if (-not (Test-Path -LiteralPath (Join-Path $vcpkgRoot "vcpkg.exe"))) {
    & (Join-Path $vcpkgRoot "bootstrap-vcpkg.bat") -disableMetrics
}

Write-Step "Installing Rust 1.75 toolchain"
rustup toolchain install 1.75.0-x86_64-pc-windows-msvc --profile minimal
Write-Step "Installing flutter_rust_bridge build dependencies"
rustup run 1.75.0-x86_64-pc-windows-msvc cargo install cargo-expand --version 1.0.121 --locked
rustup run 1.75.0-x86_64-pc-windows-msvc cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked

if ($PersistUserEnv) {
    [Environment]::SetEnvironmentVariable("VCPKG_ROOT", $vcpkgRoot, "User")
    [Environment]::SetEnvironmentVariable("LIBCLANG_PATH", (Join-Path $llvmRoot "bin"), "User")
    [Environment]::SetEnvironmentVariable("VCPKG_VISUAL_STUDIO_PATH", $vsInstallPath, "User")
}

[ordered]@{
    visualStudio = $vsInstallPath
    msbuild = $msbuild
    nuget = $nugetExe
    flutter = $flutterRoot
    llvm = $llvmRoot
    vcpkg = $vcpkgRoot
    rustToolchain = "1.75.0-x86_64-pc-windows-msvc"
} | ConvertTo-Json
