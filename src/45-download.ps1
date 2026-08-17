function Open-PseDownloadWatch {
    param(
        [Parameter(Mandatory = $true)]
        $State,

        [Parameter(Mandatory = $true)]
        [hashtable]$DialogPolicy
    )

    if ($null -eq $State -or -not $State.port) {
        throw "browser is not running - run 'start' first"
    }

    try {
        $version = Invoke-PseHttpJson -Port ([int]$State.port) -Path '/json/version'
    } catch {
        throw "browser is not running - run 'start' first"
    }
    if ($null -eq $version -or -not $version.webSocketDebuggerUrl) {
        throw 'browser WebSocket URL was not available'
    }

    $downloadDir = $null
    if ($null -ne $State.PSObject.Properties['downloadDir'] -and -not [string]::IsNullOrWhiteSpace([string]$State.downloadDir)) {
        $downloadDir = [string]$State.downloadDir
    }

    $conn = $null
    try {
        $conn = Connect-PseCdp -WebSocketUrl $version.webSocketDebuggerUrl
        $conn.DialogPolicy = $DialogPolicy
        [void](Send-PseCdp -Conn $conn -Method 'Target.setAutoAttach' -Params @{
            autoAttach = $true
            waitForDebuggerOnStart = $false
            flatten = $true
        } -TimeoutSec 5)

        if ($null -ne $downloadDir) {
            [void](Send-PseCdp -Conn $conn -Method 'Browser.setDownloadBehavior' -Params @{
                behavior = 'allow'
                downloadPath = $downloadDir
                eventsEnabled = $true
            } -TimeoutSec 5)
        } else {
            [void](Send-PseCdp -Conn $conn -Method 'Browser.setDownloadBehavior' -Params @{
                behavior = 'default'
                eventsEnabled = $true
            } -TimeoutSec 5)
        }

        return [pscustomobject]@{
            Conn = $conn
            Port = [int]$State.port
            DownloadDir = $downloadDir
        }
    } catch {
        if ($null -ne $conn) {
            Close-PseCdp -Conn $conn
        }
        throw
    }
}

function Wait-PseDownloadWatch {
    param(
        [Parameter(Mandatory = $true)]
        $Watch,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSec
    )

    $downloadsByGuid = @{}
    $downloads = New-Object System.Collections.ArrayList
    $terminalDownload = $null
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)

    while ([DateTime]::UtcNow -lt $deadline) {
        $message = $null
        if ($Watch.Conn.Events.Count -gt 0) {
            $message = $Watch.Conn.Events[0]
            $Watch.Conn.Events.RemoveAt(0)
        } else {
            $remaining = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)
            if ($remaining -lt 1) {
                $remaining = 1
            }

            try {
                $message = Receive-PseCdpMessage -Conn $Watch.Conn -TimeoutSec $remaining
            } catch {
                if ($_.Exception.Message -match '^Timed out after \d+ seconds waiting for a CDP message\.$') {
                    break
                }
                throw
            }
        }

        if ($null -eq $message) {
            continue
        }
        if (Invoke-PseCdpAutoHandler -Conn $Watch.Conn -Message $message) {
            continue
        }
        if ($null -ne $message.PSObject.Properties['id']) {
            continue
        }

        if ($message.method -eq 'Browser.downloadWillBegin') {
            $p = $message.params
            $guid = [string]$p.guid
            if ([string]::IsNullOrWhiteSpace($guid)) {
                continue
            }

            if ($downloadsByGuid.ContainsKey($guid)) {
                $download = $downloadsByGuid[$guid]
                $download.Filename = [string]$p.suggestedFilename
                $download.Url = [string]$p.url
            } else {
                $download = [pscustomobject]@{
                    Guid = $guid
                    Filename = [string]$p.suggestedFilename
                    Url = [string]$p.url
                    State = 'in-progress'
                    ReceivedBytes = [long]0
                    TotalBytes = [long]0
                    FilePath = $null
                }
                $downloadsByGuid[$guid] = $download
                [void]$downloads.Add($download)
            }
            continue
        }

        if ($message.method -ne 'Browser.downloadProgress') {
            continue
        }

        $p = $message.params
        $guid = [string]$p.guid
        if (-not $downloadsByGuid.ContainsKey($guid)) {
            continue
        }

        $download = $downloadsByGuid[$guid]
        if ($null -ne $p.PSObject.Properties['receivedBytes']) {
            $download.ReceivedBytes = [long]$p.receivedBytes
        }
        if ($null -ne $p.PSObject.Properties['totalBytes']) {
            $download.TotalBytes = [long]$p.totalBytes
        }
        if ($null -ne $p.PSObject.Properties['filePath'] -and -not [string]::IsNullOrWhiteSpace([string]$p.filePath)) {
            $download.FilePath = [string]$p.filePath
        }

        if ($p.state -eq 'completed') {
            $download.State = 'completed'
            $terminalDownload = $download
            break
        }
        if ($p.state -eq 'canceled') {
            $download.State = 'canceled'
            $terminalDownload = $download
            break
        }
        $download.State = 'in-progress'
    }

    $downloadArray = @($downloads | ForEach-Object { $_ })
    if ($null -ne $terminalDownload) {
        return [pscustomobject]@{
            State = $terminalDownload.State
            Download = $terminalDownload
            Downloads = $downloadArray
        }
    }

    if ($downloads.Count -eq 0) {
        return [pscustomobject]@{
            State = 'not-observed'
            Download = $null
            Downloads = $downloadArray
        }
    }

    foreach ($download in $downloads) {
        $download.State = 'in-progress'
    }
    return [pscustomobject]@{
        State = 'in-progress'
        Download = $downloads[0]
        Downloads = $downloadArray
    }
}

function Get-PseDownloadEventLogPath {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    return Join-Path (Get-PseStateDir) "downloads-events-$Port.jsonl"
}

function Write-PseDownloadEventLog {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Downloads
    )

    if ($Downloads.Count -eq 0) {
        return
    }

    $path = Get-PseDownloadEventLogPath -Port $Port
    $lines = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
            [void]$lines.Add($line)
        }
    }

    foreach ($download in $Downloads) {
        $entry = [ordered]@{
            guid = $download.Guid
            filename = $download.Filename
            url = $download.Url
            state = $download.State
            receivedBytes = [long]$download.ReceivedBytes
            totalBytes = [long]$download.TotalBytes
            filePath = $download.FilePath
            endedAt = [DateTime]::UtcNow.ToString('o')
        }
        [void]$lines.Add((ConvertTo-PseJson $entry))
    }

    $keptLines = @($lines | Select-Object -Last 200 | ForEach-Object { [string]$_ })
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [void][System.IO.File]::WriteAllLines($path, [string[]]$keptLines, $encoding)
}

function Write-PseDownloadWaitResult {
    param(
        [Parameter(Mandatory = $true)]
        $Result,

        [Parameter(Mandatory = $true)]
        $Watch,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSec
    )

    if ($Result.State -eq 'not-observed') {
        Write-Output "download: [not-observed] no download events within $TimeoutSec sec"
        Write-Output "# note: the click may still trigger a download later; check 'downloads' before retrying non-idempotent actions"
        return
    }

    $download = $Result.Download
    $filename = [string]$download.Filename
    if ([string]::IsNullOrWhiteSpace($filename)) {
        $filename = '(unknown)'
    }

    if ($Result.State -eq 'completed') {
        Write-Output "download: $filename [completed] $($download.ReceivedBytes) bytes"
        Write-Output "# guid: $($download.Guid)"

        $path = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$download.FilePath)) {
            $path = [string]$download.FilePath
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$Watch.DownloadDir)) {
            $path = Join-Path ([string]$Watch.DownloadDir) $filename
        }

        if ($null -ne $path) {
            $suffix = ''
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $suffix = " (file not found - it may have been renamed or removed; run 'downloads')"
            }
            Write-Output "# path: $path$suffix"
        }
        return
    }

    if ($Result.State -eq 'canceled') {
        Write-Output "download: $filename [canceled]"
        Write-Output "# guid: $($download.Guid)"
        return
    }

    Write-Output "download: $filename [in-progress] $($download.ReceivedBytes)/$($download.TotalBytes) bytes"
    Write-Output "# guid: $($download.Guid)"
    Write-Output "# note: still downloading after $TimeoutSec sec; check 'downloads' before retrying"
}
