# SPDX-License-Identifier: Apache-2.0

param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string]$Project,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^/[^\r\n]*$')]
    [string]$SitePath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$SiteHost,

    [string]$DriveName = 'Documents',
    [string]$RemoteRoot = 'General',
    [string]$LocalRoot,

    [switch]$SkipForbidden,

    [ValidateRange(1, 20)]
    [int]$MaxDownloadAttempts = 4,

    [ValidateRange(1, 3600)]
    [int]$ConnectionTimeoutSeconds = 60,

    [ValidateRange(1, 86400)]
    [int]$OperationTimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-SyncLog([string]$Message) {
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$Project] $Message"
}

function Expand-HomePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if ($Path -eq '~') {
        return $HOME
    }

    if ($Path.StartsWith('~/')) {
        return Join-Path $HOME $Path.Substring(2)
    }

    return $Path
}

function Convert-ToUtcDateTime($Value) {
    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [DateTimeOffset]) {
        return $Value.UtcDateTime
    }

    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime()
    }

    $text = [string]$Value
    $dto = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AllowWhiteSpaces -bor [Globalization.DateTimeStyles]::AssumeUniversal

    if ([DateTimeOffset]::TryParse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            $styles,
            [ref]$dto)) {
        return $dto.UtcDateTime
    }

    if ([DateTimeOffset]::TryParse(
            $text,
            [Globalization.CultureInfo]::GetCultureInfo('en-US'),
            $styles,
            [ref]$dto)) {
        return $dto.UtcDateTime
    }

    throw "Unable to parse remote date: '$text'"
}

function Convert-ToGraphPath([string]$Path) {
    $segments = $Path.Trim('/').Split('/', [StringSplitOptions]::RemoveEmptyEntries)
    if ($segments.Count -eq 0) {
        return ''
    }

    return (($segments | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
}

function Get-SafeLocalPath([string]$RelativePath) {
    $root = [IO.Path]::GetFullPath($script:EffectiveLocalRoot)
    $path = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    $prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

    if (($path -ne $root) -and (-not $path.StartsWith($prefix, [StringComparison]::Ordinal))) {
        throw "Unsafe local path: $RelativePath"
    }

    return $path
}

function Get-RelativePath($Item) {
    $parentPath = [Uri]::UnescapeDataString([string]$Item['parentReference']['path'])
    $name = [string]$Item['name']
    $marker = "root:/$RemoteRoot"
    $pos = $parentPath.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase)

    if ($pos -lt 0) {
        throw "Item outside configured root: $parentPath"
    }

    $relativeParent = $parentPath.Substring($pos + $marker.Length).Trim('/')
    if ($relativeParent) {
        return "$relativeParent/$name"
    }

    return $name
}

function Save-State($State) {
    $tmp = "$script:StateFile.tmp.$PID"

    try {
        $State |
            ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $tmp -Encoding utf8

        [IO.File]::Move($tmp, $script:StateFile, $true)
    }
    finally {
        if ([IO.File]::Exists($tmp)) {
            [IO.File]::Delete($tmp)
        }
    }
}

function Test-FileIsCurrent([string]$Path, $Item) {
    if (-not [IO.File]::Exists($Path)) {
        return $false
    }

    $local = [IO.FileInfo]::new($Path)

    if ($null -ne $Item['size'] -and $local.Length -ne [long]$Item['size']) {
        return $false
    }

    if ($Item['lastModifiedDateTime']) {
        $remoteTime = Convert-ToUtcDateTime $Item['lastModifiedDateTime']
        $difference = [Math]::Abs(($local.LastWriteTimeUtc - $remoteTime).TotalSeconds)

        # Allow small filesystem timestamp-rounding differences.
        if ($difference -gt 2) {
            return $false
        }
    }

    return $true
}

function Get-PartialMetadata([string]$MetadataPath) {
    if (-not [IO.File]::Exists($MetadataPath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        return $null
    }
}

function Remove-PartialDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PartialPath,

        [Parameter(Mandatory = $true)]
        [string]$MetadataPath
    )

    if ([IO.File]::Exists($PartialPath)) {
        [IO.File]::Delete($PartialPath)
    }
    if ([IO.File]::Exists($MetadataPath)) {
        [IO.File]::Delete($MetadataPath)
    }
}

function Write-CurlUrlConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    if ($Url.Contains([char]13) -or $Url.Contains([char]10)) {
        throw 'Download URL contains an unexpected newline'
    }

    $escaped = $Url.Replace('\', '\\').Replace('"', '\"')
    [IO.File]::WriteAllText(
        $Path,
        "url = `"$escaped`"`n",
        [Text.UTF8Encoding]::new($false)
    )

    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode(
            $Path,
            [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        )
    }
}

function Download-DriveItem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveId,

        [Parameter(Mandatory = $true)]
        [string]$ItemId,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        $ExpectedSize
    )

    $partialPath = "$Destination.part"
    $partialMetadataPath = "$Destination.part.meta.json"

    for ($attempt = 1; $attempt -le $MaxDownloadAttempts; $attempt++) {
        $curlConfigPath = $null
        $curlErrorPath = $null

        try {
            # Request fresh metadata on every attempt because the pre-authenticated
            # download URL is intentionally short-lived.
            $metadata = Invoke-MgGraphRequest `
                -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId"

            $downloadUrl = [string]$metadata['@microsoft.graph.downloadUrl']
            if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
                throw 'Graph did not return @microsoft.graph.downloadUrl'
            }

            $downloadUri = [Uri]$downloadUrl
            if ($downloadUri.Scheme -ne 'https') {
                throw 'Graph returned a non-HTTPS download URL'
            }

            $expected = $metadata['size']
            if ($null -eq $expected) {
                $expected = $ExpectedSize
            }

            $etag = [string]$metadata['eTag']
            $partialMetadata = Get-PartialMetadata $partialMetadataPath

            # Preserve a partial file only when it belongs to the same provider
            # version and expected size.
            $partialIsCompatible = $false
            if ($partialMetadata -and -not [string]::IsNullOrWhiteSpace($etag)) {
                $partialIsCompatible =
                    ([string]$partialMetadata['eTag'] -eq $etag) -and
                    (($null -eq $expected) -or ([long]$partialMetadata['size'] -eq [long]$expected))
            }

            if (-not $partialIsCompatible) {
                Remove-PartialDownload `
                    -PartialPath $partialPath `
                    -MetadataPath $partialMetadataPath
            }

            if ([IO.File]::Exists($partialPath) -and $null -ne $expected) {
                $partialLength = [IO.FileInfo]::new($partialPath).Length

                if ($partialLength -gt [long]$expected) {
                    Remove-PartialDownload `
                        -PartialPath $partialPath `
                        -MetadataPath $partialMetadataPath
                }
                elseif ($partialLength -eq [long]$expected) {
                    [IO.File]::Move($partialPath, $Destination, $true)
                    if ([IO.File]::Exists($partialMetadataPath)) {
                        [IO.File]::Delete($partialMetadataPath)
                    }
                    return @{
                        status   = 'downloaded'
                        metadata = $metadata
                    }
                }
            }

            @{
                eTag = $etag
                size = $expected
            } |
                ConvertTo-Json -Compress |
                Set-Content -LiteralPath $partialMetadataPath -Encoding utf8

            Write-SyncLog "DOWNLOAD attempt $attempt/$MaxDownloadAttempts : $([IO.Path]::GetFileName($Destination))"

            # Use curl for the byte stream. The short-lived pre-authenticated
            # URL is stored in a mode-0600 temp config so it is not exposed in
            # the process command line.
            $curlConfigPath = Join-Path (
                [IO.Path]::GetTempPath()
            ) "sharepoint-sync-$PID-$([Guid]::NewGuid().ToString('N')).curl"
            $curlErrorPath = "$curlConfigPath.stderr"
            Write-CurlUrlConfig -Path $curlConfigPath -Url $downloadUrl

            $curlArgs = @(
                '--config', $curlConfigPath,
                '--location',
                '--max-redirs', '8',
                '--proto', '=https',
                '--proto-redir', '=https',
                '--fail',
                '--silent',
                '--show-error',
                '--connect-timeout', [string]$ConnectionTimeoutSeconds,
                '--speed-limit', '1',
                '--speed-time', [string]$OperationTimeoutSeconds,
                '--continue-at', '-',
                '--output', $partialPath,
                '--write-out', '%{http_code}'
            )

            $statusOutput = & $script:CurlCommand @curlArgs 2> $curlErrorPath
            $curlExitCode = $LASTEXITCODE
            $httpCodeText = (($statusOutput | ForEach-Object { [string]$_ }) -join '').Trim()
            $httpCode = 0
            [void][int]::TryParse($httpCodeText, [ref]$httpCode)

            $curlError = ''
            if ([IO.File]::Exists($curlErrorPath)) {
                $curlError = [IO.File]::ReadAllText($curlErrorPath).Trim()
            }

            if ($curlExitCode -ne 0) {
                if ($curlExitCode -eq 33) {
                    Remove-PartialDownload `
                        -PartialPath $partialPath `
                        -MetadataPath $partialMetadataPath
                    throw 'Server refused byte-range resume; partial download reset'
                }

                if ($httpCode -eq 403 -and $SkipForbidden) {
                    Remove-PartialDownload `
                        -PartialPath $partialPath `
                        -MetadataPath $partialMetadataPath
                    Write-SyncLog "DENIED  $([IO.Path]::GetFileName($Destination)) (HTTP 403; skipForbidden=true)"
                    return @{
                        status     = 'forbidden'
                        metadata   = $metadata
                        httpStatus = 403
                    }
                }

                $detail = if ($curlError) { ": $curlError" } else { '' }
                $httpDetail = if ($httpCode -gt 0) { ", HTTP $httpCode" } else { '' }
                throw "curl download failed (exit $curlExitCode$httpDetail)$detail"
            }

            if ($httpCode -lt 200 -or $httpCode -ge 300) {
                throw "Unexpected download HTTP status: $httpCode"
            }

            if ($null -ne $expected) {
                $actual = [IO.FileInfo]::new($partialPath).Length
                if ($actual -ne [long]$expected) {
                    throw "Downloaded size mismatch: expected $expected, got $actual"
                }
            }

            [IO.File]::Move($partialPath, $Destination, $true)
            if ([IO.File]::Exists($partialMetadataPath)) {
                [IO.File]::Delete($partialMetadataPath)
            }

            return @{
                status   = 'downloaded'
                metadata = $metadata
            }
        }
        catch {
            if ($attempt -ge $MaxDownloadAttempts) {
                throw
            }

            Write-SyncLog "RETRY   download failed: $($_.Exception.Message)"
            Start-Sleep -Seconds ([Math]::Min(30, 5 * $attempt))
        }
        finally {
            foreach ($temporaryPath in @($curlConfigPath, $curlErrorPath)) {
                if (
                    -not [string]::IsNullOrWhiteSpace($temporaryPath) -and
                    [IO.File]::Exists($temporaryPath)
                ) {
                    [IO.File]::Delete($temporaryPath)
                }
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($DriveName)) {
    throw 'DriveName must not be empty'
}

if ([string]::IsNullOrWhiteSpace($RemoteRoot)) {
    throw 'RemoteRoot must not be empty'
}

if ($RemoteRoot -match '(^|/)\.\.(/|$)') {
    throw 'RemoteRoot must not contain parent traversal segments'
}

$LocalRoot = Expand-HomePath $LocalRoot
if ([string]::IsNullOrWhiteSpace($LocalRoot)) {
    $LocalRoot = Join-Path $HOME "SharePoint/$Project/$RemoteRoot"
}

$script:EffectiveLocalRoot = [IO.Path]::GetFullPath($LocalRoot)
$stateRootName = ($RemoteRoot -replace '[^A-Za-z0-9._-]+', '_').Trim('_')
if (-not $stateRootName) {
    $stateRootName = 'root'
}

$stateHome = if (-not [string]::IsNullOrWhiteSpace($env:XDG_STATE_HOME)) {
    $env:XDG_STATE_HOME
}
else {
    Join-Path $HOME '.local/state'
}

$script:StateDir = Join-Path $stateHome "sharepoint-sync/$Project-$stateRootName"
$script:StateFile = Join-Path $script:StateDir 'state.json'
$lockFile = Join-Path $script:StateDir 'sync.lock'

New-Item -ItemType Directory -Force -Path $script:EffectiveLocalRoot | Out-Null
New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null

$curl = Get-Command curl -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $curl) {
    throw 'curl is required for SharePoint file downloads'
}
$script:CurlCommand = $curl.Source

$lock = $null

try {
    try {
        $lock = [IO.File]::Open(
            $lockFile,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    catch {
        Write-SyncLog 'Another sync is already running. Skipping.'
        return
    }

    Import-Module Microsoft.Graph.Authentication

    Connect-MgGraph `
        -Scopes 'Files.Read.All' `
        -ContextScope CurrentUser `
        -NoWelcome

    $encodedSitePath = Convert-ToGraphPath $SitePath
    $site = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/sites/$SiteHost`:/$encodedSitePath"

    $drives = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/sites/$($site['id'])/drives"

    $drive = $drives['value'] |
        Where-Object { $_['name'] -eq $DriveName } |
        Select-Object -First 1

    if (-not $drive) {
        throw "Drive '$DriveName' not found"
    }

    $driveId = [string]$drive['id']
    $encodedRemoteRoot = Convert-ToGraphPath $RemoteRoot
    $rootItem = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/drives/$driveId/root:/$encodedRemoteRoot"

    $rootId = [string]$rootItem['id']

    if (Test-Path -LiteralPath $script:StateFile) {
        $state = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json -AsHashtable
    }
    else {
        $state = @{
            version   = 2
            deltaLink = $null
            items     = @{}
        }
    }

    if (-not $state['items']) {
        $state['items'] = @{}
    }

    # If skipForbidden is enabled, denied items remain in state and are
    # retried on later runs so a later permission grant can recover them.
    if ($SkipForbidden) {
        $deniedRecovered = 0

        foreach ($deniedId in @($state['items'].Keys)) {
            $deniedState = $state['items'][$deniedId]
            if (-not $deniedState['denied'] -or [bool]$deniedState['folder']) {
                continue
            }

            $deniedRelative = [string]$deniedState['path']
            $deniedPath = Get-SafeLocalPath $deniedRelative
            $deniedParent = Split-Path -Parent $deniedPath
            New-Item -ItemType Directory -Force -Path $deniedParent | Out-Null

            try {
                $retryResult = Download-DriveItem `
                    -DriveId $driveId `
                    -ItemId $deniedId `
                    -Destination $deniedPath `
                    -ExpectedSize $deniedState['size']

                if ($retryResult['status'] -eq 'downloaded') {
                    $retryMetadata = $retryResult['metadata']

                    if ($retryMetadata['lastModifiedDateTime']) {
                        $retryModifiedUtc = Convert-ToUtcDateTime $retryMetadata['lastModifiedDateTime']
                        [IO.File]::SetLastWriteTimeUtc($deniedPath, $retryModifiedUtc)
                    }

                    $deniedState['size'] = $retryMetadata['size']
                    $deniedState['etag'] = $retryMetadata['eTag']
                    $deniedState['modified'] = $retryMetadata['lastModifiedDateTime']
                    $deniedState['denied'] = $false
                    $deniedRecovered++
                    Write-SyncLog "RECOVER $deniedRelative"
                }
            }
            catch {
                Write-SyncLog "WARN    denied-item retry failed: $deniedRelative : $($_.Exception.Message)"
            }
        }

        if ($deniedRecovered -gt 0) {
            Save-State $state
        }
    }

    if ($state['deltaLink']) {
        Write-SyncLog 'Incremental sync'
        $url = [string]$state['deltaLink']
    }
    else {
        Write-SyncLog 'Initial sync'
        $url = "https://graph.microsoft.com/v1.0/drives/$driveId/items/$rootId/delta"
    }

    $changes = @()
    $newDeltaLink = $null
    $pageNumber = 0

    do {
        $pageNumber++
        $response = Invoke-MgGraphRequest -Method GET -Uri $url
        $batch = @($response['value'])
        $changes += $batch

        Write-SyncLog "Delta page $pageNumber : $($batch.Count) items"

        if ($response['@odata.nextLink']) {
            $url = [string]$response['@odata.nextLink']
        }
        else {
            $newDeltaLink = [string]$response['@odata.deltaLink']
            $url = $null
        }
    } while ($url)

    if ([string]::IsNullOrWhiteSpace($newDeltaLink)) {
        throw 'Graph did not return deltaLink'
    }

    # A delta feed can mention one item more than once. Keep only its latest
    # representation from this collection pass.
    $latest = @{}
    foreach ($item in $changes) {
        if ($item['id']) {
            $latest[[string]$item['id']] = $item
        }
    }

    $downloaded = 0
    $skipped = 0
    $folders = 0
    $deleted = 0
    $moved = 0
    $forbidden = 0

    foreach ($id in $latest.Keys) {
        $item = $latest[$id]

        if ($id -eq $rootId) {
            continue
        }

        if ($item['deleted']) {
            if ($state['items'].ContainsKey($id)) {
                $oldRelative = [string]$state['items'][$id]['path']
                $oldPath = Get-SafeLocalPath $oldRelative

                if (Test-Path -LiteralPath $oldPath) {
                    Remove-Item -LiteralPath $oldPath -Recurse -Force
                    Write-SyncLog "DELETE  $oldRelative"
                }

                $prefix = "$oldRelative/"
                $idsToRemove = @(
                    $state['items'].Keys |
                        Where-Object {
                            $_ -eq $id -or
                            ([string]$state['items'][$_]['path']).StartsWith($prefix, [StringComparison]::Ordinal)
                        }
                )

                foreach ($removeId in $idsToRemove) {
                    $state['items'].Remove($removeId)
                }

                $deleted++
            }

            continue
        }

        $relative = Get-RelativePath $item
        $localPath = Get-SafeLocalPath $relative
        $isFolder = $null -ne $item['folder']
        $downloadResult = $null

        if ($state['items'].ContainsKey($id)) {
            $oldRelative = [string]$state['items'][$id]['path']

            if ($oldRelative -ne $relative) {
                $oldPath = Get-SafeLocalPath $oldRelative
                $destinationParent = Split-Path -Parent $localPath
                New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null

                if ($isFolder) {
                    if ([IO.Directory]::Exists($oldPath) -and -not [IO.Directory]::Exists($localPath)) {
                        [IO.Directory]::Move($oldPath, $localPath)
                    }

                    $oldPrefix = "$oldRelative/"
                    $newPrefix = "$relative/"

                    foreach ($childId in @($state['items'].Keys)) {
                        $p = [string]$state['items'][$childId]['path']
                        if ($p.StartsWith($oldPrefix, [StringComparison]::Ordinal)) {
                            $state['items'][$childId]['path'] = $newPrefix + $p.Substring($oldPrefix.Length)
                        }
                    }
                }
                elseif ([IO.File]::Exists($oldPath)) {
                    [IO.File]::Move($oldPath, $localPath, $true)
                }

                Write-SyncLog "MOVE    $oldRelative -> $relative"
                $moved++
            }
        }

        if ($isFolder) {
            New-Item -ItemType Directory -Force -Path $localPath | Out-Null
            $folders++
        }
        else {
            $parent = Split-Path -Parent $localPath
            New-Item -ItemType Directory -Force -Path $parent | Out-Null

            if (Test-FileIsCurrent $localPath $item) {
                Write-SyncLog "SKIP    $relative"
                $skipped++
            }
            else {
                $downloadResult = Download-DriveItem `
                    -DriveId $driveId `
                    -ItemId $id `
                    -Destination $localPath `
                    -ExpectedSize $item['size']

                if ($downloadResult['status'] -eq 'forbidden') {
                    $forbidden++
                }
                else {
                    if ($item['lastModifiedDateTime']) {
                        $modifiedUtc = Convert-ToUtcDateTime $item['lastModifiedDateTime']
                        [IO.File]::SetLastWriteTimeUtc($localPath, $modifiedUtc)
                    }

                    Write-SyncLog "GET     $relative"
                    $downloaded++
                }
            }
        }

        $state['items'][$id] = @{
            path     = $relative
            folder   = $isFolder
            size     = $item['size']
            etag     = $item['eTag']
            modified = $item['lastModifiedDateTime']
            denied   = (
                -not $isFolder -and
                $null -ne $downloadResult -and
                $downloadResult['status'] -eq 'forbidden'
            )
        }
    }

    # Advance the checkpoint only after all local effects above succeeded.
    $state['version'] = 2
    $state['deltaLink'] = $newDeltaLink
    Save-State $state

    Write-SyncLog (
        "DONE: $downloaded downloaded, $skipped unchanged, $folders folders, " +
        "$moved moved, $deleted deleted, $forbidden forbidden"
    )
}
finally {
    if ($lock) {
        $lock.Dispose()
    }
}
