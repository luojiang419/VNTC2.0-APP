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
        $tcp = $null
        $udp = $null
        try {
            $tcp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
            $tcp.Start()
            $udp = [Net.Sockets.UdpClient]::new($port)
            return $port
        }
        catch {
            continue
        }
        finally {
            if ($null -ne $tcp) { $tcp.Stop() }
            if ($null -ne $udp) { $udp.Dispose() }
        }
    }
    throw "无法分配同时可用的 TCP/UDP 测试端口。"
}

$resolvedZip = (Resolve-Path -LiteralPath $ZipPath).Path
$temporaryRoot = Join-Path $env:TEMP ("vnts2-console-zero-install-" + [Guid]::NewGuid().ToString("N"))
$serviceName = "vnts2-console-auto-" + [Guid]::NewGuid().ToString("N").Substring(0, 10)
$apiPort = Get-FreeTcpPort
$tunnelPort = Get-FreeDualTransportPort
while ($tunnelPort -eq $apiPort -or $tunnelPort -eq 41195) { $tunnelPort = Get-FreeDualTransportPort }
$consoleProcess = $null
$installed = $false
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($resolvedZip, $temporaryRoot)
    $roots = @(Get-ChildItem -LiteralPath $temporaryRoot -Directory)
    Assert-Smoke ($roots.Count -eq 1) "增强 ZIP 必须只有一个顶层目录。"
    $root = $roots[0].FullName
    $console = Join-Path $root "VNTS2-Console.exe"
    $config = Join-Path $root "data\config.toml"
    $wireGuardKey = Join-Path $root "data\wireguard-master.key"
    $setupMarker = Join-Path $root "data\.console-initial-setup-required"
    Assert-Smoke (-not (Test-Path -LiteralPath $config)) "全新增强包不应预置 data/config.toml。"
    Assert-Smoke (Test-Path -LiteralPath (Join-Path $root "initialize-vnts2-console.ps1") -PathType Leaf) "增强包缺少自动初始化脚本。"

    $consoleProcess = Start-Process `
        -FilePath $console `
        -ArgumentList @(
            "--service-name=$serviceName",
            "--api-port=$apiPort",
            "--tunnel-port=$tunnelPort"
        ) `
        -WorkingDirectory $root `
        -WindowStyle Hidden `
        -PassThru

    $deadline = (Get-Date).AddSeconds(45)
    $status = $null
    do {
        if ($consoleProcess.HasExited) {
            throw "增强控制台在自动初始化完成前退出（代码 $($consoleProcess.ExitCode)）。"
        }
        $status = & (Join-Path $root "status-vnts2-service.ps1") -ServiceName $serviceName
        if ($status.Installed) { $installed = $true }
        if ($status.State -eq "Running" -and (Test-Path -LiteralPath $config -PathType Leaf)) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    Assert-Smoke $installed "增强控制台未自动安装 Windows 服务。"
    Assert-Smoke ($status.State -eq "Running") "增强控制台未自动启动 Windows 服务。"
    Assert-Smoke $status.PortableLayout "自动安装的服务未使用便携 data 布局。"
    $configText = [IO.File]::ReadAllText($config)
    Assert-Smoke ($configText.Contains("web_bind = `"127.0.0.1:$apiPort`"")) "首次 API 未绑定指定回环端口。"
    Assert-Smoke ($configText.Contains('username = "bootstrap-admin"')) "首次设置临时用户名错误。"
    Assert-Smoke ($configText.Contains('wireguard_master_key_file = "wireguard-master.key"')) "首次设置未启用 WireGuard。"
    Assert-Smoke ($configText.Contains('wireguard_bind = "0.0.0.0:41195"')) "增强版 WireGuard 默认端口错误。"
    $wireGuardEndpointMatch = [regex]::Match($configText, '(?m)^wireguard_public_endpoint\s*=\s*"([^"\s]+):41195"\s*$')
    Assert-Smoke $wireGuardEndpointMatch.Success "首次设置未生成 WireGuard 外部访问地址。"
    Assert-Smoke (-not ($wireGuardEndpointMatch.Groups[1].Value -match '^198\.(18|19)\.')) "增强版误选了代理基准测试网段作为外部访问地址。"
    Assert-Smoke (Test-Path -LiteralPath $wireGuardKey -PathType Leaf) "首次设置未创建 WireGuard 主密钥。"
    Assert-Smoke ((Get-Item -LiteralPath $wireGuardKey).Length -eq 32) "WireGuard 主密钥不是 32 字节。"
    Assert-Smoke (Test-Path -LiteralPath $setupMarker -PathType Leaf) "首次设置标记不存在。"
    $passwordMatch = [regex]::Match($configText, '(?m)^password\s*=\s*"([^"]+)"\s*$')
    Assert-Smoke $passwordMatch.Success "首次设置临时密码不存在。"
    $bootstrapPassword = $passwordMatch.Groups[1].Value
    Assert-Smoke ($bootstrapPassword -ne "VNTS") "首次设置不得使用可预测默认密码。"

    $defaultBody = @{ username = "bootstrap-admin"; password = $bootstrapPassword } | ConvertTo-Json -Compress
    $login = Invoke-RestMethod `
        -Uri ("http://127.0.0.1:{0}/api/login" -f $apiPort) `
        -Method Post `
        -ContentType "application/json" `
        -Body $defaultBody `
        -SessionVariable defaultSession `
        -TimeoutSec 10
    Assert-Smoke ($login.code -eq 200) "首次设置临时凭据无法登录。"
    Assert-Smoke (-not [string]::IsNullOrWhiteSpace($login.data.token)) "首次登录未返回 API Token。"
    $apiHeaders = @{ Authorization = "Bearer $($login.data.token)" }
    $dashboard = Invoke-RestMethod `
        -Uri ("http://127.0.0.1:{0}/api/dashboard/snapshot" -f $apiPort) `
        -WebSession $defaultSession `
        -TimeoutSec 10
    Assert-Smoke ($dashboard.code -eq 200) "自动初始化后的 dashboard 不可用。"
    Assert-Smoke $dashboard.data.listeners.wireguard_udp "自动初始化后 WireGuard UDP 未运行。"

    $networkBody = @{
        network_code = "zero-install-wireguard"
        gateway = "10.46.0.1"
        netmask = 24
        lease_duration = 86400
    } | ConvertTo-Json -Compress
    $network = Invoke-RestMethod `
        -Uri ("http://127.0.0.1:{0}/api/networks" -f $apiPort) `
        -Method Post `
        -ContentType "application/json" `
        -Body $networkBody `
        -Headers $apiHeaders `
        -TimeoutSec 10
    Assert-Smoke ($network.code -eq 200) "自动初始化后创建 WireGuard 测试网络失败。"
    $peerBody = @{ network_code = "zero-install-wireguard"; peer_id = "zero-install-peer" } | ConvertTo-Json -Compress
    $generated = Invoke-RestMethod `
        -Uri ("http://127.0.0.1:{0}/api/wireguard/peers/generated" -f $apiPort) `
        -Method Post `
        -ContentType "application/json" `
        -Body $peerBody `
        -Headers $apiHeaders `
        -TimeoutSec 10
    Assert-Smoke ($generated.code -eq 200) "默认 WireGuard 配置无法生成客户端配置。"
    Assert-Smoke ($generated.data.endpoint.EndsWith(":41195")) "生成的客户端配置未使用增强版默认 WireGuard 端点。"
    Assert-Smoke (-not [string]::IsNullOrWhiteSpace($generated.data.private_key)) "生成的客户端配置缺少私钥。"

    $changedUsername = "admin"
    $changedPassword = "x"
    $backupDirectory = Join-Path $root "data\.backups"
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $backupPath = Join-Path $backupDirectory "config.toml.pre-zero-install-smoke.bak"
    Copy-Item -LiteralPath $config -Destination $backupPath
    $updatedConfig = $configText.Replace('username = "bootstrap-admin"', "username = `"$changedUsername`"")
    $updatedConfig = [regex]::Replace(
        $updatedConfig,
        '(?m)^password\s*=\s*"[^"]+"\s*$',
        "password = `"$changedPassword`""
    )
    [IO.File]::WriteAllText($config, $updatedConfig, [Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $setupMarker -Force
    & (Join-Path $root "stop-vnts2-service.ps1") -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    & (Join-Path $root "start-vnts2-service.ps1") -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null

    $oldLogin = Invoke-WebRequest `
        -Uri ("http://127.0.0.1:{0}/api/login" -f $apiPort) `
        -Method Post `
        -ContentType "application/json" `
        -Body $defaultBody `
        -SkipHttpErrorCheck `
        -TimeoutSec 10
    Assert-Smoke ([int]$oldLogin.StatusCode -eq 401) "完成首次设置后临时凭据仍可登录。"
    $changedBody = @{ username = $changedUsername; password = $changedPassword } | ConvertTo-Json -Compress
    $changedLogin = Invoke-RestMethod `
        -Uri ("http://127.0.0.1:{0}/api/login" -f $apiPort) `
        -Method Post `
        -ContentType "application/json" `
        -Body $changedBody `
        -TimeoutSec 10
    Assert-Smoke ($changedLogin.code -eq 200) "短 API 密码无法登录。"
    Assert-Smoke (-not (Test-Path -LiteralPath $setupMarker)) "完成首次设置后标记未删除。"
    Assert-Smoke (Test-Path -LiteralPath $backupPath -PathType Leaf) "密码修改前配置备份不存在。"

    & (Join-Path $root "uninstall-vnts2-service.ps1") -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    $installed = $false
    [pscustomobject]@{
        Result = "PASS"
        AutoInstalled = $true
        AutoStarted = $true
        InitialSetupRequired = $true
        WireGuardReady = $true
        WireGuardClientGenerated = $true
        PasswordChanged = $true
        ShortPasswordAccepted = $true
        OldPasswordRejected = $true
        ServiceUninstalled = $true
    }
}
finally {
    if ($null -ne $consoleProcess -and -not $consoleProcess.HasExited) {
        Stop-Process -Id $consoleProcess.Id -Force -ErrorAction SilentlyContinue
        $consoleProcess.WaitForExit()
    }
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
            (Split-Path -Leaf $resolved) -like "vnts2-console-zero-install-*"
        if (-not $safe) { throw "拒绝清理边界外的测试目录：$resolved" }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
