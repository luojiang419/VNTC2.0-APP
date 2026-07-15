param(
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($env:OS -ne "Windows_NT") {
    throw "VNTS2 Windows 服务管理器只能在 Windows 上运行。"
}

$commonScript = Join-Path $PSScriptRoot "vnts2-service-common.ps1"
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) {
    throw "缺少 Windows 服务共享脚本：$commonScript"
}
. $commonScript

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Test-Vnts2ManagerAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $ValidateOnly -and -not (Test-Vnts2ManagerAdministrator)) {
    $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f `
        $PSCommandPath.Replace('"', '""')
    try {
        Start-Process `
            -FilePath $windowsPowerShell `
            -Verb RunAs `
            -WindowStyle Hidden `
            -ArgumentList $arguments | Out-Null
    } catch {
        [Windows.Forms.MessageBox]::Show(
            "需要管理员权限才能管理 Windows 服务。`r`n`r`n$($_.Exception.Message)",
            "VNTS 2.0 服务管理器",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
    return
}

if (-not $ValidateOnly) {
    Assert-Vnts2Administrator
}

$statusScript = Join-Path $PSScriptRoot "status-vnts2-service.ps1"
$installScript = Join-Path $PSScriptRoot "install-vnts2-service.ps1"
$updateScript = Join-Path $PSScriptRoot "update-vnts2-service.ps1"
$startScript = Join-Path $PSScriptRoot "start-vnts2-service.ps1"
$stopScript = Join-Path $PSScriptRoot "stop-vnts2-service.ps1"
$diagnoseScript = Join-Path $PSScriptRoot "diagnose-vnts2-service.ps1"
$uninstallScript = Join-Path $PSScriptRoot "uninstall-vnts2-service.ps1"
$portableLayout = Get-Vnts2PortableLayout -RootPath $PSScriptRoot
$packageDataPath = $portableLayout.DataPath
$packageConfigPath = $portableLayout.ConfigPath
$packageExecutablePath = Join-Path $PSScriptRoot "vnts2.exe"
$configTemplatePath = Join-Path $PSScriptRoot "config.example.toml"
$script:currentStatus = $null

foreach ($requiredScript in @(
    $statusScript,
    $installScript,
    $updateScript,
    $startScript,
    $stopScript,
    $diagnoseScript,
    $uninstallScript
)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "服务管理器缺少脚本：$requiredScript"
    }
}

[Windows.Forms.Application]::EnableVisualStyles()
$form = [Windows.Forms.Form]::new()
$form.Text = "VNTS 2.0 Windows 服务管理器"
$form.ClientSize = [Drawing.Size]::new(900, 760)
$form.MinimumSize = [Drawing.Size]::new(820, 710)
$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = [Drawing.Font]::new("Microsoft YaHei UI", 9)
$form.Icon = [Drawing.SystemIcons]::Application

$titleLabel = [Windows.Forms.Label]::new()
$titleLabel.Text = "VNTS 2.0 Windows 服务管理器"
$titleLabel.Font = [Drawing.Font]::new("Microsoft YaHei UI", 18, [Drawing.FontStyle]::Bold)
$titleLabel.Location = [Drawing.Point]::new(20, 15)
$titleLabel.Size = [Drawing.Size]::new(840, 40)
$titleLabel.Anchor = "Top, Left, Right"
$form.Controls.Add($titleLabel)

$subtitleLabel = [Windows.Forms.Label]::new()
$subtitleLabel.Text = "安装、运行、诊断服务，并打开内嵌 Web 管理界面"
$subtitleLabel.ForeColor = [Drawing.Color]::DimGray
$subtitleLabel.Location = [Drawing.Point]::new(23, 57)
$subtitleLabel.Size = [Drawing.Size]::new(820, 24)
$subtitleLabel.Anchor = "Top, Left, Right"
$form.Controls.Add($subtitleLabel)

$serviceNameLabel = [Windows.Forms.Label]::new()
$serviceNameLabel.Text = "服务名"
$serviceNameLabel.Location = [Drawing.Point]::new(22, 94)
$serviceNameLabel.Size = [Drawing.Size]::new(75, 25)
$form.Controls.Add($serviceNameLabel)

$serviceNameTextBox = [Windows.Forms.TextBox]::new()
$serviceNameTextBox.Text = "vnts2"
$serviceNameTextBox.Location = [Drawing.Point]::new(100, 90)
$serviceNameTextBox.Size = [Drawing.Size]::new(430, 28)
$serviceNameTextBox.Anchor = "Top, Left, Right"
$form.Controls.Add($serviceNameTextBox)

$refreshButton = [Windows.Forms.Button]::new()
$refreshButton.Text = "刷新状态"
$refreshButton.Location = [Drawing.Point]::new(550, 88)
$refreshButton.Size = [Drawing.Size]::new(120, 32)
$refreshButton.Anchor = "Top, Right"
$form.Controls.Add($refreshButton)

$statusGroup = [Windows.Forms.GroupBox]::new()
$statusGroup.Text = "服务状态"
$statusGroup.Location = [Drawing.Point]::new(20, 135)
$statusGroup.Size = [Drawing.Size]::new(860, 180)
$statusGroup.Anchor = "Top, Left, Right"
$form.Controls.Add($statusGroup)

$stateCaption = [Windows.Forms.Label]::new()
$stateCaption.Text = "当前状态"
$stateCaption.Location = [Drawing.Point]::new(18, 31)
$stateCaption.Size = [Drawing.Size]::new(80, 25)
$statusGroup.Controls.Add($stateCaption)

$stateValue = [Windows.Forms.Label]::new()
$stateValue.Text = "正在读取..."
$stateValue.Font = [Drawing.Font]::new("Microsoft YaHei UI", 11, [Drawing.FontStyle]::Bold)
$stateValue.Location = [Drawing.Point]::new(105, 28)
$stateValue.Size = [Drawing.Size]::new(230, 30)
$statusGroup.Controls.Add($stateValue)

$processCaption = [Windows.Forms.Label]::new()
$processCaption.Text = "进程 ID"
$processCaption.Location = [Drawing.Point]::new(370, 31)
$processCaption.Size = [Drawing.Size]::new(80, 25)
$statusGroup.Controls.Add($processCaption)

$processValue = [Windows.Forms.Label]::new()
$processValue.Text = "-"
$processValue.Location = [Drawing.Point]::new(455, 31)
$processValue.Size = [Drawing.Size]::new(120, 25)
$statusGroup.Controls.Add($processValue)

$accountCaption = [Windows.Forms.Label]::new()
$accountCaption.Text = "运行账户"
$accountCaption.Location = [Drawing.Point]::new(600, 31)
$accountCaption.Size = [Drawing.Size]::new(80, 25)
$statusGroup.Controls.Add($accountCaption)

$accountValue = [Windows.Forms.Label]::new()
$accountValue.Text = "-"
$accountValue.Location = [Drawing.Point]::new(685, 31)
$accountValue.Size = [Drawing.Size]::new(155, 25)
$statusGroup.Controls.Add($accountValue)

$executableCaption = [Windows.Forms.Label]::new()
$executableCaption.Text = "程序路径"
$executableCaption.Location = [Drawing.Point]::new(18, 72)
$executableCaption.Size = [Drawing.Size]::new(80, 25)
$statusGroup.Controls.Add($executableCaption)

$executableValue = [Windows.Forms.Label]::new()
$executableValue.Text = "-"
$executableValue.AutoEllipsis = $true
$executableValue.Location = [Drawing.Point]::new(105, 72)
$executableValue.Size = [Drawing.Size]::new(735, 25)
$executableValue.Anchor = "Top, Left, Right"
$statusGroup.Controls.Add($executableValue)

$configCaption = [Windows.Forms.Label]::new()
$configCaption.Text = "配置路径"
$configCaption.Location = [Drawing.Point]::new(18, 106)
$configCaption.Size = [Drawing.Size]::new(80, 25)
$statusGroup.Controls.Add($configCaption)

$configValue = [Windows.Forms.Label]::new()
$configValue.Text = $packageConfigPath
$configValue.AutoEllipsis = $true
$configValue.Location = [Drawing.Point]::new(105, 106)
$configValue.Size = [Drawing.Size]::new(735, 25)
$configValue.Anchor = "Top, Left, Right"
$statusGroup.Controls.Add($configValue)

$dataCaption = [Windows.Forms.Label]::new()
$dataCaption.Text = "数据目录"
$dataCaption.Location = [Drawing.Point]::new(18, 140)
$dataCaption.Size = [Drawing.Size]::new(80, 25)
$statusGroup.Controls.Add($dataCaption)

$dataValue = [Windows.Forms.Label]::new()
$dataValue.Text = $packageDataPath
$dataValue.AutoEllipsis = $true
$dataValue.Location = [Drawing.Point]::new(105, 140)
$dataValue.Size = [Drawing.Size]::new(735, 25)
$dataValue.Anchor = "Top, Left, Right"
$statusGroup.Controls.Add($dataValue)

$actionsGroup = [Windows.Forms.GroupBox]::new()
$actionsGroup.Text = "快捷操作"
$actionsGroup.Location = [Drawing.Point]::new(20, 330)
$actionsGroup.Size = [Drawing.Size]::new(860, 125)
$actionsGroup.Anchor = "Top, Left, Right"
$form.Controls.Add($actionsGroup)

$actionPanel = [Windows.Forms.FlowLayoutPanel]::new()
$actionPanel.Dock = [Windows.Forms.DockStyle]::Fill
$actionPanel.Padding = [Windows.Forms.Padding]::new(12, 12, 12, 8)
$actionPanel.WrapContents = $true
$actionsGroup.Controls.Add($actionPanel)

function New-Vnts2ManagerButton {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$Width = 128
    )

    $button = [Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.Size = [Drawing.Size]::new($Width, 36)
    $button.Margin = [Windows.Forms.Padding]::new(4)
    $actionPanel.Controls.Add($button)
    return $button
}

$configButton = New-Vnts2ManagerButton -Text "初始化/编辑配置" -Width 145
$installButton = New-Vnts2ManagerButton -Text "一键安装并启动" -Width 145
$startButton = New-Vnts2ManagerButton -Text "启动服务"
$stopButton = New-Vnts2ManagerButton -Text "停止服务"
$diagnoseButton = New-Vnts2ManagerButton -Text "运行诊断"
$webButton = New-Vnts2ManagerButton -Text "打开 Web 控制台" -Width 145
$uninstallButton = New-Vnts2ManagerButton -Text "卸载服务"
$clearButton = New-Vnts2ManagerButton -Text "清空输出"
$actionButtons = @(
    $configButton,
    $installButton,
    $startButton,
    $stopButton,
    $diagnoseButton,
    $webButton,
    $uninstallButton,
    $clearButton
)

$outputLabel = [Windows.Forms.Label]::new()
$outputLabel.Text = "操作输出"
$outputLabel.Location = [Drawing.Point]::new(22, 471)
$outputLabel.Size = [Drawing.Size]::new(100, 25)
$form.Controls.Add($outputLabel)

$outputTextBox = [Windows.Forms.TextBox]::new()
$outputTextBox.Location = [Drawing.Point]::new(20, 498)
$outputTextBox.Size = [Drawing.Size]::new(860, 190)
$outputTextBox.Anchor = "Top, Bottom, Left, Right"
$outputTextBox.Multiline = $true
$outputTextBox.ReadOnly = $true
$outputTextBox.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
$outputTextBox.BackColor = [Drawing.Color]::White
$outputTextBox.Font = [Drawing.Font]::new("Consolas", 9)
$form.Controls.Add($outputTextBox)

$footerLabel = [Windows.Forms.Label]::new()
$footerLabel.Text = "整个目录可快捷迁移；卸载只移除服务注册，data 中的配置、数据库、密钥和日志全部保留。"
$footerLabel.ForeColor = [Drawing.Color]::DimGray
$footerLabel.Location = [Drawing.Point]::new(22, 727)
$footerLabel.Size = [Drawing.Size]::new(840, 24)
$footerLabel.Anchor = "Bottom, Left, Right"
$form.Controls.Add($footerLabel)

function Write-Vnts2ManagerLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [object[]]$Data
    )

    $outputTextBox.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Message`r`n")
    if ($null -ne $Data -and $Data.Count -gt 0) {
        $text = ($Data | Format-List * | Out-String).TrimEnd()
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $outputTextBox.AppendText("$text`r`n")
        }
    }
    $outputTextBox.AppendText("`r`n")
    $outputTextBox.SelectionStart = $outputTextBox.TextLength
    $outputTextBox.ScrollToCaret()
}

function Get-Vnts2ManagerServiceName {
    $serviceName = $serviceNameTextBox.Text.Trim()
    Assert-Vnts2ServiceName -ServiceName $serviceName
    return $serviceName
}

function Get-Vnts2ManagerDeploymentMode {
    param([Parameter(Mandatory = $true)][object]$Status)

    if (-not $Status.Installed) {
        return "NotInstalled"
    }
    if ($null -eq $Status.ExecutablePath -or $null -eq $Status.ConfigPath) {
        return "ExistingDeployment"
    }

    $sameExecutable = [string]::Equals(
        [IO.Path]::GetFullPath($Status.ExecutablePath),
        [IO.Path]::GetFullPath($packageExecutablePath),
        [StringComparison]::OrdinalIgnoreCase
    )
    $sameConfig = [string]::Equals(
        [IO.Path]::GetFullPath($Status.ConfigPath),
        [IO.Path]::GetFullPath($packageConfigPath),
        [StringComparison]::OrdinalIgnoreCase
    )
    if ($sameExecutable -and $sameConfig) {
        return "CurrentDeployment"
    }
    return "ExistingDeployment"
}

function Get-Vnts2ManagerActiveConfigPath {
    $serviceName = Get-Vnts2ManagerServiceName
    if ($null -eq $script:currentStatus -or $script:currentStatus.Name -ne $serviceName) {
        $freshStatus = & $statusScript -ServiceName $serviceName
        Set-Vnts2ManagerStatus -Status $freshStatus
    }
    if ($script:currentStatus.Installed) {
        if ($null -eq $script:currentStatus.ConfigPath) {
            throw "无法从 Windows 服务启动命令解析配置路径，请先运行诊断。"
        }
        return $script:currentStatus.ConfigPath
    }
    return $packageConfigPath
}

function Set-Vnts2ManagerStatus {
    param([Parameter(Mandatory = $true)][object]$Status)

    $script:currentStatus = $Status

    if (-not $Status.Installed) {
        $stateValue.Text = "未安装"
        $stateValue.ForeColor = [Drawing.Color]::DimGray
        $processValue.Text = "-"
        $accountValue.Text = "-"
        $executableValue.Text = "-"
        $configValue.Text = $packageConfigPath
        $dataValue.Text = $packageDataPath
        $configButton.Text = "初始化/编辑配置"
        $installButton.Text = "一键安装并启动"
        return
    }

    $deploymentMode = Get-Vnts2ManagerDeploymentMode -Status $Status
    $stateValue.Text = if ($deploymentMode -eq "ExistingDeployment") {
        "$($Status.State)（待迁移部署）"
    } else {
        $Status.State
    }
    switch ($Status.State) {
        "Running" { $stateValue.ForeColor = [Drawing.Color]::ForestGreen }
        "Stopped" { $stateValue.ForeColor = [Drawing.Color]::DarkOrange }
        default { $stateValue.ForeColor = [Drawing.Color]::RoyalBlue }
    }
    $processValue.Text = if ($Status.ProcessId -gt 0) { [string]$Status.ProcessId } else { "-" }
    $accountValue.Text = if ($null -eq $Status.StartName) { "-" } else { $Status.StartName }
    $executableValue.Text = if ($null -eq $Status.ExecutablePath) { "无法解析" } else { $Status.ExecutablePath }
    $configValue.Text = if ($null -eq $Status.ConfigPath) { "无法解析" } else { $Status.ConfigPath }
    $dataValue.Text = if ($null -eq $Status.DataPath) { "无法解析" } else { $Status.DataPath }
    $configButton.Text = "编辑已安装配置"
    $installButton.Text = if ($deploymentMode -eq "ExistingDeployment") {
        "迁移并启动服务"
    } else {
        "校验安装并启动"
    }
}

function Update-Vnts2ManagerStatus {
    param([switch]$Silent)

    try {
        $serviceName = Get-Vnts2ManagerServiceName
        $status = & $statusScript -ServiceName $serviceName
        Set-Vnts2ManagerStatus -Status $status
        if (-not $Silent) {
            Write-Vnts2ManagerLog -Message "状态已刷新。" -Data @($status)
        }
    } catch {
        if (-not $Silent) {
            Write-Vnts2ManagerLog -Message "读取状态失败：$($_.Exception.Message)"
            [Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                "状态读取失败",
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    }
}

function Invoke-Vnts2ManagerOperation {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [switch]$SkipRefresh
    )

    $form.UseWaitCursor = $true
    $actionPanel.Enabled = $false
    $refreshButton.Enabled = $false
    try {
        Write-Vnts2ManagerLog -Message "开始：$Name"
        $result = @(& $Action)
        Write-Vnts2ManagerLog -Message "完成：$Name" -Data $result
    } catch {
        Write-Vnts2ManagerLog -Message "失败：$Name；$($_.Exception.Message)"
        [Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "$Name 失败",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } finally {
        $form.UseWaitCursor = $false
        $actionPanel.Enabled = $true
        $refreshButton.Enabled = $true
        if (-not $SkipRefresh) {
            Update-Vnts2ManagerStatus -Silent
        }
    }
}

function Initialize-Vnts2ManagerConfig {
    $activeConfigPath = Get-Vnts2ManagerActiveConfigPath
    if (Test-Path -LiteralPath $activeConfigPath -PathType Leaf) {
        return $false
    }
    if ($null -ne $script:currentStatus -and $script:currentStatus.Installed) {
        throw "已安装服务的配置文件不存在：$activeConfigPath；为避免改写其他部署，GUI 不会自动创建。"
    }
    if (-not (Test-Path -LiteralPath $configTemplatePath -PathType Leaf)) {
        throw "缺少配置模板：$configTemplatePath"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $activeConfigPath) -Force | Out-Null
    Copy-Item -LiteralPath $configTemplatePath -Destination $activeConfigPath
    return $true
}

function Open-Vnts2ManagerConfig {
    $activeConfigPath = Get-Vnts2ManagerActiveConfigPath
    $created = Initialize-Vnts2ManagerConfig
    if ($created) {
        Write-Vnts2ManagerLog -Message "已从模板创建 config.toml；请按需设置强密码和监听地址。"
    } else {
        Write-Vnts2ManagerLog -Message "config.toml 已存在，不会覆盖。"
    }
    $notepad = Join-Path $env:SystemRoot "System32\notepad.exe"
    Start-Process -FilePath $notepad -ArgumentList ('"{0}"' -f $activeConfigPath) | Out-Null
}

function Open-Vnts2ManagerWebConsole {
    $activeConfigPath = Get-Vnts2ManagerActiveConfigPath
    if (-not (Test-Path -LiteralPath $activeConfigPath -PathType Leaf)) {
        throw "配置文件不存在：$activeConfigPath"
    }
    $webBinding = @(Get-Vnts2ConfigBindEndpoints -ConfigPath $activeConfigPath | Where-Object Name -eq "web_bind") |
        Select-Object -First 1
    if ($null -eq $webBinding) {
        throw "config.toml 尚未启用 web_bind，请先编辑配置并重启服务。"
    }

    $endpoint = $webBinding.Endpoint
    if ($endpoint -match '^(?:127\.0\.0\.1|localhost):(?<Port>\d{1,5})$') {
        $hostPart = "127.0.0.1"
    } elseif ($endpoint -match '^\[::1\]:(?<Port>\d{1,5})$') {
        $hostPart = "[::1]"
    } else {
        throw "Web 管理端必须使用回环地址，当前配置为：$endpoint"
    }
    $port = [int]$matches["Port"]
    if ($port -lt 1 -or $port -gt 65535) {
        throw "Web 管理端端口无效：$port"
    }
    Start-Process -FilePath "http://${hostPart}:$port/" | Out-Null
}

$refreshButton.Add_Click({ Update-Vnts2ManagerStatus })
$configButton.Add_Click({
    Invoke-Vnts2ManagerOperation -Name "初始化/编辑配置" -SkipRefresh -Action {
        Open-Vnts2ManagerConfig
    }
})
$installButton.Add_Click({
    Invoke-Vnts2ManagerOperation -Name "安装并启动服务" -Action {
        $serviceName = Get-Vnts2ManagerServiceName
        $status = & $statusScript -ServiceName $serviceName
        if ((Get-Vnts2ManagerDeploymentMode -Status $status) -eq "ExistingDeployment") {
            $target = if ($null -eq $status.ExecutablePath) { "无法解析的路径" } else { $status.ExecutablePath }
            $answer = [Windows.Forms.MessageBox]::Show(
                "服务 $serviceName 已安装于：`r`n$target`r`n`r`n" +
                "是否迁移到当前便携目录？`r`n`r`n" +
                "程序：$packageExecutablePath`r`n" +
                "数据：$packageDataPath`r`n`r`n" +
                "迁移前会停止服务并校验配置、数据库、证书和密钥；失败自动恢复原路径。",
                "确认迁移已有服务",
                [Windows.Forms.MessageBoxButtons]::YesNo,
                [Windows.Forms.MessageBoxIcon]::Warning,
                [Windows.Forms.MessageBoxDefaultButton]::Button2
            )
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                Write-Vnts2ManagerLog -Message "已取消迁移服务 $serviceName。"
                return
            }
            & $updateScript `
                -ServiceName $serviceName `
                -TargetDir $PSScriptRoot `
                -SourceExecutable $packageExecutablePath `
                -MigrateExistingData
            return
        }
        if (Initialize-Vnts2ManagerConfig) {
            Write-Vnts2ManagerLog -Message "已自动初始化 $packageConfigPath。"
        }
        & $installScript `
            -ServiceName $serviceName `
            -TargetDir $PSScriptRoot
    }
})
$startButton.Add_Click({
    Invoke-Vnts2ManagerOperation -Name "启动服务" -Action {
        & $startScript -ServiceName (Get-Vnts2ManagerServiceName)
    }
})
$stopButton.Add_Click({
    Invoke-Vnts2ManagerOperation -Name "停止服务" -Action {
        & $stopScript -ServiceName (Get-Vnts2ManagerServiceName)
    }
})
$diagnoseButton.Add_Click({
    Invoke-Vnts2ManagerOperation -Name "运行诊断" -Action {
        & $diagnoseScript -ServiceName (Get-Vnts2ManagerServiceName)
    }
})
$webButton.Add_Click({
    Invoke-Vnts2ManagerOperation -Name "打开 Web 控制台" -SkipRefresh -Action {
        Open-Vnts2ManagerWebConsole
    }
})
$uninstallButton.Add_Click({
    try {
        $serviceName = Get-Vnts2ManagerServiceName
    } catch {
        [Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "服务名无效",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }
    $answer = [Windows.Forms.MessageBox]::Show(
        "确定卸载 Windows 服务 $serviceName 吗？`r`n配置、数据库、密钥和日志会保留。",
        "确认卸载",
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning,
        [Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
        Invoke-Vnts2ManagerOperation -Name "卸载服务" -Action {
            & $uninstallScript -ServiceName $serviceName
        }
    }
})
$clearButton.Add_Click({ $outputTextBox.Clear() })

if ($ValidateOnly) {
    $detectedStatus = & $statusScript -ServiceName $serviceNameTextBox.Text
    $detectedDeploymentMode = Get-Vnts2ManagerDeploymentMode -Status $detectedStatus
    [pscustomobject]@{
        Title = $form.Text
        ActionCount = $actionButtons.Count
        Actions = @($actionButtons | ForEach-Object Text)
        DefaultServiceName = $serviceNameTextBox.Text
        ConfigPath = $packageConfigPath
        DataPath = $packageDataPath
        PortableDataRelativePath = "data"
        ExistingDeploymentMode = Get-Vnts2ManagerDeploymentMode -Status ([pscustomobject]@{
            Installed = $true
            ExecutablePath = "C:\ProgramData\VNTS2\vnts2.exe"
            ConfigPath = "C:\ProgramData\VNTS2\config.toml"
        })
        ExistingDeploymentInstallAction = "MigrateExistingService"
        DetectedDefaultDeploymentMode = $detectedDeploymentMode
        DetectedDefaultConfigPath = $detectedStatus.ConfigPath
        DetectedDefaultInstallAction = if ($detectedDeploymentMode -eq "ExistingDeployment") {
            "MigrateExistingService"
        } else {
            "InstallCurrentDeployment"
        }
    }
    $form.Dispose()
    return
}

Update-Vnts2ManagerStatus -Silent
Write-Vnts2ManagerLog -Message "服务管理器已启动。"
[void]$form.ShowDialog()
$form.Dispose()
