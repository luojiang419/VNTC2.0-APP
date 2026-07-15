$ErrorActionPreference = 'Stop'

$projectDir = Resolve-Path (Join-Path $PSScriptRoot '..')
$portableScript = Join-Path $PSScriptRoot 'export_portable_package.ps1'
$versionFile = Join-Path $PSScriptRoot 'build_version.txt'
$versionUtils = Join-Path $PSScriptRoot 'build_version_utils.ps1'
$releaseRoot = Join-Path $projectDir 'release'
$portableRoot = Join-Path $releaseRoot 'portable'
$installerRoot = Join-Path $releaseRoot 'installer'
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
$payloadDir = Join-Path $stageDir 'payload'
$payloadZip = Join-Path $stageDir 'brand_payload.zip'
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

Require-Path -Path $portableScript -Label 'Portable export script'
Require-Path -Path $versionFile -Label 'Build version file'
Require-Path -Path $versionUtils -Label 'Build version utility script'
Require-Path -Path $iconSource -Label 'Application icon'
Require-Path -Path $languageSource -Label 'Chinese language file'
Require-Path -Path $localizedTextSource -Label 'Chinese installer text file'
Require-Path -Path $vntcRustDeskMsiSource -Label 'vntcrustdesk MSI artifact'
Require-Path -Path $bootstrapScriptSource -Label 'vntcrustdesk bootstrap script'
Require-Path -Path $uninstallScriptSource -Label 'vntcrustdesk uninstall script'
$innoCompiler = Ensure-InnoSetup
Require-Path -Path $innoCompiler -Label 'Inno Setup compiler'
. $versionUtils

$currentBuildVersion = Get-VntBuildVersion -VersionFile $versionFile
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
Require-Path -Path (Join-Path $portablePackageDir 'dartjni.dll') -Label 'Portable dartjni dll'
Require-Path -Path (Join-Path $portablePackageDir 'record_windows_plugin.dll') -Label 'Portable record plugin dll'
Require-Path -Path (Join-Path $portablePackageDir 'sqlite3.dll') -Label 'Portable sqlite runtime dll'
Require-Path -Path (Join-Path $portablePackageDir 'wintun.dll') -Label 'Portable wintun dll'
Require-Path -Path (Join-Path $portablePackageDir 'native_assets.json') -Label 'Portable native assets manifest'
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

New-Item -ItemType Directory -Force -Path $payloadDir | Out-Null
Get-ChildItem -LiteralPath $portablePackageDir -Force | Copy-Item -Destination $payloadDir -Recurse -Force
$payloadConfigDir = Join-Path $payloadDir 'config'
if (Test-Path -LiteralPath $payloadConfigDir) {
    Remove-WithRetry -Path $payloadConfigDir -Recurse
}
$payloadManifest = [ordered]@{
    schemaVersion = 1
    brandReady = $true
    version = $currentBuildVersion
    executableName = 'vnt_app.exe'
    sourceProductName = 'VNTC APP2.0'
    capabilities = @('runtimeBrandingV1', 'hideAboutPage', 'removeUpdateFeature')
}
$payloadManifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $payloadDir 'brand_package_manifest.json') -Encoding UTF8
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $payloadDir,
    $payloadZip,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false
)

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
#define MyBrandPayload "$(Convert-ToInnoPath -Path $payloadZip)"

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
Compression=none
SolidCompression=no
ArchiveExtraction=full
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
CloseApplications=yes
RestartApplications=no
RestartIfNeededByRun=no
VersionInfoDescription=VNT_BRAND_READY_V1
VersionInfoProductName={#MyAppName}

[Languages]
Name: "chinesesimplified"; MessagesFile: ".\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "$desktopShortcutDescription"; GroupDescription: "$additionalShortcutsGroup"; Flags: unchecked

[Files]
Source: "{#MyBrandPayload}"; Flags: dontcopy noencryption

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\bootstrap_vntcrustdesk.ps1"" -AppDir ""{app}"" -MsiPath ""{app}\remote_assist\artifacts\vntcrustdesk.msi"""; Flags: runhidden waituntilterminated; Check: not IsBrandValidationMode
Filename: "{app}\{#MyAppExeName}"; Description: "$launchAfterInstallDescription"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\uninstall_vntcrustdesk.ps1"" -AppDir ""{app}"""; Flags: runhidden waituntilterminated; Check: not IsBrandValidationMode

[UninstallDelete]
Type: files; Name: "{app}\*"
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\dlls"
Type: filesandordirs; Name: "{app}\remote_assist"
Type: filesandordirs; Name: "{app}\scripts"
Type: dirifempty; Name: "{app}"

[Code]
var
  BrandExportMode: Boolean;

function IsBrandValidationMode: Boolean;
var
  Index: Integer;
begin
  Result := False;
  for Index := 1 to ParamCount do
  begin
    if CompareText(ParamStr(Index), '/BRAND-VALIDATE-INSTALL') = 0 then
    begin
      Result := True;
      exit;
    end;
  end;
end;

function InitializeSetup: Boolean;
var
  ExportPath: String;
begin
  ExportPath := ExpandConstant('{param:BRAND-EXPORT|}');
  BrandExportMode := ExportPath <> '';
  if BrandExportMode then
  begin
    ForceDirectories(ExtractFileDir(ExportPath));
    ExtractTemporaryFile('brand_payload.zip');
    if not FileCopy(ExpandConstant('{tmp}\brand_payload.zip'), ExportPath, False) then
      RaiseException('无法导出品牌母包数据');
    Result := False;
    exit;
  end;
  Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    ForceDirectories(ExpandConstant('{app}'));
    ExtractTemporaryFile('brand_payload.zip');
    ExtractArchive(
      ExpandConstant('{tmp}\brand_payload.zip'),
      ExpandConstant('{app}'),
      '',
      True,
      nil
    );
  end;
end;
"@

Set-Content -LiteralPath $issPath -Value $issContent -Encoding UTF8

& $innoCompiler "/Qp" $issPath | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup build failed: $LASTEXITCODE"
}

Require-Path -Path $setupPath -Label 'Installer exe'
$setupHash = Get-FileSha256 -Path $setupPath
Set-Content -LiteralPath $shaPath -Value "$setupHash *VNT_App_${currentBuildVersion}_Windows_Setup.exe" -Encoding ASCII

$nextBuildVersion = Get-NextVntBuildVersion -CurrentVersion $currentBuildVersion
Set-Content -LiteralPath $versionFile -Value $nextBuildVersion -Encoding ASCII

Write-Host "[OK] Installer exe: $setupPath"
Write-Host "[OK] Installer SHA256 file: $shaPath"
Write-Host "[OK] EXE SHA256: $setupHash"
