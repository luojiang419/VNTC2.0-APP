param(
    [string]$ServiceName = "vnts2",
    [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"

$commonScript = Join-Path $PSScriptRoot "vnts2-service-common.ps1"
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) {
    throw "缺少 Windows 服务共享脚本：$commonScript"
}
. $commonScript

Assert-Vnts2Administrator
Assert-Vnts2ServiceName -ServiceName $ServiceName

$service = Get-Service -Name $ServiceName -ErrorAction Stop
if ($service.Status.ToString() -eq "StopPending") {
    Wait-Vnts2ServiceStatus `
        -ServiceName $ServiceName `
        -DesiredStatus Stopped `
        -TimeoutSeconds $TimeoutSeconds | Out-Null
    $service = Get-Service -Name $ServiceName -ErrorAction Stop
}

switch ($service.Status.ToString()) {
    "Running" { }
    "StartPending" {
        Wait-Vnts2ServiceStatus `
            -ServiceName $ServiceName `
            -DesiredStatus Running `
            -TimeoutSeconds $TimeoutSeconds | Out-Null
    }
    "Stopped" {
        Start-Service -Name $ServiceName
        Wait-Vnts2ServiceStatus `
            -ServiceName $ServiceName `
            -DesiredStatus Running `
            -TimeoutSeconds $TimeoutSeconds | Out-Null
    }
    default {
        throw "Windows 服务 $ServiceName 当前状态为 $($service.Status)，无法按启动契约处理。"
    }
}

Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" |
    Select-Object Name, State, StartMode, StartName, ProcessId, ExitCode, PathName
