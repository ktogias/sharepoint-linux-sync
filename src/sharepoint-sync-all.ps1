# SPDX-License-Identifier: Apache-2.0

param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Expand-HomePath([string]$Path) {
    if ($Path -eq '~') { return $HOME }
    if ($Path.StartsWith('~/')) { return Join-Path $HOME $Path.Substring(2) }
    return $Path
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $configHome = if (-not [string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) {
        $env:XDG_CONFIG_HOME
    }
    else {
        Join-Path $HOME '.config'
    }
    $ConfigPath = Join-Path $configHome 'sharepoint-sync/projects.json'
}
else {
    $ConfigPath = Expand-HomePath $ConfigPath
}

$syncScript = Join-Path $PSScriptRoot 'sharepoint-sync.ps1'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration not found: $ConfigPath"
}

if (-not (Test-Path -LiteralPath $syncScript)) {
    throw "Sync script not found: $syncScript"
}

$projects = @(Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json)

$failures = @()
$enabledCount = 0

foreach ($p in $projects) {
    if ($null -ne $p.enabled -and -not [bool]$p.enabled) {
        continue
    }

    $enabledCount++
    Write-Host ''
    Write-Host '============================================================'
    Write-Host "SYNC $($p.project)"
    Write-Host '============================================================'

    try {
        $arguments = @{
            Project   = [string]$p.project
            SiteHost  = [string]$p.siteHost
            SitePath  = [string]$p.sitePath
            DriveName = if ($p.driveName) { [string]$p.driveName } else { 'Documents' }
            RemoteRoot = if ($p.remoteRoot) { [string]$p.remoteRoot } else { 'General' }
        }

        if ($p.localRoot) {
            $arguments['LocalRoot'] = [string]$p.localRoot
        }
        if ($null -ne $p.skipForbidden -and [bool]$p.skipForbidden) {
            $arguments['SkipForbidden'] = $true
        }
        if ($p.maxDownloadAttempts) {
            $arguments['MaxDownloadAttempts'] = [int]$p.maxDownloadAttempts
        }
        if ($p.connectionTimeoutSeconds) {
            $arguments['ConnectionTimeoutSeconds'] = [int]$p.connectionTimeoutSeconds
        }
        if ($p.operationTimeoutSeconds) {
            $arguments['OperationTimeoutSeconds'] = [int]$p.operationTimeoutSeconds
        }

        & $syncScript @arguments
    }
    catch {
        Write-Error "SYNC FAILED: $($p.project): $($_.Exception.Message)"
        $failures += [string]$p.project
    }
}

Write-Host ''

if ($enabledCount -eq 0) {
    Write-Host 'No enabled projects in configuration.'
    exit 0
}

if ($failures.Count -gt 0) {
    Write-Host "Failed projects: $($failures -join ', ')"
    exit 1
}

Write-Host 'All enabled projects synced successfully.'
exit 0
