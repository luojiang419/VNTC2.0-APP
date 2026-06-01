param(
    [Parameter(Mandatory = $true)][string]$AppDir
)

$ErrorActionPreference = 'Stop'

$serviceName = 'vntcrustdesk'
$managedBy = 'VNT App 2.0'
$tcpRuleName = 'VNTC Remote Assist TCP 49999'
$udpRuleName = 'VNTC Remote Assist Presence UDP 49998'
$remoteAssistDir = Join-Path $AppDir 'remote_assist'
$logDir = Join-Path $remoteAssistDir 'logs'
$manifestPath = Join-Path $remoteAssistDir 'vntcrustdesk_manifest.json'
$uninstallLog = Join-Path $logDir 'vntcrustdesk_uninstall.log'

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Quote-ProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    return '"' + $Value.Replace('"', '""') + '"'
}

function Try-RemoveFirewallRule {
    param([Parameter(Mandatory = $true)][string]$DisplayName)

    try {
        Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule | Out-Null
    } catch {
    }
}

function Resolve-ProductCode {
    param($Manifest)

    $candidate = [string]$Manifest.productCode
    if ($candidate -match '^\{[0-9A-Fa-f\-]+\}$') {
        return $candidate
    }

    $uninstallString = [string]$Manifest.uninstallString
    if ($uninstallString -match '\{[0-9A-Fa-f\-]+\}') {
        return $matches[0]
    }

    return ''
}

if (-not (Test-Path -LiteralPath $manifestPath)) {
    exit 0
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$manifest.managedBy -ne $managedBy) {
    exit 0
}

try {
    Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
} catch {
}
Get-Process -Name vntcrustdesk -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Ensure-Directory -Path $remoteAssistDir
Ensure-Directory -Path $logDir

$productCode = Resolve-ProductCode -Manifest $manifest
if (-not [string]::IsNullOrWhiteSpace($productCode)) {
    try {
        $process = Start-Process msiexec.exe `
            -ArgumentList @(
                '/x',
                $productCode,
                '/qn',
                '/l*v',
                (Quote-ProcessArgument -Value $uninstallLog)
            ) `
            -Wait `
            -PassThru `
            -NoNewWindow
        if ($process.ExitCode -notin @(0, 1605, 1614, 3010)) {
            Write-Warning "vntcrustdesk MSI uninstall returned $($process.ExitCode)"
        }
    } catch {
        Write-Warning "vntcrustdesk MSI uninstall failed: $_"
    }
}

Try-RemoveFirewallRule -DisplayName $tcpRuleName
Try-RemoveFirewallRule -DisplayName $udpRuleName

try {
    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
} catch {
}

Write-Host '[OK] vntcrustdesk managed artifacts removed'
