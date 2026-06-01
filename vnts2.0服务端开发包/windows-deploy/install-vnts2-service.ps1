param(
    [string]$ServiceName = "vnts2",
    [string]$DisplayName = "VNTS 2.0 Service",
    [string]$TargetDir = $PSScriptRoot,
    [switch]$SkipStart
)

$ErrorActionPreference = "Stop"

$resolvedTarget = (Resolve-Path -LiteralPath $TargetDir).Path
$exePath = Join-Path $resolvedTarget "vnts2.exe"
$configPath = Join-Path $resolvedTarget "config.toml"
$logsDir = Join-Path $resolvedTarget "logs"
$backupDir = Join-Path $resolvedTarget ".backups"

if (-not (Test-Path -LiteralPath $exePath)) {
    throw "未找到 $exePath，请先将编译好的 vnts2.exe 放到 windows-deploy 目录。"
}

if (-not (Test-Path -LiteralPath $configPath)) {
    throw "未找到 $configPath，请先准备 config.toml。"
}

if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    throw "Windows 服务 $ServiceName 已存在，请先停止并卸载旧服务。"
}

New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$binaryPath = "`"$exePath`" --service --conf `"$configPath`""
New-Service -Name $ServiceName -BinaryPathName $binaryPath -DisplayName $DisplayName -StartupType Automatic
& sc.exe description $ServiceName "VNTS 2.0 server for Windows" | Out-Null
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/""/0 | Out-Null
& sc.exe failureflag $ServiceName 1 | Out-Null

if (-not $SkipStart) {
    Start-Service -Name $ServiceName
    Start-Sleep -Seconds 1
}

Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" |
    Select-Object Name, State, StartMode, PathName
