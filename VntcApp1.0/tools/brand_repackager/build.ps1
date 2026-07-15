param(
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Resolve-Path (Join-Path $toolRoot '..\..')
$sourceDir = Join-Path $toolRoot 'src'
$buildDir = Join-Path $toolRoot 'build'
$toolchainDir = Join-Path $buildDir 'toolchain'
$toolchainZip = Join-Path $buildDir 'toolchain.zip'
$officialAndroidTrustConfig = Join-Path $projectRoot `
    'config\android_official_signing_trust.json'
$releaseDir = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Join-Path $projectRoot 'release\brand_repackager'
} else {
    [System.IO.Path]::GetFullPath($OutputDirectory)
}
$outputExe = Join-Path $releaseDir 'VNT_一键品牌换牌工具.exe'
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

function Reset-Directory([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $expectedRoot = [System.IO.Path]::GetFullPath($toolRoot).TrimEnd('\') + '\'
    if (-not $full.StartsWith($expectedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理工具目录之外的路径：$full"
    }
    if (Test-Path -LiteralPath $full) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $full | Out-Null
}

function Assert-NoSensitiveSigningMaterial([string]$Path) {
    $forbiddenExtensions = @('.p12', '.pfx', '.jks', '.keystore')
    $forbiddenFileNames = @('profile.json')
    $textExtensions = @(
        '.json', '.yaml', '.yml', '.txt', '.config', '.properties',
        '.ps1', '.xml', '.ini'
    )
    $forbiddenTextPatterns = @(
        '(?i)"passwordProtectedBase64"\s*:',
        '(?i)"(?:keystore|keystorePath)"\s*:',
        '(?i)"(?:profile|profileId)"\s*:',
        '(?i)\bDPAPI\b',
        '(?i)DataProtectionScope\.CurrentUser',
        '(?i)ProtectedData\.(?:Protect|Unprotect)'
    )
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File)
    foreach ($file in $files) {
        $extension = [System.IO.Path]::GetExtension($file.Name).ToLowerInvariant()
        if ($forbiddenExtensions -contains $extension -or
            $forbiddenFileNames -contains $file.Name.ToLowerInvariant()) {
            throw "内置工具链不得包含签名私钥或签名档案：$($file.FullName)"
        }

        if (($extension -eq '.jar' -or $extension -eq '.zip') -and
            $file.Length -gt 0) {
            $archive = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
            try {
                foreach ($entry in $archive.Entries) {
                    $entryName = [System.IO.Path]::GetFileName($entry.FullName)
                    $entryExtension = [System.IO.Path]::GetExtension(
                        $entryName
                    ).ToLowerInvariant()
                    if ($forbiddenExtensions -contains $entryExtension -or
                        $forbiddenFileNames -contains $entryName.ToLowerInvariant()) {
                        throw "内置工具链归档不得包含签名私钥或签名档案：$($entry.FullName)"
                    }
                }
            } finally {
                $archive.Dispose()
            }
        }

        if ($textExtensions -contains $extension -and
            $file.Length -le 4MB) {
            $content = [System.IO.File]::ReadAllText($file.FullName)
            foreach ($pattern in $forbiddenTextPatterns) {
                if ($content -match $pattern) {
                    throw "内置工具链不得包含签名档案或 DPAPI 私密字段：$($file.FullName)"
                }
            }
        }
    }
}

if (-not (Test-Path -LiteralPath $csc)) {
    throw "Windows .NET Framework C# 编译器缺失：$csc"
}
if (-not (Test-Path -LiteralPath $officialAndroidTrustConfig -PathType Leaf)) {
    throw "Android 官方签名公开信任配置缺失：$officialAndroidTrustConfig"
}

$innoCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6'),
    'C:\Program Files (x86)\Inno Setup 6',
    'C:\Program Files\Inno Setup 6'
)
$innoDir = $innoCandidates | Where-Object {
    Test-Path -LiteralPath (Join-Path $_ 'ISCC.exe')
} | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($innoDir)) {
    throw '构建工具软件时需要本机存在 Inno Setup 6；最终工具运行时不需要安装。'
}

Reset-Directory -Path $buildDir
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $toolchainDir 'inno') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $toolchainDir 'rcedit') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $toolchainDir 'assets') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $toolchainDir 'licenses') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $toolchainDir 'android') | Out-Null

Get-ChildItem -LiteralPath $innoDir -File | Copy-Item -Destination (Join-Path $toolchainDir 'inno') -Force
Copy-Item -LiteralPath (Join-Path $toolRoot 'third_party\rcedit\rcedit-x64.exe') -Destination (Join-Path $toolchainDir 'rcedit\rcedit-x64.exe') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\app_icon.ico') -Destination (Join-Path $toolchainDir 'assets\app_icon.ico') -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'scripts\inno\ChineseSimplified.isl') -Destination (Join-Path $toolchainDir 'assets\ChineseSimplified.isl') -Force
Copy-Item -LiteralPath (Join-Path $innoDir 'license.txt') -Destination (Join-Path $toolchainDir 'licenses\INNO_SETUP_LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $toolRoot 'third_party\rcedit\LICENSE.txt') -Destination (Join-Path $toolchainDir 'licenses\RCEDIT_LICENSE.txt') -Force

& (Join-Path $toolRoot 'prepare_android_toolchain.ps1') `
    -Destination (Join-Path $toolchainDir 'android')
if ($LASTEXITCODE -ne 0) {
    throw "Android 内置工具链准备失败：$LASTEXITCODE"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
Assert-NoSensitiveSigningMaterial -Path $toolchainDir

[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $toolchainDir,
    $toolchainZip,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false
)

$sourceFiles = Get-ChildItem -LiteralPath $sourceDir -Filter '*.cs' -File |
    Sort-Object Name |
    ForEach-Object { $_.FullName }

$compileArgs = @(
    '/nologo',
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    "/out:$outputExe",
    "/win32manifest:$(Join-Path $sourceDir 'app.manifest')",
    "/win32icon:$(Join-Path $projectRoot 'assets\app_icon.ico')",
    "/resource:$toolchainZip,VntBrandRepackager.Toolchain.zip",
    "/resource:$officialAndroidTrustConfig,VntBrandRepackager.OfficialAndroidSigningTrust.json",
    '/reference:System.dll',
    '/reference:System.Core.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.IO.Compression.dll',
    '/reference:System.IO.Compression.FileSystem.dll',
    '/reference:System.Security.dll',
    '/reference:System.Web.Extensions.dll',
    '/reference:System.Xml.dll',
    '/reference:System.Xml.Linq.dll'
)
$compileArgs += $sourceFiles

& $csc $compileArgs
if ($LASTEXITCODE -ne 0) {
    throw "品牌换牌工具编译失败：$LASTEXITCODE"
}

$hash = (Get-FileHash -LiteralPath $outputExe -Algorithm SHA256).Hash
Set-Content -LiteralPath "$outputExe.sha256" -Value "$hash *$(Split-Path -Leaf $outputExe)" -Encoding UTF8
Write-Host "[OK] 工具软件：$outputExe"
Write-Host "[OK] SHA-256：$hash"
