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

$dismissPolicy = @{ mode = 'dismiss'; text = $null }
$acceptPolicy = @{ mode = 'accept'; text = $null }

$beforeUnload = Resolve-PseDialogResponse -Type 'beforeunload' -Policy $dismissPolicy -DefaultPrompt $null
Assert-PseTrue ($beforeUnload.accept -eq $true -and $null -eq $beforeUnload.promptText) 'beforeunload must always be accepted.'

$alert = Resolve-PseDialogResponse -Type 'alert' -Policy $dismissPolicy -DefaultPrompt $null
Assert-PseTrue ($alert.accept -eq $true -and $null -eq $alert.promptText) 'alert must always be accepted.'

$confirmDismiss = Resolve-PseDialogResponse -Type 'confirm' -Policy $dismissPolicy -DefaultPrompt $null
Assert-PseTrue ($confirmDismiss.accept -eq $false -and $null -eq $confirmDismiss.promptText) 'confirm should follow dismiss policy.'

$confirmAccept = Resolve-PseDialogResponse -Type 'confirm' -Policy $acceptPolicy -DefaultPrompt $null
Assert-PseTrue ($confirmAccept.accept -eq $true -and $null -eq $confirmAccept.promptText) 'confirm should follow accept policy.'

$promptText = Resolve-PseDialogResponse -Type 'prompt' -Policy @{ mode = 'accept'; text = 'hi' } -DefaultPrompt 'def'
Assert-PseTrue ($promptText.accept -eq $true -and $promptText.promptText -eq 'hi') 'prompt should prefer policy text.'

$promptDefault = Resolve-PseDialogResponse -Type 'prompt' -Policy $acceptPolicy -DefaultPrompt 'def'
Assert-PseTrue ($promptDefault.accept -eq $true -and $promptDefault.promptText -eq 'def') 'prompt should use its default when policy text is null.'

$promptDismiss = Resolve-PseDialogResponse -Type 'prompt' -Policy $dismissPolicy -DefaultPrompt 'def'
Assert-PseTrue ($promptDismiss.accept -eq $false -and $null -eq $promptDismiss.promptText) 'dismissed prompt should not send prompt text.'

$nullPolicy = Resolve-PseDialogResponse -Type 'confirm' -Policy $null -DefaultPrompt $null
Assert-PseTrue ($nullPolicy.accept -eq $false -and $null -eq $nullPolicy.promptText) 'null policy should be treated as dismiss.'

Assert-PseTrue (Test-PseNoDialogError -Message 'CDP error -32000: No dialog is showing (Page.handleJavaScriptDialog)') 'the no-dialog CDP error should be recognized.'
Assert-PseTrue (-not (Test-PseNoDialogError -Message 'CDP error -32000: Something else')) 'an unrelated CDP error must not be treated as no-dialog.'
Assert-PseTrue (-not (Test-PseNoDialogError -Message 'Timed out after 5 seconds waiting for CDP response to Page.handleJavaScriptDialog.')) 'a dialog-clear timeout must not be treated as no-dialog.'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-dialogguard-test-' + [Guid]::NewGuid().ToString('N'))
$serverJob = $null

try {
    Clear-PseState

    $pageB = @'
<!doctype html>
<html>
<head><title>Dialog Guard Fixture</title></head>
<body>
  <p>CDP dialog safety net fixture</p>
  <button id="c" onclick="document.getElementById('log').textContent = String(confirm('guard?'))">Confirm Button</button>
  <div id="log"></div>
  <script>
    // Snapshot reconnects and installs the JS fast path. Keep this fixture's original
    // confirm so the later click specifically exercises the native CDP safety net.
    Object.defineProperty(window, 'confirm', {
      value: window.confirm,
      writable: false,
      configurable: false
    });
  </script>
</body>
</html>
'@
    # Modern Edge blocks renderer-initiated top-level data: navigation. A one-request
    # loopback server preserves the delayed fresh-document scenario without internet I/O.
    $serverPort = Get-PseFreePort
    $serverJob = Start-Job -ArgumentList $serverPort, $pageB -ScriptBlock {
        param($Port, $Html)

        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), ([int]$Port)
        $listener.Start()
        try {
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $requestBuffer = New-Object byte[] 4096
                [void]$stream.Read($requestBuffer, 0, $requestBuffer.Length)

                $body = [System.Text.Encoding]::UTF8.GetBytes([string]$Html)
                $header = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
                $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                $stream.Write($body, 0, $body.Length)
                $stream.Flush()
            } finally {
                $client.Dispose()
            }
        } finally {
            $listener.Stop()
        }
    }
    Start-Sleep -Milliseconds 500
    if ($serverJob.State -eq 'Failed') {
        throw "fixture server failed: $(Receive-Job -Job $serverJob)"
    }

    $port = Get-PseFreePort
    $pageBUrl = "http://127.0.0.1:$serverPort/fixture"
    $pageA = @"
<!doctype html>
<html>
<head><title>Dialog Guard Navigation</title></head>
<body>
  <iframe id="frame1" title="frame fixture" srcdoc='
    <button id="fc" onclick="document.getElementById(&#39;flog&#39;).textContent = String(confirm(&#39;frame?&#39;))">Frame Confirm</button>
    <div id="flog"></div>
    <iframe id="frame2" title="nested frame fixture" srcdoc=&quot;
      <button id=&amp;quot;nc&amp;quot; onclick=&amp;quot;document.getElementById(&amp;#39;nlog&amp;#39;).textContent = String(confirm(&amp;#39;nested frame?&amp;#39;))&amp;quot;>Nested Frame Confirm</button>
      <div id=&amp;quot;nlog&amp;quot;></div>
    &quot;></iframe>
  '></iframe>
  <button id="nav" onclick="setTimeout(function(){ location.href='$pageBUrl'; }, 400)">Navigate Button</button>
</body>
</html>
"@

    $start = Invoke-PseCliForTest -Arguments @('start', '-Port', [string]$port, '-Headless', '-UserDataDir', $testRoot)
    Assert-PseTrue ($start.ExitCode -eq 0) "start failed: $($start.Stderr)"

    $goto = Invoke-PseCliForTest -Arguments @('goto', (New-PseDataUrl -Html $pageA))
    Assert-PseTrue ($goto.ExitCode -eq 0) "goto page A failed: $($goto.Stderr)"

    $frameTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $frameClick = Invoke-PseCliForTest -Arguments @('eval', "(function(){ var w = frames[0]; w.document.getElementById('fc').click(); return w.document.getElementById('flog').textContent; })()")
    $frameTimer.Stop()
    Assert-PseTrue ($frameClick.ExitCode -eq 0) "iframe confirm failed: $($frameClick.Stderr)"
    Assert-PseTrue ($frameTimer.Elapsed.TotalSeconds -lt 15) "iframe confirm command took too long: $($frameTimer.Elapsed.TotalSeconds) seconds"
    Assert-PseTrue ($frameClick.Stdout.Trim() -eq 'false') "iframe confirm should follow dismiss policy, got: $($frameClick.Stdout)"

    $nestedTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $nestedClick = Invoke-PseCliForTest -Arguments @('eval', "(function(){ var w = frames[0].frames[0]; w.document.getElementById('nc').click(); return w.document.getElementById('nlog').textContent; })()")
    $nestedTimer.Stop()
    Assert-PseTrue ($nestedClick.ExitCode -eq 0) "nested iframe confirm failed: $($nestedClick.Stderr)"
    Assert-PseTrue ($nestedTimer.Elapsed.TotalSeconds -lt 15) "nested iframe confirm command took too long: $($nestedTimer.Elapsed.TotalSeconds) seconds"
    Assert-PseTrue ($nestedClick.Stdout.Trim() -eq 'false') "nested iframe confirm should follow dismiss policy, got: $($nestedClick.Stdout)"

    $frameDialogs = Invoke-PseCliForTest -Arguments @('dialog')
    Assert-PseTrue ($frameDialogs.ExitCode -eq 0) "reading iframe dialogs failed: $($frameDialogs.Stderr)"
    Assert-PseTrue ($frameDialogs.Stdout -match '\[confirm\] frame\? -> false') "main-frame dialog history did not include the iframe confirm: $($frameDialogs.Stdout)"
    Assert-PseTrue ($frameDialogs.Stdout -match '\[confirm\] nested frame\? -> false') "main-frame dialog history did not include the nested iframe confirm: $($frameDialogs.Stdout)"

    $lateFrameJs = @'
(function() {
  setTimeout(function() {
    var frame = document.createElement("iframe");
    frame.id = "late";
    frame.srcdoc = "<button id=\"lc\" onclick=\"document.getElementById('llog').textContent = String(confirm('late outer frame?'))\">Late Outer Frame Confirm</button><div id=\"llog\"></div><iframe id=\"lateNested\" srcdoc='<button id=&quot;lnc&quot; onclick=&quot;document.getElementById(&amp;quot;lnlog&amp;quot;).textContent = String(confirm(&amp;quot;late nested frame?&amp;quot;))&quot;>Late Nested Frame Confirm</button><div id=&quot;lnlog&quot;></div>'></iframe>";
    document.body.appendChild(frame);
  }, 400);
  return "armed";
})()
'@
    $lateCreate = Invoke-PseCliForTest -Arguments @('eval', $lateFrameJs)
    Assert-PseTrue ($lateCreate.ExitCode -eq 0) "later-created iframe setup failed: $($lateCreate.Stderr)"
    Assert-PseTrue ($lateCreate.Stdout.Trim() -eq 'armed') "later-created iframe timer was not armed: $($lateCreate.Stdout)"

    Start-Sleep -Seconds 2

    $lateReconnect = Invoke-PseCliForTest -Arguments @('dialog')
    Assert-PseTrue ($lateReconnect.ExitCode -eq 0) "reconnect after creating an iframe failed: $($lateReconnect.Stderr)"

    $lateOuterTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $lateOuterClick = Invoke-PseCliForTest -Arguments @('eval', "(function(){ var w = document.getElementById('late').contentWindow; w.document.getElementById('lc').click(); return w.document.getElementById('llog').textContent; })()")
    $lateOuterTimer.Stop()
    Assert-PseTrue ($lateOuterClick.ExitCode -eq 0) "later-created outer iframe confirm failed: $($lateOuterClick.Stderr)"
    Assert-PseTrue ($lateOuterTimer.Elapsed.TotalSeconds -lt 15) "later-created outer iframe confirm command took too long: $($lateOuterTimer.Elapsed.TotalSeconds) seconds"
    Assert-PseTrue ($lateOuterClick.Stdout.Trim() -eq 'false') "later-created outer iframe confirm should follow dismiss policy, got: $($lateOuterClick.Stdout)"

    $lateNestedTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $lateNestedClick = Invoke-PseCliForTest -Arguments @('eval', "(function(){ var w = document.getElementById('late').contentWindow.frames[0]; w.document.getElementById('lnc').click(); return w.document.getElementById('lnlog').textContent; })()")
    $lateNestedTimer.Stop()
    Assert-PseTrue ($lateNestedClick.ExitCode -eq 0) "later-created nested iframe confirm failed: $($lateNestedClick.Stderr)"
    Assert-PseTrue ($lateNestedTimer.Elapsed.TotalSeconds -lt 15) "later-created nested iframe confirm command took too long: $($lateNestedTimer.Elapsed.TotalSeconds) seconds"
    Assert-PseTrue ($lateNestedClick.Stdout.Trim() -eq 'false') "later-created nested iframe confirm should follow dismiss policy, got: $($lateNestedClick.Stdout)"

    $lateDialogs = Invoke-PseCliForTest -Arguments @('dialog')
    Assert-PseTrue ($lateDialogs.ExitCode -eq 0) "reading later-created iframe dialogs failed: $($lateDialogs.Stderr)"
    Assert-PseTrue ($lateDialogs.Stdout -match '\[confirm\] late outer frame\? -> false') "main-frame dialog history did not include the later-created outer iframe confirm: $($lateDialogs.Stdout)"
    Assert-PseTrue ($lateDialogs.Stdout -match '\[confirm\] late nested frame\? -> false') "main-frame dialog history did not include the later-created nested iframe confirm: $($lateDialogs.Stdout)"

    $snapshotA = Invoke-PseCliForTest -Arguments @('snapshot')
    Assert-PseTrue ($snapshotA.ExitCode -eq 0) "page A snapshot failed: $($snapshotA.Stderr)"
    $navRef = Get-PseTestRef -Snapshot $snapshotA.Stdout -Name 'Navigate Button'

    $navigate = Invoke-PseCliForTest -Arguments @('click', $navRef)
    Assert-PseTrue ($navigate.ExitCode -eq 0) "navigation click failed: $($navigate.Stderr)"

    Start-Sleep -Seconds 2

    $snapshotB = Invoke-PseCliForTest -Arguments @('snapshot')
    Assert-PseTrue ($snapshotB.ExitCode -eq 0) "page B snapshot failed: $($snapshotB.Stderr)"
    Assert-PseTrue ($snapshotB.Stdout -match 'CDP dialog safety net fixture') "page B did not load: $($snapshotB.Stdout)"
    $confirmRef = Get-PseTestRef -Snapshot $snapshotB.Stdout -Name 'Confirm Button'

    $dismissClick = Invoke-PseCliForTest -Arguments @('click', $confirmRef)
    Assert-PseTrue ($dismissClick.ExitCode -eq 0) "dismiss-policy click failed: $($dismissClick.Stderr)"
    Assert-PseTrue ($dismissClick.Stdout -match '# dialog: \[confirm\] guard\? -> dismissed') "dismissed native dialog was not reported: $($dismissClick.Stdout)"

    $dismissLog = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('log').textContent")
    Assert-PseTrue ($dismissLog.ExitCode -eq 0) "dismiss result eval failed: $($dismissLog.Stderr)"
    Assert-PseTrue ($dismissLog.Stdout.Trim() -eq 'false') "dismissed confirm should return false, got: $($dismissLog.Stdout)"

    $accept = Invoke-PseCliForTest -Arguments @('dialog', '-Accept')
    Assert-PseTrue ($accept.ExitCode -eq 0) "dialog -Accept failed: $($accept.Stderr)"

    $acceptClick = Invoke-PseCliForTest -Arguments @('click', $confirmRef)
    Assert-PseTrue ($acceptClick.ExitCode -eq 0) "accept-policy click failed: $($acceptClick.Stderr)"
    Assert-PseTrue ($acceptClick.Stdout -match '# dialog: \[confirm\] guard\? -> accepted') "accepted native dialog was not reported: $($acceptClick.Stdout)"

    $acceptLog = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('log').textContent")
    Assert-PseTrue ($acceptLog.ExitCode -eq 0) "accept result eval failed: $($acceptLog.Stderr)"
    Assert-PseTrue ($acceptLog.Stdout.Trim() -eq 'true') "accepted confirm should return true, got: $($acceptLog.Stdout)"
} finally {
    try {
        [void](Invoke-PseCliForTest -Arguments @('stop'))
    } catch {
    }
    if ($null -ne $serverJob) {
        Stop-Job -Job $serverJob -ErrorAction SilentlyContinue
        Remove-Job -Job $serverJob -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
