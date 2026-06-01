param(
    [string]$ServiceName = "vnts2"
)

$ErrorActionPreference = "Stop"

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -eq $service) {
    Write-Host "Windows 服务 $ServiceName 不存在，无需卸载。"
    return
}

if ($service.Status -ne "Stopped") {
    Stop-Service -Name $ServiceName -Force
    Start-Sleep -Seconds 1
}

& sc.exe delete $ServiceName | Out-Null
Start-Sleep -Seconds 1
Write-Host "Windows 服务 $ServiceName 已删除。"
