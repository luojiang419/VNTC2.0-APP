[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$ReleaseTag = '',
    [string]$DestinationRoot = '',
    [string]$ExpectedSha256Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectDir = Resolve-Path (Join-Path $PSScriptRoot '..')
if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
    $DestinationRoot = Join-Path $projectDir 'third_party\vntcrustdesk\windows\dist'
}
if ([string]::IsNullOrWhiteSpace($ExpectedSha256Path)) {
    $ExpectedSha256Path = Join-Path $projectDir 'third_party\vntcrustdesk\windows\vntcrustdesk.msi.sha256'
}

if (-not (Test-Path -LiteralPath $ExpectedSha256Path)) {
    throw "vntcrustdesk SHA-256 lock file missing: $ExpectedSha256Path"
}

$expectedSha256 = ((Get-Content -LiteralPath $ExpectedSha256Path -Raw -Encoding UTF8).Trim() -split '\s+')[0].ToUpperInvariant()
if ($expectedSha256 -notmatch '^[A-F0-9]{64}$') {
    throw "Invalid vntcrustdesk SHA-256 lock value: $expectedSha256"
}

$DestinationRoot = [IO.Path]::GetFullPath($DestinationRoot)
New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
$targetMsi = Join-Path $DestinationRoot 'vntcrustdesk.msi'
if (Test-Path -LiteralPath $targetMsi) {
    $currentSha256 = (Get-FileHash -LiteralPath $targetMsi -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($currentSha256 -eq $expectedSha256) {
        Write-Host "[OK] Existing vntcrustdesk MSI matches the lock file: $targetMsi"
        return
    }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI is required to restore vntcrustdesk.msi.'
}

if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
    $releaseTagOutput = & gh api "repos/$Repository/releases/latest" --jq '.tag_name'
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to resolve the latest GitHub Release for $Repository"
    }
    $ReleaseTag = ($releaseTagOutput | Out-String).Trim()
}
if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
    throw "GitHub Release tag is empty for $Repository"
}

$assetNames = @(& gh release view $ReleaseTag --repo $Repository --json assets --jq '.assets[].name')
if ($LASTEXITCODE -ne 0) {
    throw "Unable to list assets for GitHub Release $ReleaseTag"
}

$tempRoot = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [IO.Path]::GetTempPath()
} else {
    $env:RUNNER_TEMP
}
$tempRoot = [IO.Path]::GetFullPath($tempRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$tempDir = [IO.Path]::GetFullPath((Join-Path $tempRoot ("vntcrustdesk-release-" + [guid]::NewGuid().ToString('N'))))
$safeTempPrefix = $tempRoot + [IO.Path]::DirectorySeparatorChar
if (-not $tempDir.StartsWith($safeTempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    -not ([IO.Path]::GetFileName($tempDir)).StartsWith('vntcrustdesk-release-', [StringComparison]::Ordinal)) {
    throw "Unsafe temporary directory rejected: $tempDir"
}

New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
try {
    $sourceMsi = $null
    $standaloneAsset = $assetNames | Where-Object { $_ -eq 'vntcrustdesk.msi' } | Select-Object -First 1
    if ($null -ne $standaloneAsset) {
        & gh release download $ReleaseTag --repo $Repository --pattern $standaloneAsset --dir $tempDir
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to download $standaloneAsset from GitHub Release $ReleaseTag"
        }
        $sourceMsi = Get-ChildItem -LiteralPath $tempDir -Filter 'vntcrustdesk.msi' -File | Select-Object -First 1
    } else {
        $portableAsset = $assetNames |
            Where-Object { $_ -like 'VNT_App_*_Windows_Portable.zip' } |
            Select-Object -First 1
        if ($null -eq $portableAsset) {
            throw "Neither vntcrustdesk.msi nor a Windows portable package exists in GitHub Release $ReleaseTag"
        }

        & gh release download $ReleaseTag --repo $Repository --pattern $portableAsset --dir $tempDir
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to download $portableAsset from GitHub Release $ReleaseTag"
        }
        $portableZip = Get-ChildItem -LiteralPath $tempDir -Filter $portableAsset -File | Select-Object -First 1
        if ($null -eq $portableZip) {
            throw "Downloaded Windows portable package missing: $portableAsset"
        }

        $extractDir = Join-Path $tempDir 'portable'
        Expand-Archive -LiteralPath $portableZip.FullName -DestinationPath $extractDir -Force
        $sourceMsi = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'vntcrustdesk.msi' -File | Select-Object -First 1
    }

    if ($null -eq $sourceMsi) {
        throw "vntcrustdesk.msi was not found in GitHub Release $ReleaseTag"
    }

    $downloadedSha256 = (Get-FileHash -LiteralPath $sourceMsi.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($downloadedSha256 -ne $expectedSha256) {
        throw "vntcrustdesk MSI SHA-256 mismatch. Expected $expectedSha256, got $downloadedSha256"
    }

    Copy-Item -LiteralPath $sourceMsi.FullName -Destination $targetMsi -Force
    Write-Host "[OK] Restored vntcrustdesk MSI from ${ReleaseTag}: $targetMsi"
    Write-Host "[OK] SHA-256: $downloadedSha256"
} finally {
    if ((Test-Path -LiteralPath $tempDir) -and
        $tempDir.StartsWith($safeTempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        ([IO.Path]::GetFileName($tempDir)).StartsWith('vntcrustdesk-release-', [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}
