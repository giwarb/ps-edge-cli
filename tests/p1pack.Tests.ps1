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

function Get-PseOutputBeforeFooter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Output
    )

    $index = $Output.IndexOf("# url:")
    if ($index -lt 0) {
        throw "Output had no # url: footer. Output: $Output"
    }
    return $Output.Substring(0, $index).TrimEnd()
}

$port = Get-PseFreePort
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-p1pack-test-' + [Guid]::NewGuid().ToString('N'))
$pdfPath = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-p1pack-' + [Guid]::NewGuid().ToString('N') + '.pdf')

try {
    Clear-PseState

    $paragraphs = New-Object System.Text.StringBuilder
    for ($i = 1; $i -le 35; $i++) {
        [void]$paragraphs.AppendLine("<p>Repeated snapshot paragraph $i with enough visible text to push the snapshot output beyond two thousand characters for truncation checks.</p>")
    }

    $html = @"
<!doctype html>
<html>
<head><title>P1 Pack Fixture</title></head>
<body>
  <div id="marker">MARKER</div>
  <script>
    setTimeout(function(){ var d=document.createElement('div'); d.id='late'; d.textContent='LATE'; document.body.appendChild(d); }, 1500);
  </script>
  $paragraphs
</body>
</html>
"@

    $start = Invoke-PseCliForTest -Arguments @('start', '-Port', [string]$port, '-Headless', '-UserDataDir', $testRoot)
    Assert-PseTrue ($start.ExitCode -eq 0) "start failed: $($start.Stderr)"

    $goto = Invoke-PseCliForTest -Arguments @('goto', (New-PseDataUrl -Html $html))
    Assert-PseTrue ($goto.ExitCode -eq 0) "goto fixture failed: $($goto.Stderr)"

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $waitLate = Invoke-PseCliForTest -Arguments @('wait', '-Selector', '#late', '-TimeoutSec', '10')
    $watch.Stop()
    Assert-PseTrue ($waitLate.ExitCode -eq 0) "wait -Selector #late failed: $($waitLate.Stderr)"
    Assert-PseTrue ($watch.Elapsed.TotalMilliseconds -ge 1000) "wait -Selector #late returned too quickly: $($watch.Elapsed.TotalMilliseconds)ms."

    $waitNever = Invoke-PseCliForTest -Arguments @('wait', '-Selector', '#never', '-TimeoutSec', '2')
    Assert-PseTrue ($waitNever.ExitCode -eq 1) "wait -Selector #never expected exit 1, got $($waitNever.ExitCode)."
    Assert-PseTrue ($waitNever.Stderr -match "timeout waiting for selector '#never'") "wait missing selector timeout. Stderr: $($waitNever.Stderr)"

    $removeLate = Invoke-PseCliForTest -Arguments @('eval', "var n=document.querySelector('#late'); if(n){n.parentNode.removeChild(n);} 'removed'")
    Assert-PseTrue ($removeLate.ExitCode -eq 0) "remove late eval failed: $($removeLate.Stderr)"
    $waitGone = Invoke-PseCliForTest -Arguments @('wait', '-SelectorGone', '#late', '-TimeoutSec', '5')
    Assert-PseTrue ($waitGone.ExitCode -eq 0) "wait -SelectorGone #late failed: $($waitGone.Stderr)"

    $badSelector = Invoke-PseCliForTest -Arguments @('wait', '-Selector', '[[[', '-TimeoutSec', '5')
    Assert-PseTrue ($badSelector.ExitCode -eq 1) "wait invalid selector expected exit 1, got $($badSelector.ExitCode)."
    Assert-PseTrue ($badSelector.Stderr -match "invalid selector '\[\[\['") "invalid selector stderr mismatch: $($badSelector.Stderr)"

    $shortSnapshot = Invoke-PseCliForTest -Arguments @('snapshot', '-MaxChars', '500')
    Assert-PseTrue ($shortSnapshot.ExitCode -eq 0) "snapshot -MaxChars 500 failed: $($shortSnapshot.Stderr)"
    $shortBeforeFooter = Get-PseOutputBeforeFooter -Output $shortSnapshot.Stdout
    $marker = '[snapshot truncated at 500 chars - narrow with -Selector <css> or raise -MaxChars]'
    Assert-PseTrue ($shortBeforeFooter.Length -le 600) "truncated snapshot before footer expected <= 600 chars, got $($shortBeforeFooter.Length)."
    Assert-PseTrue ($shortBeforeFooter.EndsWith($marker)) "truncated snapshot did not end with marker. Output: $shortBeforeFooter"
    Assert-PseTrue ($shortSnapshot.Stdout -match '# url:') "truncated snapshot missing url footer. Output: $($shortSnapshot.Stdout)"

    $unlimitedSnapshot = Invoke-PseCliForTest -Arguments @('snapshot', '-MaxChars', '0')
    Assert-PseTrue ($unlimitedSnapshot.ExitCode -eq 0) "snapshot -MaxChars 0 failed: $($unlimitedSnapshot.Stderr)"
    Assert-PseTrue ($unlimitedSnapshot.Stdout -notmatch [regex]::Escape('[snapshot truncated')) "snapshot -MaxChars 0 unexpectedly contained truncation marker."

    $defaultSnapshot = Invoke-PseCliForTest -Arguments @('snapshot')
    Assert-PseTrue ($defaultSnapshot.ExitCode -eq 0) "default snapshot failed: $($defaultSnapshot.Stderr)"
    Assert-PseTrue ($defaultSnapshot.Stdout -notmatch [regex]::Escape('[snapshot truncated')) "default snapshot unexpectedly contained truncation marker."

    $pdf = Invoke-PseCliForTest -Arguments @('pdf', $pdfPath)
    Assert-PseTrue ($pdf.ExitCode -eq 0) "pdf failed: $($pdf.Stderr)"
    Assert-PseTrue (Test-Path -LiteralPath $pdfPath) "pdf file was not created: $pdfPath"
    $pdfInfo = Get-Item -LiteralPath $pdfPath
    Assert-PseTrue ($pdfInfo.Length -gt 1000) "pdf expected > 1000 bytes, got $($pdfInfo.Length)."
    $pdfBytes = [System.IO.File]::ReadAllBytes($pdfPath)
    $pdfHeader = [System.Text.Encoding]::ASCII.GetString($pdfBytes, 0, 5)
    Assert-PseTrue ($pdfHeader -eq '%PDF-') "pdf header expected %PDF-, got $pdfHeader."

    $resize = Invoke-PseCliForTest -Arguments @('resize', '800', '600')
    Assert-PseTrue ($resize.ExitCode -eq 0) "resize 800 600 failed: $($resize.Stderr)"
    $viewport = Invoke-PseCliForTest -Arguments @('eval', "window.innerWidth + 'x' + window.innerHeight")
    Assert-PseTrue ($viewport.ExitCode -eq 0) "viewport eval failed: $($viewport.Stderr)"
    Assert-PseTrue ($viewport.Stdout.Trim() -eq '800x600') "expected 800x600, got: $($viewport.Stdout)"

    $badResize = Invoke-PseCliForTest -Arguments @('resize', '-5', '0')
    Assert-PseTrue ($badResize.ExitCode -eq 1) "resize -5 0 expected exit 1, got $($badResize.ExitCode)."
} finally {
    try {
        [void](Invoke-PseCliForTest -Arguments @('stop'))
    } catch {
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pdfPath -Force -ErrorAction SilentlyContinue
}
