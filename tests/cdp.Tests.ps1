$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $repoRoot 'src'
$srcFiles = Get-ChildItem -Path $srcDir -Filter '*.ps1' | Sort-Object Name

$dotSourceOutput = @(
    foreach ($file in $srcFiles) {
        . $file.FullName
    }
)
if ($dotSourceOutput.Count -ne 0) {
    throw 'Dot-sourcing src/*.ps1 produced output.'
}

$edgePath = Get-PseEdgePath
if (-not (Test-Path -LiteralPath $edgePath)) {
    throw "Get-PseEdgePath returned a missing path: $edgePath"
}

$freePort = Get-PseFreePort
if (-not ($freePort -is [int])) {
    throw "Get-PseFreePort did not return an int: $($freePort.GetType().FullName)"
}
if ($freePort -lt 1024 -or $freePort -gt 65535) {
    throw "Get-PseFreePort returned an out-of-range port: $freePort"
}

$port = Get-PseFreePort
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-cdp-test-' + [Guid]::NewGuid().ToString('N'))
$conn = $null
$edgePid = $null
$step = 'starting browser'

try {
    $version = Start-PseBrowser -Port $port -Headless -UserDataDir $testRoot
    $state = Read-PseState
    if ($null -ne $state) {
        $edgePid = $state.pid
    }

    $step = 'reading /json/version'
    $httpVersion = Invoke-PseHttpJson -Port $port -Path '/json/version'
    if ($null -eq $httpVersion -or $httpVersion.Browser -notmatch 'Edg') {
        throw "Expected /json/version Browser to contain Edg, got '$($httpVersion.Browser)'."
    }

    $step = 'listing page targets'
    $targets = @(Get-PseTargets -Port $port)
    if ($targets.Count -lt 1) {
        throw 'Expected at least one page target.'
    }

    $target = $targets[0]
    if (-not $target.webSocketDebuggerUrl) {
        throw 'First page target did not include webSocketDebuggerUrl.'
    }

    $step = 'connecting to page target'
    $conn = Connect-PseCdp -WebSocketUrl $target.webSocketDebuggerUrl
    $step = 'enabling Page domain'
    [void](Send-PseCdp -Conn $conn -Method 'Page.enable')
    $step = 'navigating data URL'
    [void](Send-PseCdp -Conn $conn -Method 'Page.navigate' -Params @{ url = 'data:text/html,<title>pse-test</title><h1>hello</h1>' })
    $step = 'waiting for Page.loadEventFired'
    [void](Wait-PseCdpEvent -Conn $conn -EventName 'Page.loadEventFired')
    $step = 'evaluating document.title'
    $evalResult = Send-PseCdp -Conn $conn -Method 'Runtime.evaluate' -Params @{ expression = 'document.title'; returnByValue = $true }

    if ($evalResult.result.value -ne 'pse-test') {
        throw "Expected document.title to be pse-test, got '$($evalResult.result.value)'."
    }

    Close-PseCdp -Conn $conn
    $conn = $null

    $step = 'stopping browser'
    Stop-PseBrowser

    $step = 'waiting for Edge process exit'
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($edgePid -and [DateTime]::UtcNow -lt $deadline) {
        $process = Get-Process -Id $edgePid -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if ($edgePid -and (Get-Process -Id $edgePid -ErrorAction SilentlyContinue)) {
        throw "Edge process $edgePid was still running after Stop-PseBrowser."
    }

    $stateFile = Join-Path (Get-PseStateDir) 'state.json'
    if (Test-Path -LiteralPath $stateFile) {
        throw 'State file still existed after Stop-PseBrowser.'
    }
} catch {
    throw "Integration step '$step' failed: $($_.Exception.Message)"
} finally {
    if ($null -ne $conn) {
        Close-PseCdp -Conn $conn
    }

    if ($edgePid) {
        Stop-Process -Id $edgePid -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
