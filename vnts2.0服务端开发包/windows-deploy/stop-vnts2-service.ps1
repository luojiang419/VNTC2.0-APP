param(
    [string]$ServiceName = "vnts2"
)

$ErrorActionPreference = "Stop"

$service = Get-Service -Name $ServiceName -ErrorAction Stop
if ($service.Status -ne "Stopped") {
    Stop-Service -Name $ServiceName -Force
    $service.WaitForStatus("Stopped", "00:00:15")
}

Get-Service -Name $ServiceName | Select-Object Name, Status
