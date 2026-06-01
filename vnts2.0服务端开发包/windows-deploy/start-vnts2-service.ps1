param(
    [string]$ServiceName = "vnts2"
)

$ErrorActionPreference = "Stop"

$service = Get-Service -Name $ServiceName -ErrorAction Stop
if ($service.Status -ne "Running") {
    Start-Service -Name $ServiceName
    $service.WaitForStatus("Running", "00:00:15")
}

Get-Service -Name $ServiceName | Select-Object Name, Status
