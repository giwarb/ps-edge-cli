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
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-updialog-test-' + [Guid]::NewGuid().ToString('N'))
$fileRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-updialog-files-' + [Guid]::NewGuid().ToString('N'))
$file1 = Join-Path $fileRoot 'one.txt'
$file2 = Join-Path $fileRoot 'two.txt'

try {
    Clear-PseState
    New-Item -ItemType Directory -Path $fileRoot | Out-Null
    Set-Content -LiteralPath $file1 -Value 'one' -Encoding ASCII
    Set-Content -LiteralPath $file2 -Value 'two' -Encoding ASCII

    $html = @'
<!doctype html>
<html>
<head><title>Upload Dialog Fixture</title></head>
<body>
  <input type="file" id="up" aria-label="Upload Input" multiple>
  <input type="text" id="txt" aria-label="Text Input">
  <button id="confirm" type="button" onclick="document.getElementById('log').textContent = String(confirm('really?'))">Confirm Button</button>
  <button id="prompt" type="button" onclick="document.getElementById('log').textContent = String(prompt('name?','def'))">Prompt Button</button>
  <button id="alert" type="button" onclick="alert('boom'); document.getElementById('log').textContent = 'alerted'">Alert Button</button>
  <div id="log"></div>
</body>
</html>
'@

    $start = Invoke-PseCliForTest -Arguments @('start', '-Port', [string]$port, '-Headless', '-UserDataDir', $testRoot)
    Assert-PseTrue ($start.ExitCode -eq 0) "start failed: $($start.Stderr)"

    $goto = Invoke-PseCliForTest -Arguments @('goto', (New-PseDataUrl -Html $html))
    Assert-PseTrue ($goto.ExitCode -eq 0) "goto fixture failed: $($goto.Stderr)"

    $snapshot = Invoke-PseCliForTest -Arguments @('snapshot')
    Assert-PseTrue ($snapshot.ExitCode -eq 0) "snapshot failed: $($snapshot.Stderr)"
    $uploadRef = Get-PseTestRef -Snapshot $snapshot.Stdout -Name 'Upload Input'
    $textRef = Get-PseTestRef -Snapshot $snapshot.Stdout -Name 'Text Input'
    $confirmRef = Get-PseTestRef -Snapshot $snapshot.Stdout -Name 'Confirm Button'
    $promptRef = Get-PseTestRef -Snapshot $snapshot.Stdout -Name 'Prompt Button'
    $alertRef = Get-PseTestRef -Snapshot $snapshot.Stdout -Name 'Alert Button'

    $upload = Invoke-PseCliForTest -Arguments @('upload', $uploadRef, $file1, $file2)
    Assert-PseTrue ($upload.ExitCode -eq 0) "upload failed: $($upload.Stderr)"
    Assert-PseTrue ($upload.Stdout -match "Uploaded 2 file\(s\) to $uploadRef") "upload output mismatch: $($upload.Stdout)"
    $fileCount = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('up').files.length")
    Assert-PseTrue ($fileCount.Stdout.Trim() -eq '2') "expected two uploaded files, got: $($fileCount.Stdout)"
    $fileName = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('up').files[0].name")
    Assert-PseTrue ($fileName.Stdout.Trim() -eq ([System.IO.Path]::GetFileName($file1))) "first uploaded filename mismatch: $($fileName.Stdout)"

    $badInput = Invoke-PseCliForTest -Arguments @('upload', $textRef, $file1)
    Assert-PseTrue ($badInput.ExitCode -eq 1) "upload to text input expected exit 1, got $($badInput.ExitCode)."
    Assert-PseTrue ($badInput.Stderr -match 'not a file input') "upload to text input stderr mismatch: $($badInput.Stderr)"

    $missing = Invoke-PseCliForTest -Arguments @('upload', $uploadRef, 'C:\definitely\missing.bin')
    Assert-PseTrue ($missing.ExitCode -eq 1) "upload missing file expected exit 1, got $($missing.ExitCode)."
    Assert-PseTrue ($missing.Stderr -match 'file not found') "missing file stderr mismatch: $($missing.Stderr)"

    $confirmDismiss = Invoke-PseCliForTest -Arguments @('click', $confirmRef)
    Assert-PseTrue ($confirmDismiss.ExitCode -eq 0) "default confirm click failed: $($confirmDismiss.Stderr)"
    $logAfterDismiss = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('log').textContent")
    Assert-PseTrue ($logAfterDismiss.Stdout.Trim() -eq 'false') "default confirm should dismiss, got: $($logAfterDismiss.Stdout)"
    $dialogDefault = Invoke-PseCliForTest -Arguments @('dialog')
    Assert-PseTrue ($dialogDefault.ExitCode -eq 0) "dialog default read failed: $($dialogDefault.Stderr)"
    Assert-PseTrue ($dialogDefault.Stdout -match '\[confirm\] really\? -> false') "dialog output missing confirm: $($dialogDefault.Stdout)"

    $accept = Invoke-PseCliForTest -Arguments @('dialog', '-Accept', '-Text', 'hello')
    Assert-PseTrue ($accept.ExitCode -eq 0) "dialog -Accept failed: $($accept.Stderr)"
    Assert-PseTrue ($accept.Stdout -match 'Dialog policy: accept text: hello') "dialog -Accept output mismatch: $($accept.Stdout)"
    $prompt = Invoke-PseCliForTest -Arguments @('click', $promptRef)
    Assert-PseTrue ($prompt.ExitCode -eq 0) "prompt click failed: $($prompt.Stderr)"
    $logAfterPrompt = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('log').textContent")
    Assert-PseTrue ($logAfterPrompt.Stdout.Trim() -eq 'hello') "prompt should return hello, got: $($logAfterPrompt.Stdout)"
    $dialogPrompt = Invoke-PseCliForTest -Arguments @('dialog')
    Assert-PseTrue ($dialogPrompt.Stdout -match 'policy: accept text: hello') "dialog policy line missing accept text: $($dialogPrompt.Stdout)"
    Assert-PseTrue ($dialogPrompt.Stdout -match '\[prompt\] name\? -> hello') "dialog output missing prompt: $($dialogPrompt.Stdout)"

    $dismiss = Invoke-PseCliForTest -Arguments @('dialog', '-Dismiss')
    Assert-PseTrue ($dismiss.ExitCode -eq 0) "dialog -Dismiss failed: $($dismiss.Stderr)"
    $confirmDismissAgain = Invoke-PseCliForTest -Arguments @('click', $confirmRef)
    Assert-PseTrue ($confirmDismissAgain.ExitCode -eq 0) "confirm after dismiss failed: $($confirmDismissAgain.Stderr)"
    $logAfterDismissAgain = Invoke-PseCliForTest -Arguments @('eval', "document.getElementById('log').textContent")
    Assert-PseTrue ($logAfterDismissAgain.Stdout.Trim() -eq 'false') "confirm after dismiss should be false, got: $($logAfterDismissAgain.Stdout)"

    $alert = Invoke-PseCliForTest -Arguments @('click', $alertRef)
    Assert-PseTrue ($alert.ExitCode -eq 0) "alert click failed: $($alert.Stderr)"
    $dialogAlert = Invoke-PseCliForTest -Arguments @('dialog')
    Assert-PseTrue ($dialogAlert.Stdout -match '\[alert\] boom ->') "dialog output missing alert: $($dialogAlert.Stdout)"

    $badPolicy = Invoke-PseCliForTest -Arguments @('dialog', '-Accept', '-Dismiss')
    Assert-PseTrue ($badPolicy.ExitCode -eq 1) "dialog -Accept -Dismiss expected exit 1, got $($badPolicy.ExitCode)."
} finally {
    try {
        [void](Invoke-PseCliForTest -Arguments @('stop'))
    } catch {
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fileRoot -Recurse -Force -ErrorAction SilentlyContinue
}
