param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [Parameter(Mandatory = $true)][string]$MsiPath
)

$ErrorActionPreference = 'Stop'

$serviceName = 'vntcrustdesk'
$managedBy = 'VNT App 2.0'
$tcpRuleName = 'VNTC Remote Assist TCP 49999'
$udpRuleName = 'VNTC Remote Assist Presence UDP 49998'
$remoteAssistDir = Join-Path $AppDir 'remote_assist'
$artifactDir = Join-Path $remoteAssistDir 'artifacts'
$logDir = Join-Path $remoteAssistDir 'logs'
$manifestPath = Join-Path $remoteAssistDir 'vntcrustdesk_manifest.json'
$installLog = Join-Path $logDir 'vntcrustdesk_install.log'
$repairUninstallLog = Join-Path $logDir 'vntcrustdesk_repair_uninstall.log'

function Quote-ProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    return '"' + $Value.Replace('"', '""') + '"'
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-UninstallEntry {
    $registryPaths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($registryPath in $registryPaths) {
        $entries = Get-ItemProperty $registryPath -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.DisplayName -like 'VNTC RustDesk*' -or $_.DisplayName -like 'vntcrustdesk*') -and
                -not [string]::IsNullOrWhiteSpace($_.DisplayName)
            } |
            ForEach-Object {
                $installLocation = [string]$_.InstallLocation
                $hasExecutable = $false
                if (-not [string]::IsNullOrWhiteSpace($installLocation)) {
                    $hasExecutable = Test-Path -LiteralPath (Join-Path $installLocation 'vntcrustdesk.exe')
                }
                $_ | Add-Member -NotePropertyName HasExecutable -NotePropertyValue $hasExecutable -PassThru
            } |
            Sort-Object `
                @{ Expression = { $_.HasExecutable }; Descending = $true }, `
                @{ Expression = { -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) }; Descending = $true }, `
                @{ Expression = { $_.DisplayVersion }; Descending = $true }

        if ($entries) {
            return $entries[0]
        }
    }

    return $null
}

function Resolve-ProductCode {
    param($UninstallEntry)

    if ($null -eq $UninstallEntry) {
        return ''
    }

    $candidate = [string]$UninstallEntry.PSChildName
    if ($candidate -match '^\{[0-9A-Fa-f\-]+\}$') {
        return $candidate
    }

    $uninstallString = [string]$UninstallEntry.UninstallString
    if ($uninstallString -match '\{[0-9A-Fa-f\-]+\}') {
        return $matches[0]
    }

    return ''
}

function Resolve-ExecutablePath {
    try {
        $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
        if ($null -ne $service -and -not [string]::IsNullOrWhiteSpace($service.PathName)) {
            $pathName = $service.PathName.Trim()
            if ($pathName.StartsWith('"')) {
                return $pathName.Split('"')[1]
            }
            return $pathName.Split(' ')[0]
        }
    } catch {
    }

    $entry = Get-UninstallEntry
    if ($null -ne $entry -and -not [string]::IsNullOrWhiteSpace($entry.InstallLocation)) {
        $candidate = Join-Path $entry.InstallLocation 'vntcrustdesk.exe'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $defaultCandidate = 'C:\Program Files\VNTC RustDesk\vntcrustdesk.exe'
    if (Test-Path -LiteralPath $defaultCandidate) {
        return $defaultCandidate
    }

    return $null
}

function Get-MsiInstallArguments {
    return @(
        '/i',
        (Quote-ProcessArgument -Value $MsiPath),
        '/qn',
        '/norestart',
        '/l*v',
        (Quote-ProcessArgument -Value $installLog)
    )
}

function Get-MsiProperty {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Property
    )

    $installer = $null
    $database = $null
    $view = $null
    $record = $null

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.GetType().InvokeMember(
            'OpenDatabase',
            'InvokeMethod',
            $null,
            $installer,
            @($Path, 0)
        )
        $query = "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Property'"
        $view = $database.GetType().InvokeMember(
            'OpenView',
            'InvokeMethod',
            $null,
            $database,
            @($query)
        )
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($null -eq $record) {
            return ''
        }
        return [string]$record.GetType().InvokeMember(
            'StringData',
            'GetProperty',
            $null,
            $record,
            1
        )
    } catch {
        return ''
    } finally {
        if ($null -ne $view) {
            try {
                $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
            } catch {
            }
        }
        foreach ($comObject in @($record, $view, $database, $installer)) {
            if ($null -ne $comObject) {
                try {
                    [Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) | Out-Null
                } catch {
                }
            }
        }
    }
}

function Invoke-MsiProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    return Start-Process msiexec.exe `
        -ArgumentList $Arguments `
        -Wait `
        -PassThru `
        -NoNewWindow
}

function Test-ManagedRuntimePresent {
    param($ExistingEntry)

    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return $false
    }

    $candidatePaths = @()
    if ($null -ne $ExistingEntry -and -not [string]::IsNullOrWhiteSpace([string]$ExistingEntry.InstallLocation)) {
        $candidatePaths += (Join-Path ([string]$ExistingEntry.InstallLocation) 'vntcrustdesk.exe')
    }
    $candidatePaths += 'C:\Program Files\VNTC RustDesk\vntcrustdesk.exe'

    foreach ($candidatePath in $candidatePaths | Select-Object -Unique) {
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and (Test-Path -LiteralPath $candidatePath)) {
            return $true
        }
    }

    return $false
}

function Repair-ByCleanReinstall {
    param($ExistingEntry)

    $productCode = Resolve-ProductCode -UninstallEntry $ExistingEntry
    if ([string]::IsNullOrWhiteSpace($productCode)) {
        return
    }

    try {
        Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
    } catch {
    }
    Get-Process -Name vntcrustdesk -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $uninstallProcess = Invoke-MsiProcess -Arguments @(
        '/x',
        $productCode,
        '/qn',
        '/norestart',
        '/l*v',
        (Quote-ProcessArgument -Value $repairUninstallLog)
    )

    if ($uninstallProcess.ExitCode -notin @(0, 1605, 1614, 3010)) {
        throw "vntcrustdesk MSI uninstall failed during repair: $($uninstallProcess.ExitCode)"
    }
}

function Ensure-FirewallRule {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$ProgramPath,
        [Parameter(Mandatory = $true)][string]$Protocol,
        [Parameter(Mandatory = $true)][int]$LocalPort
    )

    if (-not (Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName $DisplayName `
            -Direction Inbound `
            -Action Allow `
            -Profile Any `
            -Program $ProgramPath `
            -Protocol $Protocol `
            -LocalPort $LocalPort | Out-Null
    }

    Get-NetFirewallRule -DisplayName $DisplayName | Enable-NetFirewallRule | Out-Null
    Get-NetFirewallRule -DisplayName $DisplayName |
        Get-NetFirewallAddressFilter |
        Set-NetFirewallAddressFilter -RemoteAddress 'Any' | Out-Null
}

function Wait-ForTcpListener {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][int]$LocalPort,
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $matchingProcesses = Get-CimInstance Win32_Process -Filter "Name='vntcrustdesk.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -eq $ExecutablePath } |
            Select-Object -ExpandProperty ProcessId
        if ($matchingProcesses) {
            $listener = Get-NetTCPConnection -State Listen -LocalPort $LocalPort -ErrorAction SilentlyContinue |
                Where-Object { $_.OwningProcess -in $matchingProcesses } |
                Select-Object -First 1
            if ($null -ne $listener) {
                return $listener
            }
        }
        Start-Sleep -Seconds 1
    }

    return $null
}

function Ensure-ServiceControlPermission {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName
    )

    $rawDescriptor = & sc.exe sdshow $ServiceName 2>$null
    if ($LASTEXITCODE -ne 0 -or $null -eq $rawDescriptor) {
        throw "Failed to query service security descriptor: $ServiceName"
    }

    $descriptor = ($rawDescriptor | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1).Trim()
    if ([string]::IsNullOrWhiteSpace($descriptor)) {
        throw "Service security descriptor is empty: $ServiceName"
    }

    $desiredInteractiveUsersAce = '(A;;CCLCSWRPWPLOCRRC;;;IU)'
    $startOnlyInteractiveUsersAce = '(A;;CCLCSWRPLOCRRC;;;IU)'
    $legacyInteractiveUsersAce = '(A;;CCLCSWLOCRRC;;;IU)'
    if ($descriptor.Contains($desiredInteractiveUsersAce)) {
        return
    }

    if ($descriptor.Contains($startOnlyInteractiveUsersAce)) {
        $updatedDescriptor = $descriptor.Replace($startOnlyInteractiveUsersAce, $desiredInteractiveUsersAce)
    } elseif ($descriptor.Contains($legacyInteractiveUsersAce)) {
        $updatedDescriptor = $descriptor.Replace($legacyInteractiveUsersAce, $desiredInteractiveUsersAce)
    } elseif ($descriptor.Contains('S:')) {
        $updatedDescriptor = $descriptor.Replace('S:', "$desiredInteractiveUsersAce" + 'S:')
    } else {
        $updatedDescriptor = $descriptor + $desiredInteractiveUsersAce
    }

    & sc.exe sdset $ServiceName $updatedDescriptor | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update service security descriptor: $ServiceName"
    }
}

function Ensure-ServiceRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string]$ExecutablePath
    )

    $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $existingService) {
        return
    }

    $binaryPath = ('"{0}" --service' -f $ExecutablePath)
    New-Service `
        -Name $ServiceName `
        -BinaryPathName $binaryPath `
        -DisplayName 'VNTC RustDesk' `
        -StartupType Automatic | Out-Null
}

Ensure-Directory -Path $remoteAssistDir
Ensure-Directory -Path $artifactDir
Ensure-Directory -Path $logDir

if (-not (Test-Path -LiteralPath $MsiPath)) {
    throw "vntcrustdesk MSI not found: $MsiPath"
}

$existingEntry = Get-UninstallEntry
if ($null -ne $existingEntry -and -not (Test-ManagedRuntimePresent -ExistingEntry $existingEntry)) {
    Repair-ByCleanReinstall -ExistingEntry $existingEntry
    $existingEntry = $null
}

$runtimePresent = $null -ne $existingEntry -and (Test-ManagedRuntimePresent -ExistingEntry $existingEntry)
$bundledVersion = Get-MsiProperty -Path $MsiPath -Property 'ProductVersion'
$existingVersion = if ($null -ne $existingEntry) { [string]$existingEntry.DisplayVersion } else { '' }
$shouldInstallMsi = -not $runtimePresent
if ($runtimePresent -and
    -not [string]::IsNullOrWhiteSpace($bundledVersion) -and
    $existingVersion -ne $bundledVersion) {
    $shouldInstallMsi = $true
}

if ($shouldInstallMsi) {
    $installProcess = Invoke-MsiProcess -Arguments (Get-MsiInstallArguments)

    if ($installProcess.ExitCode -notin @(0, 3010)) {
        throw "vntcrustdesk MSI install failed: $($installProcess.ExitCode)"
    }
} else {
    Write-Host "[OK] vntcrustdesk MSI already present, skip reinstall: $existingVersion"
}

$uninstallEntry = Get-UninstallEntry
$executablePath = Resolve-ExecutablePath
if ([string]::IsNullOrWhiteSpace($executablePath)) {
    throw 'vntcrustdesk executable path could not be resolved after install.'
}

$displayVersion = ''
$productCode = ''
$uninstallString = ''
if ($null -ne $uninstallEntry) {
    if (-not [string]::IsNullOrWhiteSpace($uninstallEntry.DisplayVersion)) {
        $displayVersion = [string]$uninstallEntry.DisplayVersion
    }
    if (-not [string]::IsNullOrWhiteSpace($uninstallEntry.PSChildName)) {
        $productCode = [string]$uninstallEntry.PSChildName
    }
    if (-not [string]::IsNullOrWhiteSpace($uninstallEntry.UninstallString)) {
        $uninstallString = [string]$uninstallEntry.UninstallString
    }
    $productCode = Resolve-ProductCode -UninstallEntry $uninstallEntry
}

try {
    Start-Service -Name $serviceName -ErrorAction SilentlyContinue
} catch {
}

$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -eq $service) {
    Ensure-ServiceRegistration -ServiceName $serviceName -ExecutablePath $executablePath
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
}
if ($null -eq $service) {
    throw "vntcrustdesk service missing after install: $serviceName"
}

Ensure-ServiceControlPermission -ServiceName $serviceName

try {
    Start-Service -Name $serviceName -ErrorAction SilentlyContinue
} catch {
}

$hostExecutable = Join-Path $AppDir 'vnt_app.exe'
if (Test-Path -LiteralPath $hostExecutable) {
    Ensure-FirewallRule -DisplayName $udpRuleName -ProgramPath $hostExecutable -Protocol 'UDP' -LocalPort 49998
}
Ensure-FirewallRule -DisplayName $tcpRuleName -ProgramPath $executablePath -Protocol 'TCP' -LocalPort 49999

$listener = Wait-ForTcpListener -ExecutablePath $executablePath -LocalPort 49999
if ($null -eq $listener) {
    throw "vntcrustdesk listener did not bind TCP 49999: $executablePath"
}

$manifest = [ordered]@{
    executablePath = $executablePath
    installDirectory = Split-Path -Path $executablePath -Parent
    version = $displayVersion
    serviceName = $serviceName
    managedBy = $managedBy
    productCode = $productCode
    uninstallString = $uninstallString
    listenerAddress = $listener.LocalAddress
    listenerPort = $listener.LocalPort
    installedAt = (Get-Date).ToString('o')
}

$manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host "[OK] vntcrustdesk installed and registered: $executablePath"
