param(
    [string]$ServiceName = "vnts2"
)

$ErrorActionPreference = "Stop"

$commonScript = Join-Path $PSScriptRoot "vnts2-service-common.ps1"
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) {
    throw "缺少 Windows 服务共享脚本：$commonScript"
}
. $commonScript

Assert-Vnts2Windows
Assert-Vnts2ServiceName -ServiceName $ServiceName

$service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
if ($null -eq $service) {
    [pscustomobject]@{
        Name = $ServiceName
        Installed = $false
        State = "NotInstalled"
        StartMode = $null
        StartName = $null
        ProcessId = 0
        ExitCode = $null
        ExecutablePath = $null
        ConfigPath = $null
        DataPath = $null
        PortableLayout = $false
        PathName = $null
    }
    return
}

$commandInfo = Get-Vnts2ServiceCommandInfo -PathName $service.PathName
[pscustomobject]@{
    Name = $service.Name
    Installed = $true
    State = $service.State
    StartMode = $service.StartMode
    StartName = $service.StartName
    ProcessId = $service.ProcessId
    ExitCode = $service.ExitCode
    ExecutablePath = if ($null -eq $commandInfo) { $null } else { $commandInfo.ExecutablePath }
    ConfigPath = if ($null -eq $commandInfo) { $null } else { $commandInfo.ConfigPath }
    DataPath = if ($null -eq $commandInfo) { $null } else { Split-Path -Parent $commandInfo.ConfigPath }
    PortableLayout = if ($null -eq $commandInfo) { $false } else { Test-Vnts2PortableServiceCommand -CommandInfo $commandInfo }
    PathName = $service.PathName
}
