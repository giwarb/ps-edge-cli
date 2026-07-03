$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildPath = Join-Path $repoRoot 'build.ps1'
$distPath = Join-Path $repoRoot 'skills\ps-edge\scripts\ps-edge.ps1'
$skillPath = Join-Path $repoRoot 'skills\ps-edge\SKILL.md'
$dogfoodSkillPath = Join-Path $repoRoot '.claude\skills\ps-edge\SKILL.md'
$dogfoodBundlePath = Join-Path $repoRoot '.claude\skills\ps-edge\scripts\ps-edge.ps1'
$srcDir = Join-Path $repoRoot 'src'

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

function Assert-PseSameBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExpectedPath,

        [Parameter(Mandatory = $true)]
        [string]$ActualPath,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $expectedBytes = [System.IO.File]::ReadAllBytes($ExpectedPath)
    $actualBytes = [System.IO.File]::ReadAllBytes($ActualPath)
    Assert-PseTrue ($expectedBytes.Length -eq $actualBytes.Length) "$Label byte lengths differ."
    for ($i = 0; $i -lt $expectedBytes.Length; $i++) {
        if ($expectedBytes[$i] -ne $actualBytes[$i]) {
            throw "$Label bytes differ at offset $i."
        }
    }
}

function Invoke-PseDistCliForTest {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $distPath) + $Arguments
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

function Get-PseTestFreePort {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return $listener.LocalEndpoint.Port
    } finally {
        $listener.Stop()
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

& $buildPath | Out-Host
Assert-PseTrue (Test-Path -LiteralPath $distPath) 'build.ps1 did not create skills/ps-edge/scripts/ps-edge.ps1.'
Assert-PseTrue (Test-Path -LiteralPath $dogfoodSkillPath) 'build.ps1 did not sync .claude/skills/ps-edge/SKILL.md.'
Assert-PseTrue (Test-Path -LiteralPath $dogfoodBundlePath) 'build.ps1 did not sync .claude/skills/ps-edge/scripts/ps-edge.ps1.'
Assert-PseSameBytes -ExpectedPath $skillPath -ActualPath $dogfoodSkillPath -Label 'Synced SKILL.md'
Assert-PseSameBytes -ExpectedPath $distPath -ActualPath $dogfoodBundlePath -Label 'Synced bundle'

$skillText = Get-Content -LiteralPath $skillPath -Raw
Assert-PseTrue (-not ($skillText.Contains('dist\') -or $skillText.Contains('dist/'))) 'skills/ps-edge/SKILL.md must not contain dist paths.'

$bundleText = Get-Content -LiteralPath $distPath -Raw
[void][scriptblock]::Create($bundleText)

$srcText = Get-ChildItem -Path $srcDir -Filter '*.ps1' | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw
}
$commandFunctions = @(
    [regex]::Matches(($srcText -join "`n"), '(?m)^\s*function\s+(\S+)') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -like 'Invoke-PseCmd*' } |
        Sort-Object -Unique
)
foreach ($functionName in $commandFunctions) {
    Assert-PseTrue ($bundleText -match ('(?m)\b' + [regex]::Escape($functionName) + '\b')) "Bundle is missing function $functionName."
}

$help = Invoke-PseDistCliForTest -Arguments @('help')
Assert-PseTrue ($help.ExitCode -eq 0) "dist help exited $($help.ExitCode): $($help.Stderr)"
Assert-PseTrue ($help.Stdout -match 'Usage:') "dist help did not print usage. Output: $($help.Stdout)"

$bytes1 = [System.IO.File]::ReadAllBytes($distPath)
& $buildPath | Out-Host
$bytes2 = [System.IO.File]::ReadAllBytes($distPath)
Assert-PseTrue ($bytes1.Length -eq $bytes2.Length) 'Running build.ps1 twice produced different file sizes.'
for ($i = 0; $i -lt $bytes1.Length; $i++) {
    if ($bytes1[$i] -ne $bytes2[$i]) {
        throw "Running build.ps1 twice produced different bytes at offset $i."
    }
}

$port = Get-PseTestFreePort
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-dist-test-' + [Guid]::NewGuid().ToString('N'))
$screenshotPath = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-dist-shot-' + [Guid]::NewGuid().ToString('N') + '.png')

try {
    $html = @'
<!doctype html>
<html>
<head><title>Dist Fixture</title></head>
<body>
  <button id="button" type="button" onclick="document.body.setAttribute('data-clicked','yes')">Dist Button</button>
</body>
</html>
'@

    $start = Invoke-PseDistCliForTest -Arguments @('start', '-Port', [string]$port, '-Headless', '-UserDataDir', $testRoot)
    Assert-PseTrue ($start.ExitCode -eq 0) "dist start failed: $($start.Stderr)"

    $goto = Invoke-PseDistCliForTest -Arguments @('goto', (New-PseDataUrl -Html $html))
    Assert-PseTrue ($goto.ExitCode -eq 0) "dist goto failed: $($goto.Stderr)"

    $snapshot = Invoke-PseDistCliForTest -Arguments @('snapshot')
    Assert-PseTrue ($snapshot.ExitCode -eq 0) "dist snapshot failed: $($snapshot.Stderr)"
    Assert-PseTrue ($snapshot.Stdout -match '\[ref=e\d+\]') "dist snapshot did not contain a ref. Output: $($snapshot.Stdout)"
    $buttonRef = Get-PseTestRef -Snapshot $snapshot.Stdout -Name 'Dist Button'

    $click = Invoke-PseDistCliForTest -Arguments @('click', $buttonRef)
    Assert-PseTrue ($click.ExitCode -eq 0) "dist click failed: $($click.Stderr)"
    $clicked = Invoke-PseDistCliForTest -Arguments @('eval', "document.body.getAttribute('data-clicked')")
    Assert-PseTrue ($clicked.Stdout.Trim() -eq 'yes') "dist click did not update the page. Output: $($clicked.Stdout)"

    $screenshot = Invoke-PseDistCliForTest -Arguments @('screenshot', $screenshotPath)
    Assert-PseTrue ($screenshot.ExitCode -eq 0) "dist screenshot failed: $($screenshot.Stderr)"
    Assert-PseTrue (Test-Path -LiteralPath $screenshotPath) 'dist screenshot did not create a PNG file.'
    $pngBytes = [System.IO.File]::ReadAllBytes($screenshotPath)
    Assert-PseTrue ($pngBytes.Length -gt 8) 'dist screenshot PNG was empty.'
    Assert-PseTrue ($pngBytes[0] -eq 137 -and $pngBytes[1] -eq 80 -and $pngBytes[2] -eq 78 -and $pngBytes[3] -eq 71) 'dist screenshot file did not have a PNG signature.'

    $stop = Invoke-PseDistCliForTest -Arguments @('stop')
    Assert-PseTrue ($stop.ExitCode -eq 0) "dist stop failed: $($stop.Stderr)"
} finally {
    try {
        [void](Invoke-PseDistCliForTest -Arguments @('stop'))
    } catch {
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $screenshotPath -Force -ErrorAction SilentlyContinue
}
