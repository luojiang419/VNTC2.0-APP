param(
    [string]$ServiceName = "vnts2-console",
    [string]$TargetDir = $PSScriptRoot,
    [int]$ApiPort = 39871,
    [int]$TunnelPort = 39872
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$wireGuardPort = 41195

$commonScript = Join-Path $PSScriptRoot "vnts2-service-common.ps1"
$installScript = Join-Path $PSScriptRoot "install-vnts2-service.ps1"
foreach ($requiredScript in @($commonScript, $installScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "缺少增强控制台初始化依赖：$requiredScript"
    }
}
. $commonScript

Assert-Vnts2Administrator
Assert-Vnts2ServiceName -ServiceName $ServiceName

foreach ($port in @($ApiPort, $TunnelPort, $wireGuardPort)) {
    if ($port -lt 1 -or $port -gt 65535) {
        throw "增强控制台端口必须在 1-65535 范围内。"
    }
}
if ($ApiPort -eq $TunnelPort -or $ApiPort -eq $wireGuardPort -or $TunnelPort -eq $wireGuardPort) {
    throw "管理 API、隧道监听和 WireGuard UDP 端口不能重复。"
}

function Get-WireGuardPublicHost {
    $fallback = $null
    try {
        foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($adapter.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up -or
                $adapter.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Loopback -or
                $adapter.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Tunnel) {
                continue
            }
            $properties = $adapter.GetIPProperties()
            foreach ($item in $properties.UnicastAddresses) {
                $address = $item.Address
                if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
                    [Net.IPAddress]::IsLoopback($address)) {
                    continue
                }
                $bytes = $address.GetAddressBytes()
                if (($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or
                    ($bytes[0] -eq 198 -and ($bytes[1] -eq 18 -or $bytes[1] -eq 19))) {
                    continue
                }
                if ($null -eq $fallback) { $fallback = $address.ToString() }
                $ipv4Gateways = @($properties.GatewayAddresses | Where-Object {
                    $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
                    -not $_.Address.Equals([Net.IPAddress]::Any)
                })
                if ($ipv4Gateways.Count -gt 0) { return $address.ToString() }
            }
        }
    }
    catch [Net.NetworkInformation.NetworkInformationException] {
        # 无可用网卡信息时继续使用主机名或回环地址。
    }
    if ($null -ne $fallback) { return $fallback }
    $hostName = [Net.Dns]::GetHostName().Trim()
    if ($hostName -match '^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$') {
        return $hostName
    }
    return "127.0.0.1"
}

$resolvedTarget = (Resolve-Path -LiteralPath $TargetDir).Path
$layout = Get-Vnts2PortableLayout -RootPath $resolvedTarget
if (-not (Test-Path -LiteralPath $layout.ExecutablePath -PathType Leaf)) {
    throw "增强版发布目录缺少 vnts2.exe：$($layout.ExecutablePath)"
}

$layout = Initialize-Vnts2PortableDirectories -RootPath $resolvedTarget
$expectedBinaryPath = Get-Vnts2ServiceBinaryPath `
    -ExecutablePath $layout.ExecutablePath `
    -ConfigPath $layout.ConfigPath `
    -ServiceName $ServiceName
$existingService = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
if ($null -ne $existingService -and
    -not (Test-Vnts2ServiceBinaryPath -Actual $existingService.PathName -Expected $expectedBinaryPath)) {
    throw "Windows 服务 $ServiceName 已指向其他部署目录；增强控制台不会静默覆盖或迁移现有服务。"
}

$configCreated = $false
$setupMarker = Join-Path $layout.DataPath ".console-initial-setup-required"
if (-not (Test-Path -LiteralPath $layout.ConfigPath -PathType Leaf)) {
    $randomBytes = New-Object byte[] 24
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($randomBytes)
    }
    finally {
        $random.Dispose()
    }
    $bootstrapPassword = [Convert]::ToBase64String($randomBytes).TrimEnd('=')
    $wireGuardHost = Get-WireGuardPublicHost
    $wireGuardKeyPath = Join-Path $layout.DataPath "wireguard-master.key"
    $wireGuardKeyCreated = $false
    if (Test-Path -LiteralPath $wireGuardKeyPath -PathType Leaf) {
        if ((Get-Item -LiteralPath $wireGuardKeyPath).Length -ne 32) {
            throw "WireGuard 主密钥文件必须是 32 字节：$wireGuardKeyPath"
        }
    }
    else {
        $wireGuardKey = New-Object byte[] 32
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $random.GetBytes($wireGuardKey)
            $stream = [IO.File]::Open(
                $wireGuardKeyPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            try {
                $stream.Write($wireGuardKey, 0, $wireGuardKey.Length)
                $stream.Flush($true)
            }
            finally {
                $stream.Dispose()
            }
            $wireGuardKeyCreated = $true
        }
        finally {
            $random.Dispose()
        }
    }
    $configText = @"
tcp_bind = "0.0.0.0:$TunnelPort"
quic_bind = "0.0.0.0:$TunnelPort"
ws_bind = "0.0.0.0:$TunnelPort"
network = "10.26.0.0/24"
white_list = []
lease_duration = 86400
web_bind = "127.0.0.1:$ApiPort"
username = "bootstrap-admin"
password = "$bootstrapPassword"
persistence = true
wireguard_master_key_file = "wireguard-master.key"
wireguard_bind = "0.0.0.0:$wireGuardPort"
wireguard_public_endpoint = "${wireGuardHost}:$wireGuardPort"
wireguard_max_active_peers = 4096
peer_servers = []

[custom_nets]
"@
    try {
        [IO.File]::WriteAllText(
            $layout.ConfigPath,
            $configText,
            [Text.UTF8Encoding]::new($false)
        )
    }
    catch {
        if ($wireGuardKeyCreated -and (Test-Path -LiteralPath $wireGuardKeyPath -PathType Leaf)) {
            Remove-Item -LiteralPath $wireGuardKeyPath -Force
        }
        throw
    }
    [IO.File]::WriteAllText(
        $setupMarker,
        "setup-required`r`n",
        [Text.UTF8Encoding]::new($false)
    )
    $configCreated = $true
}

& $installScript `
    -ServiceName $ServiceName `
    -DisplayName "VNTS 2.0 Enhanced Service" `
    -TargetDir $resolvedTarget | Out-Null

$service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
$bindings = @(Get-Vnts2ConfigBindEndpoints -ConfigPath $layout.ConfigPath)
$webBinding = @($bindings | Where-Object Name -eq "web_bind" | Select-Object -First 1)

[pscustomobject]@{
    Ready = $service.State -eq "Running"
    Installed = $true
    State = $service.State
    ProcessId = [int]$service.ProcessId
    PortableLayout = $true
    ConfigCreated = $configCreated
    InitialSetupRequired = (Test-Path -LiteralPath $setupMarker -PathType Leaf)
    ApiEndpoint = if ($webBinding.Count -eq 1) { $webBinding[0].Endpoint } else { $null }
    DataPath = $layout.DataPath
}
