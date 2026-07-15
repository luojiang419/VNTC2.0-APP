param(
    [ValidateSet('Library', 'Bootstrap', 'Ensure')]
    [string]$Action = 'Ensure',
    [switch]$UpdateTrustConfig
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security -ErrorAction Stop

$script:SigningSchema = 'vnt.android.official-signing-profile.v1'
$script:SigningKeyId = 'vnt-official-android-release-v1'
$script:SigningAlias = 'vnt_official_android_release_v1'
$script:SigningBrandId = 'official'
$script:SigningApplicationId = 'top.wherewego.vnt_app'
$script:SigningEntropy = [System.Text.Encoding]::UTF8.GetBytes(
    'VNTBrandRepackager.AndroidOfficialSigning.v1'
)
$script:CiKeystoreBase64EnvironmentVariable =
    'VNT_ANDROID_OFFICIAL_KEYSTORE_BASE64'
$script:CiKeystorePasswordEnvironmentVariable =
    'VNT_ANDROID_OFFICIAL_KEYSTORE_PASSWORD_PLAIN'
$script:SigningEnvironmentVariable = 'VNT_ANDROID_OFFICIAL_KEYSTORE_PASSWORD'
$script:SigningRoot = Join-Path $env:LOCALAPPDATA `
    'VNTBrandRepackager\android-official-signing\v1'
$script:SigningKeystorePath = Join-Path $script:SigningRoot 'official-release-v1.p12'
$script:SigningProfilePath = Join-Path $script:SigningRoot 'profile.json'
$script:SigningScriptRoot = $PSScriptRoot
$script:SigningProjectRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $script:SigningScriptRoot '..')
)
$script:SigningTrustPath = Join-Path $script:SigningProjectRoot `
    'config\android_official_signing_trust.json'

function Get-RequiredJsonString {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Value.PSObject.Properties[$Name]
    if ($null -eq $property -or -not ($property.Value -is [string]) -or
        [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "JSON 字段 $Name 缺失或不是非空字符串"
    }
    return [string]$property.Value
}

function Assert-Sha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -cnotmatch '^[0-9A-F]{64}$') {
        throw "$Name 必须是 64 位大写 SHA-256：$Value"
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "缺少文件：$Path"
    }
    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json
    } catch {
        throw "JSON 文件无效：$Path。$($_.Exception.Message)"
    }
}

function Write-Utf8JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporaryPath = Join-Path $directory (
        '.' + [System.IO.Path]::GetFileName($Path) + '.' +
        [guid]::NewGuid().ToString('N') + '.tmp'
    )
    $backupPath = Join-Path $directory (
        '.' + [System.IO.Path]::GetFileName($Path) + '.' +
        [guid]::NewGuid().ToString('N') + '.bak'
    )
    try {
        $json = ($Value | ConvertTo-Json -Depth 8) + "`r`n"
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json,
            [System.Text.UTF8Encoding]::new($false)
        )
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace(
                $temporaryPath,
                $Path,
                $backupPath,
                $true
            )
        } else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-JavaTool {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
        $candidates.Add((Join-Path $env:JAVA_HOME "bin\$FileName"))
    }
    $command = Get-Command $FileName -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) {
        $candidates.Add($command.Source)
    }
    $candidates.Add("C:\Program Files\Android\Android Studio\jbr\bin\$FileName")
    $candidates.Add(
        "C:\Program Files\ojdkbuild\java-17-openjdk-17.0.3.0.6-1\bin\$FileName"
    )
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    throw "未找到 $FileName；Bootstrap/Ensure 需要完整 JDK 17"
}

function Set-PasswordEnvironment {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        [System.Environment]::SetEnvironmentVariable(
            $script:SigningEnvironmentVariable,
            $null,
            [System.EnvironmentVariableTarget]::Process
        )
        Remove-Item -LiteralPath "Env:$($script:SigningEnvironmentVariable)" `
            -Force -ErrorAction SilentlyContinue
    } else {
        [System.Environment]::SetEnvironmentVariable(
            $script:SigningEnvironmentVariable,
            $Value,
            [System.EnvironmentVariableTarget]::Process
        )
    }
}

function Invoke-KeyToolWithPassword {
    param(
        [Parameter(Mandatory = $true)][string]$KeyTool,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($null -ne [System.Environment]::GetEnvironmentVariable(
        $script:SigningEnvironmentVariable,
        [System.EnvironmentVariableTarget]::Process
    )) {
        throw "进程环境变量 $($script:SigningEnvironmentVariable) 已被占用"
    }
    try {
        Set-PasswordEnvironment -Value $Password
        $output = @(& $KeyTool @ArgumentList 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "$Description 失败：$($output -join [Environment]::NewLine)"
        }
    } finally {
        Set-PasswordEnvironment -Value $null
    }
}

function Protect-OfficialSigningPassword {
    param([Parameter(Mandatory = $true)][string]$Password)

    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
    try {
        $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $script:SigningEntropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        try {
            return [Convert]::ToBase64String($protectedBytes)
        } finally {
            [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
        }
    } finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Get-AndroidOfficialSigningPassword {
    param([Parameter(Mandatory = $true)]$Profile)

    $plainPasswordProperty = $Profile.PSObject.Properties['plainPassword']
    if ($null -ne $plainPasswordProperty -and
        $plainPasswordProperty.Value -is [string] -and
        -not [string]::IsNullOrWhiteSpace([string]$plainPasswordProperty.Value)) {
        return [string]$plainPasswordProperty.Value
    }

    $protectedBase64 = Get-RequiredJsonString `
        -Value $Profile -Name 'passwordProtectedBase64'
    try {
        $protectedBytes = [Convert]::FromBase64String($protectedBase64)
    } catch {
        throw '本地签名档案的 DPAPI 密文不是有效 Base64'
    }
    try {
        $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $script:SigningEntropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        try {
            return [System.Text.Encoding]::UTF8.GetString($plainBytes)
        } finally {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
    } catch {
        throw "无法用当前 Windows 用户解密官方签名密码：$($_.Exception.Message)"
    } finally {
        [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
    }
}

function Read-OfficialSigningTrust {
    param([switch]$AllowPending)

    $trust = Read-JsonFile -Path $script:SigningTrustPath
    $schemaProperty = $trust.PSObject.Properties['schemaVersion']
    if ($null -eq $schemaProperty -or [int]$schemaProperty.Value -ne 1) {
        throw '官方 Android 签名信任配置 schemaVersion 必须为 1'
    }
    if ((Get-RequiredJsonString $trust 'keyId') -cne $script:SigningKeyId -or
        (Get-RequiredJsonString $trust 'brandId') -cne $script:SigningBrandId -or
        (Get-RequiredJsonString $trust 'applicationId') -cne
            $script:SigningApplicationId -or
        (Get-RequiredJsonString $trust 'alias') -cne $script:SigningAlias) {
        throw '官方 Android 签名信任配置的身份字段被修改'
    }
    $certificateSha256 = Get-RequiredJsonString $trust 'certificateSha256'
    if ($certificateSha256 -ceq 'PENDING_BOOTSTRAP') {
        if (-not $AllowPending) {
            throw '官方 Android 签名指纹尚未固定；仅允许首次 Bootstrap 完成固定'
        }
    } else {
        Assert-Sha256 $certificateSha256 'certificateSha256'
    }
    return $trust
}

function Update-OfficialSigningTrust {
    param([Parameter(Mandatory = $true)][string]$CertificateSha256)

    Assert-Sha256 $CertificateSha256 'certificateSha256'
    $trust = Read-OfficialSigningTrust -AllowPending
    $existing = Get-RequiredJsonString $trust 'certificateSha256'
    if ($existing -cne 'PENDING_BOOTSTRAP' -and
        $existing -cne $CertificateSha256) {
        throw '拒绝覆盖已固定为其他证书的官方 Android 签名信任配置'
    }
    $publicTrust = [ordered]@{
        schemaVersion = 1
        keyId = $script:SigningKeyId
        brandId = $script:SigningBrandId
        applicationId = $script:SigningApplicationId
        alias = $script:SigningAlias
        certificateSha256 = $CertificateSha256
    }
    Write-Utf8JsonAtomic -Path $script:SigningTrustPath -Value $publicTrust
}

function Export-OfficialCertificate {
    param(
        [Parameter(Mandatory = $true)][string]$KeystorePath,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $keyTool = Get-JavaTool -FileName 'keytool.exe'
    Invoke-KeyToolWithPassword -KeyTool $keyTool -Password $Password `
        -Description '读取官方 Android 签名证书' -ArgumentList @(
            '-exportcert', '-noprompt',
            '-keystore', $KeystorePath,
            '-storetype', 'PKCS12',
            '-alias', $script:SigningAlias,
            '-storepass:env', $script:SigningEnvironmentVariable,
            '-file', $OutputPath
        )
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf) -or
        (Get-Item -LiteralPath $OutputPath).Length -le 0) {
        throw 'keytool 未导出官方 Android 签名证书'
    }
}

function Get-OfficialCertificateSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$KeystorePath,
        [Parameter(Mandatory = $true)][string]$Password
    )

    $certificatePath = Join-Path $script:SigningRoot (
        '.certificate.' + [guid]::NewGuid().ToString('N') + '.der'
    )
    try {
        Export-OfficialCertificate -KeystorePath $KeystorePath `
            -Password $Password -OutputPath $certificatePath
        return (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash
    } finally {
        Remove-Item -LiteralPath $certificatePath -Force -ErrorAction SilentlyContinue
    }
}

function Test-OfficialSigningProfile {
    param([Parameter(Mandatory = $true)]$Profile)

    if ((Get-RequiredJsonString $Profile 'schema') -cne $script:SigningSchema -or
        (Get-RequiredJsonString $Profile 'keyId') -cne $script:SigningKeyId -or
        (Get-RequiredJsonString $Profile 'alias') -cne $script:SigningAlias) {
        throw '本地官方 Android 签名档案身份字段无效'
    }
    Assert-Sha256 (Get-RequiredJsonString $Profile 'certSHA256') 'certSHA256'
    Assert-Sha256 (Get-RequiredJsonString $Profile 'keystoreSHA256') `
        'keystoreSHA256'
    [void](Get-RequiredJsonString $Profile 'passwordProtectedBase64')
    $createdProperty = $Profile.PSObject.Properties['createdAtUtc']
    if ($null -eq $createdProperty) {
        throw '本地官方 Android 签名档案 createdAtUtc 缺失'
    }
    if (-not ($createdProperty.Value -is [DateTime]) -and
        -not ($createdProperty.Value -is [DateTimeOffset])) {
        if (-not ($createdProperty.Value -is [string]) -or
            [string]::IsNullOrWhiteSpace([string]$createdProperty.Value)) {
            throw '本地官方 Android 签名档案 createdAtUtc 无效'
        }
        $parsedCreatedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse(
            [string]$createdProperty.Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsedCreatedAt
        )) {
            throw '本地官方 Android 签名档案 createdAtUtc 无效'
        }
    }
}

function Get-AndroidOfficialSigningIdentityFromEnvironment {
    param([switch]$AllowPendingTrust)

    $keystoreBase64 = [System.Environment]::GetEnvironmentVariable(
        $script:CiKeystoreBase64EnvironmentVariable,
        [System.EnvironmentVariableTarget]::Process
    )
    $plainPassword = [System.Environment]::GetEnvironmentVariable(
        $script:CiKeystorePasswordEnvironmentVariable,
        [System.EnvironmentVariableTarget]::Process
    )

    if ([string]::IsNullOrWhiteSpace($keystoreBase64) -and
        [string]::IsNullOrWhiteSpace($plainPassword)) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($keystoreBase64) -or
        [string]::IsNullOrWhiteSpace($plainPassword)) {
        throw "CI 官方签名环境变量必须同时提供：$($script:CiKeystoreBase64EnvironmentVariable) / $($script:CiKeystorePasswordEnvironmentVariable)"
    }

    try {
        $keystoreBytes = [Convert]::FromBase64String($keystoreBase64)
    } catch {
        throw "CI 官方 Android keystore 不是有效 Base64：$($_.Exception.Message)"
    }
    if ($keystoreBytes.Length -le 0) {
        throw 'CI 官方 Android keystore Base64 解码后为空'
    }

    New-Item -ItemType Directory -Force -Path $script:SigningRoot | Out-Null
    $keystorePath = Join-Path $script:SigningRoot '.ci-official-release-v1.p12'
    try {
        [System.IO.File]::WriteAllBytes($keystorePath, $keystoreBytes)
    } finally {
        [Array]::Clear($keystoreBytes, 0, $keystoreBytes.Length)
    }

    $keystoreHash = (
        Get-FileHash -LiteralPath $keystorePath -Algorithm SHA256
    ).Hash
    $certificateHash = Get-OfficialCertificateSha256 `
        -KeystorePath $keystorePath -Password $plainPassword

    $trust = Read-OfficialSigningTrust -AllowPending:$AllowPendingTrust
    $trustedHash = Get-RequiredJsonString $trust 'certificateSha256'
    if ($trustedHash -cne 'PENDING_BOOTSTRAP' -and
        $trustedHash -cne $certificateHash) {
        throw 'CI 官方 Android 证书与仓库公开信任指纹不匹配'
    }

    return [pscustomobject]@{
        KeystorePath = $keystorePath
        Profile = [pscustomobject]@{
            plainPassword = $plainPassword
        }
        KeyId = $script:SigningKeyId
        Alias = $script:SigningAlias
        CertificateSha256 = $certificateHash
        KeystoreSha256 = $keystoreHash
    }
}

function Get-AndroidOfficialSigningIdentity {
    param([switch]$AllowPendingTrust)

    $environmentIdentity = Get-AndroidOfficialSigningIdentityFromEnvironment `
        -AllowPendingTrust:$AllowPendingTrust
    if ($null -ne $environmentIdentity) {
        return $environmentIdentity
    }

    $hasKeystore = Test-Path -LiteralPath $script:SigningKeystorePath -PathType Leaf
    $hasProfile = Test-Path -LiteralPath $script:SigningProfilePath -PathType Leaf
    if (-not $hasKeystore -or -not $hasProfile) {
        throw '官方 Android 签名身份缺失；禁止自动重建，请从安全备份恢复或仅在首次部署执行 Bootstrap'
    }
    $profile = Read-JsonFile -Path $script:SigningProfilePath
    Test-OfficialSigningProfile -Profile $profile
    $expectedKeystoreHash = Get-RequiredJsonString $profile 'keystoreSHA256'
    $actualKeystoreHash = (
        Get-FileHash -LiteralPath $script:SigningKeystorePath -Algorithm SHA256
    ).Hash
    if ($actualKeystoreHash -cne $expectedKeystoreHash) {
        throw '官方 Android PKCS12 文件哈希与本地档案不匹配'
    }

    $password = Get-AndroidOfficialSigningPassword -Profile $profile
    try {
        $actualCertificateHash = Get-OfficialCertificateSha256 `
            -KeystorePath $script:SigningKeystorePath -Password $password
    } finally {
        $password = $null
    }
    $profileCertificateHash = Get-RequiredJsonString $profile 'certSHA256'
    if ($actualCertificateHash -cne $profileCertificateHash) {
        throw '官方 Android PKCS12 证书与本地档案不匹配'
    }

    $trust = Read-OfficialSigningTrust -AllowPending:$AllowPendingTrust
    $trustedHash = Get-RequiredJsonString $trust 'certificateSha256'
    if ($trustedHash -cne 'PENDING_BOOTSTRAP' -and
        $trustedHash -cne $actualCertificateHash) {
        throw '本地官方 Android 证书与仓库公开信任指纹不匹配'
    }
    return [pscustomobject]@{
        KeystorePath = $script:SigningKeystorePath
        Profile = $profile
        KeyId = $script:SigningKeyId
        Alias = $script:SigningAlias
        CertificateSha256 = $actualCertificateHash
        KeystoreSha256 = $actualKeystoreHash
    }
}

function Initialize-AndroidOfficialSigning {
    param([switch]$PinTrust)

    $hasKeystore = Test-Path -LiteralPath $script:SigningKeystorePath
    $hasProfile = Test-Path -LiteralPath $script:SigningProfilePath
    if ($hasKeystore -or $hasProfile) {
        throw '官方 Android 签名身份已经存在；Bootstrap 绝不会覆盖或轮换现有密钥'
    }
    $trust = Read-OfficialSigningTrust -AllowPending
    if ((Get-RequiredJsonString $trust 'certificateSha256') -cne
        'PENDING_BOOTSTRAP') {
        throw '仓库已固定官方证书；本机缺少对应私钥时禁止生成新密钥，请从安全备份恢复'
    }

    New-Item -ItemType Directory -Force -Path $script:SigningRoot | Out-Null
    $randomBytes = New-Object byte[] 48
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($randomBytes)
        $password = [Convert]::ToBase64String($randomBytes)
    } finally {
        $random.Dispose()
        [Array]::Clear($randomBytes, 0, $randomBytes.Length)
    }

    $token = [guid]::NewGuid().ToString('N')
    $stagingKeystore = Join-Path $script:SigningRoot ".bootstrap.$token.p12"
    $stagingProfile = Join-Path $script:SigningRoot ".bootstrap.$token.json"
    $certificatePath = Join-Path $script:SigningRoot ".bootstrap.$token.der"
    $keystoreCommitted = $false
    $profileCommitted = $false
    try {
        $keyTool = Get-JavaTool -FileName 'keytool.exe'
        Invoke-KeyToolWithPassword -KeyTool $keyTool -Password $password `
            -Description '生成官方 Android RSA 3072 发布密钥' -ArgumentList @(
                '-genkeypair', '-noprompt',
                '-keystore', $stagingKeystore,
                '-storetype', 'PKCS12',
                '-alias', $script:SigningAlias,
                '-keyalg', 'RSA',
                '-keysize', '3072',
                '-sigalg', 'SHA256withRSA',
                '-validity', '9125',
                '-dname', 'CN=VNT Android Official Release, OU=Release, O=VNT, C=CN',
                '-storepass:env', $script:SigningEnvironmentVariable,
                '-keypass:env', $script:SigningEnvironmentVariable
            )
        Export-OfficialCertificate -KeystorePath $stagingKeystore `
            -Password $password -OutputPath $certificatePath
        $certificateHash = (
            Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256
        ).Hash
        Assert-Sha256 $certificateHash '新证书 SHA-256'
        $keystoreHash = (
            Get-FileHash -LiteralPath $stagingKeystore -Algorithm SHA256
        ).Hash
        $protectedPassword = Protect-OfficialSigningPassword -Password $password
        $profile = [ordered]@{
            schema = $script:SigningSchema
            keyId = $script:SigningKeyId
            alias = $script:SigningAlias
            certSHA256 = $certificateHash
            keystoreSHA256 = $keystoreHash
            passwordProtectedBase64 = $protectedPassword
            createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        [System.IO.File]::WriteAllText(
            $stagingProfile,
            (($profile | ConvertTo-Json -Depth 4) + "`r`n"),
            [System.Text.UTF8Encoding]::new($false)
        )

        [System.IO.File]::Move($stagingKeystore, $script:SigningKeystorePath)
        $keystoreCommitted = $true
        [System.IO.File]::Move($stagingProfile, $script:SigningProfilePath)
        $profileCommitted = $true
        if ($PinTrust) {
            Update-OfficialSigningTrust -CertificateSha256 $certificateHash
        }
        return Get-AndroidOfficialSigningIdentity `
            -AllowPendingTrust:(-not $PinTrust)
    } catch {
        if ($keystoreCommitted -and -not $profileCommitted) {
            Remove-Item -LiteralPath $script:SigningKeystorePath -Force `
                -ErrorAction SilentlyContinue
        }
        throw
    } finally {
        $password = $null
        Remove-Item -LiteralPath $stagingKeystore -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stagingProfile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $certificatePath -Force -ErrorAction SilentlyContinue
    }
}

function Confirm-AndroidOfficialSigning {
    param([switch]$PinTrust)

    $identity = Get-AndroidOfficialSigningIdentity -AllowPendingTrust:$PinTrust
    if ($PinTrust) {
        Update-OfficialSigningTrust `
            -CertificateSha256 $identity.CertificateSha256
        $identity = Get-AndroidOfficialSigningIdentity
    }
    return $identity
}

function Write-PublicIdentity {
    param([Parameter(Mandatory = $true)]$Identity)

    [pscustomobject][ordered]@{
        keyId = $Identity.KeyId
        alias = $Identity.Alias
        certificateSha256 = $Identity.CertificateSha256
        keystoreSha256 = $Identity.KeystoreSha256
        trustPinned = ((Read-OfficialSigningTrust -AllowPending).
            certificateSha256 -cne 'PENDING_BOOTSTRAP')
    } | ConvertTo-Json
}

switch ($Action) {
    'Library' { }
    'Bootstrap' {
        $identity = Initialize-AndroidOfficialSigning `
            -PinTrust:$UpdateTrustConfig
        if (-not $UpdateTrustConfig) {
            Write-Warning '密钥已生成，但公开指纹仍为 PENDING；请执行 Ensure -UpdateTrustConfig 固定指纹。'
        }
        Write-PublicIdentity -Identity $identity
    }
    'Ensure' {
        $identity = Confirm-AndroidOfficialSigning `
            -PinTrust:$UpdateTrustConfig
        Write-PublicIdentity -Identity $identity
    }
}
