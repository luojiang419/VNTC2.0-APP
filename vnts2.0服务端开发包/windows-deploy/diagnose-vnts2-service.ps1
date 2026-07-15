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

$checks = [Collections.Generic.List[object]]::new()
function Add-Vnts2DiagnosticCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet("PASS", "WARN", "FAIL")][string]$Status,
        [Parameter(Mandatory = $true)][string]$Details
    )

    $checks.Add([pscustomobject]@{
        Check = $Name
        Status = $Status
        Details = $Details
    }) | Out-Null
}

$service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
if ($null -eq $service) {
    Add-Vnts2DiagnosticCheck -Name "SCM" -Status "FAIL" -Details "服务未安装。"
    $checks
    throw "Windows 服务 $ServiceName 诊断失败：服务未安装。"
}

Add-Vnts2DiagnosticCheck -Name "SCM" -Status "PASS" -Details (
    "State={0}; StartMode={1}; ProcessId={2}; ExitCode={3}" -f `
        $service.State, $service.StartMode, $service.ProcessId, $service.ExitCode
)

$commandInfo = Get-Vnts2ServiceCommandInfo -PathName $service.PathName
if ($null -eq $commandInfo) {
    Add-Vnts2DiagnosticCheck -Name "ImagePath" -Status "FAIL" -Details "无法解析服务启动命令。"
} else {
    $nameMatches = [string]::Equals(
        $commandInfo.ServiceName,
        $ServiceName,
        [StringComparison]::OrdinalIgnoreCase
    )
    Add-Vnts2DiagnosticCheck `
        -Name "ImagePath" `
        -Status $(if ($nameMatches) { "PASS" } else { "FAIL" }) `
        -Details "Executable=$($commandInfo.ExecutablePath); Config=$($commandInfo.ConfigPath); ServiceName=$($commandInfo.ServiceName)"

    $portableLayout = Test-Vnts2PortableServiceCommand -CommandInfo $commandInfo
    $expectedLayout = Get-Vnts2PortableLayout -RootPath (Split-Path -Parent $commandInfo.ExecutablePath)
    Add-Vnts2DiagnosticCheck `
        -Name "PortableLayout" `
        -Status $(if ($portableLayout) { "PASS" } else { "WARN" }) `
        -Details $(if ($portableLayout) {
            "Root=$($expectedLayout.RootPath); Data=$($expectedLayout.DataPath)"
        } else {
            "当前仍是旧目录布局；期望配置位于 $($expectedLayout.ConfigPath)"
        })
}

$accountOk = $service.StartName -in @("LocalSystem", "NT AUTHORITY\SYSTEM")
Add-Vnts2DiagnosticCheck `
    -Name "ServiceAccount" `
    -Status $(if ($accountOk) { "PASS" } else { "FAIL" }) `
    -Details "StartName=$($service.StartName)"
Add-Vnts2DiagnosticCheck `
    -Name "StartupType" `
    -Status $(if ($service.StartMode -eq "Auto") { "PASS" } else { "WARN" }) `
    -Details "StartMode=$($service.StartMode)"

if ($null -ne $commandInfo) {
    $exeExists = Test-Path -LiteralPath $commandInfo.ExecutablePath -PathType Leaf
    Add-Vnts2DiagnosticCheck `
        -Name "Executable" `
        -Status $(if ($exeExists) { "PASS" } else { "FAIL" }) `
        -Details $(if ($exeExists) {
            $file = Get-Item -LiteralPath $commandInfo.ExecutablePath
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
            "Length=$($file.Length); SHA256=$hash"
        } else {
            "文件不存在：$($commandInfo.ExecutablePath)"
        })

    $configExists = Test-Path -LiteralPath $commandInfo.ConfigPath -PathType Leaf
    Add-Vnts2DiagnosticCheck `
        -Name "Config" `
        -Status $(if ($configExists) { "PASS" } else { "FAIL" }) `
        -Details $(if ($configExists) { "配置文件存在。" } else { "配置文件不存在。" })

    $dataDirectory = Split-Path -Parent $commandInfo.ConfigPath
    $dataDirectoryExists = Test-Path -LiteralPath $dataDirectory -PathType Container
    Add-Vnts2DiagnosticCheck `
        -Name "DataDirectory" `
        -Status $(if ($dataDirectoryExists) { "PASS" } else { "FAIL" }) `
        -Details $(if ($dataDirectoryExists) { "Path=$dataDirectory" } else { "数据目录不存在：$dataDirectory" })

    if ($configExists) {
        try {
            $bindings = @(Get-Vnts2ConfigBindEndpoints -ConfigPath $commandInfo.ConfigPath)
            $bindingDetails = ($bindings | ForEach-Object { "$($_.Name)=$($_.Endpoint)" }) -join "; "
            Add-Vnts2DiagnosticCheck `
                -Name "ConfiguredBindings" `
                -Status $(if ($bindings.Count -gt 0) { "PASS" } else { "WARN" }) `
                -Details $(if ($bindings.Count -gt 0) { $bindingDetails } else { "未发现 bind 配置。" })
        } catch {
            Add-Vnts2DiagnosticCheck -Name "ConfiguredBindings" -Status "FAIL" -Details $_.Exception.Message
        }
    }

    $serviceDirectory = Split-Path -Parent $commandInfo.ExecutablePath
    if (Test-Path -LiteralPath $serviceDirectory -PathType Container) {
        $acl = Get-Acl -LiteralPath $serviceDirectory
        $allowedSids = @("S-1-5-18", "S-1-5-32-544")
        $unexpected = @($acl.Access | Where-Object {
            if ($_.AccessControlType -ne "Allow") {
                return $false
            }
            try {
                $sid = $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
                return $sid -notin $allowedSids
            } catch {
                return $true
            }
        })
        $aclOk = $acl.AreAccessRulesProtected -and $unexpected.Count -eq 0
        Add-Vnts2DiagnosticCheck `
            -Name "RootDirectoryAcl" `
            -Status $(if ($aclOk) { "PASS" } else { "FAIL" }) `
            -Details "InheritanceProtected=$($acl.AreAccessRulesProtected); UnexpectedAllowRules=$($unexpected.Count)"
    }

    if (Test-Path -LiteralPath $dataDirectory -PathType Container) {
        $dataAcl = Get-Acl -LiteralPath $dataDirectory
        $allowedSids = @("S-1-5-18", "S-1-5-32-544")
        $unexpectedDataRules = @($dataAcl.Access | Where-Object {
            if ($_.AccessControlType -ne "Allow") {
                return $false
            }
            try {
                $sid = $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
                return $sid -notin $allowedSids
            } catch {
                return $true
            }
        })
        $dataAclOk = $dataAcl.AreAccessRulesProtected -and $unexpectedDataRules.Count -eq 0
        Add-Vnts2DiagnosticCheck `
            -Name "DataDirectoryAcl" `
            -Status $(if ($dataAclOk) { "PASS" } else { "FAIL" }) `
            -Details "InheritanceProtected=$($dataAcl.AreAccessRulesProtected); UnexpectedAllowRules=$($unexpectedDataRules.Count)"
    }

    $logPath = Join-Path $dataDirectory "logs\vnts2.log"
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $logFile = Get-Item -LiteralPath $logPath
        Add-Vnts2DiagnosticCheck `
            -Name "Log" `
            -Status "PASS" `
            -Details "Length=$($logFile.Length); LastWriteTime=$($logFile.LastWriteTime.ToString('s'))"
    } else {
        Add-Vnts2DiagnosticCheck -Name "Log" -Status "WARN" -Details "日志文件尚不存在。"
    }
}

if ($service.State -eq "Running" -and $service.ProcessId -gt 0) {
    $tcpEndpoints = @(Get-NetTCPConnection -OwningProcess $service.ProcessId -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object { "TCP $($_.LocalAddress):$($_.LocalPort)" })
    $udpEndpoints = @(Get-NetUDPEndpoint -OwningProcess $service.ProcessId -ErrorAction SilentlyContinue |
        ForEach-Object { "UDP $($_.LocalAddress):$($_.LocalPort)" })
    $endpoints = @($tcpEndpoints + $udpEndpoints | Sort-Object -Unique)
    Add-Vnts2DiagnosticCheck `
        -Name "RuntimePorts" `
        -Status $(if ($endpoints.Count -gt 0) { "PASS" } else { "WARN" }) `
        -Details $(if ($endpoints.Count -gt 0) { $endpoints -join "; " } else { "运行进程没有可见监听端口。" })
} else {
    Add-Vnts2DiagnosticCheck -Name "RuntimePorts" -Status "WARN" -Details "服务未运行，跳过实际端口检查。"
}

$failures = @($checks | Where-Object Status -eq "FAIL").Count
$warnings = @($checks | Where-Object Status -eq "WARN").Count
$checks
[pscustomobject]@{
    Check = "Summary"
    Status = if ($failures -gt 0) { "FAIL" } elseif ($warnings -gt 0) { "WARN" } else { "PASS" }
    Details = "Failures=$failures; Warnings=$warnings"
}
if ($failures -gt 0) {
    throw "Windows 服务 $ServiceName 诊断失败：$failures 项失败。"
}
