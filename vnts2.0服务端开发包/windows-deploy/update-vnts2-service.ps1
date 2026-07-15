param(
    [string]$ServiceName = "vnts2",
    [string]$TargetDir = $PSScriptRoot,
    [string]$SourceExecutable = (Join-Path $PSScriptRoot "vnts2.exe"),
    [switch]$MigrateExistingData,
    [switch]$SkipStart
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$commonScript = Join-Path $PSScriptRoot "vnts2-service-common.ps1"
$installScript = Join-Path $PSScriptRoot "install-vnts2-service.ps1"
$stopScript = Join-Path $PSScriptRoot "stop-vnts2-service.ps1"
foreach ($requiredScript in @($commonScript, $installScript, $stopScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "缺少 Windows 服务更新依赖：$requiredScript"
    }
}
. $commonScript

Assert-Vnts2Administrator
Assert-Vnts2ServiceName -ServiceName $ServiceName

function Merge-Vnts2MigrationDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        return
    }
    New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
    $resolvedSource = (Resolve-Path -LiteralPath $SourcePath).Path.TrimEnd('\')
    $resolvedTarget = (Resolve-Path -LiteralPath $TargetPath).Path.TrimEnd('\')
    $items = @(Get-ChildItem -LiteralPath $resolvedSource -Force -Recurse)
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "迁移源目录中存在重解析点，拒绝跟随：$($item.FullName)"
        }
        $relativePath = $item.FullName.Substring($resolvedSource.Length).TrimStart('\')
        $destination = Join-Path $resolvedTarget $relativePath
        if ($item.PSIsContainer) {
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                throw "迁移目标已有同名文件，拒绝覆盖：$destination"
            }
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            continue
        }
        if (Test-Path -LiteralPath $destination) {
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or
                (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash -ne
                (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash) {
                throw "迁移目标已有同名不同内容，拒绝覆盖：$destination"
            }
            continue
        }
        Copy-Item -LiteralPath $item.FullName -Destination $destination
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash -ne
            (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash) {
            throw "迁移文件哈希校验失败：$destination"
        }
    }
}

$resolvedTargetRoot = (Resolve-Path -LiteralPath $TargetDir).Path
$layout = Get-Vnts2PortableLayout -RootPath $resolvedTargetRoot
$resolvedSource = (Resolve-Path -LiteralPath $SourceExecutable).Path
if (-not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {
    throw "便携发布包缺少服务程序：$resolvedSource"
}

$service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
if ($null -eq $service) {
    throw "Windows 服务 $ServiceName 不存在，请使用安装脚本。"
}
$commandInfo = Get-Vnts2ServiceCommandInfo -PathName $service.PathName
if ($null -eq $commandInfo) {
    throw "无法解析 Windows 服务 $ServiceName 的启动路径，拒绝更新。"
}
if (-not [string]::Equals(
    $commandInfo.ServiceName,
    $ServiceName,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "服务启动命令中的服务名与 $ServiceName 不一致，拒绝更新。"
}
if (-not (Test-Path -LiteralPath $commandInfo.ConfigPath -PathType Leaf)) {
    throw "已安装服务的配置文件不存在：$($commandInfo.ConfigPath)"
}

$originalPathName = $service.PathName
$originalState = $service.State
$sourceDataPath = Split-Path -Parent ([IO.Path]::GetFullPath($commandInfo.ConfigPath))
$targetDataPath = $layout.DataPath
$sameDataPath = [string]::Equals(
    $sourceDataPath,
    $targetDataPath,
    [StringComparison]::OrdinalIgnoreCase
)
$newBinaryPath = Get-Vnts2ServiceBinaryPath `
    -ExecutablePath $layout.ExecutablePath `
    -ConfigPath $layout.ConfigPath `
    -ServiceName $ServiceName
$servicePathChanged = $false
$executableReplaced = $false
$temporaryPath = Join-Path $layout.RootPath (".vnts2-update-{0}.exe" -f [Guid]::NewGuid().ToString("N"))
$replaceBackupPath = "$temporaryPath.replace-backup"
$programBackupPath = $null

if (-not $sameDataPath -and -not $MigrateExistingData) {
    throw "服务当前位于其他目录；请显式使用 -MigrateExistingData 迁移到 $targetDataPath。"
}

if ($service.State -ne "Stopped") {
    & $stopScript -ServiceName $ServiceName | Out-Null
}

try {
    if (-not $sameDataPath) {
        $criticalFiles = @(
            "config.toml",
            "network_control.db",
            "cert.pem",
            "key.pem",
            "wireguard-master.key"
        )
        New-Item -ItemType Directory -Path $targetDataPath -Force | Out-Null
        foreach ($name in $criticalFiles) {
            $sourcePath = Join-Path $sourceDataPath $name
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                continue
            }
            $targetPath = Join-Path $targetDataPath $name
            $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash
            if (Test-Path -LiteralPath $targetPath) {
                if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf) -or
                    $sourceHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash) {
                    throw "目标 data 已有不同的 $name，拒绝覆盖；请先确认要保留的数据。"
                }
                continue
            }
            Copy-Item -LiteralPath $sourcePath -Destination $targetPath
            if ($sourceHash -ne (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash) {
                throw "迁移后的 $name 哈希校验失败。"
            }
        }
        foreach ($name in @("logs", ".backups")) {
            Merge-Vnts2MigrationDirectory `
                -SourcePath (Join-Path $sourceDataPath $name) `
                -TargetPath (Join-Path $targetDataPath $name)
        }
    }

    if (-not (Test-Path -LiteralPath $layout.ConfigPath -PathType Leaf)) {
        throw "便携 data 中缺少 config.toml：$($layout.ConfigPath)"
    }

    $layout = Initialize-Vnts2PortableDirectories -RootPath $layout.RootPath
    $resolvedPortableExecutable = if (Test-Path -LiteralPath $layout.ExecutablePath -PathType Leaf) {
        (Resolve-Path -LiteralPath $layout.ExecutablePath).Path
    } else {
        $null
    }
    $sourceIsPortableExecutable = $null -ne $resolvedPortableExecutable -and [string]::Equals(
        $resolvedSource,
        $resolvedPortableExecutable,
        [StringComparison]::OrdinalIgnoreCase
    )

    if (-not $sourceIsPortableExecutable) {
        if ($null -eq $resolvedPortableExecutable) {
            Copy-Item -LiteralPath $resolvedSource -Destination $layout.ExecutablePath
        } else {
            $programBackupPath = Join-Path $layout.BackupsPath (
                "vnts2.exe.pre-update-{0}.bak" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff")
            )
            Copy-Item -LiteralPath $resolvedPortableExecutable -Destination $programBackupPath
            $originalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedPortableExecutable).Hash
            if ((Get-FileHash -Algorithm SHA256 -LiteralPath $programBackupPath).Hash -ne $originalHash) {
                throw "旧程序备份哈希校验失败：$programBackupPath"
            }
            Copy-Item -LiteralPath $resolvedSource -Destination $temporaryPath
            [IO.File]::Replace($temporaryPath, $resolvedPortableExecutable, $replaceBackupPath, $true)
            $executableReplaced = $true
        }
    }

    $portableHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $layout.ExecutablePath).Hash
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedSource).Hash
    if ($portableHash -ne $sourceHash) {
        throw "便携目录中的 vnts2.exe 与更新源哈希不一致。"
    }

    Set-Vnts2ServiceConfiguration -ServiceName $ServiceName -BinaryPath $newBinaryPath
    $servicePathChanged = $true
    & $installScript `
        -ServiceName $ServiceName `
        -TargetDir $layout.RootPath `
        -SkipStart:$SkipStart | Out-Null

    [pscustomobject]@{
        Name = $ServiceName
        Updated = $true
        MigratedData = (-not $sameDataPath)
        State = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'").State
        RootPath = $layout.RootPath
        ExecutablePath = $layout.ExecutablePath
        ConfigPath = $layout.ConfigPath
        DataPath = $layout.DataPath
        CurrentSHA256 = $portableHash
        BackupPath = $programBackupPath
    }
} catch {
    $updateError = $_
    if ($executableReplaced -and $null -ne $programBackupPath -and
        (Test-Path -LiteralPath $programBackupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $programBackupPath -Destination $layout.ExecutablePath -Force
    }
    if ($servicePathChanged) {
        $currentService = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
        if ($null -ne $currentService) {
            $restoreResult = Invoke-CimMethod -InputObject $currentService -MethodName Change -Arguments @{
                PathName = $originalPathName
            }
            if ($restoreResult.ReturnValue -ne 0) {
                throw "更新失败，且恢复原服务启动路径失败（返回 $($restoreResult.ReturnValue)）：$($updateError.Exception.Message)"
            }
        }
    }
    if ($originalState -eq "Running") {
        Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    }
    throw $updateError
} finally {
    foreach ($path in @($temporaryPath, $replaceBackupPath)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}
