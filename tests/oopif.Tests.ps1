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

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-oopif-test-' + [Guid]::NewGuid().ToString('N'))
$serverJob = $null

try {
    Clear-PseState

    $serverPort = Get-PseFreePort
    $serverJob = Start-Job -ArgumentList $serverPort -ScriptBlock {
        param($Port)

        $ipv4Listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), ([int]$Port)
        $ipv6Listener = $null
        $ipv4Listener.Start()
        try {
            try {
                $ipv6Listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::IPv6Loopback), ([int]$Port)
                $ipv6Listener.Server.DualMode = $false
                $ipv6Listener.Start()
            } catch {
                if ($null -ne $ipv6Listener) {
                    $ipv6Listener.Stop()
                }
                $ipv6Listener = $null
            }

            while ($true) {
                $listeners = @($ipv4Listener)
                if ($null -ne $ipv6Listener) {
                    $listeners += $ipv6Listener
                }

                $handledRequest = $false
                foreach ($listener in $listeners) {
                    if (-not $listener.Pending()) {
                        continue
                    }

                    $handledRequest = $true
                    $client = $listener.AcceptTcpClient()
                    try {
                        $stream = $client.GetStream()
                        $stream.ReadTimeout = 1000
                        $requestBuffer = New-Object byte[] 8192
                        try {
                            $requestLength = $stream.Read($requestBuffer, 0, $requestBuffer.Length)
                        } catch {
                            continue
                        }
                        if ($requestLength -le 0) {
                            continue
                        }
                        $requestText = [System.Text.Encoding]::ASCII.GetString($requestBuffer, 0, $requestLength)
                        $firstLine = ($requestText -split "`r`n", 2)[0]

                        $status = '200 OK'
                        if ($firstLine -match '/main') {
                            $bodyText = '<!doctype html><html><body><h1>OOPIF Main</h1><iframe src="http://localhost:' + $Port + '/frame"></iframe></body></html>'
                        } elseif ($firstLine -match '/frame') {
                            $bodyText = '<!doctype html><html><body><p>frame body</p><script>setInterval(function(){ confirm(''oopif?''); }, 1200);</script></body></html>'
                        } else {
                            $status = '404 Not Found'
                            $bodyText = 'not found'
                        }

                        $body = [System.Text.Encoding]::UTF8.GetBytes($bodyText)
                        $header = "HTTP/1.1 $status`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
                        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($body, 0, $body.Length)
                        $stream.Flush()
                    } finally {
                        $client.Dispose()
                    }
                }

                if (-not $handledRequest) {
                    Start-Sleep -Milliseconds 50
                }
            }
        } finally {
            if ($null -ne $ipv6Listener) {
                $ipv6Listener.Stop()
            }
            $ipv4Listener.Stop()
        }
    }
    Start-Sleep -Milliseconds 500
    if ($serverJob.State -eq 'Failed') {
        throw "fixture server failed: $(Receive-Job -Job $serverJob)"
    }

    $browserPort = Get-PseFreePort
    $start = Invoke-PseCliForTest -Arguments @('start', '-Headless', '-UserDataDir', $testRoot, '-Port', [string]$browserPort, '-ExtraArg', '--site-per-process')
    Assert-PseTrue ($start.ExitCode -eq 0) "start failed: $($start.Stderr)"

    $goto = Invoke-PseCliForTest -Arguments @('goto', "http://127.0.0.1:$serverPort/main")
    Assert-PseTrue ($goto.ExitCode -eq 0) "goto OOPIF fixture failed: $($goto.Stderr)"

    $waitTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $wait = Invoke-PseCliForTest -Arguments @('wait', '-Time', '3')
    $waitTimer.Stop()
    Assert-PseTrue ($wait.ExitCode -eq 0) "wait with OOPIF dialog failed: $($wait.Stderr)"
    Assert-PseTrue ($waitTimer.Elapsed.TotalSeconds -lt 15) "wait with OOPIF dialog took too long: $($waitTimer.Elapsed.TotalSeconds) seconds"
    Assert-PseTrue ($wait.Stdout -match '# dialog: \[confirm\] oopif\? -> dismissed') "OOPIF dialog was not reported as dismissed: $($wait.Stdout)"

    $snapshot = Invoke-PseCliForTest -Arguments @('snapshot')
    Assert-PseTrue ($snapshot.ExitCode -eq 0) "snapshot after OOPIF dialog failed: $($snapshot.Stderr)"
    Assert-PseTrue ($snapshot.Stdout -match 'OOPIF Main') "snapshot did not contain the main document: $($snapshot.Stdout)"
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
