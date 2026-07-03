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
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-actions-test-' + [Guid]::NewGuid().ToString('N'))

try {
    $html = @'
<!doctype html>
<html>
<head>
  <title>Actions Fixture</title>
</head>
<body>
  <form id="form">
    <input id="input" aria-label="Action Input" type="text">
  </form>
  <button id="button" type="button" onclick="appendLog('CLICKED')">Action Button</button>
  <label><input id="check" type="checkbox"> Action Checkbox</label>
  <select id="choice" aria-label="Action Select">
    <option value="v1">Choice One</option>
    <option value="v2">Choice Two</option>
  </select>
  <a id="link" href="#anchor">Action Link</a>
  <div id="hover" role="button" tabindex="0">Hover Target</div>
  <div id="anchor">Anchor</div>
  <div id="log"></div>
  <script>
    function appendLog(text) {
      document.getElementById('log').textContent += text + ' ';
    }
    document.getElementById('form').addEventListener('submit', function(event) {
      event.preventDefault();
      appendLog('SUBMITTED');
    });
    document.getElementById('hover').addEventListener('mouseover', function() {
      appendLog('HOVERED');
    });
    console.log('hello-from-load');
  </script>
</body>
</html>
'@

    $start = Invoke-PseCliForTest -Arguments @('start', '-Port', [string]$port, '-Headless', '-UserDataDir', $testRoot)
    Assert-PseTrue ($start.ExitCode -eq 0) "start failed: $($start.Stderr)"

    $goto = Invoke-PseCliForTest -Arguments @('goto', (New-PseDataUrl -Html $html))
    Assert-PseTrue ($goto.ExitCode -eq 0) "goto fixture failed: $($goto.Stderr)"

    $snapshot = Invoke-PseCliForTest -Arguments @('snapshot')
    Assert-PseTrue ($snapshot.ExitCode -eq 0) "snapshot failed: $($snapshot.Stderr)"
    $buttonRef = Get-PseTestRef -Snapshot $snapshot.Stdout -Name 'Action Button'
    $inputRef = Get-PseTestRef -Snapshot $snapshot.Stdout -Name 'Action Input'
    $selectRef = Get-PseTestRef -Snapshot $snapshot.Stdout -Name 'Action Select'
    $hoverRef = Get-PseTestRef -Snapshot $snapshot.Stdout -Name 'Hover Target'

    $click = Invoke-PseCliForTest -Arguments @('click', $buttonRef)
    Assert-PseTrue ($click.ExitCode -eq 0) "click failed: $($click.Stderr)"
    $logAfterClick = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('log').textContent")
    Assert-PseTrue ($logAfterClick.Stdout -match 'CLICKED') "click did not append CLICKED. Output: $($logAfterClick.Stdout)"

    $type = Invoke-PseCliForTest -Arguments @('type', $inputRef, 'abc123')
    Assert-PseTrue ($type.ExitCode -eq 0) "type failed: $($type.Stderr)"
    $typedValue = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('input').value")
    Assert-PseTrue ($typedValue.Stdout.Trim() -eq 'abc123') "type expected abc123, got: $($typedValue.Stdout)"

    $submit = Invoke-PseCliForTest -Arguments @('type', $inputRef, 'xyz', '-Submit')
    Assert-PseTrue ($submit.ExitCode -eq 0) "type -Submit failed: $($submit.Stderr)"
    $logAfterSubmit = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('log').textContent")
    Assert-PseTrue ($logAfterSubmit.Stdout -match 'SUBMITTED') "submit did not append SUBMITTED. Output: $($logAfterSubmit.Stdout)"

    $fill = Invoke-PseCliForTest -Arguments @('fill', $inputRef, 'hello world')
    Assert-PseTrue ($fill.ExitCode -eq 0) "fill failed: $($fill.Stderr)"
    $filledValue = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('input').value")
    Assert-PseTrue ($filledValue.Stdout.Trim() -eq 'hello world') "fill expected hello world, got: $($filledValue.Stdout)"

    $focusInput = Invoke-PseCliForTest -Arguments @('click', $inputRef)
    Assert-PseTrue ($focusInput.ExitCode -eq 0) "click input before press failed: $($focusInput.Stderr)"
    $pressSelectAll = Invoke-PseCliForTest -Arguments @('press', 'Control+A')
    Assert-PseTrue ($pressSelectAll.ExitCode -eq 0) "press Control+A failed: $($pressSelectAll.Stderr)"
    $pressDelete = Invoke-PseCliForTest -Arguments @('press', 'Delete')
    Assert-PseTrue ($pressDelete.ExitCode -eq 0) "press Delete failed: $($pressDelete.Stderr)"
    $clearedValue = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('input').value")
    Assert-PseTrue ($clearedValue.Stdout.Trim() -eq '') "press Control+A Delete did not clear input. Output: $($clearedValue.Stdout)"

    $hover = Invoke-PseCliForTest -Arguments @('hover', $hoverRef)
    Assert-PseTrue ($hover.ExitCode -eq 0) "hover failed: $($hover.Stderr)"
    $logAfterHover = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('log').textContent")
    Assert-PseTrue ($logAfterHover.Stdout -match 'HOVERED') "hover did not append HOVERED. Output: $($logAfterHover.Stdout)"

    $select = Invoke-PseCliForTest -Arguments @('select', $selectRef, 'v2')
    Assert-PseTrue ($select.ExitCode -eq 0) "select failed: $($select.Stderr)"
    $selectedValue = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('choice').value")
    Assert-PseTrue ($selectedValue.Stdout.Trim() -eq 'v2') "select expected v2, got: $($selectedValue.Stdout)"
    $badSelect = Invoke-PseCliForTest -Arguments @('select', $selectRef, 'missing-option')
    Assert-PseTrue ($badSelect.ExitCode -eq 1) "bad select expected exit 1, got $($badSelect.ExitCode)."
    Assert-PseTrue ($badSelect.Stderr -match 'no option matched') "bad select stderr missing no option matched. Stderr: $($badSelect.Stderr)"

    $waitText = Invoke-PseCliForTest -Arguments @('wait', '-Text', 'CLICKED')
    Assert-PseTrue ($waitText.ExitCode -eq 0) "wait -Text CLICKED failed: $($waitText.Stderr)"
    $waitNope = Invoke-PseCliForTest -Arguments @('wait', '-Text', 'NOPE', '-TimeoutSec', '2')
    Assert-PseTrue ($waitNope.ExitCode -eq 1) "wait -Text NOPE expected exit 1, got $($waitNope.ExitCode)."
    Assert-PseTrue ($waitNope.Stderr -match 'timeout waiting') "wait timeout stderr missing timeout waiting. Stderr: $($waitNope.Stderr)"

    $missingRef = Invoke-PseCliForTest -Arguments @('click', 'e999')
    Assert-PseTrue ($missingRef.ExitCode -eq 1) "click e999 expected exit 1, got $($missingRef.ExitCode)."
    Assert-PseTrue ($missingRef.Stderr -match 'snapshot') "click e999 stderr did not mention snapshot. Stderr: $($missingRef.Stderr)"

    $triggerConsole = Invoke-PseCliForTest -Arguments @('eval', "console.log('hello-from-page'); 'ok'")
    Assert-PseTrue ($triggerConsole.ExitCode -eq 0) "console trigger eval failed: $($triggerConsole.Stderr)"
    $console = Invoke-PseCliForTest -Arguments @('console')
    Assert-PseTrue ($console.ExitCode -eq 0) "console failed: $($console.Stderr)"
    Assert-PseTrue ($console.Stdout -match 'hello-from-page') "console output did not contain hello-from-page. Output: $($console.Stdout)"
} finally {
    try {
        [void](Invoke-PseCliForTest -Arguments @('stop'))
    } catch {
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
