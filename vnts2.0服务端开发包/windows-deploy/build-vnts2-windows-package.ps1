param(
    [string]$SourceExecutable = (Join-Path $PSScriptRoot "..\official-vnts-source-2.0.0\target\release\vnts2.exe"),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "dist"),
    [string]$Version = "2.0.0",
    [switch]$SyncPortableRoot,
    [string]$PortableRoot = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -eq "Core") {
    $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw "生成规范 Windows ZIP 需要系统自带 Windows PowerShell 5.1。"
    }
    $quoteArgument = {
        param([string]$Value)
        return "'" + $Value.Replace("'", "''") + "'"
    }
    $command = '$ErrorActionPreference = ''Stop''; $ProgressPreference = ''SilentlyContinue''; try { & ' +
        (& $quoteArgument $PSCommandPath) +
        ' -SourceExecutable ' + (& $quoteArgument $SourceExecutable) +
        ' -OutputDirectory ' + (& $quoteArgument $OutputDirectory) +
        ' -Version ' + (& $quoteArgument $Version) +
        $(if ($SyncPortableRoot) { ' -SyncPortableRoot' } else { '' }) +
        ' -PortableRoot ' + (& $quoteArgument $PortableRoot) +
        ' | ConvertTo-Json -Compress } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }'
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $json = & $windowsPowerShell `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -EncodedCommand $encodedCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Windows PowerShell 5.1 规范发布包生成失败（退出码 $LASTEXITCODE）。"
    }
    ($json -join "`n") | ConvertFrom-Json
    return
}

if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
    throw "版本号只能包含字母、数字、点、下划线和连字符，且长度不能超过 64。"
}
if (-not (Test-Path -LiteralPath $SourceExecutable -PathType Leaf)) {
    throw "未找到 Release 可执行文件：$SourceExecutable"
}

function Write-Vnts2Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-Vnts2RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    return $Path.Substring($Root.Length + 1).Replace('\', '/')
}

function Assert-Vnts2OutputChild {
    param(
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $expectedParent = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\', '/')
    $actualParent = [IO.Path]::GetFullPath((Split-Path -Parent $Path)).TrimEnd('\', '/')
    if (-not [string]::Equals($expectedParent, $actualParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝操作输出目录以外的路径：$Path"
    }
}

$deployRoot = $PSScriptRoot
$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $deployRoot "..\official-vnts-source-2.0.0")).Path
$resolvedExecutable = (Resolve-Path -LiteralPath $SourceExecutable).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$outputRoot = (Resolve-Path -LiteralPath $OutputDirectory).Path
$packageName = "vnts2-$Version-windows-x64"
$stagingDirectory = Join-Path $outputRoot $packageName
$zipPath = Join-Path $outputRoot "$packageName.zip"
$zipHashPath = "$zipPath.sha256"

foreach ($path in @($stagingDirectory, $zipPath, $zipHashPath)) {
    Assert-Vnts2OutputChild -OutputRoot $outputRoot -Path $path
    if (Test-Path -LiteralPath $path) {
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "拒绝删除重解析点输出：$path"
        }
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}
New-Item -ItemType Directory -Path $stagingDirectory | Out-Null

$managerPath = Join-Path $deployRoot "VNTS2-Manager.exe"
$managerValidationPath = Join-Path $env:TEMP ("vnts2-package-manager-{0}.json" -f [Guid]::NewGuid().ToString("N"))
try {
    $managerProcess = Start-Process `
        -FilePath $managerPath `
        -ArgumentList @("--validate-only", "`"$managerValidationPath`"") `
        -Wait `
        -PassThru
    if ($managerProcess.ExitCode -ne 0 -or
        -not (Test-Path -LiteralPath $managerValidationPath -PathType Leaf)) {
        throw "原生 GUI 验证失败，请先重新构建 VNTS2-Manager.exe。"
    }
    $managerModel = Get-Content -LiteralPath $managerValidationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($managerModel.PortableDataRelativePath -ne "data" -or
        $managerModel.ExistingDeploymentAction -ne "MigrateExistingService") {
        throw "VNTS2-Manager.exe 仍是旧版，请先运行 build-vnts2-manager-exe.ps1。"
    }
} finally {
    if (Test-Path -LiteralPath $managerValidationPath -PathType Leaf) {
        Remove-Item -LiteralPath $managerValidationPath -Force
    }
}

$sourceFiles = [ordered]@{
    "vnts2.exe" = $resolvedExecutable
    "config.example.toml" = (Join-Path $deployRoot "config.example.toml")
    "README.md" = (Join-Path $deployRoot "README-PACKAGE.md")
    "NOTICE" = (Join-Path $sourceRoot "NOTICE")
    "VNTS2-Manager.exe" = (Join-Path $deployRoot "VNTS2-Manager.exe")
    "vnts2-service-common.ps1" = (Join-Path $deployRoot "vnts2-service-common.ps1")
    "install-vnts2-service.ps1" = (Join-Path $deployRoot "install-vnts2-service.ps1")
    "update-vnts2-service.ps1" = (Join-Path $deployRoot "update-vnts2-service.ps1")
    "uninstall-vnts2-service.ps1" = (Join-Path $deployRoot "uninstall-vnts2-service.ps1")
    "start-vnts2-service.ps1" = (Join-Path $deployRoot "start-vnts2-service.ps1")
    "stop-vnts2-service.ps1" = (Join-Path $deployRoot "stop-vnts2-service.ps1")
    "status-vnts2-service.ps1" = (Join-Path $deployRoot "status-vnts2-service.ps1")
    "diagnose-vnts2-service.ps1" = (Join-Path $deployRoot "diagnose-vnts2-service.ps1")
    "licenses/dijkstrajs.txt" = (Join-Path $sourceRoot "static\licenses\dijkstrajs.txt")
    "licenses/fontawesome.txt" = (Join-Path $sourceRoot "static\licenses\fontawesome.txt")
    "licenses/qrcode.txt" = (Join-Path $sourceRoot "static\licenses\qrcode.txt")
    "licenses/tailwindcss.txt" = (Join-Path $sourceRoot "static\licenses\tailwindcss.txt")
    "licenses/vue.txt" = (Join-Path $sourceRoot "static\licenses\vue.txt")
}

foreach ($entry in $sourceFiles.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
        throw "发布白名单文件不存在：$($entry.Value)"
    }
    $destination = Join-Path $stagingDirectory $entry.Key.Replace('/', '\')
    $destinationParent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
    Copy-Item -LiteralPath $entry.Value -Destination $destination
}

$dataReadmePath = Join-Path $stagingDirectory "data\README.txt"
New-Item -ItemType Directory -Path (Split-Path -Parent $dataReadmePath) -Force | Out-Null
Write-Vnts2Utf8NoBom -Path $dataReadmePath -Content @"
VNTS2 便携数据目录

首次点击 GUI 的“安装并启动”后，配置、数据库、证书、密钥、日志和备份都会保存在本目录。
迁移时请复制整个 VNTS2 文件夹；卸载 Windows 服务不会删除本目录。
不要把真实 data 内容重新打入公开发布包。
"@

$payloadFiles = @(Get-ChildItem -LiteralPath $stagingDirectory -Recurse -File | Sort-Object {
    Get-Vnts2RelativePath -Root $stagingDirectory -Path $_.FullName
})
$manifestEntries = @($payloadFiles | ForEach-Object {
    [ordered]@{
        path = Get-Vnts2RelativePath -Root $stagingDirectory -Path $_.FullName
        length = [long]$_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
})
$manifest = [ordered]@{
    format_version = 1
    package_name = $packageName
    product = "VNTS 2.0"
    version = $Version
    platform = "windows"
    architecture = "x64"
    files = $manifestEntries
}
$manifestPath = Join-Path $stagingDirectory "MANIFEST.json"
$manifestJson = (($manifest | ConvertTo-Json -Depth 5) -replace "`r`n", "`n") + "`n"
Write-Vnts2Utf8NoBom -Path $manifestPath -Content $manifestJson

$checksumFiles = @(Get-ChildItem -LiteralPath $stagingDirectory -Recurse -File | Sort-Object {
    Get-Vnts2RelativePath -Root $stagingDirectory -Path $_.FullName
})
$checksumLines = @($checksumFiles | ForEach-Object {
    $relativePath = Get-Vnts2RelativePath -Root $stagingDirectory -Path $_.FullName
    "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $relativePath
})
$checksumsPath = Join-Path $stagingDirectory "SHA256SUMS.txt"
Write-Vnts2Utf8NoBom -Path $checksumsPath -Content (($checksumLines -join "`n") + "`n")

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fixedTimestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$zipStream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $archive = [IO.Compression.ZipArchive]::new(
        $zipStream,
        [IO.Compression.ZipArchiveMode]::Create,
        $false
    )
    try {
        $archiveFiles = @(Get-ChildItem -LiteralPath $stagingDirectory -Recurse -File | Sort-Object {
            Get-Vnts2RelativePath -Root $stagingDirectory -Path $_.FullName
        })
        foreach ($file in $archiveFiles) {
            $relativePath = Get-Vnts2RelativePath -Root $stagingDirectory -Path $file.FullName
            $zipEntry = $archive.CreateEntry(
                "$packageName/$relativePath",
                [IO.Compression.CompressionLevel]::Optimal
            )
            $zipEntry.LastWriteTime = $fixedTimestamp
            $zipEntry.ExternalAttributes = 0
            $entryStream = $zipEntry.Open()
            $fileStream = [IO.File]::OpenRead($file.FullName)
            try {
                $fileStream.CopyTo($entryStream)
            } finally {
                $fileStream.Dispose()
                $entryStream.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    $zipStream.Dispose()
}

$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
Write-Vnts2Utf8NoBom -Path $zipHashPath -Content ("$zipHash  $packageName.zip`n")

$portableRootSynchronized = $false
$portableExecutableHash = $null
$portableManagerHash = $null
if ($SyncPortableRoot) {
    $resolvedPortableRoot = [IO.Path]::GetFullPath($PortableRoot).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $resolvedPortableRoot -PathType Container)) {
        throw "便携根目录不存在：$resolvedPortableRoot"
    }
    $portableData = Join-Path $resolvedPortableRoot "data"
    $portableBackups = Join-Path $portableData ".backups"
    New-Item -ItemType Directory -Path $portableBackups -Force | Out-Null

    foreach ($name in @("vnts2.exe", "VNTS2-Manager.exe")) {
        $sourcePath = Join-Path $stagingDirectory $name
        $targetPath = Join-Path $resolvedPortableRoot $name
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        $targetHash = if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
        } else {
            $null
        }
        if ($sourceHash -ne $targetHash) {
            if ($null -ne $targetHash) {
                $backupPath = Join-Path $portableBackups (
                    "{0}.pre-sync-{1}.bak" -f $name, (Get-Date -Format "yyyyMMdd-HHmmss-fff")
                )
                Copy-Item -LiteralPath $targetPath -Destination $backupPath
                if ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -ne $targetHash) {
                    throw "便携根目录旧文件备份失败：$targetPath"
                }
            }
            $temporaryTarget = Join-Path $resolvedPortableRoot (
                ".{0}.sync-{1}.tmp" -f $name, [Guid]::NewGuid().ToString("N")
            )
            try {
                Copy-Item -LiteralPath $sourcePath -Destination $temporaryTarget
                if ((Get-FileHash -LiteralPath $temporaryTarget -Algorithm SHA256).Hash -ne $sourceHash) {
                    throw "便携根目录临时文件哈希失败：$name"
                }
                if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
                    $replaceBackup = "$temporaryTarget.replace-backup"
                    try {
                        [IO.File]::Replace($temporaryTarget, $targetPath, $replaceBackup, $true)
                    } finally {
                        if (Test-Path -LiteralPath $replaceBackup -PathType Leaf) {
                            Remove-Item -LiteralPath $replaceBackup -Force
                        }
                    }
                } else {
                    Move-Item -LiteralPath $temporaryTarget -Destination $targetPath
                }
            } finally {
                if (Test-Path -LiteralPath $temporaryTarget -PathType Leaf) {
                    Remove-Item -LiteralPath $temporaryTarget -Force
                }
            }
            if ((Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash -ne $sourceHash) {
                throw "便携根目录同步后哈希失败：$targetPath"
            }
        }
    }

    Copy-Item -LiteralPath $dataReadmePath -Destination (Join-Path $portableData "README.txt") -Force
    $portableExecutableHash = (Get-FileHash -LiteralPath (Join-Path $resolvedPortableRoot "vnts2.exe") -Algorithm SHA256).Hash
    $portableManagerHash = (Get-FileHash -LiteralPath (Join-Path $resolvedPortableRoot "VNTS2-Manager.exe") -Algorithm SHA256).Hash
    $portableRootSynchronized = $true
}

[pscustomobject]@{
    PackageName = $packageName
    StagingDirectory = $stagingDirectory
    ZipPath = $zipPath
    ZipLength = (Get-Item -LiteralPath $zipPath).Length
    ZipSHA256 = $zipHash
    ZipHashPath = $zipHashPath
    PortableRootSynchronized = $portableRootSynchronized
    PortableExecutableSHA256 = $portableExecutableHash
    PortableManagerSHA256 = $portableManagerHash
}
