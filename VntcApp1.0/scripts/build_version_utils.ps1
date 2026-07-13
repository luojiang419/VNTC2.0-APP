function Get-VntBuildVersion {
    param([Parameter(Mandatory = $true)][string]$VersionFile)

    $version = (Get-Content -LiteralPath $VersionFile -Raw -Encoding UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Build version file is empty: $VersionFile"
    }
    return $version
}
function Get-NextVntBuildVersion {
    param([Parameter(Mandatory = $true)][string]$CurrentVersion)

    if ($CurrentVersion -match '^(\d+)\.(\d+)\.(\d+)$') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        $patch = [int]$Matches[3] + 1
        return "$major.$minor.$patch"
    }

    $nextVersion = [decimal]::Parse(
        $CurrentVersion,
        [System.Globalization.CultureInfo]::InvariantCulture
    ) + [decimal]'0.1'
    return $nextVersion.ToString(
        '0.0',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}
