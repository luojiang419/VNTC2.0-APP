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

function Get-RelativeFileList {
    param([Parameter(Mandatory = $true)][string]$Root)

    return @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object {
        $_.FullName.Substring($Root.Length + 1).Replace('\', '/')
    } | Sort-Object)
}

$deployRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $deployRoot "build-vnts2-windows-package.ps1"
$legacyExecutable = Join-Path $deployRoot "vnts2.exe"
$legacyConfig = Join-Path $deployRoot "config.toml"
$legacyExecutableHash = (Get-FileHash -LiteralPath $legacyExecutable -Algorithm SHA256).Hash
Assert-Contract (-not (Test-Path -LiteralPath $legacyConfig)) `
    "便携根目录不应保留容易误用的 config.toml；真实配置必须位于 data。"
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$temporaryRoot = Join-Path $tempBase ("vnts2-package-contract-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

try {
    $fakeExecutable = Join-Path $temporaryRoot "vnts2.exe"
    [IO.File]::WriteAllBytes($fakeExecutable, [Text.Encoding]::UTF8.GetBytes("deterministic-test-binary"))
    $outputDirectory = Join-Path $temporaryRoot "output with spaces"
    $version = "9.9.9-test"

    $first = & $buildScript `
        -SourceExecutable $fakeExecutable `
        -OutputDirectory $outputDirectory `
        -Version $version
    $firstHash = $first.ZipSHA256
    $firstLength = $first.ZipLength
    [IO.File]::SetLastWriteTimeUtc($fakeExecutable, [DateTime]::UtcNow.AddDays(-7))
    $second = & $buildScript `
        -SourceExecutable $fakeExecutable `
        -OutputDirectory $outputDirectory `
        -Version $version

    Assert-Contract ($firstHash -eq $second.ZipSHA256) "相同输入重复生成的 ZIP 哈希不一致。"
    Assert-Contract ($firstLength -eq $second.ZipLength) "相同输入重复生成的 ZIP 长度不一致。"

    $stagingDirectory = $second.StagingDirectory
    $expectedFiles = @(
        "MANIFEST.json",
        "NOTICE",
        "README.md",
        "SHA256SUMS.txt",
        "VNTS2-Manager.exe",
        "config.example.toml",
        "data/README.txt",
        "diagnose-vnts2-service.ps1",
        "install-vnts2-service.ps1",
        "licenses/dijkstrajs.txt",
        "licenses/fontawesome.txt",
        "licenses/qrcode.txt",
        "licenses/tailwindcss.txt",
        "licenses/vue.txt",
        "start-vnts2-service.ps1",
        "status-vnts2-service.ps1",
        "stop-vnts2-service.ps1",
        "uninstall-vnts2-service.ps1",
        "update-vnts2-service.ps1",
        "vnts2-service-common.ps1",
        "vnts2.exe"
    ) | Sort-Object
    $actualFiles = Get-RelativeFileList -Root $stagingDirectory
    Assert-Contract `
        (($actualFiles -join "`n") -ceq ($expectedFiles -join "`n")) `
        "staging 文件不符合严格发布白名单。"

    $forbiddenFiles = @($actualFiles | Where-Object {
        $_ -match '(?i)(^|/)(config\.toml|logs?|\.backups?|.*\.db(?:\..*)?|.*\.(?:key|pem|pfx|log|lock))$'
    })
    Assert-Contract ($forbiddenFiles.Count -eq 0) "发布包包含数据库、日志、密钥、锁或真实配置。"

    $template = Get-Content -LiteralPath (Join-Path $stagingDirectory "config.example.toml") -Raw
    $activeSecretPattern = '(?m)^\s*(?:password|server_token|wireguard_master_key_file|cert|key)\s*='
    Assert-Contract (-not [regex]::IsMatch($template, $activeSecretPattern)) "配置模板包含有效敏感配置项。"

    $manifestPath = Join-Path $stagingDirectory "MANIFEST.json"
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Contract ($manifest.package_name -eq "vnts2-$version-windows-x64") "MANIFEST 包名错误。"
    Assert-Contract ($manifest.files.Count -eq 19) "MANIFEST 应只记录 19 个白名单负载文件。"
    foreach ($entry in $manifest.files) {
        $filePath = Join-Path $stagingDirectory $entry.path.Replace('/', '\')
        Assert-Contract (Test-Path -LiteralPath $filePath -PathType Leaf) "MANIFEST 引用了不存在的文件。"
        Assert-Contract ((Get-Item -LiteralPath $filePath).Length -eq $entry.length) "MANIFEST 文件长度不匹配。"
        Assert-Contract `
            ((Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash -eq $entry.sha256) `
            "MANIFEST 文件哈希不匹配。"
    }

    $checksumLines = @(Get-Content -LiteralPath (Join-Path $stagingDirectory "SHA256SUMS.txt"))
    Assert-Contract ($checksumLines.Count -eq 20) "SHA256SUMS 应覆盖 19 个负载文件和 MANIFEST。"
    foreach ($line in $checksumLines) {
        Assert-Contract ($line -match '^([A-F0-9]{64})  (.+)$') "SHA256SUMS 格式无效。"
        $filePath = Join-Path $stagingDirectory $matches[2].Replace('/', '\')
        Assert-Contract (Test-Path -LiteralPath $filePath -PathType Leaf) "SHA256SUMS 引用了不存在的文件。"
        Assert-Contract `
            ((Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash -eq $matches[1]) `
            "SHA256SUMS 文件哈希不匹配。"
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($second.ZipPath)
    try {
        $zipEntries = @($archive.Entries | ForEach-Object FullName | Sort-Object)
    } finally {
        $archive.Dispose()
    }
    $expectedZipEntries = @($actualFiles | ForEach-Object { "$($second.PackageName)/$_" } | Sort-Object)
    Assert-Contract `
        (($zipEntries -join "`n") -ceq ($expectedZipEntries -join "`n")) `
        "ZIP 条目与 staging 不一致。"

    $zipHashLine = (Get-Content -LiteralPath $second.ZipHashPath -Raw).Trim()
    Assert-Contract ($zipHashLine -eq "$($second.ZipSHA256)  $($second.PackageName).zip") "ZIP 外部哈希文件错误。"
    Assert-Contract `
        ((Get-FileHash -LiteralPath $second.ZipPath -Algorithm SHA256).Hash -eq $second.ZipSHA256) `
        "ZIP 实际哈希与报告值不一致。"
    Assert-Contract `
        ((Get-FileHash -LiteralPath $legacyExecutable -Algorithm SHA256).Hash -eq $legacyExecutableHash) `
        "发布脚本覆盖了旧 windows-deploy/vnts2.exe。"
    Assert-Contract `
        (-not (Test-Path -LiteralPath $legacyConfig)) `
        "发布脚本不应在便携根目录创建 config.toml。"

    $portableRoot = Join-Path $temporaryRoot "portable root"
    New-Item -ItemType Directory -Path $portableRoot | Out-Null
    [IO.File]::WriteAllBytes(
        (Join-Path $portableRoot "vnts2.exe"),
        [Text.Encoding]::UTF8.GetBytes("old-portable-binary")
    )
    [IO.File]::WriteAllBytes(
        (Join-Path $portableRoot "VNTS2-Manager.exe"),
        [Text.Encoding]::UTF8.GetBytes("old-portable-manager")
    )
    $synced = & $buildScript `
        -SourceExecutable $fakeExecutable `
        -OutputDirectory $outputDirectory `
        -Version $version `
        -SyncPortableRoot `
        -PortableRoot $portableRoot
    Assert-Contract $synced.PortableRootSynchronized "便携根目录同步未报告成功。"
    Assert-Contract `
        ((Get-FileHash -LiteralPath (Join-Path $portableRoot "vnts2.exe") -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $fakeExecutable -Algorithm SHA256).Hash) `
        "便携根目录 vnts2.exe 未同步。"
    Assert-Contract `
        ((Get-FileHash -LiteralPath (Join-Path $portableRoot "VNTS2-Manager.exe") -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath (Join-Path $deployRoot "VNTS2-Manager.exe") -Algorithm SHA256).Hash) `
        "便携根目录 GUI 未同步。"
    Assert-Contract (Test-Path -LiteralPath (Join-Path $portableRoot "data\README.txt") -PathType Leaf) `
        "便携根目录缺少 data 说明。"
    Assert-Contract (-not (Test-Path -LiteralPath (Join-Path $portableRoot "data\config.toml"))) `
        "发布同步不应创建真实 data 配置。"
    Assert-Contract (@(Get-ChildItem -LiteralPath (Join-Path $portableRoot "data\.backups") -File).Count -eq 2) `
        "便携同步未备份被替换的程序和 GUI。"
} finally {
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    $safePrefix = $tempBase + [IO.Path]::DirectorySeparatorChar
    $safeToDelete = $resolvedTemporaryRoot.StartsWith(
        $safePrefix,
        [StringComparison]::OrdinalIgnoreCase
    ) -and (Split-Path -Leaf $resolvedTemporaryRoot) -like 'vnts2-package-contract-*'
    if (-not $safeToDelete) {
        throw "拒绝清理边界以外的测试目录：$resolvedTemporaryRoot"
    }
    if (Test-Path -LiteralPath $resolvedTemporaryRoot) {
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}

Write-Host "Windows 可重复发布包契约测试通过。"
