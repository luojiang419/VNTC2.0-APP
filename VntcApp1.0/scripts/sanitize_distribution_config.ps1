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
    'is-auto-start',
    'is-always-on-top',
    'is-close-app'
)

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

    $json |
        ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $configPath -Encoding UTF8

    Write-Host "[Config] Sanitized $configPath"
}
