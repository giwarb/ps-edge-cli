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

function Wait-PseDownloadedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

$port = Get-PseFreePort
$unusedPort = Get-PseFreePort
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-downloads-test-' + [Guid]::NewGuid().ToString('N'))
$downloadDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-downloads-dir-' + [Guid]::NewGuid().ToString('N'))
$downloadPath = Join-Path $downloadDir 'pse-test.txt'
$edgePid = $null
$downloadCreated = $false

try {
    Clear-PseState

    $start = Invoke-PseCliForTest -Arguments @('start', '-Port', [string]$port, '-Headless', '-UserDataDir', $testRoot, '-DownloadDir', $downloadDir)
    Assert-PseTrue ($start.ExitCode -eq 0) "start failed: $($start.Stderr)"

    $state = Read-PseState
    Assert-PseTrue ($null -ne $state) 'State was not written after start.'
    Assert-PseTrue ($state.downloadDir -eq [System.IO.Path]::GetFullPath($downloadDir)) "Expected state downloadDir '$downloadDir', got '$($state.downloadDir)'."
    $edgePid = $state.pid

    $html = @'
<!doctype html>
<html>
<head><title>Download Fixture</title></head>
<body>
  <a id="dl" download="pse-test.txt" href="data:text/plain,hello-download">DL</a>
</body>
</html>
'@
    $goto = Invoke-PseCliForTest -Arguments @('goto', (New-PseDataUrl -Html $html))
    Assert-PseTrue ($goto.ExitCode -eq 0) "goto download fixture failed: $($goto.Stderr)"

    $snapshot = Invoke-PseCliForTest -Arguments @('snapshot')
    Assert-PseTrue ($snapshot.ExitCode -eq 0) "snapshot failed: $($snapshot.Stderr)"
    $downloadRef = Get-PseTestRef -Snapshot $snapshot.Stdout -Name 'DL'

    $click = Invoke-PseCliForTest -Arguments @('click', $downloadRef)
    Assert-PseTrue ($click.ExitCode -eq 0) "click download failed: $($click.Stderr)"
    $downloadCreated = Wait-PseDownloadedFile -Path $downloadPath

    if (-not $downloadCreated) {
        $evalClick = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('dl').click(); 'clicked'")
        Assert-PseTrue ($evalClick.ExitCode -eq 0) "eval fallback click failed: $($evalClick.Stderr)"
        $downloadCreated = Wait-PseDownloadedFile -Path $downloadPath
    }

    $downloads = Invoke-PseCliForTest -Arguments @('downloads')
    Assert-PseTrue ($downloads.ExitCode -eq 0) "downloads failed: $($downloads.Stderr)"
    Assert-PseTrue ($downloads.Stdout -match '(?m)# dir: ') "downloads output did not contain dir footer. Output: $($downloads.Stdout)"
    if ($downloadCreated) {
        $content = Get-Content -LiteralPath $downloadPath -Raw
        Assert-PseTrue ($content -eq 'hello-download') "Downloaded file content mismatch: '$content'."
        Assert-PseTrue ($downloads.Stdout -match 'pse-test\.txt') "downloads output did not mention pse-test.txt. Output: $($downloads.Stdout)"
    }

    Clear-PseState
    $downloadsNoDir = Invoke-PseCliForTest -Arguments @('downloads')
    Assert-PseTrue ($downloadsNoDir.ExitCode -eq 1) "downloads without configured dir expected exit 1, got $($downloadsNoDir.ExitCode)."
    Assert-PseTrue ($downloadsNoDir.Stderr -match 'no download directory configured') "downloads without dir stderr mismatch: $($downloadsNoDir.Stderr)"

    $attach = Invoke-PseCliForTest -Arguments @('start', '-Attach', '-Port', [string]$port)
    Assert-PseTrue ($attach.ExitCode -eq 0) "attach failed: $($attach.Stderr)"
    Assert-PseTrue ($attach.Stdout -match 'Attached to Edge') "attach output missing Attached to Edge. Output: $($attach.Stdout)"

    $status = Invoke-PseCliForTest -Arguments @('status')
    Assert-PseTrue ($status.ExitCode -eq 0) "status after attach failed: $($status.Stderr)"
    Assert-PseTrue ($status.Stdout -match 'attached: true') "status did not show attached true. Output: $($status.Stdout)"

    $detach = Invoke-PseCliForTest -Arguments @('stop')
    Assert-PseTrue ($detach.ExitCode -eq 0) "attached stop failed: $($detach.Stderr)"
    Assert-PseTrue ($detach.Stdout -match 'Detached \(browser left running\)\.') "attached stop did not detach. Output: $($detach.Stdout)"

    $versionAfterDetach = Invoke-PseHttpJson -Port $port -Path '/json/version'
    Assert-PseTrue ($null -ne $versionAfterDetach -and $versionAfterDetach.Browser -match 'Edg') 'CDP endpoint did not answer after attached stop.'

    $reattach = Invoke-PseCliForTest -Arguments @('start', '-Attach', '-Port', [string]$port)
    Assert-PseTrue ($reattach.ExitCode -eq 0) "reattach failed: $($reattach.Stderr)"

    $badAttach = Invoke-PseCliForTest -Arguments @('start', '-Attach', '-Port', [string]$unusedPort)
    Assert-PseTrue ($badAttach.ExitCode -eq 1) "attach to unused port expected exit 1, got $($badAttach.ExitCode)."
    Assert-PseTrue ($badAttach.Stderr -match 'no CDP endpoint') "bad attach stderr did not mention no CDP endpoint. Stderr: $($badAttach.Stderr)"
} finally {
    Clear-PseState
    if ($edgePid) {
        Stop-Process -Id $edgePid -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
}
