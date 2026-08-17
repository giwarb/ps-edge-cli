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

function New-PseDataUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Html
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
    return 'data:text/html;charset=utf-8;base64,' + [Convert]::ToBase64String($bytes)
}

function Get-PseTestRef {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Snapshot,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $escaped = [regex]::Escape($Name)
    $match = [regex]::Match($Snapshot, '"[^"]*' + $escaped + '[^"]*" \[ref=(e\d+)\]')
    if (-not $match.Success) {
        throw "Could not find ref for '$Name'. Snapshot: $Snapshot"
    }
    return $match.Groups[1].Value
}

$port = Get-PseFreePort
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-downloadwait-test-' + [Guid]::NewGuid().ToString('N'))
$downloadDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-downloadwait-dir-' + [Guid]::NewGuid().ToString('N'))
$downloadPath = Join-Path $downloadDir 'pse-wait-test.txt'
$eventLogPath = Get-PseDownloadEventLogPath -Port $port
$edgePid = $null

try {
    Clear-PseState
    Remove-Item -LiteralPath $eventLogPath -Force -ErrorAction SilentlyContinue

    $start = Invoke-PseCliForTest -Arguments @('start', '-Port', [string]$port, '-Headless', '-UserDataDir', $testRoot, '-DownloadDir', $downloadDir)
    Assert-PseTrue ($start.ExitCode -eq 0) "start failed: $($start.Stderr)"

    $state = Read-PseState
    Assert-PseTrue ($null -ne $state) 'State was not written after start.'
    $edgePid = $state.pid

    $html = @'
<!doctype html>
<html>
<head><title>Download Wait Fixture</title></head>
<body>
  <button id="confirm" type="button" onclick="if (confirm('go?')) { setTimeout(function(){ document.getElementById('dl').click(); }, 500); }">Confirm Download</button>
  <button id="nothing" type="button">Do Nothing</button>
  <a id="dl" download="pse-wait-test.txt" href="data:text/plain,pse-wait-content">Download target</a>
</body>
</html>
'@
    $goto = Invoke-PseCliForTest -Arguments @('goto', (New-PseDataUrl -Html $html))
    Assert-PseTrue ($goto.ExitCode -eq 0) "goto fixture failed: $($goto.Stderr)"

    $snapshot = Invoke-PseCliForTest -Arguments @('snapshot')
    Assert-PseTrue ($snapshot.ExitCode -eq 0) "snapshot failed: $($snapshot.Stderr)"
    $confirmRef = Get-PseTestRef -Snapshot $snapshot.Stdout -Name 'Confirm Download'
    $nothingRef = Get-PseTestRef -Snapshot $snapshot.Stdout -Name 'Do Nothing'

    $completed = Invoke-PseCliForTest -Arguments @('click', $confirmRef, '-WaitDownload', '-AcceptDialog', '-DownloadTimeoutSec', '30')
    Assert-PseTrue ($completed.ExitCode -eq 0) "wait download click failed: $($completed.Stderr) Output: $($completed.Stdout)"
    Assert-PseTrue ($completed.Stdout -match '\[completed\]') "completed output was missing. Output: $($completed.Stdout)"
    Assert-PseTrue ($completed.Stdout -match '(?m)^# path: ') "path output was missing. Output: $($completed.Stdout)"
    Assert-PseTrue (Test-Path -LiteralPath $downloadPath -PathType Leaf) "downloaded file was not found at '$downloadPath'."
    $content = Get-Content -LiteralPath $downloadPath -Raw
    Assert-PseTrue ($content -eq 'pse-wait-content') "Downloaded file content mismatch: '$content'."

    $notObserved = Invoke-PseCliForTest -Arguments @('click', $nothingRef, '-WaitDownload', '-DownloadTimeoutSec', '3')
    Assert-PseTrue ($notObserved.ExitCode -eq 1) "no-op wait expected exit 1, got $($notObserved.ExitCode)."
    Assert-PseTrue ($notObserved.Stdout -match '\[not-observed\]') "no-op output was not not-observed. Output: $($notObserved.Stdout)"

    $dismissed = Invoke-PseCliForTest -Arguments @('click', $confirmRef, '-WaitDownload', '-DownloadTimeoutSec', '3')
    Assert-PseTrue ($dismissed.ExitCode -eq 1) "dismissed confirm expected exit 1, got $($dismissed.ExitCode)."
    Assert-PseTrue ($dismissed.Stdout -match '\[not-observed\]') "dismissed confirm output was not not-observed. Output: $($dismissed.Stdout)"

    Assert-PseTrue (Test-Path -LiteralPath $eventLogPath -PathType Leaf) "download event log was not found at '$eventLogPath'."
    $lastLine = Get-Content -LiteralPath $eventLogPath -Encoding UTF8 | Select-Object -Last 1
    $lastEvent = $lastLine | ConvertFrom-Json
    Assert-PseTrue ($lastEvent.state -eq 'completed') "Expected last logged state completed, got '$($lastEvent.state)'."
} finally {
    Clear-PseState
    if ($edgePid) {
        Stop-Process -Id $edgePid -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $eventLogPath -Force -ErrorAction SilentlyContinue
}
