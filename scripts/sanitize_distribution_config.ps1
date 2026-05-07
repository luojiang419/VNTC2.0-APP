param(
    [string[]]$ConfigPaths
)

$ErrorActionPreference = "Stop"

$unsafeKeys = @(
    'window-x',
    'window-y',
    'window-width',
    'window-height',
    'vnt-unique-id-key',
    'vnt-install-registration-id',
    'vnt-identity-refreshed-at',
    'is-auto-start',
    'is-always-on-top',
    'is-close-app'
)

$unsafeNetworkConfigKeys = @(
    'ip',
    'device_id'
)

function Sanitize-NetworkConfigObject {
    param([object]$ConfigObject)

    foreach ($key in $unsafeNetworkConfigKeys) {
        if ($null -ne $ConfigObject.PSObject.Properties[$key]) {
            $ConfigObject.PSObject.Properties[$key].Value = ''
        }
    }

    return $ConfigObject
}

function Sanitize-SerializedConfigEntry {
    param([object]$Entry)

    if ($Entry -isnot [string] -or [string]::IsNullOrWhiteSpace($Entry)) {
        return $Entry
    }

    try {
        $decoded = $Entry | ConvertFrom-Json
        if ($null -eq $decoded) {
            return $Entry
        }
        $sanitized = Sanitize-NetworkConfigObject -ConfigObject $decoded
        return ($sanitized | ConvertTo-Json -Depth 100 -Compress)
    } catch {
        Write-Host "[Config] Skip invalid config entry"
        return $Entry
    }
}

$resolvedPaths = @()
foreach ($rawPath in $ConfigPaths) {
    if ([string]::IsNullOrWhiteSpace($rawPath)) {
        continue
    }
    $resolvedPaths += ($rawPath -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

foreach ($configPath in $resolvedPaths) {
    if ([string]::IsNullOrWhiteSpace($configPath)) {
        continue
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-Host "[Config] Skip missing $configPath"
        continue
    }

    $raw = Get-Content -LiteralPath $configPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host "[Config] Skip empty $configPath"
        continue
    }

    $json = $raw | ConvertFrom-Json
    foreach ($key in $unsafeKeys) {
        if ($null -ne $json.PSObject.Properties[$key]) {
            $json.PSObject.Properties.Remove($key)
        }
    }

    if ($null -ne $json.PSObject.Properties['data-key']) {
        $sanitizedList = @()
        foreach ($entry in $json.'data-key') {
            $sanitizedList += Sanitize-SerializedConfigEntry -Entry $entry
        }
        $json.'data-key' = $sanitizedList
    }

    if ($null -ne $json.PSObject.Properties['data-key-native']) {
        $nativeRaw = [string]$json.'data-key-native'
        if (-not [string]::IsNullOrWhiteSpace($nativeRaw)) {
            try {
                $nativeList = $nativeRaw | ConvertFrom-Json
                $sanitizedNativeList = @()
                foreach ($entry in $nativeList) {
                    $sanitizedNativeList += Sanitize-SerializedConfigEntry -Entry $entry
                }
                $nativeJson = ($sanitizedNativeList | ConvertTo-Json -Depth 100 -Compress)
                if (-not $nativeJson.TrimStart().StartsWith('[')) {
                    $nativeJson = "[$nativeJson]"
                }
                $json.'data-key-native' = $nativeJson
            } catch {
                Write-Host "[Config] Skip invalid data-key-native payload"
            }
        }
    }

    $json |
        ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $configPath -Encoding UTF8

    Write-Host "[Config] Sanitized $configPath"
}
