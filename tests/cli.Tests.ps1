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

function Invoke-PseCliForTest {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-cli-stdout-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-cli-stderr-' + [Guid]::NewGuid().ToString('N') + '.txt')
    try {
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
        $exitCode = $process.ExitCode
        Set-Content -LiteralPath $stdoutPath -Value $stdout -Encoding UTF8
        Set-Content -LiteralPath $stderrPath -Value $stderr -Encoding UTF8
        $stdout = ''
        $stderr = ''
        if (Test-Path -LiteralPath $stdoutPath) {
            $stdout = Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8
        }
        if (Test-Path -LiteralPath $stderrPath) {
            $stderr = Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8
        }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Stdout = $stdout
            Stderr = $stderr
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
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

function Get-PseTestTabLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    @($Text -split "`r?`n" | Where-Object { $_ -match '^\s*\*?\[\d+\]' })
}

function Get-PseTestTabIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    if ($Line -notmatch '^\s*\*?\[(\d+)\]') {
        throw "Could not parse tab index from line: $Line"
    }
    return [int]$Matches[1]
}

function Test-PseTestTabLineIsCurrent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    return ($Line -match '^\s*\*\[\d+\]')
}

$helpCode = Invoke-PseMain @('help')
Assert-PseTrue ($helpCode -eq 0) "Expected help to return 0, got $helpCode."

$usage = Get-PseUsage
$v1Commands = @(
    'start',
    'stop',
    'status',
    'goto',
    'back',
    'forward',
    'reload',
    'snapshot',
    'screenshot',
    'click',
    'type',
    'fill',
    'press',
    'hover',
    'select',
    'eval',
    'wait',
    'tabs',
    'console',
    'cdp',
    'help'
)
foreach ($command in $v1Commands) {
    Assert-PseTrue ($usage -match "(?m)\b$command\b") "Usage did not mention command '$command'."
}

$unknownCode = Invoke-PseMain @('definitely-not-a-command')
Assert-PseTrue ($unknownCode -eq 1) "Expected unknown command to return 1, got $unknownCode."

$empty = Invoke-PseCliForTest -Arguments @()
Assert-PseTrue ($empty.ExitCode -eq 0) "Expected empty invocation to exit 0, got $($empty.ExitCode)."
Assert-PseTrue ($empty.Stdout -match 'Usage:') 'Expected empty invocation to print usage.'

$parsed = ConvertFrom-PseArgs @('e5', 'hello world', '-Submit', '--port', '9333')
Assert-PseTrue ($parsed.Positional.Count -eq 2) "Expected 2 positional args, got $($parsed.Positional.Count)."
Assert-PseTrue ($parsed.Positional[0] -eq 'e5') "Expected first positional e5, got '$($parsed.Positional[0])'."
Assert-PseTrue ($parsed.Positional[1] -eq 'hello world') "Expected second positional hello world, got '$($parsed.Positional[1])'."
Assert-PseTrue ($parsed.Options['submit'] -eq $true) 'Expected submit flag to be true.'
Assert-PseTrue ($parsed.Options['port'] -eq '9333') "Expected port option 9333, got '$($parsed.Options['port'])'."

$port = Get-PseFreePort
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-cli-test-' + [Guid]::NewGuid().ToString('N'))

try {
    $start = Invoke-PseCliForTest -Arguments @('start', '-Port', [string]$port, '-Headless', '-UserDataDir', $testRoot)
    Assert-PseTrue ($start.ExitCode -eq 0) "start failed: $($start.Stderr)"
    Assert-PseTrue ($start.Stdout -match [regex]::Escape([string]$port)) "start output did not contain port $port. Output: $($start.Stdout)"

    $status = Invoke-PseCliForTest -Arguments @('status')
    Assert-PseTrue ($status.ExitCode -eq 0) "status failed: $($status.Stderr)"
    Assert-PseTrue ($status.Stdout -match '(?i)pid') "status output did not contain pid. Output: $($status.Stdout)"

    $goto = Invoke-PseCliForTest -Arguments @('goto', 'data:text/html,<title>t2</title><p>hi</p>')
    Assert-PseTrue ($goto.ExitCode -eq 0) "goto failed: $($goto.Stderr)"
    Assert-PseTrue ($goto.Stdout -match '# title: t2') "goto output did not contain title t2. Output: $($goto.Stdout)"

    $evalTitle = Invoke-PseCliForTest -Arguments @('eval', 'document.title')
    Assert-PseTrue ($evalTitle.ExitCode -eq 0) "eval document.title failed: $($evalTitle.Stderr)"
    Assert-PseTrue ($evalTitle.Stdout -match 't2') "eval document.title output did not contain t2. Output: $($evalTitle.Stdout)"

    $evalMath = Invoke-PseCliForTest -Arguments @('eval', '1+1')
    Assert-PseTrue ($evalMath.ExitCode -eq 0) "eval 1+1 failed: $($evalMath.Stderr)"
    Assert-PseTrue ($evalMath.Stdout.Trim() -eq '2') "eval 1+1 expected 2, got '$($evalMath.Stdout.Trim())'."

    $cdp = Invoke-PseCliForTest -Arguments @('cdp', 'Runtime.evaluate', '{"expression":"2*3","returnByValue":true}')
    Assert-PseTrue ($cdp.ExitCode -eq 0) "cdp Runtime.evaluate failed: $($cdp.Stderr)"
    Assert-PseTrue ($cdp.Stdout -match '6') "cdp output did not contain 6. Output: $($cdp.Stdout)"

    $tabsBeforeNew = Invoke-PseCliForTest -Arguments @('tabs')
    Assert-PseTrue ($tabsBeforeNew.ExitCode -eq 0) "tabs before new failed: $($tabsBeforeNew.Stderr)"
    $baseTabLines = @(Get-PseTestTabLines -Text $tabsBeforeNew.Stdout)
    $baseCount = $baseTabLines.Count
    Assert-PseTrue ($baseCount -ge 1) "Expected at least 1 base tab. Output: $($tabsBeforeNew.Stdout)"

    $tabsNew = Invoke-PseCliForTest -Arguments @('tabs', 'new')
    Assert-PseTrue ($tabsNew.ExitCode -eq 0) "tabs new failed: $($tabsNew.Stderr)"
    $newTabLines = @(Get-PseTestTabLines -Text $tabsNew.Stdout)
    Assert-PseTrue ($newTabLines.Count -ge 1) "tabs new did not print a tab line. Output: $($tabsNew.Stdout)"
    $newTabIndex = Get-PseTestTabIndex -Line $newTabLines[0]
    Assert-PseTrue (Test-PseTestTabLineIsCurrent -Line $newTabLines[0]) "tabs new did not mark the new tab current. Output: $($tabsNew.Stdout)"

    $tabsList = Invoke-PseCliForTest -Arguments @('tabs')
    Assert-PseTrue ($tabsList.ExitCode -eq 0) "tabs list failed: $($tabsList.Stderr)"
    $tabLines = @(Get-PseTestTabLines -Text $tabsList.Stdout)
    Assert-PseTrue ($tabLines.Count -eq ($baseCount + 1)) "Expected $($baseCount + 1) tabs, got $($tabLines.Count). Output: $($tabsList.Stdout)"
    $listedNewTabLine = $tabLines | Where-Object { (Get-PseTestTabIndex -Line $_) -eq $newTabIndex } | Select-Object -First 1
    Assert-PseTrue ($null -ne $listedNewTabLine) "New tab index $newTabIndex was not listed. Output: $($tabsList.Stdout)"
    Assert-PseTrue (Test-PseTestTabLineIsCurrent -Line $listedNewTabLine) "New tab index $newTabIndex was not current. Output: $($tabsList.Stdout)"

    $tabsSelect = Invoke-PseCliForTest -Arguments @('tabs', 'select', '1')
    Assert-PseTrue ($tabsSelect.ExitCode -eq 0) "tabs select 1 failed: $($tabsSelect.Stderr)"
    $tabsAfterSelect = Invoke-PseCliForTest -Arguments @('tabs')
    Assert-PseTrue ($tabsAfterSelect.ExitCode -eq 0) "tabs after select failed: $($tabsAfterSelect.Stderr)"
    $tabOneLine = @(Get-PseTestTabLines -Text $tabsAfterSelect.Stdout) | Where-Object { (Get-PseTestTabIndex -Line $_) -eq 1 } | Select-Object -First 1
    Assert-PseTrue ($null -ne $tabOneLine) "Tab 1 was not listed after select. Output: $($tabsAfterSelect.Stdout)"
    Assert-PseTrue (Test-PseTestTabLineIsCurrent -Line $tabOneLine) "Tab 1 was not current after tabs select 1. Output: $($tabsAfterSelect.Stdout)"

    $tabsClose = Invoke-PseCliForTest -Arguments @('tabs', 'close', [string]$newTabIndex)
    Assert-PseTrue ($tabsClose.ExitCode -eq 0) "tabs close $newTabIndex failed: $($tabsClose.Stderr)"

    $tabsAfterClose = Invoke-PseCliForTest -Arguments @('tabs')
    $tabLinesAfterClose = @(Get-PseTestTabLines -Text $tabsAfterClose.Stdout)
    Assert-PseTrue ($tabLinesAfterClose.Count -eq $baseCount) "Expected $baseCount tabs after close, got $($tabLinesAfterClose.Count). Output: $($tabsAfterClose.Stdout)"

    $freshTab = Invoke-PseCliForTest -Arguments @('tabs', 'new')
    Assert-PseTrue ($freshTab.ExitCode -eq 0) "tabs new for back test failed: $($freshTab.Stderr)"

    $back = Invoke-PseCliForTest -Arguments @('back')
    Assert-PseTrue ($back.ExitCode -eq 1) "Expected back on fresh tab to exit 1, got $($back.ExitCode). Output: $($back.Stdout)"
    Assert-PseTrue ($back.Stderr -match 'cannot go back') "Expected back stderr to contain cannot go back, got: $($back.Stderr)"

    [void](Invoke-PseCliForTest -Arguments @('tabs', 'close'))

    $stop = Invoke-PseCliForTest -Arguments @('stop')
    Assert-PseTrue ($stop.ExitCode -eq 0) "stop failed: $($stop.Stderr)"

    $stopAgain = Invoke-PseCliForTest -Arguments @('stop')
    Assert-PseTrue ($stopAgain.ExitCode -eq 0) "second stop failed: $($stopAgain.Stderr)"
    Assert-PseTrue ($stopAgain.Stdout -match 'Not running\.') "second stop did not print Not running. Output: $($stopAgain.Stdout)"
} finally {
    try {
        [void](Invoke-PseCliForTest -Arguments @('stop'))
    } catch {
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
