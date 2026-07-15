param(
    [Parameter(Mandatory = $true)]
    [string]$Destination,
    [string]$CacheDirectory = ''
)

$ErrorActionPreference = 'Stop'
$apktoolVersion = '3.0.2'
$apktoolSha256 = 'EEE4669A704A14E0623407E6701B0B91887E61E1E4049CB7A82833E14AE8B5FD'
$apktoolUri = 'https://github.com/iBotPeaches/Apktool/releases/download/v3.0.2/apktool_3.0.2.jar'
$apktoolLicenseUri = 'https://raw.githubusercontent.com/iBotPeaches/Apktool/v3.0.2/LICENSE.md'
$apktoolLicenseSha256 = 'C49C53FDC79E1143A1892EB7333B595EECDBE40623E72BE325267DB28CB72114'
$temurinVersion = '17.0.19+10'
$temurinSha256 = 'B5B235C48ADF6A081874B812C630B9F4B5F637B7A5ED18B9174D08A41EC4C235'
$temurinUri = 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.19%2B10/OpenJDK17U-jdk_x64_windows_hotspot_17.0.19_10.zip'
$androidBuildToolsVersion = '36.0.0'
$utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)

if ([string]::IsNullOrWhiteSpace($CacheDirectory)) {
    $CacheDirectory = Join-Path $env:LOCALAPPDATA 'VNTBrandRepackager\build-cache'
}
$cacheRoot = [System.IO.Path]::GetFullPath($CacheDirectory)
$destinationRoot = [System.IO.Path]::GetFullPath($Destination)

function Remove-DirectorySafely([string]$Path, [string]$AllowedRoot) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理允许目录之外的路径：$full"
    }
    if (Test-Path -LiteralPath $full) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

function Get-VerifiedDownload(
    [string]$Uri,
    [string]$Path,
    [string]$ExpectedSha256
) {
    if (Test-Path -LiteralPath $Path) {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if ($actual -eq $ExpectedSha256) {
            return
        }
        Remove-Item -LiteralPath $Path -Force
    }

    $temporary = "$Path.download"
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    try {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $temporary
        } catch {
            Invoke-WebRequest -UseBasicParsing -Proxy 'http://127.0.0.1:7890' `
                -Uri $Uri -OutFile $temporary
        }
        $actual = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
        if ($actual -ne $ExpectedSha256) {
            throw "下载文件 SHA-256 不匹配：$Uri`n期望：$ExpectedSha256`n实际：$actual"
        }
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Find-AndroidBuildTools {
    $sdkCandidates = @(
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($sdk in $sdkCandidates) {
        $candidate = Join-Path $sdk "build-tools\$androidBuildToolsVersion"
        $required = @(
            (Join-Path $candidate 'zipalign.exe'),
            (Join-Path $candidate 'lib\apksigner.jar'),
            (Join-Path $candidate 'NOTICE.txt')
        )
        if (@($required | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    throw "未找到固定版本 Android Build Tools $androidBuildToolsVersion（需要 zipalign.exe、apksigner.jar 和 NOTICE.txt）"
}

New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
$licensesDirectory = Join-Path (Split-Path -Parent $destinationRoot) 'licenses'
New-Item -ItemType Directory -Force -Path $licensesDirectory | Out-Null

$apktoolCache = Join-Path $cacheRoot "apktool_$apktoolVersion.jar"
Get-VerifiedDownload -Uri $apktoolUri -Path $apktoolCache `
    -ExpectedSha256 $apktoolSha256
Copy-Item -LiteralPath $apktoolCache `
    -Destination (Join-Path $destinationRoot 'apktool.jar') -Force

$licenseCache = Join-Path $cacheRoot "apktool_$apktoolVersion.LICENSE.md"
Get-VerifiedDownload -Uri $apktoolLicenseUri -Path $licenseCache `
    -ExpectedSha256 $apktoolLicenseSha256
Copy-Item -LiteralPath $licenseCache `
    -Destination (Join-Path $licensesDirectory 'APKTOOL_LICENSE.md') -Force

$jdkArchive = Join-Path $cacheRoot 'OpenJDK17U-jdk_x64_windows_hotspot_17.0.19_10.zip'
Get-VerifiedDownload -Uri $temurinUri -Path $jdkArchive `
    -ExpectedSha256 $temurinSha256
$jdkExtractRoot = Join-Path $cacheRoot ('.extract_jdk_' + [guid]::NewGuid().ToString('N'))
$jreDestination = Join-Path $destinationRoot 'jre'
Remove-DirectorySafely -Path $jreDestination -AllowedRoot $destinationRoot
New-Item -ItemType Directory -Force -Path $jdkExtractRoot | Out-Null
try {
    Expand-Archive -LiteralPath $jdkArchive -DestinationPath $jdkExtractRoot -Force
    $jdkHome = Get-ChildItem -LiteralPath $jdkExtractRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\jlink.exe') } |
        Select-Object -First 1
    if ($null -eq $jdkHome) {
        throw 'Temurin JDK 压缩包中缺少 jlink.exe'
    }
    $modules = @(
        'java.base',
        'java.desktop',
        'java.logging',
        'java.management',
        'java.naming',
        'java.xml',
        'jdk.crypto.ec',
        'jdk.zipfs'
    ) -join ','
    & (Join-Path $jdkHome.FullName 'bin\jlink.exe') `
        --add-modules $modules `
        --strip-debug `
        --no-header-files `
        --no-man-pages `
        --compress=2 `
        --output $jreDestination
    if ($LASTEXITCODE -ne 0) {
        throw "jlink 裁剪 Java 运行时失败：$LASTEXITCODE"
    }
} finally {
    Remove-DirectorySafely -Path $jdkExtractRoot -AllowedRoot $cacheRoot
}

$buildTools = Find-AndroidBuildTools
Copy-Item -LiteralPath (Join-Path $buildTools 'zipalign.exe') `
    -Destination (Join-Path $destinationRoot 'zipalign.exe') -Force
if (Test-Path -LiteralPath (Join-Path $buildTools 'libwinpthread-1.dll')) {
    Copy-Item -LiteralPath (Join-Path $buildTools 'libwinpthread-1.dll') `
        -Destination (Join-Path $destinationRoot 'libwinpthread-1.dll') -Force
}
Copy-Item -LiteralPath (Join-Path $buildTools 'lib\apksigner.jar') `
    -Destination (Join-Path $destinationRoot 'apksigner.jar') -Force
Copy-Item -LiteralPath (Join-Path $buildTools 'NOTICE.txt') `
    -Destination (Join-Path $licensesDirectory 'ANDROID_BUILD_TOOLS_NOTICE.txt') -Force

$java = Join-Path $jreDestination 'bin\java.exe'
$keytool = Join-Path $jreDestination 'bin\keytool.exe'
if (-not (Test-Path -LiteralPath $java) -or -not (Test-Path -LiteralPath $keytool)) {
    throw '裁剪 Java 运行时缺少 java.exe 或 keytool.exe'
}
& $java -jar (Join-Path $destinationRoot 'apktool.jar') --version | Out-Null
if ($LASTEXITCODE -ne 0) { throw '内置 APKTool 自检失败' }
& $java -jar (Join-Path $destinationRoot 'apksigner.jar') version | Out-Null
if ($LASTEXITCODE -ne 0) { throw '内置 apksigner 自检失败' }
& $keytool -help 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw '内置 keytool 自检失败' }

$buildToolsVersion = Split-Path -Leaf $buildTools
$components = @"
Android 重封装内置组件

APKTool $apktoolVersion
来源：$apktoolUri
对应源码：https://github.com/iBotPeaches/Apktool/tree/v$apktoolVersion
SHA-256：$apktoolSha256
许可证：Apache License 2.0（见 APKTOOL_LICENSE.md）

Eclipse Temurin JRE $temurinVersion（由对应 JDK 使用 jlink 裁剪）
来源：$temurinUri
对应源码：https://github.com/adoptium/jdk17u/tree/jdk-17.0.19%2B10_adopt
JDK SHA-256：$temurinSha256
许可证及 legal 文件：见 android/jre/legal

Android Build Tools $buildToolsVersion
组件：zipalign、apksigner
来源：本机 Android SDK Build Tools
对应源码：https://android.googlesource.com/platform/tools/apksig/ 与 https://android.googlesource.com/platform/build/+/refs/heads/main/tools/zipalign/
许可证与第三方通知：见 ANDROID_BUILD_TOOLS_NOTICE.txt
"@
[System.IO.File]::WriteAllText(
    (Join-Path $licensesDirectory 'ANDROID_COMPONENTS.txt'),
    $components,
    $utf8WithoutBom
)

Write-Host "[OK] Android 内置工具链：$destinationRoot"
Write-Host "[OK] APKTool：$apktoolVersion"
Write-Host "[OK] Java：Eclipse Temurin $temurinVersion"
Write-Host "[OK] Android Build Tools：$buildToolsVersion"
