$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $repoRoot 'src'
$scriptPath = Join-Path $repoRoot 'ps-edge.ps1'
$srcFiles = Get-ChildItem -Path $srcDir -Filter '*.ps1' | Sort-Object Name

$dotSourceOutput = @(
    foreach ($file in $srcFiles) {
        . $file.FullName
    }
)
if ($dotSourceOutput.Count -ne 0) {
    throw 'Dot-sourcing src/*.ps1 produced output.'
}

function Assert-PseTrue {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function ConvertTo-PseTestCommandLine {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $quoted = New-Object System.Collections.ArrayList
    foreach ($argument in $Arguments) {
        if ($argument -notmatch '[\s"]') {
            [void]$quoted.Add($argument)
            continue
        }

        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $backslashes = 0
        foreach ($ch in $argument.ToCharArray()) {
            if ($ch -eq '\') {
                $backslashes++
            } elseif ($ch -eq '"') {
                [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
                [void]$builder.Append('"')
                $backslashes = 0
            } else {
                if ($backslashes -gt 0) {
                    [void]$builder.Append(('\' * $backslashes))
                    $backslashes = 0
                }
                [void]$builder.Append($ch)
            }
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * ($backslashes * 2)))
        }
        [void]$builder.Append('"')
        [void]$quoted.Add($builder.ToString())
    }
    return [string]::Join(' ', @($quoted | ForEach-Object { [string]$_ }))
}

function Invoke-PseCliForTest {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $Arguments
    $exePath = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        $exePath = (Get-Process -Id $PID).Path
    }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $exePath
    $startInfo.Arguments = ConvertTo-PseTestCommandLine -Arguments $argumentList
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    [void]$process.WaitForExit()

    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Write-PseTestDownloadEventLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object[]]$Events
    )

    $lines = @($Events | ForEach-Object { ConvertTo-PseJson $_ })
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [void][System.IO.File]::WriteAllLines($Path, [string[]]$lines, $encoding)
}

function Write-PseTestDownloadState {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [string]$DownloadDir
    )

    Write-PseState @{
        port = $Port
        pid = $null
        userDataDir = $null
        targetId = $null
        attached = $false
        downloadDir = $DownloadDir
    }
}

# Empty directory and no event log.
$port = Get-PseFreePort
$downloadDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-downloadsevents-empty-' + [Guid]::NewGuid().ToString('N'))
$eventLogPath = Get-PseDownloadEventLogPath -Port $port
try {
    Clear-PseState
    Remove-Item -LiteralPath $eventLogPath -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Path $downloadDir)
    Write-PseTestDownloadState -Port $port -DownloadDir $downloadDir

    $result = Invoke-PseCliForTest -Arguments @('downloads')
    Assert-PseTrue ($result.ExitCode -eq 0) "empty downloads exited $($result.ExitCode): $($result.Stderr)"
    Assert-PseTrue ($result.Stdout -match 'No download files and no tracked download events\.') "new empty-state message missing. Output: $($result.Stdout)"
    Assert-PseTrue ($result.Stdout -match "# note: only 'click -WaitDownload' records events; an untracked download may still have occurred") "empty-state note missing. Output: $($result.Stdout)"
    Assert-PseTrue ($result.Stdout -notmatch 'No downloads yet\.') "legacy empty-state message was printed. Output: $($result.Stdout)"
} finally {
    Clear-PseState
    Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $eventLogPath -Force -ErrorAction SilentlyContinue
}

# Completed event whose file is no longer present.
$port = Get-PseFreePort
$downloadDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-downloadsevents-missing-' + [Guid]::NewGuid().ToString('N'))
$eventLogPath = Get-PseDownloadEventLogPath -Port $port
$gonePath = Join-Path $downloadDir 'gone.xlsx'
try {
    Clear-PseState
    Remove-Item -LiteralPath $eventLogPath -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Path $downloadDir)
    Write-PseTestDownloadState -Port $port -DownloadDir $downloadDir
    Write-PseTestDownloadEventLog -Path $eventLogPath -Events @(
        [ordered]@{ guid = 'gone-guid'; filename = 'gone.xlsx'; url = 'https://example.test/gone.xlsx'; state = 'completed'; receivedBytes = 321; totalBytes = 321; filePath = $gonePath; endedAt = '2026-08-17T00:00:00.0000000Z' }
    )

    $result = Invoke-PseCliForTest -Arguments @('downloads')
    Assert-PseTrue ($result.ExitCode -eq 0) "missing completed download exited $($result.ExitCode): $($result.Stderr)"
    Assert-PseTrue ($result.Stdout -match 'event: gone\.xlsx \[completed\] .* file missing') "missing completed event was not reported. Output: $($result.Stdout)"
    Assert-PseTrue ($result.Stdout.Contains("# path: $gonePath")) "completed event path missing. Output: $($result.Stdout)"
    Assert-PseTrue ($result.Stdout.Contains("# events: $eventLogPath")) "event log footer missing. Output: $($result.Stdout)"
    Assert-PseTrue ($result.Stdout -notmatch 'No download files') "empty-state message should not accompany an event. Output: $($result.Stdout)"
} finally {
    Clear-PseState
    Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $eventLogPath -Force -ErrorAction SilentlyContinue
}

# Existing completed file accounts for its event; canceled events remain visible.
$port = Get-PseFreePort
$downloadDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-downloadsevents-accounted-' + [Guid]::NewGuid().ToString('N'))
$eventLogPath = Get-PseDownloadEventLogPath -Port $port
$keptPath = Join-Path $downloadDir 'kept.txt'
try {
    Clear-PseState
    Remove-Item -LiteralPath $eventLogPath -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Path $downloadDir)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [void][System.IO.File]::WriteAllText($keptPath, 'kept', $encoding)
    Write-PseTestDownloadState -Port $port -DownloadDir $downloadDir
    Write-PseTestDownloadEventLog -Path $eventLogPath -Events @(
        [ordered]@{ guid = 'kept-guid'; filename = 'kept.txt'; url = 'https://example.test/kept.txt'; state = 'completed'; receivedBytes = 4; totalBytes = 4; filePath = $keptPath; endedAt = '2026-08-17T00:00:00.0000000Z' },
        [ordered]@{ guid = 'other-guid'; filename = 'other.bin'; url = 'https://example.test/other.bin'; state = 'canceled'; receivedBytes = 10; totalBytes = 100; filePath = $null; endedAt = '2026-08-17T00:01:00.0000000Z' }
    )

    $result = Invoke-PseCliForTest -Arguments @('downloads')
    Assert-PseTrue ($result.ExitCode -eq 0) "accounted download exited $($result.ExitCode): $($result.Stderr)"
    Assert-PseTrue ($result.Stdout -match '(?m)^\d+  \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}  kept\.txt\r?$') "kept.txt file row missing. Output: $($result.Stdout)"
    Assert-PseTrue ($result.Stdout -notmatch '(?m)^event: kept\.txt') "kept.txt should not have an event row. Output: $($result.Stdout)"
    Assert-PseTrue ($result.Stdout -match '(?m)^event: other\.bin \[canceled\]\r?$') "canceled event missing. Output: $($result.Stdout)"
} finally {
    Clear-PseState
    Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $eventLogPath -Force -ErrorAction SilentlyContinue
}

# Last occurrence of a duplicate guid wins.
$port = Get-PseFreePort
$downloadDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-downloadsevents-duplicate-' + [Guid]::NewGuid().ToString('N'))
$eventLogPath = Get-PseDownloadEventLogPath -Port $port
try {
    Clear-PseState
    Remove-Item -LiteralPath $eventLogPath -Force -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Path $downloadDir)
    Write-PseTestDownloadState -Port $port -DownloadDir $downloadDir
    Write-PseTestDownloadEventLog -Path $eventLogPath -Events @(
        [ordered]@{ guid = 'duplicate-guid'; filename = 'duplicate.zip'; url = 'https://example.test/duplicate.zip'; state = 'in-progress'; receivedBytes = 12; totalBytes = 100; filePath = $null; endedAt = '2026-08-17T00:00:00.0000000Z' },
        [ordered]@{ guid = 'duplicate-guid'; filename = 'duplicate.zip'; url = 'https://example.test/duplicate.zip'; state = 'completed'; receivedBytes = 100; totalBytes = 100; filePath = $null; endedAt = '2026-08-17T00:01:00.0000000Z' }
    )

    $result = Invoke-PseCliForTest -Arguments @('downloads')
    $duplicateEventLines = @($result.Stdout -split "`r?`n" | Where-Object { $_ -match '^event: duplicate\.zip ' })
    Assert-PseTrue ($result.ExitCode -eq 0) "duplicate event download exited $($result.ExitCode): $($result.Stderr)"
    Assert-PseTrue ($duplicateEventLines.Count -eq 1) "expected one deduplicated event, got $($duplicateEventLines.Count). Output: $($result.Stdout)"
    Assert-PseTrue ($duplicateEventLines[0] -match '\[completed\] 100 bytes') "last duplicate event was not retained. Output: $($result.Stdout)"
    Assert-PseTrue ($duplicateEventLines[0] -notmatch '\[in-progress') "stale in-progress event was retained. Output: $($result.Stdout)"
} finally {
    Clear-PseState
    Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $eventLogPath -Force -ErrorAction SilentlyContinue
}

# Explicit directory remains usable without state.
$downloadDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-downloadsevents-explicit-' + [Guid]::NewGuid().ToString('N'))
try {
    Clear-PseState
    [void](New-Item -ItemType Directory -Path $downloadDir)

    $result = Invoke-PseCliForTest -Arguments @('downloads', '-Dir', $downloadDir)
    Assert-PseTrue ($result.ExitCode -eq 0) "explicit downloads exited $($result.ExitCode): $($result.Stderr)"
    Assert-PseTrue ($result.Stdout.Contains("# dir: $([System.IO.Path]::GetFullPath($downloadDir))")) "explicit directory footer missing. Output: $($result.Stdout)"
    Assert-PseTrue ($result.Stdout -notmatch '(?m)^# events:') "explicit directory without state should not show an event footer. Output: $($result.Stdout)"
} finally {
    Clear-PseState
    Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
}
