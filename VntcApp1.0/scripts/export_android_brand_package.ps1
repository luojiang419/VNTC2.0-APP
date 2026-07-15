param(
    [string]$InputApk = '',
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptRoot = $PSScriptRoot
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot '..'))
$version = (Get-Content -LiteralPath (Join-Path $scriptRoot 'build_version.txt') `
    -Raw).Trim()

. (Join-Path $scriptRoot 'android_official_signing.ps1') -Action Library

function Resolve-UnsignedInputApk {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        return [System.IO.Path]::GetFullPath($RequestedPath)
    }
    $candidates = @(
        (Join-Path $projectRoot `
            'build\app\outputs\flutter-apk\app-release-unsigned.apk'),
        (Join-Path $projectRoot `
            'build\app\outputs\flutter-apk\app-release.apk')
    )
    $match = $candidates | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($match)) {
        return $candidates[0]
    }
    return [System.IO.Path]::GetFullPath($match)
}

function Resolve-BuildTools36 {
    $sdkRoots = New-Object System.Collections.Generic.List[string]
    foreach ($root in @(
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
    )) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and
            -not $sdkRoots.Contains($root)) {
            $sdkRoots.Add($root)
        }
    }
    foreach ($sdkRoot in $sdkRoots) {
        $candidate = Join-Path $sdkRoot 'build-tools\36.0.0'
        $required = @(
            (Join-Path $candidate 'aapt2.exe'),
            (Join-Path $candidate 'zipalign.exe'),
            (Join-Path $candidate 'lib\apksigner.jar')
        )
        if (@($required | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    throw '缺少固定版本 Android Build Tools 36.0.0（aapt2/zipalign/apksigner）'
}

function Get-ApkCertificateDigests {
    param([Parameter(Mandatory = $true)][string]$SignatureText)

    return @([regex]::Matches(
        $SignatureText,
        'Signer #\d+ certificate SHA-256 digest:\s*([0-9A-Fa-f:]{64,95})'
    ) | ForEach-Object {
        $_.Groups[1].Value.Replace(':', '').ToUpperInvariant()
    })
}

function Get-PathMutexName {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(
        [System.IO.Path]::GetFullPath($Path).ToUpperInvariant()
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($bytes)
        try {
            $token = ([BitConverter]::ToString($digest)).Replace('-', '')
            return 'Local\VNTAndroidOfficialExport_' + $token.Substring(0, 32)
        } finally {
            [Array]::Clear($digest, 0, $digest.Length)
        }
    } finally {
        $sha.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Publish-ApkAndHashAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$StagingApk,
        [Parameter(Mandatory = $true)][string]$OutputApk,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )

    $sidecarPath = "$OutputApk.sha256"
    $outputDirectory = Split-Path -Parent $OutputApk
    $outputName = [System.IO.Path]::GetFileName($OutputApk)
    $token = [guid]::NewGuid().ToString('N')
    $stagingSidecar = Join-Path $outputDirectory ".android_export.$token.sha256"
    $backupApk = Join-Path $outputDirectory ".android_export.$token.apk.bak"
    $backupSidecar = Join-Path $outputDirectory ".android_export.$token.sha256.bak"
    $sidecarText = "$ExpectedHash *$outputName`r`n"
    [System.IO.File]::WriteAllText(
        $stagingSidecar,
        $sidecarText,
        [System.Text.UTF8Encoding]::new($false)
    )

    $mutex = [System.Threading.Mutex]::new(
        $false,
        (Get-PathMutexName -Path $OutputApk)
    )
    $ownsMutex = $false
    $published = $false
    try {
        try {
            $ownsMutex = $mutex.WaitOne([TimeSpan]::FromMinutes(2))
        } catch [System.Threading.AbandonedMutexException] {
            $ownsMutex = $true
        }
        if (-not $ownsMutex) {
            throw '等待 Android 母版发布锁超时'
        }

        if (Test-Path -LiteralPath $OutputApk) {
            Move-Item -LiteralPath $OutputApk -Destination $backupApk
        }
        if (Test-Path -LiteralPath $sidecarPath) {
            Move-Item -LiteralPath $sidecarPath -Destination $backupSidecar
        }
        try {
            Move-Item -LiteralPath $StagingApk -Destination $OutputApk
            Move-Item -LiteralPath $stagingSidecar -Destination $sidecarPath
            $actualHash = (
                Get-FileHash -LiteralPath $OutputApk -Algorithm SHA256
            ).Hash
            $actualSidecar = [System.IO.File]::ReadAllText($sidecarPath)
            if ($actualHash -cne $ExpectedHash -or
                $actualSidecar -cne $sidecarText) {
                throw '发布后的 APK/SHA-256 文件复核失败'
            }
            $published = $true
        } catch {
            $publishError = $_
            Remove-Item -LiteralPath $OutputApk -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $sidecarPath -Force -ErrorAction SilentlyContinue
            try {
                if (Test-Path -LiteralPath $backupApk) {
                    Move-Item -LiteralPath $backupApk -Destination $OutputApk
                }
                if (Test-Path -LiteralPath $backupSidecar) {
                    Move-Item -LiteralPath $backupSidecar -Destination $sidecarPath
                }
            } catch {
                throw "Android 母版发布失败且旧产物恢复失败；备份仍位于 $outputDirectory。原始错误：$($publishError.Exception.Message)；恢复错误：$($_.Exception.Message)"
            }
            throw $publishError
        }
    } finally {
        if ($ownsMutex) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
        Remove-Item -LiteralPath $stagingSidecar -Force -ErrorAction SilentlyContinue
        if ($published) {
            Remove-Item -LiteralPath $backupApk -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $backupSidecar -Force -ErrorAction SilentlyContinue
        }
    }
}

$inputPath = Resolve-UnsignedInputApk -RequestedPath $InputApk
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot 'release\android'
}
$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
    throw "找不到未签名 Android release APK：$inputPath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($inputPath)
try {
    $manifestEntry = $archive.Entries | Where-Object {
        $_.FullName -ceq `
            'assets/flutter_assets/assets/android_brand_package_manifest.json'
    }
    $brandingEntry = $archive.Entries | Where-Object {
        $_.FullName -ceq 'assets/flutter_assets/assets/android_branding.json'
    }
    if ($null -eq $manifestEntry -or $null -eq $brandingEntry) {
        throw 'APK 缺少 Android 品牌母版协议文件'
    }
    if ($manifestEntry.Length -gt 65536 -or $brandingEntry.Length -gt 65536) {
        throw 'APK 品牌协议文件大小异常'
    }
    $reader = [System.IO.StreamReader]::new(
        $manifestEntry.Open(),
        [System.Text.UTF8Encoding]::new($false, $true)
    )
    try {
        $manifest = $reader.ReadToEnd() | ConvertFrom-Json
    } finally {
        $reader.Dispose()
    }
    if ($manifest.brandReady -ne $true -or $manifest.platform -cne 'android') {
        throw 'APK 不是 Android 品牌母版'
    }
    if ($manifest.versionName -cne $version -or
        $manifest.brandId -cne 'official' -or
        $manifest.applicationId -cne 'top.wherewego.vnt_app') {
        throw "APK 品牌母版身份/版本不匹配，期望 official $version"
    }
} finally {
    $archive.Dispose()
}

$buildTools = Resolve-BuildTools36
$aapt2 = Join-Path $buildTools 'aapt2.exe'
$zipalign = Join-Path $buildTools 'zipalign.exe'
$apksigner = Join-Path $buildTools 'lib\apksigner.jar'
$java = Get-JavaTool -FileName 'java.exe'

$unsignedVerify = @(& $java -jar $apksigner verify $inputPath 2>&1)
if ($LASTEXITCODE -eq 0) {
    throw '输入 APK 已包含有效签名；正式导出只接受未签名 release APK'
}
$inputBadging = @(& $aapt2 dump badging $inputPath 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "未签名 APK badging 校验失败：$($inputBadging -join [Environment]::NewLine)"
}
$inputBadgingText = $inputBadging -join "`n"
if ($inputBadgingText -notmatch
    "package: name='top\.wherewego\.vnt_app'.*versionName='$([regex]::Escape($version))'") {
    throw '未签名 APK 的 applicationId/versionName 与官方母版不一致'
}
if ($inputBadgingText -notmatch "native-code: 'arm64-v8a'") {
    throw '未签名 APK 不是 arm64-v8a 构建'
}

$identity = Confirm-AndroidOfficialSigning
$password = Get-AndroidOfficialSigningPassword -Profile $identity.Profile
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$outputName = "VNT_App_${version}_Android_arm64_Brand_Master.apk"
$outputPath = Join-Path $outputRoot $outputName
if ([System.IO.Path]::GetFullPath($inputPath) -ceq
    [System.IO.Path]::GetFullPath($outputPath)) {
    throw '输入 APK 不能与正式输出路径相同'
}
$token = [guid]::NewGuid().ToString('N')
$alignedPath = Join-Path $outputRoot ".android_export.$token.aligned.apk"
$signedPath = Join-Path $outputRoot ".android_export.$token.signed.apk"
try {
    & $zipalign -f -P 16 4 $inputPath $alignedPath
    if ($LASTEXITCODE -ne 0) {
        throw '未签名 APK 的 16KB zipalign 处理失败'
    }

    if ($null -ne [System.Environment]::GetEnvironmentVariable(
        $script:SigningEnvironmentVariable,
        [System.EnvironmentVariableTarget]::Process
    )) {
        throw "进程环境变量 $($script:SigningEnvironmentVariable) 已被占用"
    }
    try {
        Set-PasswordEnvironment -Value $password
        $signOutput = @(& $java -jar $apksigner sign `
            --ks $identity.KeystorePath `
            --ks-type PKCS12 `
            --ks-key-alias $identity.Alias `
            --ks-pass "env:$($script:SigningEnvironmentVariable)" `
            --key-pass "env:$($script:SigningEnvironmentVariable)" `
            --v1-signing-enabled false `
            --v2-signing-enabled true `
            --v3-signing-enabled true `
            --v4-signing-enabled false `
            --out $signedPath `
            $alignedPath 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "官方 APK 签名失败：$($signOutput -join [Environment]::NewLine)"
        }
    } finally {
        Set-PasswordEnvironment -Value $null
        $password = $null
    }

    $signatureOutput = @(& $java -jar $apksigner verify `
        --verbose --print-certs $signedPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "正式 APK 签名校验失败：$($signatureOutput -join [Environment]::NewLine)"
    }
    $signatureText = $signatureOutput -join "`n"
    if ($signatureText -notmatch
        'Verified using v2 scheme \(APK Signature Scheme v2\): true' -or
        $signatureText -notmatch
        'Verified using v3 scheme \(APK Signature Scheme v3\): true') {
        throw '正式 APK 必须同时通过 v2、v3 签名验证'
    }
    if ($signatureText -notmatch '(?m)^Number of signers: 1\s*$') {
        throw '正式 APK 必须且只能有一个 signer'
    }
    $certificates = @(Get-ApkCertificateDigests -SignatureText $signatureText)
    if ($certificates.Count -ne 1) {
        throw '正式 APK 必须且只能包含一个可识别签名证书'
    }
    if ($certificates[0] -cne $identity.CertificateSha256) {
        throw "正式 APK 证书指纹不匹配：$($certificates[0])"
    }

    & $zipalign -c -P 16 4 $signedPath
    if ($LASTEXITCODE -ne 0) {
        throw '正式 APK 的 16KB 对齐复核失败'
    }
    $finalBadging = @(& $aapt2 dump badging $signedPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw '正式 APK badging 复核失败'
    }
    $finalBadgingText = $finalBadging -join "`n"
    if ($finalBadgingText -notmatch
        "package: name='top\.wherewego\.vnt_app'.*versionName='$([regex]::Escape($version))'" -or
        $finalBadgingText -notmatch "native-code: 'arm64-v8a'") {
        throw '正式 APK 的 applicationId/version/native-code 复核失败'
    }

    $hash = (Get-FileHash -LiteralPath $signedPath -Algorithm SHA256).Hash
    Publish-ApkAndHashAtomically -StagingApk $signedPath `
        -OutputApk $outputPath -ExpectedHash $hash
} finally {
    $password = $null
    Set-PasswordEnvironment -Value $null
    Remove-Item -LiteralPath $alignedPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $signedPath -Force -ErrorAction SilentlyContinue
}

Write-Host "[OK] Android 官方品牌母版：$outputPath"
Write-Host "[OK] 官方证书 SHA-256：$($identity.CertificateSha256)"
Write-Host "[OK] APK SHA-256：$hash"
