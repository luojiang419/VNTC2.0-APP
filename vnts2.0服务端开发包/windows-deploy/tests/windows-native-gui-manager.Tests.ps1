$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Contract {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

$deployRoot = Split-Path -Parent $PSScriptRoot
$exePath = Join-Path $deployRoot "VNTS2-Manager.exe"
$sourcePath = Join-Path $deployRoot "gui\Vnts2Manager.cs"
$manifestPath = Join-Path $deployRoot "gui\VNTS2-Manager.manifest"
$iconPath = Join-Path $deployRoot "gui\VNTS2-Manager.ico"
$buildPath = Join-Path $deployRoot "build-vnts2-manager-exe.ps1"

foreach ($path in @($exePath, $sourcePath, $manifestPath, $iconPath, $buildPath)) {
    Assert-Contract (Test-Path -LiteralPath $path -PathType Leaf) "原生 GUI 文件不存在：$path"
}

$bytes = [IO.File]::ReadAllBytes($exePath)
Assert-Contract ($bytes.Length -gt 1024) "原生 GUI EXE 体积异常。"
Assert-Contract ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) "原生 GUI 不是 PE 可执行文件。"
$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
Assert-Contract ([BitConverter]::ToUInt32($bytes, $peOffset) -eq 0x00004550) "PE 签名错误。"
Assert-Contract ([BitConverter]::ToUInt16($bytes, $peOffset + 4) -eq 0x8664) "原生 GUI 应为 x64。"
$optionalHeader = $peOffset + 24
Assert-Contract ([BitConverter]::ToUInt16($bytes, $optionalHeader + 68) -eq 2) "原生 GUI PE Subsystem 应为 Windows GUI。"

$version = [Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)
Assert-Contract ($version.FileVersion -eq "2.0.0.0") "原生 GUI 文件版本错误。"
Assert-Contract ($version.ProductName -eq "VNTS 2.0") "原生 GUI 产品名称错误。"
$iconBytes = [IO.File]::ReadAllBytes($iconPath)
Assert-Contract ($iconBytes.Length -gt 4096) "应用图标体积异常。"
Assert-Contract ($iconBytes[0] -eq 0 -and $iconBytes[1] -eq 0 -and $iconBytes[2] -eq 1 -and $iconBytes[3] -eq 0) "应用图标不是有效的 ICO 文件。"
$embeddedIcon = [Drawing.Icon]::ExtractAssociatedIcon($exePath)
Assert-Contract ($null -ne $embeddedIcon) "原生 GUI EXE 未嵌入应用图标。"
$embeddedIcon.Dispose()

$validationPath = Join-Path $env:TEMP ("vnts2-native-gui-test-{0}.json" -f [Guid]::NewGuid().ToString("N"))
try {
    $process = Start-Process -FilePath $exePath -ArgumentList @("--validate-only", "`"$validationPath`"") -Wait -PassThru
    Assert-Contract ($process.ExitCode -eq 0) "原生 GUI 验证模式退出码错误。"
    $model = Get-Content -LiteralPath $validationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Contract ($model.Implementation -eq "CSharpWinForms") "正式 GUI 不是 C# WinForms。"
    Assert-Contract $model.ExecutableGui "正式 GUI 未声明 EXE 窗口入口。"
    Assert-Contract (-not $model.UsesPowerShellGui) "正式 GUI 仍依赖 PowerShell 窗口。"
    Assert-Contract ($model.ActionCount -eq 9) "原生 GUI 应提供 9 项操作。"
    Assert-Contract ($model.Actions -contains "网络管理") "原生 GUI 缺少网络管理入口。"
    Assert-Contract ($model.Actions -contains "刷新日志") "原生 GUI 缺少运行日志刷新入口。"
    Assert-Contract ($model.DefaultTheme -eq "Dark") "原生 GUI 默认主题应为深色。"
    Assert-Contract $model.ThemeToggle "原生 GUI 未声明浅色/深色主题切换。"
    Assert-Contract $model.NativeDarkTitleBar "原生 GUI 未声明原生深灰标题栏。"
    Assert-Contract $model.EmbeddedApplicationIcon "原生 GUI 未声明嵌入应用图标。"
    Assert-Contract $model.TraySupport "原生 GUI 未声明托盘驻留能力。"
    Assert-Contract $model.SingleInstance "原生 GUI 未声明单实例能力。"
    Assert-Contract (-not $model.CrossEditionSingleInstance) "轻量版不应阻止独立增强版运行。"
    Assert-Contract $model.IndependentEdition "轻量版未声明版本隔离能力。"
    Assert-Contract ($model.SingleInstanceMutexName -eq "Local\VNTS2.Manager.SingleInstance.v1") "原生 GUI 单实例互斥锁名称不符合约定。"
    Assert-Contract ($model.ActivationEventName -eq "Local\VNTS2.Manager.Activate.v1") "原生 GUI 唤醒事件名称不符合约定。"
    Assert-Contract ($model.DefaultCloseBehavior -eq "MinimizeToTray") "默认关闭行为应为最小化到托盘。"
    Assert-Contract ($model.CloseBehaviors -contains "StopServiceAndExit") "原生 GUI 缺少关闭服务并退出行为。"
    Assert-Contract ($model.StartupBehaviors -contains "Normal") "原生 GUI 缺少普通开机自启行为。"
    Assert-Contract ($model.StartupBehaviors -contains "SilentToTray") "原生 GUI 缺少静默托盘自启行为。"
    Assert-Contract ($model.StartupTaskName -eq "VNTS2-Manager-Autostart") "原生 GUI 开机自启任务名不符合约定。"
    Assert-Contract ($model.SilentStartArgument -eq "--silent") "原生 GUI 静默启动参数不符合约定。"
    Assert-Contract $model.StructuredConfigDialog "原生 GUI 未声明结构化配置弹窗。"
    Assert-Contract (-not $model.TextEditorConfig) "原生 GUI 仍声明使用文本编辑器修改配置。"
    Assert-Contract ($model.ConfigSections.Count -eq 5) "结构化配置弹窗应提供 5 个设置分区。"
    Assert-Contract ($model.ConfigDialogFontSize -eq 10.5) "配置弹窗基础字体应为 10.5pt。"
    Assert-Contract ($model.ConfigInputFontSize -eq 11.0) "配置输入字体应为 11pt。"
    Assert-Contract ($model.ConfigInputHeight -eq 36) "配置输入框高度应为 36px。"
    Assert-Contract $model.ConfigAdaptiveLayout "配置弹窗未声明自适应宽度布局。"
    Assert-Contract ($model.RuntimeLogRelativePath -eq "data\logs\vnts2.log") "原生 GUI 运行日志路径约定错误。"
} finally {
    if (Test-Path -LiteralPath $validationPath -PathType Leaf) {
        Remove-Item -LiteralPath $validationPath -Force
    }
}

$preferencesDirectory = Join-Path $env:TEMP ("vnts2-native-preferences-{0}" -f [Guid]::NewGuid().ToString("N"))
$preferencesPath = Join-Path $preferencesDirectory "gui-settings.json"
$preferencesResultPath = Join-Path $preferencesDirectory "result.json"
try {
    New-Item -ItemType Directory -Path $preferencesDirectory -Force | Out-Null
    [IO.File]::WriteAllText($preferencesPath, '{"quic_endpoint":"127.0.0.1:29872","theme":"light"}', [Text.UTF8Encoding]::new($false))
    $process = Start-Process -FilePath $exePath -ArgumentList @(
        "--desktop-preferences-check",
        "`"$preferencesPath`"",
        "`"$preferencesResultPath`""
    ) -Wait -PassThru
    Assert-Contract ($process.ExitCode -eq 0) "桌面行为偏好往返验证失败。"
    $result = Get-Content -LiteralPath $preferencesResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $saved = Get-Content -LiteralPath $preferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Contract ($result.CloseBehavior -eq "stop_service_and_exit") "默认关闭行为未正确往返。"
    Assert-Contract ($result.StartupBehavior -eq "silent") "静默开机自启行为未正确往返。"
    Assert-Contract ($result.NormalTaskCommand -notmatch '--silent') "普通开机自启命令不应包含静默参数。"
    Assert-Contract ($result.SilentTaskCommand -match '--silent$') "静默开机自启命令缺少 --silent。"
    Assert-Contract ($saved.theme -eq "light") "保存桌面行为时覆盖了既有主题。"
    Assert-Contract ($saved.quic_endpoint -eq "127.0.0.1:29872") "保存桌面行为时覆盖了既有 QUIC 地址。"
} finally {
    if (Test-Path -LiteralPath $preferencesDirectory) {
        Remove-Item -LiteralPath $preferencesDirectory -Recurse -Force
    }
}

$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
foreach ($script in @(
    "install-vnts2-service.ps1",
    "update-vnts2-service.ps1",
    "start-vnts2-service.ps1",
    "stop-vnts2-service.ps1",
    "status-vnts2-service.ps1",
    "diagnose-vnts2-service.ps1",
    "uninstall-vnts2-service.ps1"
)) {
    Assert-Contract ($source.Contains($script)) "原生 GUI 未委托 $script。"
}
Assert-Contract ($source.Contains("CreateNoWindow = true")) "后台 PowerShell 未隐藏窗口。"
Assert-Contract (-not $source.Contains("vnts2-manager.ps1")) "原生 EXE 不应启动 PowerShell GUI。"
Assert-Contract ($source.Contains('args[0] == "--status-only"')) "原生 EXE 缺少无窗口状态契约入口。"
Assert-Contract ($source.Contains('args[0] == "--enable-web-only"')) "原生 EXE 缺少 Web 启用端到端测试入口。"
Assert-Contract ($source.Contains('args[0] == "--network-api-check"')) "原生 EXE 缺少网络管理接口测试入口。"
Assert-Contract ($source.Contains('args[0] == "--desktop-preferences-check"')) "原生 EXE 缺少桌面行为偏好测试入口。"
Assert-Contract ($source.Contains('class NetworkManagerForm')) "原生 GUI 缺少网络管理窗口。"
Assert-Contract ($source.Contains('class NetworkEditorForm')) "原生 GUI 缺少新增和编辑网络窗口。"
Assert-Contract ($source.Contains('class LocalApiClient')) "原生 GUI 缺少本地 API 客户端。"
Assert-Contract ($source.Contains('copyQuic')) "网络列表缺少逐行复制 QUIC 操作。"
Assert-Contract ($source.Contains('copyCode')) "网络列表缺少逐行复制组网编号操作。"
Assert-Contract ($source.Contains('copyAll')) "网络列表缺少逐行复制完整连接信息操作。"
Assert-Contract ($source.Contains('gui-settings.json')) "QUIC 共享地址未存储在便携 data 目录。"
Assert-Contract ($source.Contains('request.Proxy = null')) "本地 API 请求不应经过系统代理。"
Assert-Contract ($source.Contains('WebConsoleManager.ValidateLoopbackEndpoint(endpoint)')) "本地 API 客户端缺少回环地址限制。"
Assert-Contract ($source.Contains('class ThemeManager')) "原生 GUI 缺少统一主题管理器。"
Assert-Contract ($source.Contains('class NativeTitleBar')) "原生 GUI 缺少原生标题栏主题管理器。"
Assert-Contract ($source.Contains('DwmSetWindowAttribute')) "原生 GUI 未调用 DWM 标题栏接口。"
Assert-Contract ($source.Contains('private const int CaptionColor = 35')) "原生 GUI 未设置标题栏背景色。"
Assert-Contract ($source.Contains('private const int TextColor = 36')) "原生 GUI 未设置标题栏文字颜色。"
Assert-Contract ($source.Contains('NativeTitleBar.Apply(form, dark, palette)')) "主题切换未同步原生标题栏。"
Assert-Contract ($source.Contains('class ApplicationIcon')) "原生 GUI 缺少统一应用图标加载器。"
Assert-Contract ($source.Contains('Icon = ApplicationIcon.Load()')) "窗口未使用嵌入的统一应用图标。"
Assert-Contract (-not $source.Contains('SystemIcons.Shield')) "主窗口仍在使用旧盾牌图标。"
Assert-Contract ($source.Contains('class ConfigSettingsForm')) "原生 GUI 缺少结构化配置弹窗。"
Assert-Contract ($source.Contains('class ConfigFileEditor')) "原生 GUI 缺少配置读写组件。"
Assert-Contract ($source.Contains('ConfigFileEditor.Load(path)')) "配置按钮未加载结构化配置模型。"
Assert-Contract ($source.Contains('ConfigFileEditor.Save(path, form.Settings)')) "配置弹窗未安全保存设置。"
Assert-Contract ($source.Contains('config.toml.pre-gui-')) "结构化配置保存缺少时间戳备份。"
Assert-Contract ($source.Contains('File.Replace(temporaryPath, path, backupPath, true)')) "结构化配置未使用原子替换。"
Assert-Contract ($source.Contains('保存并重启')) "结构化配置弹窗缺少保存应用操作。"
Assert-Contract (-not $source.Contains('ProcessStartInfo("notepad.exe"')) "编辑配置仍会启动记事本。"
Assert-Contract ($source.Contains('ClientSize = new Size(960, 800)')) "配置弹窗默认尺寸未扩大。"
Assert-Contract ($source.Contains('Font = new Font("Microsoft YaHei UI", 10.5F)')) "配置页标签字体未放大。"
Assert-Contract ($source.Contains('Font = new Font("Segoe UI", 11F)')) "配置输入框字体未放大。"
Assert-Contract ($source.Contains('Size = new Size(670, 36)')) "配置输入框高度未增加。"
Assert-Contract ($source.Contains('private readonly TextBox leaseBox')) "IP 租期仍使用会裁切文字的数字微调框。"
Assert-Contract ($source.Contains('private readonly TextBox wireGuardMaxBox')) "最大 Peer 仍使用会裁切文字的数字微调框。"
Assert-Contract ($source.Contains('RestrictToDigits(leaseBox)')) "IP 租期输入缺少纯数字限制。"
Assert-Contract ($source.Contains('ParseUnsigned(leaseBox.Text')) "IP 租期输入缺少范围校验。"
Assert-Contract ($source.Contains('FitToRight(parent, box, 24)')) "普通配置输入框未随页面宽度自适应。"
Assert-Contract ($source.Contains('FitSecretRow(parent, box, generateButton, 24)')) "密码配置行未随页面宽度自适应。"
Assert-Contract ($source.Contains('切换浅色')) "原生 GUI 缺少右上角浅色主题按钮。"
Assert-Contract ($source.Contains('切换深色')) "原生 GUI 缺少深色主题切换语义。"
Assert-Contract ($source.Contains('GuiSettingsManager.SaveTheme')) "主题选择未写入便携 GUI 设置。"
Assert-Contract ($source.Contains('class ManagerPreferencesForm')) "原生 GUI 缺少桌面与启动偏好设置页。"
Assert-Contract ($source.Contains('NotifyIcon trayIcon')) "原生 GUI 缺少系统托盘图标。"
Assert-Contract ($source.Contains('class SingleInstanceGuard')) "原生 GUI 缺少单实例锁组件。"
Assert-Contract ($source.Contains('new Mutex(true, MutexName, out createdNew)')) "原生 GUI 未原子获取命名互斥锁。"
Assert-Contract ($source.Contains('EventWaitHandle.OpenExisting(ActivationEventName)')) "原生 GUI 未通过命名事件唤醒已有实例。"
Assert-Contract ($source.Contains('ThreadPool.RegisterWaitForSingleObject')) "原生 GUI 主窗口未监听跨进程唤醒事件。"
Assert-Contract ($source.Contains('FormClosing += async delegate')) "原生 GUI 未接管窗口关闭行为。"
Assert-Contract ($source.Contains('MinimizeToTray(true)')) "原生 GUI 缺少最小化到托盘行为。"
Assert-Contract ($source.Contains('StopServiceAndExit()')) "原生 GUI 缺少关闭服务并退出行为。"
Assert-Contract ($source.Contains('class StartupTaskManager')) "原生 GUI 缺少开机自启任务管理器。"
Assert-Contract ($source.Contains('"/SC", "ONLOGON", "/RL", "HIGHEST"')) "开机自启未使用登录触发的最高权限计划任务。"
Assert-Contract ($source.Contains('" --silent"')) "原生 GUI 缺少静默自启命令参数。"
Assert-Contract ($source.Contains('public string close_behavior')) "GUI 设置未持久化默认关闭行为。"
Assert-Contract ($source.Contains('public string startup_behavior')) "GUI 设置未持久化开机自启行为。"
Assert-Contract ($source.Contains('class RuntimeLogReader')) "原生 GUI 缺少运行日志尾部读取器。"
Assert-Contract ($source.Contains('FileShare.ReadWrite | FileShare.Delete')) "运行日志读取未兼容服务进程占用。"
Assert-Contract ($source.Contains('RichTextBox runtimeLogBox')) "运行日志未使用支持级别着色的 RichTextBox。"
Assert-Contract ($source.Contains('ERROR')) "运行日志缺少错误级别着色规则。"
Assert-Contract ($source.Contains('WARN')) "运行日志缺少警告级别着色规则。"
Assert-Contract ($source.Contains('new System.Windows.Forms.Timer { Interval = 2000 }')) "运行日志缺少定时自动刷新。"
Assert-Contract (-not $source.Contains('Text = "操作输出"')) "主界面仍显示旧的操作输出标题。"
Assert-Contract ($source.Contains('RNGCryptoServiceProvider')) "Web 控制台密码未使用加密安全随机数。"
Assert-Contract ($source.Contains('File.Replace(temporaryPath, status.ConfigPath, backupPath, true)')) "Web 配置未使用带备份的原子替换。"
Assert-Contract ($source.Contains('Web 管理端必须使用回环地址')) "Web 控制台缺少回环地址限制。"
Assert-Contract ($source.Contains('config.toml.pre-web-')) "Web 配置缺少独立备份。"
Assert-Contract ($source.Contains('复制密码')) "原生 GUI 缺少安全凭据展示。"
Assert-Contract (-not $source.Contains('Log(settings.Password')) "Web 密码不得写入 GUI 操作日志。"
Assert-Contract (-not $source.Contains('password.Length >= 12')) "原生 GUI 仍限制 API 密码至少 12 位。"
Assert-Contract ($source.Contains('Web 管理密码不能为空')) "原生 GUI 缺少非空密码校验。"
Assert-Contract ($source.Contains('private string PortableDataPath')) "原生 GUI 缺少同级 data 路径模型。"
Assert-Contract ($source.Contains('private bool EnsurePortableConfig()')) "原生 GUI 缺少首次安装自动初始化。"
Assert-Contract ($source.Contains('" -MigrateExistingData"')) "原生 GUI 未显式授权迁移已有服务。"
Assert-Contract ($source.Contains('"迁移并启动服务"')) "原生 GUI 缺少迁移按钮语义。"
Assert-Contract ($source.Contains('{ "DataPath", status.DataPath }')) "原生 GUI 状态契约缺少 DataPath。"
Assert-Contract ($source.Contains('{ "PortableLayout", status.PortableLayout }')) "原生 GUI 状态契约缺少 PortableLayout。"
Assert-Contract ($source.Contains('internal const string Bind = "0.0.0.0:41194"')) "轻量版缺少独立 WireGuard 默认端口。"
Assert-Contract ($source.Contains('EnsureDefaultMasterKey')) "轻量版缺少 WireGuard 主密钥自动创建。"

$manifest = Get-Content -LiteralPath $manifestPath -Raw
Assert-Contract ($manifest.Contains('level="requireAdministrator"')) "原生 GUI 缺少管理员清单。"
$build = Get-Content -LiteralPath $buildPath -Raw
Assert-Contract ($build.Contains('/target:winexe')) "构建脚本未使用 Windows GUI 子系统。"
Assert-Contract ($build.Contains('/platform:x64')) "构建脚本未固定 x64。"
Assert-Contract ($build.Contains('/win32icon:$buildIcon')) "构建脚本未嵌入应用图标。"
Assert-Contract ($build.Contains('vnts2-manager-build-')) "构建脚本缺少中文路径兼容的临时构建目录。"

$configTestRoot = Join-Path $env:TEMP ("vnts2-config-editor-test-" + [Guid]::NewGuid().ToString("N"))
$configTestPath = Join-Path $configTestRoot "config.toml"
$configResultPath = Join-Path $configTestRoot "result.json"
New-Item -ItemType Directory -Path $configTestRoot | Out-Null
try {
    $configFixture = @'
tcp_bind = "0.0.0.0:29872"
quic_bind = "0.0.0.0:29872"
ws_bind = "0.0.0.0:29872"
network = "10.26.0.0/24"
white_list = ["alpha#one", "branch\\office"]
lease_duration = 86400
persistence = true
web_bind = "127.0.0.1:29871"
username = "admin"
password = "x"
wireguard_master_key_file = "keys\\wg-master.key"
wireguard_bind = "0.0.0.0:51820"
wireguard_public_endpoint = "vpn.example.com:51820"
wireguard_max_active_peers = 4096
server_quic_bind = "0.0.0.0:29873"
peer_servers = ["192.168.100.3:29873"]
server_token = "server-token-strong-2026"
future_option = "keep#future" # unknown root option

[custom_nets]
branch = "10.88.0.0/24"
'@
    [IO.File]::WriteAllText($configTestPath, $configFixture, [Text.UTF8Encoding]::new($false))
    $configProcess = Start-Process `
        -FilePath $exePath `
        -ArgumentList @("--config-roundtrip-check", "`"$configTestPath`"", "`"$configResultPath`"") `
        -Wait `
        -PassThru
    Assert-Contract ($configProcess.ExitCode -eq 0) "结构化配置往返检查失败。"
    $configResult = Get-Content -LiteralPath $configResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $savedConfig = Get-Content -LiteralPath $configTestPath -Raw -Encoding UTF8
    Assert-Contract $configResult.StructuredEditor "配置往返检查未使用结构化编辑器。"
    Assert-Contract (Test-Path -LiteralPath $configResult.BackupPath -PathType Leaf) "结构化配置保存未生成备份。"
    Assert-Contract ($savedConfig.Contains('future_option = "keep#future" # unknown root option')) "未知根配置项未保留。"
    Assert-Contract ($savedConfig.Contains('[custom_nets]')) "自定义网络区段未保留。"
    Assert-Contract ($savedConfig.Contains('branch = "10.88.0.0/24"')) "自定义网络内容未保留。"
    Assert-Contract ($savedConfig.Contains('password = "x"')) "短 API 密码未被结构化配置保留。"
    Assert-Contract ($savedConfig.Contains('wireguard_master_key_file = "keys\\wg-master.key"')) "Windows 路径转义被破坏。"

    $defaultRoot = Join-Path $configTestRoot "wireguard-default"
    $defaultConfigPath = Join-Path $defaultRoot "config.toml"
    $defaultResultPath = Join-Path $defaultRoot "result.json"
    New-Item -ItemType Directory -Path $defaultRoot | Out-Null
    $defaultFixture = @'
tcp_bind = "0.0.0.0:29872"
network = "10.26.0.0/24"
white_list = []
lease_duration = 86400
persistence = true
wireguard_master_key_file = "wireguard-master.key"
wireguard_bind = "0.0.0.0:41194"
wireguard_public_endpoint = "127.0.0.1:41194"
wireguard_max_active_peers = 4096

[custom_nets]
'@
    [IO.File]::WriteAllText($defaultConfigPath, $defaultFixture, [Text.UTF8Encoding]::new($false))
    $defaultProcess = Start-Process `
        -FilePath $exePath `
        -ArgumentList @("--config-roundtrip-check", "`"$defaultConfigPath`"", "`"$defaultResultPath`"") `
        -Wait `
        -PassThru
    Assert-Contract ($defaultProcess.ExitCode -eq 0) "WireGuard 默认配置保存失败。"
    $defaultResult = Get-Content -LiteralPath $defaultResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $defaultKeyPath = Join-Path $defaultRoot "wireguard-master.key"
    Assert-Contract ($defaultResult.WireGuardBind -eq "0.0.0.0:41194") "轻量版 WireGuard 默认端口错误。"
    Assert-Contract (Test-Path -LiteralPath $defaultKeyPath -PathType Leaf) "轻量版未自动创建 WireGuard 主密钥。"
    Assert-Contract ((Get-Item -LiteralPath $defaultKeyPath).Length -eq 32) "轻量版 WireGuard 主密钥不是 32 字节。"

    $missingEndpointRoot = Join-Path $configTestRoot "wireguard-missing-endpoint"
    $missingEndpointConfig = Join-Path $missingEndpointRoot "config.toml"
    $missingEndpointResult = Join-Path $missingEndpointRoot "result.json"
    New-Item -ItemType Directory -Path $missingEndpointRoot | Out-Null
    [IO.File]::WriteAllText(
        $missingEndpointConfig,
        $defaultFixture.Replace('wireguard_public_endpoint = "127.0.0.1:41194"', ''),
        [Text.UTF8Encoding]::new($false)
    )
    $missingEndpointProcess = Start-Process `
        -FilePath $exePath `
        -ArgumentList @("--config-roundtrip-check", "`"$missingEndpointConfig`"", "`"$missingEndpointResult`"") `
        -Wait `
        -PassThru
    Assert-Contract ($missingEndpointProcess.ExitCode -eq 0) "WireGuard 缺失外部访问地址时未自动补齐默认值。"
    $filledEndpointResult = Get-Content -LiteralPath $missingEndpointResult -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Contract ($filledEndpointResult.WireGuardPublicEndpoint.EndsWith(":41194")) "轻量版未补齐 WireGuard 默认外部访问地址。"
    Assert-Contract (-not ($filledEndpointResult.WireGuardPublicEndpoint -match '^198\.(18|19)\.')) "轻量版误选了代理基准测试网段作为外部访问地址。"
    Assert-Contract ((Get-Content -LiteralPath $missingEndpointConfig -Raw -Encoding UTF8).Contains('wireguard_public_endpoint = "')) "补齐的 WireGuard 外部访问地址未保存。"
    Assert-Contract ((Get-Item -LiteralPath (Join-Path $missingEndpointRoot "wireguard-master.key")).Length -eq 32) "补齐旧配置时未创建有效 WireGuard 主密钥。"

    $invalidRoot = Join-Path $configTestRoot "invalid"
    $invalidConfigPath = Join-Path $invalidRoot "config.toml"
    $invalidResultPath = Join-Path $invalidRoot "result.txt"
    New-Item -ItemType Directory -Path $invalidRoot | Out-Null
    $invalidFixture = @'
tcp_bind = "invalid-listener"
network = "10.26.0.0/24"
white_list = []
lease_duration = 86400
persistence = true
wireguard_max_active_peers = 4096

[custom_nets]
'@
    [IO.File]::WriteAllText($invalidConfigPath, $invalidFixture, [Text.UTF8Encoding]::new($false))
    $invalidProcess = Start-Process `
        -FilePath $exePath `
        -ArgumentList @("--config-roundtrip-check", "`"$invalidConfigPath`"", "`"$invalidResultPath`"") `
        -Wait `
        -PassThru
    Assert-Contract ($invalidProcess.ExitCode -eq 2) "无效监听地址未被结构化配置校验拒绝。"
    Assert-Contract ((Get-Content -LiteralPath $invalidResultPath -Raw).Contains("TCP 监听格式无效")) "无效配置未返回明确校验信息。"
    Assert-Contract ((Get-Content -LiteralPath $invalidConfigPath -Raw -Encoding UTF8) -eq $invalidFixture) "无效配置被意外写入。"
    Assert-Contract (-not (Test-Path -LiteralPath (Join-Path $invalidRoot ".backups") -PathType Container)) "无效配置不应生成保存备份。"
} finally {
    if (Test-Path -LiteralPath $configTestRoot -PathType Container) {
        Remove-Item -LiteralPath $configTestRoot -Recurse -Force
    }
}

Write-Host "Windows 原生 GUI EXE 契约测试通过。"
