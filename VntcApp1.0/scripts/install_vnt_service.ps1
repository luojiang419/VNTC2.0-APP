param(
    [Parameter(Mandatory = $true)][string]$AppDir
)

$ErrorActionPreference = 'Stop'

$serviceName = 'VntCoreService'
$displayName = 'VNTC Core Network Service'
$executablePath = Join-Path $AppDir 'vnt_service.exe'
$firewallRuleName = 'VNTC Core Network Service'
$machineRoot = Join-Path $env:ProgramData 'VNTC APP2.0'

if (-not (Test-Path -LiteralPath $executablePath)) {
    throw "VNT core service executable missing: $executablePath"
}

foreach ($directory in @(
    $machineRoot,
    (Join-Path $machineRoot 'config'),
    (Join-Path $machineRoot 'data'),
    (Join-Path $machineRoot 'logs')
)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    & icacls.exe $directory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to secure service directory: $directory"
    }
}

$existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -eq $existing) {
    New-Service `
        -Name $serviceName `
        -BinaryPathName ('"{0}"' -f $executablePath) `
        -DisplayName $displayName `
        -Description 'Maintains the VNT virtual network before user logon.' `
        -StartupType Automatic | Out-Null
} else {
    try {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    } catch {
    }
    & sc.exe config $serviceName binPath= ('"{0}"' -f $executablePath) start= auto DisplayName= $displayName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update Windows service: $serviceName"
    }
}

& sc.exe description $serviceName 'Maintains the VNT virtual network before user logon.' | Out-Null
& sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
& sc.exe failureflag $serviceName 1 | Out-Null

Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule `
    -DisplayName $firewallRuleName `
    -Direction Inbound `
    -Action Allow `
    -Profile Any `
    -Program $executablePath | Out-Null

Start-Service -Name $serviceName
$service = Get-Service -Name $serviceName
if ($service.Status -ne 'Running') {
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
}

Write-Host "[OK] $serviceName installed and running"
