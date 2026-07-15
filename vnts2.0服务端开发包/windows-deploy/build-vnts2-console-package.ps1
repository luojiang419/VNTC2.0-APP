param(
    [string]$SourceExecutable = (Join-Path $PSScriptRoot "..\official-vnts-source-2.0.0\target\release\vnts2.exe"),
    [string]$ConsoleProjectRoot = (Join-Path $PSScriptRoot "..\..\VntsConsole2.0"),
    [string]$FlutterExecutable = "D:\APPdata\flutter\bin\flutter.bat",
    [string]$FlutterReleaseDirectory = "",
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "dist"),
    [string]$Version = "2.0.0",
    [switch]$SkipFlutterBuild
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
        ' -ConsoleProjectRoot ' + (& $quoteArgument $ConsoleProjectRoot) +
        ' -FlutterExecutable ' + (& $quoteArgument $FlutterExecutable) +
        ' -FlutterReleaseDirectory ' + (& $quoteArgument $FlutterReleaseDirectory) +
        ' -OutputDirectory ' + (& $quoteArgument $OutputDirectory) +
        ' -Version ' + (& $quoteArgument $Version) +
        $(if ($SkipFlutterBuild) { ' -SkipFlutterBuild' } else { '' }) +
        ' | ConvertTo-Json -Compress } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }'
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $json = & $windowsPowerShell `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -EncodedCommand $encodedCommand
    if ($LASTEXITCODE -ne 0) {
        throw "Windows PowerShell 5.1 增强版发布包生成失败（退出码 $LASTEXITCODE）。"
    }
    ($json -join "`n") | ConvertFrom-Json
    return
}

if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
    throw "版本号只能包含字母、数字、点、下划线和连字符，且长度不能超过 64。"
}
if (-not (Test-Path -LiteralPath $SourceExecutable -PathType Leaf)) {
    throw "未找到服务端 Release 可执行文件：$SourceExecutable"
}
if (-not (Test-Path -LiteralPath $ConsoleProjectRoot -PathType Container)) {
    throw "未找到 Flutter 增强控制台工程：$ConsoleProjectRoot"
}

$resolvedConsoleRoot = (Resolve-Path -LiteralPath $ConsoleProjectRoot).Path
if (-not $SkipFlutterBuild) {
    if (-not (Test-Path -LiteralPath $FlutterExecutable -PathType Leaf)) {
        throw "未找到 Flutter：$FlutterExecutable"
    }
    Push-Location $resolvedConsoleRoot
    try {
        & $FlutterExecutable build windows --release
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter Windows Release 构建失败（退出码 $LASTEXITCODE）。"
        }
    } finally {
        Pop-Location
    }
}

if ([string]::IsNullOrWhiteSpace($FlutterReleaseDirectory)) {
    $FlutterReleaseDirectory = Join-Path $resolvedConsoleRoot "build\windows\x64\runner\Release"
}
if (-not (Test-Path -LiteralPath $FlutterReleaseDirectory -PathType Container)) {
    throw "未找到 Flutter Windows Release 目录：$FlutterReleaseDirectory"
}
$resolvedFlutterRelease = (Resolve-Path -LiteralPath $FlutterReleaseDirectory).Path

function Write-Vnts2Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
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

$flutterFiles = @(
    "VNTS2-Console.exe",
    "flutter_windows.dll",
    "file_selector_windows_plugin.dll",
    "screen_retriever_windows_plugin.dll",
    "tray_manager_plugin.dll",
    "window_manager_plugin.dll",
    "native_assets.json",
    "data\app.so",
    "data\icudtl.dat",
    "data\flutter_assets\AssetManifest.bin",
    "data\flutter_assets\FontManifest.json",
    "data\flutter_assets\NativeAssetsManifest.json",
    "data\flutter_assets\NOTICES.Z",
    "data\flutter_assets\fonts\MaterialIcons-Regular.otf",
    "data\flutter_assets\windows\runner\resources\app_icon.ico",
    "data\flutter_assets\shaders\ink_sparkle.frag",
    "data\flutter_assets\shaders\stretch_effect.frag"
)
foreach ($relativePath in $flutterFiles) {
    $sourcePath = Join-Path $resolvedFlutterRelease $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Flutter Release 负载不完整：$relativePath"
    }
}
$actualFlutterFiles = @(Get-ChildItem -LiteralPath $resolvedFlutterRelease -Recurse -File | ForEach-Object {
    Get-Vnts2RelativePath -Root $resolvedFlutterRelease -Path $_.FullName
} | Sort-Object)
$expectedFlutterFiles = @($flutterFiles | ForEach-Object { $_.Replace('\', '/') } | Sort-Object)
if (($actualFlutterFiles -join "`n") -cne ($expectedFlutterFiles -join "`n")) {
    throw "Flutter Release 文件集合与发布白名单不一致，请先审核新增或缺失运行库。"
}

$deployRoot = $PSScriptRoot
$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $deployRoot "..\official-vnts-source-2.0.0")).Path
$resolvedExecutable = (Resolve-Path -LiteralPath $SourceExecutable).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$outputRoot = (Resolve-Path -LiteralPath $OutputDirectory).Path
$packageName = "vnts2-console-$Version-windows-x64"
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

foreach ($relativePath in $flutterFiles) {
    $sourcePath = Join-Path $resolvedFlutterRelease $relativePath
    $destination = Join-Path $stagingDirectory $relativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destination
}

$sourceFiles = [ordered]@{
    "vnts2.exe" = $resolvedExecutable
    "config.example.toml" = (Join-Path $deployRoot "config.example.toml")
    "README.md" = (Join-Path $deployRoot "README-CONSOLE-PACKAGE.md")
    "NOTICE" = (Join-Path $sourceRoot "NOTICE")
    "vnts2-service-common.ps1" = (Join-Path $deployRoot "vnts2-service-common.ps1")
    "initialize-vnts2-console.ps1" = (Join-Path $deployRoot "initialize-vnts2-console.ps1")
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
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $entry.Value -Destination $destination
}

$dataReadmePath = Join-Path $stagingDirectory "data\README.txt"
Write-Vnts2Utf8NoBom -Path $dataReadmePath -Content @"
VNTS2 增强版便携数据与 Flutter 运行目录

本目录同时包含增强控制台运行资源和 VNTS2 可变数据。首次安装后，配置、数据库、证书、密钥、日志和备份会继续保存在本目录。
迁移时请复制整个增强版文件夹；卸载 Windows 服务不会删除本目录。
不要把使用后的真实 data 内容重新打入公开发布包。
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
    product = "VNTS 2.0 Enhanced Console"
    entrypoint = "VNTS2-Console.exe"
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
            $entry = $archive.CreateEntry(
                "$packageName/$relativePath",
                [IO.Compression.CompressionLevel]::Optimal
            )
            $entry.LastWriteTime = $fixedTimestamp
            $entry.ExternalAttributes = 0
            $entryStream = $entry.Open()
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

[pscustomobject]@{
    PackageName = $packageName
    StagingDirectory = $stagingDirectory
    ZipPath = $zipPath
    ZipLength = (Get-Item -LiteralPath $zipPath).Length
    ZipSHA256 = $zipHash
    ZipHashPath = $zipHashPath
    ConsoleSHA256 = (Get-FileHash -LiteralPath (Join-Path $stagingDirectory "VNTS2-Console.exe") -Algorithm SHA256).Hash
    ServerSHA256 = (Get-FileHash -LiteralPath (Join-Path $stagingDirectory "vnts2.exe") -Algorithm SHA256).Hash
}
