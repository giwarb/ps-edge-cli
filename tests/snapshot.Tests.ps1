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

function Assert-PsePngSignature {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Assert-PseTrue (Test-Path -LiteralPath $Path) "Expected PNG file to exist: $Path"
    $info = Get-Item -LiteralPath $Path
    Assert-PseTrue ($info.Length -gt 1000) "Expected PNG file > 1000 bytes, got $($info.Length)."
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $expected = @(137, 80, 78, 71, 13, 10, 26, 10)
    for ($i = 0; $i -lt $expected.Count; $i++) {
        Assert-PseTrue ([int]$bytes[$i] -eq $expected[$i]) "PNG signature byte $i expected $($expected[$i]), got $([int]$bytes[$i])."
    }
}

$port = Get-PseFreePort
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-snapshot-test-' + [Guid]::NewGuid().ToString('N'))
$shotPath = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-shot-' + [Guid]::NewGuid().ToString('N') + '.png')
$fullShotPath = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-full-shot-' + [Guid]::NewGuid().ToString('N') + '.png')

try {
    $html = @'
<!doctype html>
<html>
<head>
  <title>Snapshot Fixture</title>
</head>
<body>
  <h1>Snapshot Heading</h1>
  <a href="https://example.test/path">Open Example</a>
  <form id="fixture-form">
    <button type="button">Push Me</button>
    <input id="email" type="text" placeholder="Email address">
    <label><input type="checkbox" name="ok"> I accept</label>
    <select name="choice">
      <option value="one">One</option>
      <option value="two">Two</option>
    </select>
  </form>
  <div style="display:none">HIDDEN-MARKER</div>
  <p>Visible paragraph marker text.</p>
</body>
</html>
'@

    $start = Invoke-PseCliForTest -Arguments @('start', '-Port', [string]$port, '-Headless', '-UserDataDir', $testRoot)
    Assert-PseTrue ($start.ExitCode -eq 0) "start failed: $($start.Stderr)"

    $goto = Invoke-PseCliForTest -Arguments @('goto', (New-PseDataUrl -Html $html))
    Assert-PseTrue ($goto.ExitCode -eq 0) "goto fixture failed: $($goto.Stderr)"

    $snapshot = Invoke-PseCliForTest -Arguments @('snapshot')
    Assert-PseTrue ($snapshot.ExitCode -eq 0) "snapshot failed: $($snapshot.Stderr)"
    $snapshotText = $snapshot.Stdout
    Assert-PseTrue ($snapshotText -match '- document "Snapshot Fixture"') "snapshot did not contain document title. Output: $snapshotText"
    Assert-PseTrue ($snapshotText -match '- heading "Snapshot Heading" \[level=1\]') "snapshot did not contain h1 heading. Output: $snapshotText"
    Assert-PseTrue ($snapshotText -match '- link "Open Example" \[ref=e\d+\]') "snapshot did not contain link ref. Output: $snapshotText"
    Assert-PseTrue ($snapshotText -match '- button "Push Me" \[ref=e\d+\]') "snapshot did not contain button ref. Output: $snapshotText"
    Assert-PseTrue ($snapshotText -match '- textbox "Email address" \[ref=e\d+\]') "snapshot did not contain textbox ref. Output: $snapshotText"
    Assert-PseTrue ($snapshotText -match '- checkbox "I accept" \[ref=e\d+\]') "snapshot did not contain checkbox. Output: $snapshotText"
    Assert-PseTrue ($snapshotText -match '- combobox "One Two" \[ref=e\d+\]') "snapshot did not contain combobox. Output: $snapshotText"
    Assert-PseTrue ($snapshotText -match '- text: Visible paragraph marker text\.') "snapshot did not contain visible p text. Output: $snapshotText"
    Assert-PseTrue ($snapshotText -notmatch 'HIDDEN-MARKER') "snapshot contained hidden marker. Output: $snapshotText"

    $refMatches = [regex]::Matches($snapshotText, 'ref=(e\d+)')
    Assert-PseTrue ($refMatches.Count -gt 0) "snapshot had no refs. Output: $snapshotText"
    $refs = @($refMatches | ForEach-Object { $_.Groups[1].Value })
    $uniqueRefs = @($refs | Sort-Object -Unique)
    Assert-PseTrue ($refs.Count -eq $uniqueRefs.Count) "snapshot refs were not unique. Refs: $([string]::Join(', ', $refs))"

    $firstRef = $refs[0]
    $evalRef = Invoke-PseCliForTest -Arguments @('eval', "window.__pseRefs['$firstRef'].tagName")
    Assert-PseTrue ($evalRef.ExitCode -eq 0) "eval ref tagName failed: $($evalRef.Stderr)"
    Assert-PseTrue (-not [string]::IsNullOrWhiteSpace($evalRef.Stdout)) "eval ref tagName returned empty output."

    $formSnapshot = Invoke-PseCliForTest -Arguments @('snapshot', '-Selector', 'form')
    Assert-PseTrue ($formSnapshot.ExitCode -eq 0) "snapshot -Selector form failed: $($formSnapshot.Stderr)"
    Assert-PseTrue ($formSnapshot.Stdout -match '- button "Push Me" \[ref=e\d+\]') "form snapshot did not contain button. Output: $($formSnapshot.Stdout)"
    Assert-PseTrue ($formSnapshot.Stdout -match '- textbox "Email address" \[ref=e\d+\]') "form snapshot did not contain textbox. Output: $($formSnapshot.Stdout)"
    Assert-PseTrue ($formSnapshot.Stdout -notmatch 'Snapshot Heading') "form snapshot unexpectedly contained h1. Output: $($formSnapshot.Stdout)"

    $shot = Invoke-PseCliForTest -Arguments @('screenshot', $shotPath)
    Assert-PseTrue ($shot.ExitCode -eq 0) "screenshot failed: $($shot.Stderr)"
    Assert-PseTrue ($shot.Stdout -match 'Saved screenshot:') "screenshot did not print saved path. Output: $($shot.Stdout)"
    Assert-PsePngSignature -Path $shotPath

    $tallHtml = @'
<!doctype html>
<html>
<head><title>Tall Page</title></head>
<body style="margin:0;height:3000px;background:linear-gradient(#fff,#ccc)">
  <h1>Tall Page</h1>
  <div style="height:2800px"></div>
</body>
</html>
'@
    $gotoTall = Invoke-PseCliForTest -Arguments @('goto', (New-PseDataUrl -Html $tallHtml))
    Assert-PseTrue ($gotoTall.ExitCode -eq 0) "goto tall page failed: $($gotoTall.Stderr)"

    $fullShot = Invoke-PseCliForTest -Arguments @('screenshot', $fullShotPath, '-FullPage')
    Assert-PseTrue ($fullShot.ExitCode -eq 0) "full page screenshot failed: $($fullShot.Stderr)"
    Assert-PseTrue ($fullShot.Stdout -match 'Saved screenshot:') "full page screenshot did not print saved path. Output: $($fullShot.Stdout)"
    Assert-PsePngSignature -Path $fullShotPath
} finally {
    try {
        [void](Invoke-PseCliForTest -Arguments @('stop'))
    } catch {
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $shotPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fullShotPath -Force -ErrorAction SilentlyContinue
}
