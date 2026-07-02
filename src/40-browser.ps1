function Get-PseEdgePath {
    $registryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    try {
        $key = Get-Item -Path $registryPath -ErrorAction Stop
        $registeredPath = $key.GetValue('')
        if ($registeredPath -and (Test-Path -LiteralPath $registeredPath)) {
            return $registeredPath
        }
    } catch {
    }

    $candidates = @()
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    }
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw 'msedge.exe was not found.'
}

function Start-PseBrowser {
    param(
        [int]$Port = 9222,

        [switch]$Headless,

        [string]$Url = 'about:blank',

        [string]$UserDataDir
    )

    try {
        [void](Invoke-PseHttpJson -Port $Port -Path '/json/version')
        throw "port $Port is already in use - run 'stop' first or use another -Port"
    } catch {
        if ($_.Exception.Message -eq "port $Port is already in use - run 'stop' first or use another -Port") {
            throw
        }
    }

    if ([string]::IsNullOrWhiteSpace($UserDataDir)) {
        $UserDataDir = Join-Path (Get-PseStateDir) "profile-$Port"
    }
    if (-not (Test-Path -LiteralPath $UserDataDir)) {
        New-Item -ItemType Directory -Path $UserDataDir | Out-Null
    }

    $edgePath = Get-PseEdgePath
    $arguments = @(
        "--remote-debugging-port=$Port",
        "--user-data-dir=$UserDataDir",
        '--no-first-run',
        '--no-default-browser-check'
    )
    if ($Headless) {
        $arguments += '--headless'
        $arguments += '--disable-gpu'
        $arguments += '--no-sandbox'
        $arguments += '--disable-dev-shm-usage'
    }
    $arguments += $Url

    $process = Start-Process -FilePath $edgePath -ArgumentList $arguments -PassThru
    $version = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(15)

    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $version = Invoke-PseHttpJson -Port $Port -Path '/json/version'
            if ($null -ne $version) {
                break
            }
        } catch {
        }
        Start-Sleep -Milliseconds 250
    }

    if ($null -eq $version) {
        try {
            if ($null -ne $process -and -not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {
        }
        throw "Edge did not start a CDP endpoint on port $Port within 15 seconds."
    }

    Write-PseState @{
        port = $Port
        pid = $process.Id
        userDataDir = $UserDataDir
        targetId = $null
    }

    return $version
}

function Stop-PseBrowser {
    $state = Read-PseState
    if ($null -eq $state) {
        return
    }

    $browserPid = $state.pid
    $port = $state.port

    try {
        $version = Invoke-PseHttpJson -Port $port -Path '/json/version'
        if ($null -ne $version -and $version.webSocketDebuggerUrl) {
            $conn = $null
            try {
                $conn = Connect-PseCdp -WebSocketUrl $version.webSocketDebuggerUrl
                [void](Send-PseCdp -Conn $conn -Method 'Browser.close' -TimeoutSec 5)
            } catch {
            } finally {
                if ($null -ne $conn) {
                    Close-PseCdp -Conn $conn
                }
            }
        }
    } catch {
    }

    try {
        if ($browserPid) {
            $process = Get-Process -Id $browserPid -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                if (-not $process.WaitForExit(5000)) {
                    Stop-Process -Id $browserPid -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } catch {
    } finally {
        Clear-PseState
    }
}
