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
$managerPath = Join-Path $deployRoot "vnts2-manager.ps1"
$launcherPath = Join-Path $deployRoot "VNTS2-Manager.cmd"
$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $managerPath,
    [ref]$tokens,
    [ref]$parseErrors
)
Assert-Contract ($parseErrors.Count -eq 0) "GUI 管理器存在 PowerShell 语法错误。"

$model = & $managerPath -ValidateOnly
Assert-Contract ($model.Title -eq "VNTS 2.0 Windows 服务管理器") "GUI 窗口标题错误。"
Assert-Contract ($model.ActionCount -eq 8) "GUI 应提供 8 个快捷操作。"
$expectedActions = @(
    "初始化/编辑配置",
    "一键安装并启动",
    "启动服务",
    "停止服务",
    "运行诊断",
    "打开 Web 控制台",
    "卸载服务",
    "清空输出"
)
Assert-Contract `
    (($model.Actions -join "`n") -ceq ($expectedActions -join "`n")) `
    "GUI 快捷操作顺序或名称错误。"
Assert-Contract ($model.DefaultServiceName -eq "vnts2") "GUI 默认服务名错误。"
Assert-Contract `
    ($model.ExistingDeploymentMode -eq "ExistingDeployment") `
    "GUI 未识别其他目录中的已有服务。"
Assert-Contract `
    ($model.ExistingDeploymentInstallAction -eq "MigrateExistingService") `
    "GUI 未将其他目录中的已有服务转换为显式迁移操作。"
Assert-Contract `
    ($model.DetectedDefaultInstallAction -in @("MigrateExistingService", "InstallCurrentDeployment")) `
    "GUI 默认服务动作与实际服务状态不一致。"
Assert-Contract ($model.PortableDataRelativePath -eq "data") "GUI 便携数据目录不是同级 data。"
Assert-Contract ($model.ConfigPath -eq (Join-Path $deployRoot "data\config.toml")) "GUI 未使用 data 中的配置。"

$source = Get-Content -LiteralPath $managerPath -Raw
foreach ($delegatedScript in @(
    "install-vnts2-service.ps1",
    "update-vnts2-service.ps1",
    "start-vnts2-service.ps1",
    "stop-vnts2-service.ps1",
    "status-vnts2-service.ps1",
    "diagnose-vnts2-service.ps1",
    "uninstall-vnts2-service.ps1"
)) {
    Assert-Contract ($source.Contains($delegatedScript)) "GUI 未委托 $delegatedScript。"
}
Assert-Contract ($source.Contains("Verb RunAs")) "GUI 缺少管理员提权入口。"
Assert-Contract ($source.Contains("config.example.toml")) "GUI 缺少配置模板初始化。"
Assert-Contract ($source.Contains("Get-Vnts2ConfigBindEndpoints")) "GUI 未安全解析 Web 回环地址。"
Assert-Contract ($source.Contains("Get-Vnts2ManagerActiveConfigPath")) "GUI 未使用已注册服务的配置路径。"
Assert-Contract ($source.Contains("Set-Vnts2ManagerStatus -Status `$freshStatus")) "服务名变化后 GUI 未刷新服务上下文。"
Assert-Contract ($source.Contains('"迁移并启动服务"')) "GUI 未提供已有服务安全迁移语义。"
Assert-Contract ($source.Contains('"确认迁移已有服务"')) "GUI 迁移已有服务前缺少明确确认。"
Assert-Contract ($source.Contains("MigrateExistingData")) "GUI 未向迁移事务传递显式授权。"
Assert-Contract ($source.Contains('Join-Path $PSScriptRoot "data"') -or $source.Contains('PortableDataRelativePath = "data"')) "GUI 缺少同级 data 模型。"
Assert-Contract `
    (-not [regex]::IsMatch($source, '(?im)^\s*(?:New-Service|Start-Service|Stop-Service|Remove-Service|sc\.exe)\b')) `
    "GUI 不应直接实现 SCM 写操作。"

$launcher = Get-Content -LiteralPath $launcherPath -Raw
Assert-Contract ($launcher.Contains('%~dp0vnts2-manager.ps1')) "双击启动器没有使用自身目录定位 GUI。"
Assert-Contract ($launcher.Contains('-ExecutionPolicy Bypass')) "双击启动器缺少进程级执行策略参数。"
Assert-Contract ($launcher.Contains('-WindowStyle Hidden')) "双击启动器没有隐藏命令行窗口。"

Write-Host "Windows GUI 服务管理器契约测试通过。"
