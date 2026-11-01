param(
    [Parameter(Mandatory = $true)][string]$AppDir
)

$ErrorActionPreference = 'Stop'

$serviceName = 'VntCoreService'
$firewallRuleName = 'VNTC Core Network Service'

try {
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
} catch {
}

if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    & sc.exe delete $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to delete Windows service: $serviceName"
    }
}

Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue | Out-Null

# Keep %ProgramData%\VNTC APP2.0 so reinstall and rollback retain network identity.
Write-Host "[OK] $serviceName removed; machine configuration preserved"
