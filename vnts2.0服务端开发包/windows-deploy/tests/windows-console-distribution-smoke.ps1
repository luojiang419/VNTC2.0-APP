param(
    [Parameter(Mandatory = $true)][string]$ZipPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Smoke {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Get-FreeUdpPort {
    $client = [Net.Sockets.UdpClient]::new(0)
    try { return ([Net.IPEndPoint]$client.Client.LocalEndPoint).Port }
    finally { $client.Dispose() }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Vnts2ConsoleSmokeNativeMethods {
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr window);
}
'@

$resolvedZip = (Resolve-Path -LiteralPath $ZipPath).Path
$temporaryRoot = Join-Path $env:TEMP ("vnts2-console-distribution-smoke-" + [Guid]::NewGuid().ToString("N"))
$serviceName = "vnts2-console-smoke-" + [Guid]::NewGuid().ToString("N").Substring(0, 10)
$installed = $false
$consoleProcess = $null
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($resolvedZip, $temporaryRoot)
    $distributionDirectories = @(Get-ChildItem -LiteralPath $temporaryRoot -Directory)
    Assert-Smoke ($distributionDirectories.Count -eq 1) "增强 ZIP 必须只有一个顶层目录。"
    $root = $distributionDirectories[0].FullName
    $console = Join-Path $root "VNTS2-Console.exe"
    $data = Join-Path $root "data"
    $config = Join-Path $data "config.toml"
    foreach ($name in @(
        "VNTS2-Console.exe", "vnts2.exe", "install-vnts2-service.ps1",
        "tray_manager_plugin.dll",
        "initialize-vnts2-console.ps1",
        "start-vnts2-service.ps1", "stop-vnts2-service.ps1",
        "status-vnts2-service.ps1", "diagnose-vnts2-service.ps1",
        "uninstall-vnts2-service.ps1"
    )) {
        Assert-Smoke (Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf) "真实分发目录缺少：$name"
    }
    Assert-Smoke (Test-Path -LiteralPath (Join-Path $root "data\flutter_assets\windows\runner\resources\app_icon.ico") -PathType Leaf) "真实分发目录缺少托盘图标。"

    $tcpPort = Get-FreeTcpPort
    $quicPort = Get-FreeUdpPort
    $webPort = Get-FreeTcpPort
    while ($webPort -eq $tcpPort) { $webPort = Get-FreeTcpPort }
    $randomBytes = New-Object byte[] 18
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($randomBytes)
    }
    finally {
        $rng.Dispose()
    }
    $password = [Convert]::ToBase64String($randomBytes)
    $configText = @"
tcp_bind = "127.0.0.1:$tcpPort"
quic_bind = "127.0.0.1:$quicPort"
ws_bind = "127.0.0.1:$tcpPort"
network = "10.26.0.0/24"
white_list = []
lease_duration = 86400
web_bind = "127.0.0.1:$webPort"
username = "admin"
password = "$password"
persistence = true
wireguard_max_active_peers = 4096
peer_servers = []

[custom_nets]
"@
    [IO.File]::WriteAllText($config, $configText, [Text.UTF8Encoding]::new($false))

    & (Join-Path $root "install-vnts2-service.ps1") `
        -ServiceName $serviceName `
        -DisplayName "VNTS2 Console Distribution Smoke" `
        -TargetDir $root `
        -SkipStart | Out-Null
    $installed = $true
    & (Join-Path $root "start-vnts2-service.ps1") -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null

    $status = & (Join-Path $root "status-vnts2-service.ps1") -ServiceName $serviceName
    Assert-Smoke ($status.State -eq "Running") "真实分发服务未进入 Running。"
    Assert-Smoke $status.PortableLayout "真实分发服务没有使用便携 data。"

    $loginBody = @{ username = "admin"; password = $password } | ConvertTo-Json -Compress
    $login = Invoke-RestMethod `
        -Uri ("http://127.0.0.1:{0}/api/login" -f $webPort) `
        -Method Post `
        -ContentType "application/json" `
        -Body $loginBody `
        -SessionVariable session `
        -TimeoutSec 10
    Assert-Smoke ($login.code -eq 200) "真实分发管理 API 登录失败。"
    $dashboard = Invoke-RestMethod `
        -Uri ("http://127.0.0.1:{0}/api/dashboard/snapshot" -f $webPort) `
        -WebSession $session `
        -TimeoutSec 10
    Assert-Smoke ($dashboard.code -eq 200) "真实分发仪表盘 API 失败。"
    Assert-Smoke ($dashboard.data.server.version -eq "2.0.0") "真实分发服务版本错误。"
    Assert-Smoke ($dashboard.data.host.memory_total_bytes -gt 0) "真实分发仪表盘没有真实主机内存。"
    Assert-Smoke ($dashboard.data.traffic.tx_bytes_total -ge 0) "真实分发仪表盘没有累计流量。"
    Invoke-RestMethod `
        -Uri ("http://127.0.0.1:{0}/api/logout" -f $webPort) `
        -Method Post `
        -WebSession $session `
        -TimeoutSec 10 | Out-Null

    $updatedConfig = ([IO.File]::ReadAllText($config)).Replace("lease_duration = 86400", "lease_duration = 7200")
    $configBackup = Join-Path $data ".backups\config.toml.pre-smoke.bak"
    New-Item -ItemType Directory -Path (Split-Path -Parent $configBackup) -Force | Out-Null
    Copy-Item -LiteralPath $config -Destination $configBackup
    [IO.File]::WriteAllText($config, $updatedConfig, [Text.UTF8Encoding]::new($false))
    & (Join-Path $root "stop-vnts2-service.ps1") -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    & (Join-Path $root "start-vnts2-service.ps1") -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    Assert-Smoke ((& (Join-Path $root "status-vnts2-service.ps1") -ServiceName $serviceName).State -eq "Running") "配置更新后重启失败。"
    $diagnostics = @(& (Join-Path $root "diagnose-vnts2-service.ps1") -ServiceName $serviceName)
    Assert-Smoke (@($diagnostics | Where-Object Status -eq "FAIL").Count -eq 0) "真实分发诊断存在 FAIL。"

    try {
        $consoleProcess = Start-Process -FilePath $console -ArgumentList @(
            "--silent",
            "--service-name=$serviceName",
            "--api-port=$webPort",
            "--tunnel-port=$tcpPort"
        ) -PassThru
        Start-Sleep -Seconds 5
        $consoleProcess.Refresh()
        Assert-Smoke (-not $consoleProcess.HasExited) "真实分发增强控制台启动后提前退出。"
        $mainWindow = $consoleProcess.MainWindowHandle
        Assert-Smoke (
            $mainWindow -eq [IntPtr]::Zero -or
            -not [Vnts2ConsoleSmokeNativeMethods]::IsWindowVisible($mainWindow)
        ) "--silent 启动后仍显示主窗口。"
    } finally {
        if ($null -ne $consoleProcess -and -not $consoleProcess.HasExited) {
            Stop-Process -Id $consoleProcess.Id -Force
            $consoleProcess.WaitForExit()
        }
    }

    & (Join-Path $root "stop-vnts2-service.ps1") -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    & (Join-Path $root "uninstall-vnts2-service.ps1") -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    $installed = $false
    Assert-Smoke (-not (& (Join-Path $root "status-vnts2-service.ps1") -ServiceName $serviceName).Installed) "真实分发服务卸载后仍存在。"

    [pscustomobject]@{
        Result = "PASS"
        Package = Split-Path -Leaf $root
        DashboardVersion = $dashboard.data.server.version
        HostMemoryBytes = [long]$dashboard.data.host.memory_total_bytes
        ConsoleStarted = $true
        SilentTrayStartup = $true
        ConfigRestarted = $true
        ServiceUninstalled = $true
    }
} finally {
    if ($null -ne $consoleProcess -and -not $consoleProcess.HasExited) {
        Stop-Process -Id $consoleProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($installed -and (Test-Path -LiteralPath $temporaryRoot -PathType Container)) {
        $rootCandidate = @(Get-ChildItem -LiteralPath $temporaryRoot -Directory | Select-Object -First 1)
        if ($rootCandidate.Count -eq 1) {
            & (Join-Path $rootCandidate[0].FullName "uninstall-vnts2-service.ps1") `
                -ServiceName $serviceName `
                -TimeoutSeconds 30 | Out-Null
        }
    }
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot).TrimEnd('\', '/')
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
        $safe = $resolved.StartsWith($tempBase + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -like "vnts2-console-distribution-smoke-*"
        if (-not $safe) { throw "拒绝清理边界以外的烟雾目录：$resolved" }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
