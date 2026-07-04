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

function Get-PseEdgeLaunchArguments {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$UserDataDir,
        [switch]$Headless,
        [switch]$NoQuietFlags,
        [string[]]$ExtraArg,
        [string]$Url = 'about:blank'
    )

    $arguments = @(
        "--remote-debugging-port=$Port",
        "--user-data-dir=$UserDataDir",
        '--no-first-run',
        '--no-default-browser-check'
    )

    if (-not $NoQuietFlags) {
        $arguments += '--disable-field-trial-config'
        $arguments += '--disable-background-networking'
        $arguments += '--disable-background-timer-throttling'
        $arguments += '--disable-backgrounding-occluded-windows'
        $arguments += '--disable-back-forward-cache'
        $arguments += '--disable-breakpad'
        $arguments += '--disable-client-side-phishing-detection'
        $arguments += '--disable-component-extensions-with-background-pages'
        $arguments += '--disable-component-update'
        $arguments += '--disable-default-apps'
        $arguments += '--disable-extensions'
        $arguments += '--disable-hang-monitor'
        $arguments += '--disable-infobars'
        $arguments += '--disable-ipc-flooding-protection'
        $arguments += '--disable-popup-blocking'
        $arguments += '--disable-prompt-on-repost'
        $arguments += '--disable-renderer-backgrounding'
        $arguments += '--disable-search-engine-choice-screen'
        $arguments += '--disable-sync'
        $arguments += '--edge-skip-compat-layer-relaunch'
        $arguments += '--force-color-profile=srgb'
        $arguments += '--metrics-recording-only'
        $arguments += '--no-service-autorun'
        $arguments += '--password-store=basic'
        $arguments += '--use-mock-keychain'
        $arguments += '--export-tagged-pdf'
        $arguments += '--allow-pre-commit-input'
        $arguments += '--disable-features=AutoDeElevate,AvoidUnnecessaryBeforeUnloadCheckSync,DestroyProfileOnBrowserClose,DialMediaRouteProvider,GlobalMediaControls,HttpsUpgrades,LensOverlay,MediaRouter,OptimizationHints,PaintHolding,ThirdPartyStoragePartitioning,Translate,msEdgeUpdateLaunchServicesPreferredVersion,msForceBrowserSignIn'
    }

    if ($Headless) {
        $arguments += '--headless'
        $arguments += '--disable-gpu'
        $arguments += '--no-sandbox'
        $arguments += '--disable-dev-shm-usage'
    }

    if ($null -ne $ExtraArg) {
        foreach ($arg in $ExtraArg) {
            $arguments += $arg
        }
    }

    $arguments += $Url
    return $arguments
}

function Start-PseBrowser {
    param(
        [int]$Port = 9222,

        [switch]$Headless,

        [switch]$NoQuietFlags,

        [string[]]$ExtraArg,

        [string]$Url = 'about:blank',

        [string]$UserDataDir,

        [string]$DownloadDir
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

    if ([string]::IsNullOrWhiteSpace($DownloadDir)) {
        $DownloadDir = Join-Path (Get-PseStateDir) "downloads-$Port"
    }
    $DownloadDir = [System.IO.Path]::GetFullPath($DownloadDir)
    if (-not (Test-Path -LiteralPath $DownloadDir)) {
        New-Item -ItemType Directory -Path $DownloadDir | Out-Null
    }

    $edgePath = Get-PseEdgePath
    $arguments = Get-PseEdgeLaunchArguments -Port $Port -UserDataDir $UserDataDir -Headless:$Headless -NoQuietFlags:$NoQuietFlags -ExtraArg $ExtraArg -Url $Url

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
        attached = $false
        downloadDir = $DownloadDir
    }

    $downloadWarning = $false
    try {
        Set-PseDownloadBehavior -Version $version -DownloadDir $DownloadDir
    } catch {
        $downloadWarning = $true
    }
    Add-Member -InputObject $version -MemberType NoteProperty -Name pseDownloadWarning -Value $downloadWarning -Force

    return $version
}

function Attach-PseBrowser {
    param(
        [int]$Port = 9222
    )

    try {
        $version = Invoke-PseHttpJson -Port $Port -Path '/json/version'
    } catch {
        throw "no CDP endpoint on port $Port - launch Edge first: msedge.exe --remote-debugging-port=$Port"
    }

    if ($null -eq $version) {
        throw "no CDP endpoint on port $Port - launch Edge first: msedge.exe --remote-debugging-port=$Port"
    }

    Write-PseState @{
        port = $Port
        pid = $null
        userDataDir = $null
        targetId = $null
        attached = $true
        downloadDir = $null
    }

    return $version
}

function Set-PseDownloadBehavior {
    param(
        [Parameter(Mandatory = $true)]
        $Version,

        [Parameter(Mandatory = $true)]
        [string]$DownloadDir
    )

    if ($null -eq $Version -or -not $Version.webSocketDebuggerUrl) {
        throw 'browser WebSocket URL was not available'
    }

    $conn = $null
    try {
        $conn = Connect-PseCdp -WebSocketUrl $Version.webSocketDebuggerUrl
        [void](Send-PseCdp -Conn $conn -Method 'Browser.setDownloadBehavior' -Params @{
            behavior = 'allow'
            downloadPath = $DownloadDir
        } -TimeoutSec 5)
    } finally {
        if ($null -ne $conn) {
            Close-PseCdp -Conn $conn
        }
    }
}

function Stop-PseBrowser {
    $state = Read-PseState
    if ($null -eq $state) {
        return
    }

    if ($null -ne $state.PSObject.Properties['attached'] -and $state.attached) {
        Clear-PseState
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
