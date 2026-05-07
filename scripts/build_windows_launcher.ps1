$ErrorActionPreference = "Stop"

$projectDir = Split-Path -Parent $PSScriptRoot
$launcherDir = Join-Path $projectDir "windows_launcher"
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstall = $null

if (Test-Path -LiteralPath $vswhere) {
    $vsInstall = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0) {
        throw "vswhere failed with exit code $LASTEXITCODE"
    }
}

if ([string]::IsNullOrWhiteSpace($vsInstall)) {
    $fallbacks = @(
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools"
    )
    foreach ($candidate in $fallbacks) {
        if (Test-Path -LiteralPath $candidate) {
            $vsInstall = $candidate
            break
        }
    }
}

if ([string]::IsNullOrWhiteSpace($vsInstall)) {
    throw "Visual Studio Build Tools not found."
}

$vsDevCmd = Join-Path $vsInstall "Common7\Tools\VsDevCmd.bat"
if (-not (Test-Path -LiteralPath $vsDevCmd)) {
    throw "VsDevCmd.bat not found: $vsDevCmd"
}

$tempCmd = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".cmd")
try {
    $scriptLines = @(
        "@echo off",
        "call `"$vsDevCmd`" -arch=x64 >nul",
        "if errorlevel 1 exit /b %errorlevel%",
        "cd /d `"$launcherDir`"",
        "del /q vnt_app_launcher.obj >nul 2>nul",
        "cl /nologo /c /O2 /MD /utf-8 /TC vnt_app_launcher.c",
        "if errorlevel 1 exit /b %errorlevel%",
        "link /nologo /SUBSYSTEM:WINDOWS /OUT:vnt_app.exe vnt_app_launcher.obj vnt_app_launcher.res user32.lib advapi32.lib shell32.lib comctl32.lib",
        "if errorlevel 1 exit /b %errorlevel%"
    )
    Set-Content -LiteralPath $tempCmd -Value $scriptLines -Encoding ASCII

    & cmd.exe /c $tempCmd
    if ($LASTEXITCODE -ne 0) {
        throw "Launcher build failed with exit code $LASTEXITCODE"
    }
} finally {
    Remove-Item -LiteralPath $tempCmd -Force -ErrorAction SilentlyContinue
}

Write-Host "[OK] Launcher rebuilt: $launcherDir\vnt_app.exe"
