$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Contract {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$deployRoot = Split-Path -Parent $PSScriptRoot
$scripts = @(
    "vnts2-service-common.ps1",
    "initialize-vnts2-console.ps1",
    "install-vnts2-service.ps1",
    "update-vnts2-service.ps1",
    "uninstall-vnts2-service.ps1",
    "start-vnts2-service.ps1",
    "stop-vnts2-service.ps1",
    "status-vnts2-service.ps1",
    "diagnose-vnts2-service.ps1",
    "vnts2-manager.ps1",
    "build-vnts2-manager-exe.ps1",
    "build-vnts2-windows-package.ps1",
    "build-vnts2-console-package.ps1",
    "tests\windows-gui-manager.Tests.ps1",
    "tests\windows-native-gui-manager.Tests.ps1",
    "tests\windows-package-build.Tests.ps1",
    "tests\windows-console-package.Tests.ps1",
    "tests\windows-console-distribution-smoke.ps1",
    "tests\windows-console-zero-install-smoke.ps1",
    "tests\windows-service-e2e.Tests.ps1"
)

foreach ($script in $scripts) {
    $path = Join-Path $deployRoot $script
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$parseErrors
    )
    Assert-Contract ($parseErrors.Count -eq 0) "$script 存在 PowerShell 语法错误。"
}

. (Join-Path $deployRoot "vnts2-service-common.ps1")

$binaryPath = Get-Vnts2ServiceBinaryPath `
    -ExecutablePath "C:\Portable\VNTS2\vnts2.exe" `
    -ConfigPath "C:\Portable\VNTS2\data\config.toml" `
    -ServiceName "vnts2"
Assert-Contract `
    ($binaryPath -eq '"C:\Portable\VNTS2\vnts2.exe" --service --service-name "vnts2" --conf "C:\Portable\VNTS2\data\config.toml"') `
    "服务启动命令没有完整引用可执行文件和配置路径。"
Assert-Contract `
    (Test-Vnts2ServiceBinaryPath -Actual $binaryPath.ToUpperInvariant() -Expected $binaryPath) `
    "服务启动路径比较应忽略 Windows 路径大小写。"
Assert-Contract `
    (Test-Vnts2ServiceBinaryPath -Actual $binaryPath.Replace('"', '""') -Expected $binaryPath) `
    "服务启动路径比较应兼容旧脚本产生的双重引号。"
Assert-Contract `
    (Test-Vnts2ServiceBinaryPath `
        -Actual '"C:\Portable\VNTS2\vnts2.exe" --service --conf "C:\Portable\VNTS2\data\config.toml"' `
        -Expected $binaryPath) `
    "默认服务应兼容 6.4.1 以前没有 --service-name 的 ImagePath。"

$customBinaryPath = Get-Vnts2ServiceBinaryPath `
    -ExecutablePath "C:\Temp\VNTS2\vnts2.exe" `
    -ConfigPath "C:\Temp\VNTS2\data\config.toml" `
    -ServiceName "vnts2-contract-test"
$commandInfo = Get-Vnts2ServiceCommandInfo -PathName $customBinaryPath
Assert-Contract ($commandInfo.ServiceName -eq "vnts2-contract-test") "自定义服务名未写入或解析。"
Assert-Contract ($commandInfo.ExecutablePath -eq "C:\Temp\VNTS2\vnts2.exe") "可执行文件路径解析错误。"
Assert-Contract ($commandInfo.ConfigPath -eq "C:\Temp\VNTS2\data\config.toml") "配置文件路径解析错误。"
Assert-Contract (Test-Vnts2PortableServiceCommand -CommandInfo $commandInfo) "便携 data 布局识别失败。"
$layout = Get-Vnts2PortableLayout -RootPath "C:\Temp\VNTS2"
Assert-Contract ($layout.DataPath -eq "C:\Temp\VNTS2\data") "便携 data 路径计算错误。"
Assert-Contract ($layout.ConfigPath -eq "C:\Temp\VNTS2\data\config.toml") "便携配置路径计算错误。"

$invalidNameRejected = $false
try {
    Assert-Vnts2ServiceName -ServiceName "vnts2'; delete service"
} catch {
    $invalidNameRejected = $true
}
Assert-Contract $invalidNameRejected "危险服务名未被拒绝。"

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("vnts2-acl-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $temporaryDirectory "vnts2.exe") -Value "test"
    $dataDirectory = Join-Path $temporaryDirectory "data"
    New-Item -ItemType Directory -Path $dataDirectory | Out-Null
    $testConfig = Join-Path $dataDirectory "config.toml"
    @'
tcp_bind = "127.0.0.1:31001"
web_bind = "127.0.0.1:31002"
password = "must-not-leak"
server_token = "must-not-leak-either"
'@ | Set-Content -LiteralPath $testConfig -Encoding UTF8
    $bindings = @(Get-Vnts2ConfigBindEndpoints -ConfigPath $testConfig)
    $bindingText = $bindings | ConvertTo-Json -Compress
    Assert-Contract ($bindings.Count -eq 2) "诊断只应提取允许的 bind 配置。"
    Assert-Contract (-not $bindingText.Contains("must-not-leak")) "诊断输出泄露了敏感配置。"

    $temporaryLayout = Initialize-Vnts2PortableDirectories -RootPath $temporaryDirectory
    Assert-Contract ($temporaryLayout.ConfigPath -eq $testConfig) "初始化返回了错误的配置路径。"

    $allowedSids = @(
        "S-1-5-18",
        "S-1-5-32-544"
    )
    foreach ($protectedPath in @($temporaryDirectory, $dataDirectory)) {
        $acl = Get-Acl -LiteralPath $protectedPath
        Assert-Contract $acl.AreAccessRulesProtected "$protectedPath 仍继承上级目录权限。"
        $actualSids = @($acl.Access | ForEach-Object {
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        })
        foreach ($sid in $allowedSids) {
            Assert-Contract ($actualSids -contains $sid) "$protectedPath 缺少 $sid 的访问规则。"
        }
        Assert-Contract `
            (@($actualSids | Where-Object { $_ -notin $allowedSids }).Count -eq 0) `
            "$protectedPath 包含 SYSTEM/Administrators 以外的访问规则。"
    }
} finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

$installSource = Get-Content -Raw -LiteralPath (Join-Path $deployRoot "install-vnts2-service.ps1")
$uninstallSource = Get-Content -Raw -LiteralPath (Join-Path $deployRoot "uninstall-vnts2-service.ps1")
$updateSource = Get-Content -Raw -LiteralPath (Join-Path $deployRoot "update-vnts2-service.ps1")
$startSource = Get-Content -Raw -LiteralPath (Join-Path $deployRoot "start-vnts2-service.ps1")
$stopSource = Get-Content -Raw -LiteralPath (Join-Path $deployRoot "stop-vnts2-service.ps1")
$diagnoseSource = Get-Content -Raw -LiteralPath (Join-Path $deployRoot "diagnose-vnts2-service.ps1")
$initializeSource = Get-Content -Raw -LiteralPath (Join-Path $deployRoot "initialize-vnts2-console.ps1")
Assert-Contract ($installSource.Contains("Test-Vnts2ServiceBinaryPath")) "安装脚本缺少幂等路径校验。"
Assert-Contract ($installSource.Contains("Initialize-Vnts2PortableDirectories")) "安装脚本缺少便携目录初始化。"
Assert-Contract ($installSource.Contains("Set-Vnts2ServiceConfiguration")) "安装脚本缺少 ImagePath 规范化。"
Assert-Contract ($updateSource.Contains("[IO.File]::Replace")) "更新脚本缺少同卷原子替换。"
Assert-Contract ($updateSource.Contains("CurrentSHA256")) "更新脚本缺少当前程序哈希记录。"
Assert-Contract ($updateSource.Contains("BackupPath")) "更新脚本缺少旧程序备份记录。"
Assert-Contract ($updateSource.Contains("PathName = `$originalPathName")) "更新失败时未恢复原 ImagePath。"
Assert-Contract ($updateSource.Contains("MigrateExistingData")) "更新脚本缺少显式 data 迁移开关。"
Assert-Contract ($updateSource.Contains("Merge-Vnts2MigrationDirectory")) "更新脚本缺少日志和备份目录安全合并。"
Assert-Contract ($updateSource.Contains("同名不同内容")) "更新脚本缺少迁移冲突拒绝语义。"
Assert-Contract ($uninstallSource.Contains("Wait-Vnts2ServiceDeleted")) "卸载脚本缺少删除完成等待。"
Assert-Contract ($startSource.Contains("Wait-Vnts2ServiceStatus")) "启动脚本缺少确定状态等待。"
Assert-Contract ($stopSource.Contains("Wait-Vnts2ServiceStatus")) "停止脚本缺少确定状态等待。"
Assert-Contract (-not $stopSource.Contains("-Force")) "停止脚本不应强制终止服务。"
Assert-Contract ($diagnoseSource.Contains("Get-Vnts2ConfigBindEndpoints")) "诊断脚本缺少脱敏 bind 检查。"
Assert-Contract ($initializeSource.Contains('RandomNumberGenerator')) "增强控制台首次配置缺少随机临时密码。"
Assert-Contract ($initializeSource.Contains('.console-initial-setup-required')) "增强控制台初始化缺少首次设置标记。"
Assert-Contract (-not $initializeSource.Contains('password = "VNTS"')) "增强控制台不得写入可预测默认 API 密码。"
Assert-Contract ($initializeSource.Contains('web_bind = "127.0.0.1:$ApiPort"')) "增强控制台首次 API 未限制为回环地址。"
Assert-Contract ($initializeSource.Contains('[string]$ServiceName = "vnts2-console"')) "增强控制台未使用独立默认服务名。"
Assert-Contract ($initializeSource.Contains('[int]$ApiPort = 39871')) "增强控制台首次 API 未使用独立默认端口。"
Assert-Contract ($initializeSource.Contains('[int]$TunnelPort = 39872')) "增强控制台隧道未使用独立默认端口。"
Assert-Contract ($initializeSource.Contains('$wireGuardPort = 41195')) "增强控制台未使用独立 WireGuard 默认端口。"
Assert-Contract ($initializeSource.Contains('wireguard_master_key_file = "wireguard-master.key"')) "增强控制台首次配置缺少 WireGuard 主密钥。"
Assert-Contract ($initializeSource.Contains('wireguard_public_endpoint = "${wireGuardHost}:$wireGuardPort"')) "增强控制台首次配置缺少自动外部访问地址。"
Assert-Contract ($initializeSource.Contains("if (-not (Test-Path -LiteralPath `$layout.ConfigPath")) "增强控制台初始化缺少已有配置保护。"
Assert-Contract ($initializeSource.Contains("不会静默覆盖或迁移现有服务")) "增强控制台初始化缺少异路径同名服务冲突保护。"
foreach ($source in @($installSource, $uninstallSource, $updateSource, $startSource, $stopSource)) {
    Assert-Contract (-not $source.Contains("ProgramData\\VNTS2")) "便携运维脚本不应硬编码 ProgramData。"
}

$missingServiceName = "vnts2-contract-missing-$PID"
$missingStatus = & (Join-Path $deployRoot "status-vnts2-service.ps1") -ServiceName $missingServiceName
Assert-Contract (-not $missingStatus.Installed) "不存在的服务应返回 NotInstalled 状态。"
Assert-Contract (-not $missingStatus.PortableLayout) "未安装服务不应报告为便携布局。"

Write-Host "Windows 服务运维脚本契约测试通过。"
