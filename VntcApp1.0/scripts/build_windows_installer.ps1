$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$workspaceDir = Split-Path -Parent $projectDir

$distDir = Join-Path $projectDir 'dist'
$outputDir = Join-Path $workspaceDir '安装包'
$issFile = Join-Path $scriptDir 'windows_installer.iss'
$appName = 'VNT GUI'
$publisher = 'lmq8267'
$appUrl = 'https://github.com/lmq8267/vntAPP'
$appExe = 'vnt_app.exe'

if (!(Test-Path -LiteralPath (Join-Path $distDir $appExe))) {
    throw "Missing '$distDir\$appExe'. Please run scripts\build_windows.bat first."
}

if (!(Test-Path -LiteralPath $issFile)) {
    throw "Missing installer script: $issFile"
}

if (!(Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

$pubspecPath = Join-Path $projectDir 'pubspec.yaml'
$versionLine = Get-Content -LiteralPath $pubspecPath | Select-String '^version:' | Select-Object -First 1
if ($null -eq $versionLine) {
    throw 'Failed to read version from pubspec.yaml'
}
$appVersion = $versionLine.Line.Split(':', 2)[1].Trim()
if ([string]::IsNullOrWhiteSpace($appVersion)) {
    throw 'Failed to resolve app version'
}

$candidateIsccPaths = @(
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe'
)
$isccPath = $candidateIsccPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($isccPath)) {
    Write-Host '[INFO] Inno Setup not found. Installing with Chocolatey...'
    & choco install InnoSetup -y --no-progress
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to install Inno Setup with Chocolatey.'
    }
    $isccPath = $candidateIsccPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($isccPath)) {
    throw 'ISCC.exe still not found after installation.'
}

Write-Host "[INFO] Building installer version $appVersion"
Write-Host "[INFO] Output directory: $outputDir"

& $isccPath `
    "/DMyAppName=$appName" `
    "/DMyAppVersion=$appVersion" `
    "/DMyAppPublisher=$publisher" `
    "/DMyAppURL=$appUrl" `
    "/DMyAppExeName=$appExe" `
    "/DMyRootDir=$projectDir" `
    "/DMyDistDir=$distDir" `
    "/DMyOutputDir=$outputDir" `
    $issFile

if ($LASTEXITCODE -ne 0) {
    throw 'Installer build failed.'
}

Write-Host "[OK] Installer build finished: $outputDir"
Get-ChildItem -LiteralPath $outputDir -Filter '*Setup*.exe' | Select-Object -ExpandProperty FullName
