param(
    [string]$ServiceName = "vnts2"
)

$ErrorActionPreference = "Stop"

$commonScript = Join-Path $PSScriptRoot "vnts2-service-common.ps1"
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) {
    throw "缺少 Windows 服务共享脚本：$commonScript"
}
. $commonScript

Assert-Vnts2Administrator
Assert-Vnts2ServiceName -ServiceName $ServiceName

$serviceInfo = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
if ($null -eq $serviceInfo) {
    Write-Host "Windows 服务 $ServiceName 不存在，无需卸载。"
    [pscustomobject]@{
        Name = $ServiceName
        Uninstalled = $false
        DataPreserved = $true
        DataPath = $null
    }
    return
}
$commandInfo = Get-Vnts2ServiceCommandInfo -PathName $serviceInfo.PathName
$dataPath = if ($null -eq $commandInfo) { $null } else { Split-Path -Parent $commandInfo.ConfigPath }
$service = Get-Service -Name $ServiceName -ErrorAction Stop

if ($service.Status -ne "Stopped") {
    if ($service.Status -ne "StopPending") {
        Stop-Service -Name $ServiceName
    }
    Wait-Vnts2ServiceStatus -ServiceName $ServiceName -DesiredStatus Stopped | Out-Null
}

Invoke-Vnts2Sc -Arguments @("delete", $ServiceName) | Out-Null
Wait-Vnts2ServiceDeleted -ServiceName $ServiceName
Write-Host "Windows 服务 $ServiceName 已删除；配置、数据库、密钥、日志和备份数据均已保留。"
[pscustomobject]@{
    Name = $ServiceName
    Uninstalled = $true
    DataPreserved = $true
    DataPath = $dataPath
}
