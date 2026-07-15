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

function Get-FreeDualTransportPort {
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        $port = Get-Random -Minimum 20000 -Maximum 45000
        if ($port -eq 41194) { continue }
        $tcp = $null
        $udp = $null
        try {
            $tcp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
            $tcp.Start()
            $udp = [Net.Sockets.UdpClient]::new($port)
            return $port
        }
        catch { continue }
        finally {
            if ($null -ne $tcp) { $tcp.Stop() }
            if ($null -ne $udp) { $udp.Dispose() }
        }
    }
    throw "无法分配同时可用的 TCP/UDP 测试端口。"
}

if (@(Get-NetUDPEndpoint -LocalPort 41194 -ErrorAction SilentlyContinue).Count -gt 0) {
    throw "轻量版默认 WireGuard UDP 端口 41194 已被占用，拒绝干扰现有服务。"
}

$resolvedZip = (Resolve-Path -LiteralPath $ZipPath).Path
$temporaryRoot = Join-Path $env:TEMP ("vnts2-light-wireguard-" + [Guid]::NewGuid().ToString("N"))
$serviceName = "vnts2-light-wg-" + [Guid]::NewGuid().ToString("N").Substring(0, 10)
$apiPort = Get-FreeTcpPort
$tunnelPort = Get-FreeDualTransportPort
$installed = $false
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($resolvedZip, $temporaryRoot)
    $roots = @(Get-ChildItem -LiteralPath $temporaryRoot -Directory)
    Assert-Smoke ($roots.Count -eq 1) "轻量 ZIP 必须只有一个顶层目录。"
    $root = $roots[0].FullName
    $manager = Join-Path $root "VNTS2-Manager.exe"
    $data = Join-Path $root "data"
    $config = Join-Path $data "config.toml"
    $key = Join-Path $data "wireguard-master.key"
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    $password = [Convert]::ToBase64String([Guid]::NewGuid().ToByteArray())
    $configText = @"
tcp_bind = "127.0.0.1:$tunnelPort"
quic_bind = "127.0.0.1:$tunnelPort"
ws_bind = "127.0.0.1:$tunnelPort"
network = "10.26.0.0/24"
white_list = []
lease_duration = 86400
web_bind = "127.0.0.1:$apiPort"
username = "admin"
password = "$password"
persistence = true
wireguard_master_key_file = "wireguard-master.key"
wireguard_bind = "0.0.0.0:41194"
wireguard_public_endpoint = "127.0.0.1:41194"
wireguard_max_active_peers = 4096
peer_servers = []

[custom_nets]
light-wireguard = "10.47.0.0/24"
"@
    [IO.File]::WriteAllText($config, $configText, [Text.UTF8Encoding]::new($false))
    $resultPath = Join-Path $data "manager-result.json"
    $managerProcess = Start-Process `
        -FilePath $manager `
        -ArgumentList @("--config-roundtrip-check", "`"$config`"", "`"$resultPath`"") `
        -Wait `
        -PassThru
    Assert-Smoke ($managerProcess.ExitCode -eq 0) "轻量 GUI 无法保存默认 WireGuard 配置。"
    Assert-Smoke (Test-Path -LiteralPath $key -PathType Leaf) "轻量 GUI 未创建 WireGuard 主密钥。"
    Assert-Smoke ((Get-Item -LiteralPath $key).Length -eq 32) "轻量版 WireGuard 主密钥不是 32 字节。"

    & (Join-Path $root "install-vnts2-service.ps1") `
        -ServiceName $serviceName `
        -DisplayName "VNTS2 Light WireGuard Smoke" `
        -TargetDir $root `
        -SkipStart | Out-Null
    $installed = $true
    & (Join-Path $root "start-vnts2-service.ps1") -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    $status = & (Join-Path $root "status-vnts2-service.ps1") -ServiceName $serviceName
    Assert-Smoke ($status.State -eq "Running") "轻量版默认 WireGuard 配置下服务未进入 Running。"
    Assert-Smoke $status.PortableLayout "轻量版服务未使用自身 data。"

    $loginBody = @{ username = "admin"; password = $password } | ConvertTo-Json -Compress
    $login = Invoke-RestMethod `
        -Uri ("http://127.0.0.1:{0}/api/login" -f $apiPort) `
        -Method Post `
        -ContentType "application/json" `
        -Body $loginBody `
        -TimeoutSec 10
    $headers = @{ Authorization = "Bearer $($login.data.token)" }
    $dashboard = Invoke-RestMethod `
        -Uri ("http://127.0.0.1:{0}/api/dashboard/snapshot" -f $apiPort) `
        -Headers $headers `
        -TimeoutSec 10
    Assert-Smoke $dashboard.data.listeners.wireguard_udp "轻量版 WireGuard UDP 未运行。"

    $peerBody = @{ network_code = "light-wireguard"; peer_id = "light-smoke-peer" } | ConvertTo-Json -Compress
    $generated = Invoke-RestMethod `
        -Uri ("http://127.0.0.1:{0}/api/wireguard/peers/generated" -f $apiPort) `
        -Method Post `
        -ContentType "application/json" `
        -Body $peerBody `
        -Headers $headers `
        -TimeoutSec 10
    Assert-Smoke ($generated.code -eq 200) "轻量版默认 WireGuard 配置无法生成客户端配置。"
    Assert-Smoke ($generated.data.endpoint -eq "127.0.0.1:41194") "轻量版客户端配置端点错误。"
    Assert-Smoke (-not [string]::IsNullOrWhiteSpace($generated.data.private_key)) "轻量版客户端配置缺少私钥。"

    & (Join-Path $root "uninstall-vnts2-service.ps1") -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    $installed = $false
    [pscustomobject]@{
        Result = "PASS"
        AutoKeyCreated = $true
        ServiceStarted = $true
        WireGuardReady = $true
        WireGuardClientGenerated = $true
        ServiceUninstalled = $true
    }
}
finally {
    if ($installed -and (Test-Path -LiteralPath $temporaryRoot -PathType Container)) {
        $rootCandidate = @(Get-ChildItem -LiteralPath $temporaryRoot -Directory | Select-Object -First 1)
        if ($rootCandidate.Count -eq 1) {
            & (Join-Path $rootCandidate[0].FullName "uninstall-vnts2-service.ps1") `
                -ServiceName $serviceName `
                -TimeoutSeconds 30 `
                -ErrorAction SilentlyContinue | Out-Null
        }
    }
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot).TrimEnd('\', '/')
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
        $safe = $resolved.StartsWith($tempBase + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -like "vnts2-light-wireguard-*"
        if (-not $safe) { throw "拒绝清理边界外的测试目录：$resolved" }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
