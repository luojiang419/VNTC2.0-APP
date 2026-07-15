param(
    [Parameter(Mandatory = $true)][string]$ReleaseBinary,
    [string]$ManagerExecutable
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-E2E {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Get-FreeUdpPort {
    $client = [Net.Sockets.UdpClient]::new(0)
    try {
        return ([Net.IPEndPoint]$client.Client.LocalEndPoint).Port
    } finally {
        $client.Dispose()
    }
}

$sourceRoot = Split-Path -Parent $PSScriptRoot
$commonScript = Join-Path $sourceRoot "vnts2-service-common.ps1"
. $commonScript
Assert-Vnts2Administrator

$resolvedBinary = (Resolve-Path -LiteralPath $ReleaseBinary).Path
$serviceName = "vnts2-e2e-" + [Guid]::NewGuid().ToString("N").Substring(0, 12)
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("VNTS2 Service Test " + [Guid]::NewGuid())
$originalService = Get-CimInstance Win32_Service -Filter "Name='vnts2'" -ErrorAction SilentlyContinue
$originalState = if ($null -eq $originalService) { $null } else { $originalService.State }
$originalPathName = if ($null -eq $originalService) { $null } else { $originalService.PathName }

New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $deployFiles = @(
        "vnts2-service-common.ps1",
        "install-vnts2-service.ps1",
        "uninstall-vnts2-service.ps1",
        "start-vnts2-service.ps1",
        "stop-vnts2-service.ps1",
        "status-vnts2-service.ps1",
        "diagnose-vnts2-service.ps1",
        "update-vnts2-service.ps1"
    )
    foreach ($file in $deployFiles) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination $temporaryRoot
    }
    Copy-Item -LiteralPath $resolvedBinary -Destination (Join-Path $temporaryRoot "vnts2.exe")
    $temporaryData = Join-Path $temporaryRoot "data"
    New-Item -ItemType Directory -Path $temporaryData | Out-Null
    $targetBackups = Join-Path $temporaryData ".backups"
    New-Item -ItemType Directory -Path $targetBackups | Out-Null
    $preexistingTargetBackup = Join-Path $targetBackups "preexisting-target-backup.txt"
    Set-Content -LiteralPath $preexistingTargetBackup -Value "target backup must survive migration" -Encoding UTF8

    $legacyRoot = Join-Path $temporaryRoot "legacy-deployment"
    $legacyData = Join-Path $legacyRoot "data"
    $legacyBackups = Join-Path $legacyData ".backups"
    $legacyLogs = Join-Path $legacyData "logs"
    New-Item -ItemType Directory -Path $legacyBackups -Force | Out-Null
    New-Item -ItemType Directory -Path $legacyLogs -Force | Out-Null
    Copy-Item -LiteralPath $resolvedBinary -Destination (Join-Path $legacyRoot "vnts2.exe")
    $sourceBackup = Join-Path $legacyBackups "legacy-source-backup.txt"
    $sourceLog = Join-Path $legacyLogs "legacy-source.log"
    Set-Content -LiteralPath $sourceBackup -Value "legacy backup must be merged" -Encoding UTF8
    Set-Content -LiteralPath $sourceLog -Value "legacy log must be merged" -Encoding UTF8

    $tcpPort = Get-FreeTcpPort
    $quicPort = Get-FreeUdpPort
    $config = @"
tcp_bind = "127.0.0.1:$tcpPort"
quic_bind = "127.0.0.1:$quicPort"
ws_bind = "127.0.0.1:$tcpPort"
network = "10.251.0.0/24"
white_list = []
lease_duration = 3600
persistence = false
wireguard_max_active_peers = 64
peer_servers = []

[custom_nets]
"@
    $legacyConfig = Join-Path $legacyData "config.toml"
    Set-Content -LiteralPath $legacyConfig -Value $config -Encoding UTF8

    $install = Join-Path $temporaryRoot "install-vnts2-service.ps1"
    $start = Join-Path $temporaryRoot "start-vnts2-service.ps1"
    $status = Join-Path $temporaryRoot "status-vnts2-service.ps1"
    $diagnose = Join-Path $temporaryRoot "diagnose-vnts2-service.ps1"
    $stop = Join-Path $temporaryRoot "stop-vnts2-service.ps1"
    $uninstall = Join-Path $temporaryRoot "uninstall-vnts2-service.ps1"
    $update = Join-Path $temporaryRoot "update-vnts2-service.ps1"

    & $install -ServiceName $serviceName -DisplayName "VNTS2 E2E Test" -TargetDir $legacyRoot -SkipStart | Out-Null
    & $start -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    $legacyStatus = & $status -ServiceName $serviceName
    Assert-E2E ($legacyStatus.State -eq "Running") "迁移测试的旧目录服务未进入 Running。"
    Assert-E2E ($legacyStatus.PathName -like "*$legacyRoot*vnts2.exe*") "迁移前 ImagePath 未指向旧目录。"

    $migration = & $update `
        -ServiceName $serviceName `
        -TargetDir $temporaryRoot `
        -SourceExecutable (Join-Path $temporaryRoot "vnts2.exe") `
        -MigrateExistingData
    Assert-E2E $migration.MigratedData "更新脚本未报告跨目录数据迁移。"
    Assert-E2E ($migration.State -eq "Running") "迁移后服务未恢复 Running。"
    Assert-E2E ((Get-FileHash -LiteralPath $legacyConfig).Hash -eq
        (Get-FileHash -LiteralPath (Join-Path $temporaryData "config.toml")).Hash) "迁移后配置哈希不一致。"
    Assert-E2E (Test-Path -LiteralPath $preexistingTargetBackup -PathType Leaf) "目标 data 原有备份被迁移覆盖。"
    Assert-E2E (Test-Path -LiteralPath (Join-Path $targetBackups "legacy-source-backup.txt") -PathType Leaf) `
        "旧部署备份没有合并到目标 data。"
    Assert-E2E (Test-Path -LiteralPath (Join-Path $temporaryData "logs\legacy-source.log") -PathType Leaf) `
        "旧部署日志没有合并到目标 data。"
    $migratedStatus = & $status -ServiceName $serviceName
    Assert-E2E $migratedStatus.PortableLayout "迁移后服务没有使用目标便携布局。"
    Assert-E2E ($migratedStatus.PathName -like "*$temporaryRoot*vnts2.exe*") "迁移后 ImagePath 未切换到目标目录。"

    & $stop -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    & $install -ServiceName $serviceName -DisplayName "VNTS2 E2E Test" -TargetDir $temporaryRoot -SkipStart | Out-Null
    & $install -ServiceName $serviceName -DisplayName "VNTS2 E2E Test" -TargetDir $temporaryRoot -SkipStart | Out-Null
    $stoppedStatus = & $status -ServiceName $serviceName
    Assert-E2E $stoppedStatus.Installed "临时服务安装后未被 status 识别。"
    Assert-E2E ($stoppedStatus.State -eq "Stopped") "临时服务安装后应保持 Stopped。"
    Assert-E2E ($stoppedStatus.PathName -like "*--service-name*$serviceName*") "ImagePath 缺少隔离服务名。"
    Assert-E2E $stoppedStatus.PortableLayout "临时服务未使用同级 data 便携布局。"
    Assert-E2E ($stoppedStatus.DataPath -eq $temporaryData) "临时服务 data 路径错误。"

    & $start -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    & $start -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    $runningStatus = & $status -ServiceName $serviceName
    Assert-E2E ($runningStatus.State -eq "Running") "临时服务未进入 Running。"
    Assert-E2E ($runningStatus.ProcessId -gt 0) "Running 服务缺少进程号。"

    if (-not [string]::IsNullOrWhiteSpace($ManagerExecutable)) {
        $resolvedManager = (Resolve-Path -LiteralPath $ManagerExecutable).Path
        $managerStatusPath = Join-Path $temporaryRoot "manager-status.json"
        $managerArguments = '--status-only "{0}" "{1}"' -f `
            $serviceName.Replace('"', '""'), $managerStatusPath.Replace('"', '""')
        $managerProcess = Start-Process `
            -FilePath $resolvedManager `
            -ArgumentList $managerArguments `
            -Wait `
            -PassThru
        Assert-E2E ($managerProcess.ExitCode -eq 0) "原生 GUI EXE 状态契约执行失败。"
        $managerStatus = Get-Content -LiteralPath $managerStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-E2E ($managerStatus.InvokedBy -eq "VNTS2-Manager.exe") "状态不是由原生 GUI EXE 获取。"
        Assert-E2E ($managerStatus.State -eq "Running") "原生 GUI EXE 未读取到 Running。"
        Assert-E2E ($managerStatus.ProcessId -eq $runningStatus.ProcessId) "原生 GUI EXE 读取的 PID 不一致。"

        $managerWebPath = Join-Path $temporaryRoot "manager-web.json"
        $managerWebPort = Get-FreeTcpPort
        $managerWebEndpoint = "127.0.0.1:$managerWebPort"
        $managerWebArguments = '--enable-web-only "{0}" "{1}" "{2}"' -f `
            $serviceName.Replace('"', '""'), $managerWebPath.Replace('"', '""'), $managerWebEndpoint
        $managerWebProcess = Start-Process `
            -FilePath $resolvedManager `
            -ArgumentList $managerWebArguments `
            -Wait `
            -PassThru
        if ($managerWebProcess.ExitCode -ne 0) {
            $managerWebError = if (Test-Path -LiteralPath $managerWebPath -PathType Leaf) {
                (Get-Content -LiteralPath $managerWebPath -Raw -Encoding UTF8).Trim()
            } else {
                "未生成错误详情文件。"
            }
            throw "原生 GUI EXE 启用 Web 失败（退出码 $($managerWebProcess.ExitCode)）：$managerWebError"
        }
        $managerWeb = Get-Content -LiteralPath $managerWebPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-E2E ($managerWeb.InvokedBy -eq "VNTS2-Manager.exe") "Web 启用不是由原生 GUI EXE 执行。"
        Assert-E2E ($managerWeb.Endpoint -eq $managerWebEndpoint) "Web 控制台未使用测试分配的回环端点。"
        Assert-E2E ($managerWeb.Username -eq "admin") "Web 控制台默认用户名错误。"
        Assert-E2E ($managerWeb.Password.Length -eq 24) "Web 控制台未生成 24 位强密码。"
        Assert-E2E (Test-Path -LiteralPath $managerWeb.BackupPath -PathType Leaf) "原配置备份不存在。"
        Assert-E2E ((& $status -ServiceName $serviceName).State -eq "Running") "启用 Web 后服务未恢复 Running。"

        $updatedLines = @(Get-Content -LiteralPath (Join-Path $temporaryData "config.toml"))
        $sectionIndex = [Array]::FindIndex(
            [string[]]$updatedLines,
            [Predicate[string]] { param($line) $line -match '^\s*\[' }
        )
        foreach ($setting in @("web_bind", "username", "password")) {
            $settingIndex = [Array]::FindIndex(
                [string[]]$updatedLines,
                [Predicate[string]] { param($line) $line -match "^\s*$setting\s*=" }
            )
            Assert-E2E ($settingIndex -ge 0 -and $settingIndex -lt $sectionIndex) "$setting 未写入 TOML 根级。"
        }

        $webResponse = Invoke-WebRequest `
            -Uri ("http://{0}/" -f $managerWeb.Endpoint) `
            -UseBasicParsing `
            -TimeoutSec 10
        Assert-E2E ($webResponse.StatusCode -eq 200) "Web 控制台首页未返回 HTTP 200。"
        $loginBody = @{ username = $managerWeb.Username; password = $managerWeb.Password } | ConvertTo-Json -Compress
        $loginResponse = Invoke-RestMethod `
            -Uri ("http://{0}/api/login" -f $managerWeb.Endpoint) `
            -Method Post `
            -ContentType "application/json" `
            -Body $loginBody `
            -TimeoutSec 10
        Assert-E2E (-not [string]::IsNullOrWhiteSpace($loginResponse.data.token)) "生成的 Web 凭据无法登录。"
    }

    $diagnostics = @(& $diagnose -ServiceName $serviceName)
    $summary = $diagnostics | Where-Object Check -eq "Summary"
    $runtimePorts = $diagnostics | Where-Object Check -eq "RuntimePorts"
    $dataDirectory = $diagnostics | Where-Object Check -eq "DataDirectory"
    Assert-E2E ($summary.Status -ne "FAIL") "临时服务诊断包含失败项。"
    Assert-E2E ($runtimePorts.Status -eq "PASS") "临时服务没有通过实际端口诊断。"
    Assert-E2E ($dataDirectory.Status -eq "PASS") "临时服务数据目录诊断失败。"

    & $stop -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    & $stop -ServiceName $serviceName -TimeoutSeconds 30 | Out-Null
    Assert-E2E ((& $status -ServiceName $serviceName).State -eq "Stopped") "临时服务未停止。"

    Invoke-Vnts2Sc -Arguments @("failureflag", $serviceName, "0") | Out-Null
    Set-Content -LiteralPath (Join-Path $temporaryData "config.toml") -Value 'invalid = [' -Encoding UTF8
    $startupFailed = $false
    try {
        Start-Service -Name $serviceName -ErrorAction Stop
    } catch {
        $startupFailed = $true
    }
    Start-Sleep -Milliseconds 500
    $failedService = Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
    $scQuery = Invoke-Vnts2Sc -Arguments @("query", $serviceName) | Out-String
    Assert-E2E $startupFailed "无效配置启动应向服务控制客户端返回失败。"
    Assert-E2E ($failedService.State -eq "Stopped") "无效配置启动后服务应回到 Stopped。"
    Assert-E2E ($failedService.ExitCode -eq 1066) "无效配置应报告 ERROR_SERVICE_SPECIFIC_ERROR (1066)。"
    Assert-E2E ($scQuery -match 'SERVICE_EXIT_CODE\s+:\s+1\s') "SCM 未暴露稳定的 service-specific 退出码 1。"

    & $uninstall -ServiceName $serviceName | Out-Null
    & $uninstall -ServiceName $serviceName | Out-Null
    Assert-E2E (-not (& $status -ServiceName $serviceName).Installed) "临时服务卸载后仍存在。"

    $currentOriginal = Get-CimInstance Win32_Service -Filter "Name='vnts2'" -ErrorAction SilentlyContinue
    if ($null -eq $originalService) {
        Assert-E2E ($null -eq $currentOriginal) "端到端测试意外创建了默认 vnts2 服务。"
    } else {
        Assert-E2E ($currentOriginal.State -eq $originalState) "端到端测试改变了默认 vnts2 服务状态。"
        Assert-E2E ($currentOriginal.PathName -eq $originalPathName) "端到端测试改变了默认 vnts2 ImagePath。"
    }

    Write-Host "Windows 服务端到端测试通过：$serviceName"
} finally {
    $leftover = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -ne $leftover) {
        if ($leftover.Status.ToString() -ne "Stopped") {
            Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
            try {
                Wait-Vnts2ServiceStatus -ServiceName $serviceName -DesiredStatus Stopped -TimeoutSeconds 30 | Out-Null
            } catch {
            }
        }
        try {
            Invoke-Vnts2Sc -Arguments @("delete", $serviceName) | Out-Null
            Wait-Vnts2ServiceDeleted -ServiceName $serviceName -TimeoutSeconds 30
        } catch {
        }
    }
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporaryRoot = (Resolve-Path -LiteralPath $temporaryRoot).Path
        $resolvedTempBase = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path
        if (-not $resolvedTemporaryRoot.StartsWith($resolvedTempBase, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $resolvedTemporaryRoot).StartsWith("VNTS2 Service Test ")) {
            throw "拒绝清理未通过边界校验的临时目录：$resolvedTemporaryRoot"
        }
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
