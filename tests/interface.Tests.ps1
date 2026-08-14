$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $repoRoot 'src'
$scriptPath = Join-Path $repoRoot 'ps-edge.ps1'
Get-ChildItem -Path $srcDir -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }

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
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

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
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments)

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
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function New-PseDataUrl {
    param([Parameter(Mandatory = $true)][string]$Html)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
    return 'data:text/html;charset=utf-8;base64,' + [Convert]::ToBase64String($bytes)
}

function Get-PseJsonOutput {
    param([Parameter(Mandatory = $true)][string]$Stdout)
    $line = @($Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[0]
    return ($line | ConvertFrom-Json)
}

$originalGetSession = ${function:Get-PseSession}
$originalCloseSession = ${function:Close-PseSession}
$originalGetLocation = ${function:Get-PseLocation}
$script:mockGetCount = 0
$script:mockCloseCount = 0
try {
    Set-Item Function:Get-PseSession -Value {
        $script:mockGetCount++
        return [pscustomobject]@{ Conn = $null }
    }
    Set-Item Function:Close-PseSession -Value {
        param($Session)
        $script:mockCloseCount++
    }
    Set-Item Function:Get-PseLocation -Value {
        param($Session)
        return [pscustomobject]@{ url = 'about:blank'; title = '' }
    }
    $emptyBatch = Invoke-PseBatch -Steps @()
    Assert-PseTrue ($emptyBatch.ok) 'Expected empty batch to succeed.'
    Assert-PseTrue ($script:mockGetCount -eq 1) "Expected one session acquisition, got $script:mockGetCount."
    Assert-PseTrue ($script:mockCloseCount -eq 1) "Expected one session close, got $script:mockCloseCount."
} finally {
    Set-Item Function:Get-PseSession -Value $originalGetSession
    Set-Item Function:Close-PseSession -Value $originalCloseSession
    Set-Item Function:Get-PseLocation -Value $originalGetLocation
}

$invalidJson = Invoke-PseCliForTest -Arguments @('batch', '-Json', '[broken')
Assert-PseTrue ($invalidJson.ExitCode -eq 1) 'Invalid batch JSON should fail.'
Assert-PseTrue ($invalidJson.Stderr -match 'invalid batch JSON') "Missing invalid JSON error: $($invalidJson.Stderr)"

$objectRoot = Invoke-PseCliForTest -Arguments @('batch', '-Json', '{"action":"eval"}')
Assert-PseTrue ($objectRoot.ExitCode -eq 1) 'Non-array batch JSON should fail.'
Assert-PseTrue ($objectRoot.Stderr -match 'root must be an array') "Missing array-root error: $($objectRoot.Stderr)"

$negativeItems = Invoke-PseCliForTest -Arguments @('inspect', '-MaxItems', '-1')
Assert-PseTrue ($negativeItems.ExitCode -eq 1) 'Negative MaxItems should fail.'
Assert-PseTrue ($negativeItems.Stderr -match 'MaxItems must be 0 or a positive integer') "Missing MaxItems error: $($negativeItems.Stderr)"

$port = Get-PseFreePort
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-interface-test-' + [Guid]::NewGuid().ToString('N'))
try {
    $start = Invoke-PseCliForTest -Arguments @('start', '-Port', [string]$port, '-Headless', '-UserDataDir', $testRoot)
    Assert-PseTrue ($start.ExitCode -eq 0) "start failed: $($start.Stderr)"

    $html = @'
<!doctype html>
<html>
<head><title>Interface Fixture</title></head>
<body>
  <label for="subject">Subject</label><input id="subject" name="subject" type="text">
  <select id="kind" aria-label="Kind"><option value="one">One</option><option value="two">Two</option></select>
  <button id="save" type="button" onclick="window.clicked=true">Save</button>
  <div id="many"></div>
  <script>
    window.clicked = false;
    window.rectCalls = 0;
    var originalRect = HTMLElement.prototype.getBoundingClientRect;
    HTMLElement.prototype.getBoundingClientRect = function() {
      window.rectCalls++;
      return originalRect.call(this);
    };
    var host = document.getElementById('many');
    for (var i = 0; i < 300; i++) {
      var button = document.createElement('button');
      button.textContent = 'Extra button ' + i;
      host.appendChild(button);
    }
  </script>
</body>
</html>
'@
    $goto = Invoke-PseCliForTest -Arguments @('goto', (New-PseDataUrl -Html $html))
    Assert-PseTrue ($goto.ExitCode -eq 0) "goto failed: $($goto.Stderr)"

    $inspect = Invoke-PseCliForTest -Arguments @('inspect', '-MaxItems', '3')
    Assert-PseTrue ($inspect.ExitCode -eq 0) "inspect failed: $($inspect.Stderr)"
    $items = @(Get-PseJsonOutput -Stdout $inspect.Stdout)
    Assert-PseTrue ($items.Count -eq 3) "Expected three inspected controls, got $($items.Count)."
    Assert-PseTrue ($items[0].name -eq 'Subject') "Unexpected accessible name: $($items[0].name)"
    Assert-PseTrue ($items[1].options.Count -eq 2) 'Expected select options in inspect output.'
    $subjectRef = [string]$items[0].ref
    $kindRef = [string]$items[1].ref
    $saveRef = [string]$items[2].ref

    $steps = @(
        @{ action = 'fill'; ref = $subjectRef; value = '日本語の会議' },
        @{ action = 'select'; ref = $kindRef; values = @('two') },
        @{ action = 'click'; ref = $saveRef },
        @{ action = 'eval'; expression = "({subject:document.getElementById('subject').value,kind:document.getElementById('kind').value,clicked:window.clicked})" }
    )
    $batchJson = ConvertTo-Json -InputObject $steps -Depth 8 -Compress
    $batch = Invoke-PseCliForTest -Arguments @('batch', '-Json', $batchJson)
    Assert-PseTrue ($batch.ExitCode -eq 0) "batch failed: $($batch.Stderr)"
    $batchResult = Get-PseJsonOutput -Stdout $batch.Stdout
    Assert-PseTrue ($batchResult.ok) 'Expected batch ok=true.'
    Assert-PseTrue ($batchResult.steps.Count -eq 4) "Expected four batch results, got $($batchResult.steps.Count)."
    $verification = $batchResult.steps[3].result
    Assert-PseTrue ($verification.subject -eq '日本語の会議') "Japanese value was not preserved: $($verification.subject)"
    Assert-PseTrue ($verification.kind -eq 'two') "Expected selected value two, got $($verification.kind)."
    Assert-PseTrue ($verification.clicked) 'Expected batch click to run.'
    Assert-PseTrue (@($batchResult.steps[1].result).Count -eq 1) 'Select result must remain an array.'

    $shapeSteps = @(
        @{ action = 'eval'; expression = '[]' },
        @{ action = 'eval'; expression = '[1]' },
        @{ action = 'eval'; expression = '[1,2]' },
        @{ action = 'inspect'; maxItems = 1 }
    )
    $shapeJson = ConvertTo-Json -InputObject $shapeSteps -Depth 6 -Compress
    $shapeBatch = Invoke-PseCliForTest -Arguments @('batch', '-Json', $shapeJson)
    Assert-PseTrue ($shapeBatch.ExitCode -eq 0) "array-shape batch failed: $($shapeBatch.Stderr)"
    $shapeResult = Get-PseJsonOutput -Stdout $shapeBatch.Stdout
    Assert-PseTrue (@($shapeResult.steps[0].result).Count -eq 0) "Empty eval array changed shape. Output: $($shapeBatch.Stdout)"
    Assert-PseTrue (@($shapeResult.steps[1].result).Count -eq 1) 'Singleton eval array changed shape.'
    Assert-PseTrue (@($shapeResult.steps[2].result).Count -eq 2) 'Multi-item eval array changed shape.'
    Assert-PseTrue (@($shapeResult.steps[3].result).Count -eq 1) 'Singleton inspect array changed shape.'

    $failSteps = @(
        @{ action = 'eval'; expression = 'window.batchMarker=1' },
        @{ action = 'does-not-exist' },
        @{ action = 'eval'; expression = 'window.batchMarker=2' }
    )
    $failJson = ConvertTo-Json -InputObject $failSteps -Depth 6 -Compress
    $failedBatch = Invoke-PseCliForTest -Arguments @('batch', '-Json', $failJson)
    Assert-PseTrue ($failedBatch.ExitCode -eq 1) 'Unknown batch action should fail.'
    Assert-PseTrue ($failedBatch.Stderr -match 'batch step 1 \(does-not-exist\)') "Missing step-index error: $($failedBatch.Stderr)"
    $marker = Invoke-PseCliForTest -Arguments @('eval', 'window.batchMarker')
    Assert-PseTrue ($marker.Stdout.Trim() -eq '1') "Batch did not fail fast. Marker: $($marker.Stdout)"

    $missingValueJson = ConvertTo-Json -InputObject @(@{ action = 'fill'; ref = $subjectRef }) -Compress
    $missingValue = Invoke-PseCliForTest -Arguments @('batch', '-Json', $missingValueJson)
    Assert-PseTrue ($missingValue.ExitCode -eq 1) 'Malformed batch step should fail.'
    Assert-PseTrue ($missingValue.Stderr -match "batch step 0 \(fill\): missing 'value'") "Missing property error was unclear: $($missingValue.Stderr)"

    $badSelector = Invoke-PseCliForTest -Arguments @('inspect', '-Selector', '[[bad')
    Assert-PseTrue ($badSelector.ExitCode -eq 1) 'Invalid inspect selector should fail.'
    Assert-PseTrue ($badSelector.Stderr -match 'invalid selector') "Missing invalid selector error: $($badSelector.Stderr)"

    $missingSelector = Invoke-PseCliForTest -Arguments @('inspect', '-Selector', '#missing')
    Assert-PseTrue ($missingSelector.ExitCode -eq 1) 'Missing inspect selector should fail.'
    Assert-PseTrue ($missingSelector.Stderr -match 'no element matches') "Missing no-match error: $($missingSelector.Stderr)"

    [void](Invoke-PseCliForTest -Arguments @('eval', 'window.rectCalls=0'))
    $smallSnapshot = Invoke-PseCliForTest -Arguments @('snapshot', '-MaxChars', '200')
    Assert-PseTrue ($smallSnapshot.ExitCode -eq 0) "bounded snapshot failed: $($smallSnapshot.Stderr)"
    Assert-PseTrue ($smallSnapshot.Stdout -match 'snapshot truncated at 200 chars') 'Expected snapshot truncation marker.'
    $rectCalls = Invoke-PseCliForTest -Arguments @('eval', 'window.rectCalls')
    Assert-PseTrue ([int]$rectCalls.Stdout.Trim() -lt 30) "Snapshot continued walking after its budget: $($rectCalls.Stdout)"
} finally {
    try { [void](Invoke-PseCliForTest -Arguments @('stop')) } catch {}
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
