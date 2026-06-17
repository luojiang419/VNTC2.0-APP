$ErrorActionPreference = 'Stop'

$projectDir = Resolve-Path (Join-Path $PSScriptRoot '..')
$portableScript = Join-Path $PSScriptRoot 'export_portable_package.ps1'
$versionFile = Join-Path $PSScriptRoot 'build_version.txt'
$portableRoot = Join-Path $projectDir 'dist\portable'
$installerRoot = Join-Path $projectDir 'dist\installer'
$stageDir = Join-Path $installerRoot 'stage'
$currentBuildVersion = ''
$portablePackageDir = ''
$setupPath = ''
$shaPath = ''
$issPath = ''
$iconSource = Join-Path $projectDir 'assets\app_icon.ico'
$iconDest = Join-Path $stageDir 'app_icon.ico'
$languageSource = Join-Path $projectDir 'scripts\inno\ChineseSimplified.isl'
$localizedTextSource = Join-Path $projectDir 'scripts\inno\installer_zh_cn.json'
$languageDest = Join-Path $stageDir 'ChineseSimplified.isl'
$vntcRustDeskMsiSource = Join-Path $projectDir 'third_party\vntcrustdesk\windows\dist\vntcrustdesk.msi'
$bootstrapScriptSource = Join-Path $projectDir 'scripts\bootstrap_vntcrustdesk.ps1'
$uninstallScriptSource = Join-Path $projectDir 'scripts\uninstall_vntcrustdesk.ps1'
$vntcRustDeskMsiDest = Join-Path $stageDir 'vntcrustdesk.msi'
$bootstrapScriptDest = Join-Path $stageDir 'bootstrap_vntcrustdesk.ps1'
$uninstallScriptDest = Join-Path $stageDir 'uninstall_vntcrustdesk.ps1'
$innoCompiler = $null

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

function Get-InnoCompilerPath {
    $candidates = @(
        'C:\Users\Administrator\AppData\Local\Programs\Inno Setup 6\ISCC.exe',
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $registryPaths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($registryPath in $registryPaths) {
        $match = Get-ItemProperty $registryPath -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Inno Setup*' } |
            Select-Object -First 1
        if ($null -eq $match) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($match.InstallLocation)) {
            $candidate = Join-Path $match.InstallLocation 'ISCC.exe'
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    return $null
}

function Ensure-InnoSetup {
    $compilerPath = Get-InnoCompilerPath
    if ($null -ne $compilerPath) {
        return $compilerPath
    }

    $wingetPath = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($wingetPath)) {
        throw 'Inno Setup compiler missing and winget.exe is unavailable.'
    }

    & $wingetPath install --id JRSoftware.InnoSetup -e --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup installation failed: $LASTEXITCODE"
    }

    $compilerPath = Get-InnoCompilerPath
    if ($null -eq $compilerPath) {
        throw 'Inno Setup compiler still not found after installation.'
    }

    return $compilerPath
}

function Convert-ToInnoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return ($Path -replace '\\', '\\')
}

function Get-CurrentBuildVersion {
    $version = (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Build version file is empty: $versionFile"
    }
    return $version
}

function Get-NextBuildVersion {
    param([Parameter(Mandatory = $true)][string]$CurrentVersion)

    $nextVersion = [decimal]::Parse(
        $CurrentVersion,
        [System.Globalization.CultureInfo]::InvariantCulture
    ) + [decimal]'0.1'
    return $nextVersion.ToString(
        '0.0',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

Require-Path -Path $portableScript -Label 'Portable export script'
Require-Path -Path $versionFile -Label 'Build version file'
Require-Path -Path $iconSource -Label 'Application icon'
Require-Path -Path $languageSource -Label 'Chinese language file'
Require-Path -Path $localizedTextSource -Label 'Chinese installer text file'
Require-Path -Path $vntcRustDeskMsiSource -Label 'vntcrustdesk MSI artifact'
Require-Path -Path $bootstrapScriptSource -Label 'vntcrustdesk bootstrap script'
Require-Path -Path $uninstallScriptSource -Label 'vntcrustdesk uninstall script'
$innoCompiler = Ensure-InnoSetup
Require-Path -Path $innoCompiler -Label 'Inno Setup compiler'

$currentBuildVersion = Get-CurrentBuildVersion
$portablePackageDir = Join-Path $portableRoot "VNT_App_${currentBuildVersion}_Windows_Portable"
$setupPath = Join-Path $installerRoot "VNT_App_${currentBuildVersion}_Windows_Setup.exe"
$shaPath = Join-Path $installerRoot "VNT_App_${currentBuildVersion}_Windows_Setup.sha256"
$issPath = Join-Path $stageDir "VNT_App_${currentBuildVersion}_Windows_Setup.iss"
$env:VNT_BUILD_VERSION = $currentBuildVersion

& $portableScript -SkipVersionAdvance
if (-not $?) {
    throw "Portable export failed: $LASTEXITCODE"
}

Require-Path -Path $portablePackageDir -Label 'Portable package directory'
Require-Path -Path (Join-Path $portablePackageDir 'vnt_app.exe') -Label 'Portable main executable'
Require-Path -Path (Join-Path $portablePackageDir 'audio_io.dll') -Label 'Portable audio io dll'
Require-Path -Path (Join-Path $portablePackageDir 'audioplayers_windows_plugin.dll') -Label 'Portable audioplayers plugin dll'
Require-Path -Path (Join-Path $portablePackageDir 'dartjni.dll') -Label 'Portable dartjni dll'
Require-Path -Path (Join-Path $portablePackageDir 'record_windows_plugin.dll') -Label 'Portable record plugin dll'
Require-Path -Path (Join-Path $portablePackageDir 'sqlite3.dll') -Label 'Portable sqlite runtime dll'
Require-Path -Path (Join-Path $portablePackageDir 'wintun.dll') -Label 'Portable wintun dll'
Require-Path -Path (Join-Path $portablePackageDir 'native_assets.json') -Label 'Portable native assets manifest'
Require-Path -Path (Join-Path $portablePackageDir 'config') -Label 'Portable config directory'
Require-Path -Path (Join-Path $portablePackageDir 'dlls') -Label 'Portable dll directory'

if (-not (Test-Path -LiteralPath $installerRoot)) {
    New-Item -ItemType Directory -Force -Path $installerRoot | Out-Null
}
Reset-Path -Path $stageDir
if (Test-Path -LiteralPath $setupPath) {
    Remove-WithRetry -Path $setupPath
}
if (Test-Path -LiteralPath $shaPath) {
    Remove-WithRetry -Path $shaPath
}

Copy-Item -LiteralPath $iconSource -Destination $iconDest -Force
Copy-Item -LiteralPath $languageSource -Destination $languageDest -Force
Copy-Item -LiteralPath $vntcRustDeskMsiSource -Destination $vntcRustDeskMsiDest -Force
Copy-Item -LiteralPath $bootstrapScriptSource -Destination $bootstrapScriptDest -Force
Copy-Item -LiteralPath $uninstallScriptSource -Destination $uninstallScriptDest -Force

$localizedText = Get-Content -LiteralPath $localizedTextSource -Raw -Encoding UTF8 | ConvertFrom-Json
$desktopShortcutDescription = [string]$localizedText.desktopShortcutDescription
$additionalShortcutsGroup = [string]$localizedText.additionalShortcutsGroup
$launchAfterInstallDescription = [string]$localizedText.launchAfterInstallDescription

$sourceDirForIss = Convert-ToInnoPath -Path $portablePackageDir
$iconPathForIss = Convert-ToInnoPath -Path $iconDest
$outputDirForIss = Convert-ToInnoPath -Path $installerRoot

$issContent = @"
#define MyAppInstallDirBaseName "VNT App"
#define MyAppName "VNTC APP2.0"
#define MyAppVersionedName "VNTC APP2.0 v$currentBuildVersion"
#define MyAppVersion "$currentBuildVersion"
#define MyAppPublisher "VNTC APP2.0"
#define MyAppExeName "vnt_app.exe"
#define MyAppSourceDir "$sourceDirForIss"
#define MyAppIcon "$iconPathForIss"

[Setup]
AppId={{B2877D56-1F3E-4F72-A53A-6D94C6C1E200}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppInstallDirBaseName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile={#MyAppIcon}
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppVersionedName}
OutputDir=$outputDirForIss
OutputBaseFilename=VNT_App_${currentBuildVersion}_Windows_Setup
DisableProgramGroupPage=no
DisableDirPage=no
DisableReadyMemo=no
ShowLanguageDialog=no

[Languages]
Name: "chinesesimplified"; MessagesFile: ".\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "$desktopShortcutDescription"; GroupDescription: "$additionalShortcutsGroup"; Flags: unchecked

[Files]
Source: "{#MyAppSourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: ".\vntcrustdesk.msi"; DestDir: "{app}\remote_assist\artifacts"; Flags: ignoreversion
Source: ".\bootstrap_vntcrustdesk.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: ".\uninstall_vntcrustdesk.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\bootstrap_vntcrustdesk.ps1"" -AppDir ""{app}"" -MsiPath ""{app}\remote_assist\artifacts\vntcrustdesk.msi"""; Flags: runhidden waituntilterminated
Filename: "{app}\{#MyAppExeName}"; Description: "$launchAfterInstallDescription"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\uninstall_vntcrustdesk.ps1"" -AppDir ""{app}"""; Flags: runhidden waituntilterminated
"@

Set-Content -LiteralPath $issPath -Value $issContent -Encoding UTF8

& $innoCompiler "/Qp" $issPath | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup build failed: $LASTEXITCODE"
}

Require-Path -Path $setupPath -Label 'Installer exe'
$setupHash = Get-FileSha256 -Path $setupPath
Set-Content -LiteralPath $shaPath -Value "$setupHash *VNT_App_${currentBuildVersion}_Windows_Setup.exe" -Encoding ASCII

$nextBuildVersion = Get-NextBuildVersion -CurrentVersion $currentBuildVersion
Set-Content -LiteralPath $versionFile -Value $nextBuildVersion -Encoding ASCII

Write-Host "[OK] Installer exe: $setupPath"
Write-Host "[OK] Installer SHA256 file: $shaPath"
Write-Host "[OK] EXE SHA256: $setupHash"
