param(
    [string]$ServiceName = "vnts2",
    [string]$DisplayName = "VNTS 2.0 Service",
    [string]$TargetDir = $PSScriptRoot,
    [switch]$SkipStart
)

$ErrorActionPreference = "Stop"

$commonScript = Join-Path $PSScriptRoot "vnts2-service-common.ps1"
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) {
    throw "缺少 Windows 服务共享脚本：$commonScript"
}
. $commonScript

Assert-Vnts2Administrator
Assert-Vnts2ServiceName -ServiceName $ServiceName

$resolvedTarget = (Resolve-Path -LiteralPath $TargetDir).Path
$layout = Get-Vnts2PortableLayout -RootPath $resolvedTarget
$exePath = $layout.ExecutablePath
$configPath = $layout.ConfigPath

if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "未找到 $exePath，请先将编译好的 vnts2.exe 放到 windows-deploy 目录。"
}

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "未找到 $configPath，请先由管理器初始化同级 data 目录中的配置。"
}

$binaryPath = Get-Vnts2ServiceBinaryPath `
    -ExecutablePath $exePath `
    -ConfigPath $configPath `
    -ServiceName $ServiceName
$existingService = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
if ($null -ne $existingService) {
    if (-not (Test-Vnts2ServiceBinaryPath -Actual $existingService.PathName -Expected $binaryPath)) {
        throw "Windows 服务 $ServiceName 已存在，但启动路径与当前部署目录不一致；为避免覆盖其他服务，安装已停止。"
    }
    if ($existingService.StartName -notin @("LocalSystem", "NT AUTHORITY\SYSTEM")) {
        throw "Windows 服务 $ServiceName 已存在，但运行账户不是 LocalSystem；安装脚本不会静默改写服务身份。"
    }
}

$layout = Initialize-Vnts2PortableDirectories -RootPath $resolvedTarget

if ($null -eq $existingService) {
    New-Service `
        -Name $ServiceName `
        -BinaryPathName $binaryPath `
        -DisplayName $DisplayName `
        -StartupType Automatic | Out-Null
    Write-Host "Windows 服务 $ServiceName 已安装。"
} else {
    Write-Host "Windows 服务 $ServiceName 已按相同路径安装，继续校验恢复策略。"
}

Set-Vnts2ServiceConfiguration -ServiceName $ServiceName -BinaryPath $binaryPath
Invoke-Vnts2Sc -Arguments @(
    "description",
    $ServiceName,
    "VNTS 2.0 server for Windows"
) | Out-Null
Invoke-Vnts2Sc -Arguments @(
    "failure",
    $ServiceName,
    "reset=",
    "86400",
    "actions=",
    'restart/5000/restart/5000/""/0'
) | Out-Null
Invoke-Vnts2Sc -Arguments @("failureflag", $ServiceName, "1") | Out-Null

if (-not $SkipStart) {
    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($service.Status.ToString() -ne "Running") {
        Start-Service -Name $ServiceName
        Wait-Vnts2ServiceStatus -ServiceName $ServiceName -DesiredStatus Running | Out-Null
    }
}

Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" |
    Select-Object Name, State, StartMode, StartName, PathName, @{
        Name = "DataPath"
        Expression = { $layout.DataPath }
    }
