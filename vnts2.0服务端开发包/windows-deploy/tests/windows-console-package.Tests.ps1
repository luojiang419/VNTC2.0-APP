$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Contract {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$deployRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $deployRoot "build-vnts2-console-package.ps1"
$consoleRoot = (Resolve-Path -LiteralPath (Join-Path $deployRoot "..\..\VntsConsole2.0")).Path
$flutterRelease = Join-Path $consoleRoot "build\windows\x64\runner\Release"
$serverRelease = Join-Path $deployRoot "..\official-vnts-source-2.0.0\target\release\vnts2.exe"
$temporaryRoot = Join-Path $env:TEMP ("vnts2-console-package-contract-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

try {
    Assert-Contract (Test-Path -LiteralPath $buildScript -PathType Leaf) "缺少增强版发布脚本。"
    Assert-Contract (Test-Path -LiteralPath $flutterRelease -PathType Container) "缺少 Flutter Release。"
    Assert-Contract (Test-Path -LiteralPath $serverRelease -PathType Leaf) "缺少服务端 Release。"

    $version = "2.0.0-contract"
    $first = & $buildScript `
        -SourceExecutable $serverRelease `
        -ConsoleProjectRoot $consoleRoot `
        -FlutterReleaseDirectory $flutterRelease `
        -OutputDirectory $temporaryRoot `
        -Version $version `
        -SkipFlutterBuild
    $firstHash = $first.ZipSHA256
    $second = & $buildScript `
        -SourceExecutable $serverRelease `
        -ConsoleProjectRoot $consoleRoot `
        -FlutterReleaseDirectory $flutterRelease `
        -OutputDirectory $temporaryRoot `
        -Version $version `
        -SkipFlutterBuild

    Assert-Contract ($firstHash -eq $second.ZipSHA256) "增强版 ZIP 不是可重复构建。"
    Assert-Contract ((Get-FileHash -LiteralPath $second.ZipPath -Algorithm SHA256).Hash -eq $second.ZipSHA256) "增强版 ZIP 哈希不一致。"
    Assert-Contract (Test-Path -LiteralPath (Join-Path $second.StagingDirectory "VNTS2-Console.exe") -PathType Leaf) "增强包缺少控制台入口。"
    Assert-Contract (Test-Path -LiteralPath (Join-Path $second.StagingDirectory "flutter_windows.dll") -PathType Leaf) "增强包缺少 Flutter 运行库。"
    Assert-Contract (Test-Path -LiteralPath (Join-Path $second.StagingDirectory "tray_manager_plugin.dll") -PathType Leaf) "增强包缺少系统托盘运行库。"
    Assert-Contract (Test-Path -LiteralPath (Join-Path $second.StagingDirectory "data\flutter_assets\windows\runner\resources\app_icon.ico") -PathType Leaf) "增强包缺少系统托盘图标。"
    Assert-Contract (Test-Path -LiteralPath (Join-Path $second.StagingDirectory "data\app.so") -PathType Leaf) "增强包缺少 Dart AOT 产物。"
    Assert-Contract (Test-Path -LiteralPath (Join-Path $second.StagingDirectory "vnts2.exe") -PathType Leaf) "增强包缺少服务端。"
    Assert-Contract (Test-Path -LiteralPath (Join-Path $second.StagingDirectory "initialize-vnts2-console.ps1") -PathType Leaf) "增强包缺少零安装初始化脚本。"
    Assert-Contract (-not (Test-Path -LiteralPath (Join-Path $second.StagingDirectory "VNTS2-Manager.exe"))) "增强包不应混入轻量入口。"
    Assert-Contract (-not (Test-Path -LiteralPath (Join-Path $second.StagingDirectory "data\config.toml"))) "增强包不应包含真实配置。"
    $pubspec = Get-Content -LiteralPath (Join-Path $consoleRoot "pubspec.yaml") -Raw -Encoding UTF8
    $expectedConsoleVersion = [regex]::Match($pubspec, '(?m)^version:\s*(\S+)\s*$').Groups[1].Value
    $consoleVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $second.StagingDirectory "VNTS2-Console.exe")).FileVersion
    Assert-Contract ($consoleVersion -eq $expectedConsoleVersion) "增强包控制台版本不是当前 pubspec 版本。"

    $manifest = Get-Content -LiteralPath (Join-Path $second.StagingDirectory "MANIFEST.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Contract ($manifest.package_name -eq "vnts2-console-$version-windows-x64") "增强版 MANIFEST 包名错误。"
    Assert-Contract ($manifest.entrypoint -eq "VNTS2-Console.exe") "增强版 MANIFEST 入口错误。"
    foreach ($entry in $manifest.files) {
        $path = Join-Path $second.StagingDirectory $entry.path.Replace('/', '\')
        Assert-Contract (Test-Path -LiteralPath $path -PathType Leaf) "MANIFEST 文件不存在：$($entry.path)"
        Assert-Contract ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $entry.sha256) "MANIFEST 哈希错误：$($entry.path)"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extractRoot = Join-Path $temporaryRoot "extracted"
    [IO.Compression.ZipFile]::ExtractToDirectory($second.ZipPath, $extractRoot)
    $distributionRoot = Join-Path $extractRoot $second.PackageName
    Assert-Contract (Test-Path -LiteralPath (Join-Path $distributionRoot "VNTS2-Console.exe") -PathType Leaf) "ZIP 解压后缺少控制台。"
    Assert-Contract (Test-Path -LiteralPath (Join-Path $distributionRoot "status-vnts2-service.ps1") -PathType Leaf) "ZIP 解压后缺少运维脚本。"
    Assert-Contract (Test-Path -LiteralPath (Join-Path $distributionRoot "initialize-vnts2-console.ps1") -PathType Leaf) "ZIP 解压后缺少零安装初始化脚本。"
    Assert-Contract (Test-Path -LiteralPath (Join-Path $distributionRoot "tray_manager_plugin.dll") -PathType Leaf) "ZIP 解压后缺少托盘运行库。"

    $flutterReleaseWithoutLegacyManifest = Join-Path $temporaryRoot "flutter-release-without-legacy-manifest"
    Copy-Item -LiteralPath $flutterRelease -Destination $flutterReleaseWithoutLegacyManifest -Recurse
    $legacyManifest = Join-Path $flutterReleaseWithoutLegacyManifest "native_assets.json"
    if (Test-Path -LiteralPath $legacyManifest -PathType Leaf) {
        Remove-Item -LiteralPath $legacyManifest -Force
    }
    $withoutLegacyManifest = & $buildScript `
        -SourceExecutable $serverRelease `
        -ConsoleProjectRoot $consoleRoot `
        -FlutterReleaseDirectory $flutterReleaseWithoutLegacyManifest `
        -OutputDirectory $temporaryRoot `
        -Version "${version}-no-legacy-manifest" `
        -SkipFlutterBuild
    Assert-Contract (Test-Path -LiteralPath $withoutLegacyManifest.ZipPath -PathType Leaf) "缺少旧版 native_assets.json 时未能生成增强包。"
    Assert-Contract (-not (Test-Path -LiteralPath (Join-Path $withoutLegacyManifest.StagingDirectory "native_assets.json"))) "新版 Flutter 负载不应虚构旧版 native_assets.json。"

    Set-Content -LiteralPath (Join-Path $flutterReleaseWithoutLegacyManifest "unreviewed-runtime.dll") -Value "contract" -Encoding ASCII
    $unknownFileRejected = $false
    try {
        & $buildScript `
            -SourceExecutable $serverRelease `
            -ConsoleProjectRoot $consoleRoot `
            -FlutterReleaseDirectory $flutterReleaseWithoutLegacyManifest `
            -OutputDirectory $temporaryRoot `
            -Version "${version}-unknown-file" `
            -SkipFlutterBuild | Out-Null
    } catch {
        $unknownFileRejected = $true
    }
    Assert-Contract $unknownFileRejected "未审核的 Flutter 负载文件未被严格白名单拒绝。"

    "windows-console-package.Tests.ps1 PASS"
} finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot).TrimEnd('\', '/')
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
        $safe = $resolved.StartsWith($tempBase + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -like "vnts2-console-package-contract-*"
        if (-not $safe) { throw "拒绝清理边界以外的测试目录：$resolved" }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
