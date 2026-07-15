Set-StrictMode -Version Latest

function Assert-Vnts2Windows {
    if ($env:OS -ne "Windows_NT") {
        throw "VNTS2 Windows 服务脚本只能在 Windows 上运行。"
    }
}

function Assert-Vnts2Administrator {
    Assert-Vnts2Windows

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "请使用管理员 PowerShell 运行 VNTS2 Windows 服务脚本。"
    }
}

function Assert-Vnts2ServiceName {
    param([Parameter(Mandatory = $true)][string]$ServiceName)

    if ($ServiceName -notmatch '^[A-Za-z0-9_.-]{1,80}$') {
        throw "服务名只能包含字母、数字、点、下划线和连字符，且长度不能超过 80。"
    }
}

function Get-Vnts2PortableLayout {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    if ([string]::IsNullOrWhiteSpace($RootPath) -or $RootPath.Contains('"')) {
        throw "便携部署根目录不能为空，也不能包含双引号。"
    }

    $root = [IO.Path]::GetFullPath($RootPath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $data = Join-Path $root "data"
    [pscustomobject]@{
        RootPath = $root
        ExecutablePath = Join-Path $root "vnts2.exe"
        ManagerPath = Join-Path $root "VNTS2-Manager.exe"
        ConfigTemplatePath = Join-Path $root "config.example.toml"
        DataPath = $data
        ConfigPath = Join-Path $data "config.toml"
        LogsPath = Join-Path $data "logs"
        BackupsPath = Join-Path $data ".backups"
    }
}

function Test-Vnts2PortableServiceCommand {
    param([Parameter(Mandatory = $true)]$CommandInfo)

    if ([string]::IsNullOrWhiteSpace($CommandInfo.ExecutablePath) -or
        [string]::IsNullOrWhiteSpace($CommandInfo.ConfigPath)) {
        return $false
    }

    $root = Split-Path -Parent ([IO.Path]::GetFullPath($CommandInfo.ExecutablePath))
    $layout = Get-Vnts2PortableLayout -RootPath $root
    return [string]::Equals(
        [IO.Path]::GetFullPath($CommandInfo.ConfigPath),
        $layout.ConfigPath,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-Vnts2ServiceBinaryPath {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [string]$ServiceName = "vnts2"
    )

    Assert-Vnts2ServiceName -ServiceName $ServiceName
    if ($ExecutablePath.Contains('"') -or $ConfigPath.Contains('"') -or $ServiceName.Contains('"')) {
        throw "可执行文件、配置文件路径和服务名不能包含双引号。"
    }

    return '"{0}" --service --service-name "{1}" --conf "{2}"' -f `
        $ExecutablePath, $ServiceName, $ConfigPath
}

function ConvertTo-Vnts2CanonicalServiceBinaryPath {
    param([Parameter(Mandatory = $true)][string]$PathName)

    $canonical = $PathName.Trim().Replace('""', '"')
    return $canonical -replace '(?i)--service\s+--conf', '--service --service-name "vnts2" --conf'
}

function Test-Vnts2ServiceBinaryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    $canonicalActual = ConvertTo-Vnts2CanonicalServiceBinaryPath -PathName $Actual
    $canonicalExpected = ConvertTo-Vnts2CanonicalServiceBinaryPath -PathName $Expected
    return [string]::Equals(
        $canonicalActual,
        $canonicalExpected,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-Vnts2ServiceCommandInfo {
    param([Parameter(Mandatory = $true)][string]$PathName)

    $canonical = ConvertTo-Vnts2CanonicalServiceBinaryPath -PathName $PathName
    $pattern = '^\s*"(?<ExecutablePath>[^"]+)"\s+--service\s+--service-name\s+"(?<ServiceName>[^"]+)"\s+--conf\s+"(?<ConfigPath>[^"]+)"\s*$'
    $match = [regex]::Match($canonical, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return $null
    }

    return [pscustomobject]@{
        ExecutablePath = $match.Groups["ExecutablePath"].Value
        ServiceName = $match.Groups["ServiceName"].Value
        ConfigPath = $match.Groups["ConfigPath"].Value
    }
}

function Get-Vnts2ConfigBindEndpoints {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $allowedNames = @(
        "tcp_bind",
        "quic_bind",
        "ws_bind",
        "web_bind",
        "server_quic_bind",
        "wireguard_bind"
    )
    foreach ($line in Get-Content -LiteralPath $ConfigPath -ErrorAction Stop) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*"([^"]+)"\s*(?:#.*)?$' -and
            $matches[1] -in $allowedNames) {
            [pscustomobject]@{
                Name = $matches[1]
                Endpoint = $matches[2]
            }
        }
    }
}

function Invoke-Vnts2Sc {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $scPath = Join-Path $env:SystemRoot "System32\sc.exe"
    $output = & $scPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $details = ($output | Out-String).Trim()
        throw "sc.exe 执行失败（退出码 $exitCode）：$details"
    }
    return $output
}

function Set-Vnts2ServiceConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string]$BinaryPath
    )

    $service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
    $result = Invoke-CimMethod -InputObject $service -MethodName Change -Arguments @{
        PathName = $BinaryPath
        StartMode = "Automatic"
        ErrorControl = 1
    }
    if ($result.ReturnValue -ne 0) {
        throw "更新 Windows 服务配置失败（Win32_Service.Change 返回 $($result.ReturnValue)）。"
    }
}

function Wait-Vnts2ServiceStatus {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][ValidateSet("Running", "Stopped")][string]$DesiredStatus,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        if ($service.Status.ToString() -eq $DesiredStatus) {
            return $service
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "等待 Windows 服务 $ServiceName 进入 $DesiredStatus 状态超时（${TimeoutSeconds}秒）。"
}

function Wait-Vnts2ServiceDeleted {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if ($null -eq (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
            return
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "等待 Windows 服务 $ServiceName 删除完成超时（${TimeoutSeconds}秒）；可能仍有服务管理器句柄未释放。"
}

function Protect-Vnts2Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $directory = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (-not $directory.PSIsContainer) {
        throw "服务目录不是文件夹：$Path"
    }

    $systemSid = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::LocalSystemSid,
        $null
    )
    $administratorsSid = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
        $null
    )
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow

    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($administratorsSid)
    foreach ($sid in @($systemSid, $administratorsSid)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $directory.FullName -AclObject $acl
}

function Initialize-Vnts2PortableDirectories {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $layout = Get-Vnts2PortableLayout -RootPath $RootPath
    foreach ($path in @($layout.DataPath, $layout.LogsPath, $layout.BackupsPath)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    # LocalSystem 会从根目录加载程序，并在 data 中读写配置、数据库和密钥。
    # 两处都限制为 SYSTEM/Administrators，避免高权限服务被普通用户替换程序。
    Protect-Vnts2Directory -Path $layout.RootPath
    Protect-Vnts2Directory -Path $layout.DataPath
    return $layout
}
