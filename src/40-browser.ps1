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
        $arguments += '--deny-permission-prompts'
        $arguments += '--edge-skip-compat-layer-relaunch'
        $arguments += '--force-color-profile=srgb'
        $arguments += '--hide-crash-restore-bubble'
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

function Resolve-PseHttpsOrigin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Origin
    )

    try {
        $uri = New-Object System.Uri($Origin, [System.UriKind]::Absolute)
    } catch {
        throw "Okta FastPass origin must be an HTTPS origin such as https://tenant.okta.com: $Origin"
    }

    if ($uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        ($uri.AbsolutePath -ne '/' -and -not [string]::IsNullOrEmpty($uri.AbsolutePath)) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw "Okta FastPass origin must be an HTTPS origin such as https://tenant.okta.com: $Origin"
    }

    return $uri.GetLeftPart([System.UriPartial]::Authority).TrimEnd('/')
}

function Get-PseJsonObjectChild {
    param(
        [Parameter(Mandatory = $true)]
        $Parent,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $Parent.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $child = [pscustomobject]@{}
        Add-Member -InputObject $Parent -MemberType NoteProperty -Name $Name -Value $child
        return $child
    }

    if (-not ($property.Value -is [System.Management.Automation.PSCustomObject])) {
        throw "profile preference '$Name' is not a JSON object"
    }
    return $property.Value
}

function Initialize-PseOktaFastPassProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserDataDir,

        [Parameter(Mandatory = $true)]
        [string]$Origin
    )

    $normalizedOrigin = Resolve-PseHttpsOrigin -Origin $Origin
    $profileDir = Join-Path $UserDataDir 'Default'
    if (-not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir | Out-Null
    }

    $preferencesPath = Join-Path $profileDir 'Preferences'
    $preferences = [pscustomobject]@{}
    if (Test-Path -LiteralPath $preferencesPath) {
        try {
            $preferences = Get-Content -LiteralPath $preferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "could not read Edge profile preferences at '$preferencesPath': $($_.Exception.Message)"
        }
        if (-not ($preferences -is [System.Management.Automation.PSCustomObject])) {
            throw "Edge profile preferences at '$preferencesPath' are not a JSON object"
        }
    }

    $protocolHandler = Get-PseJsonObjectChild -Parent $preferences -Name 'protocol_handler'
    $allowedPairs = Get-PseJsonObjectChild -Parent $protocolHandler -Name 'allowed_origin_protocol_pairs'
    $originProtocols = Get-PseJsonObjectChild -Parent $allowedPairs -Name $normalizedOrigin
    foreach ($scheme in @('com-okta-authenticator', 'okta-verify', 'com.okta.mobile')) {
        Add-Member -InputObject $originProtocols -MemberType NoteProperty -Name $scheme -Value $true -Force
    }

    $temporaryPath = "$preferencesPath.pse-$PID"
    try {
        $json = $preferences | ConvertTo-Json -Depth 100
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($temporaryPath, $json, $encoding)
        Move-Item -LiteralPath $temporaryPath -Destination $preferencesPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }

    return $normalizedOrigin
}

function Set-PseOriginPermissions {
    param(
        [Parameter(Mandatory = $true)]
        $Version,

        [Parameter(Mandatory = $true)]
        [string]$Origin,

        [Parameter(Mandatory = $true)]
        [string[]]$PermissionNames
    )

    if ($null -eq $Version -or -not $Version.webSocketDebuggerUrl) {
        throw 'browser WebSocket URL was not available'
    }

    $conn = $null
    try {
        $conn = Connect-PseCdp -WebSocketUrl $Version.webSocketDebuggerUrl
        [void](Send-PseCdp -Conn $conn -Method 'Browser.grantPermissions' -Params @{
            permissions = @($PermissionNames)
            origin = $Origin
        } -TimeoutSec 5)
    } finally {
        if ($null -ne $conn) {
            Close-PseCdp -Conn $conn
        }
    }
}

function Navigate-PseInitialUrl {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $target = @(Get-PseTargets -Port $Port) | Select-Object -First 1
    if ($null -eq $target -or -not $target.webSocketDebuggerUrl) {
        throw 'no page target was available for the initial URL'
    }

    $conn = $null
    try {
        $conn = Connect-PseCdp -WebSocketUrl $target.webSocketDebuggerUrl
        [void](Send-PseCdp -Conn $conn -Method 'Page.navigate' -Params @{ url = $Url } -TimeoutSec 5)
    } finally {
        if ($null -ne $conn) {
            Close-PseCdp -Conn $conn
        }
    }
}

function Start-PseBrowser {
    param(
        [int]$Port = 9222,

        [switch]$Headless,

        [switch]$NoQuietFlags,

        [string[]]$ExtraArg,

        [string]$Url = 'about:blank',

        [string]$UserDataDir,

        [string]$DownloadDir,

        [string]$OktaFastPassOrigin
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

    $normalizedOktaOrigin = $null
    if (-not [string]::IsNullOrWhiteSpace($OktaFastPassOrigin)) {
        $normalizedOktaOrigin = Initialize-PseOktaFastPassProfile -UserDataDir $UserDataDir -Origin $OktaFastPassOrigin
    }

    if ([string]::IsNullOrWhiteSpace($DownloadDir)) {
        $DownloadDir = Join-Path (Get-PseStateDir) "downloads-$Port"
    }
    $DownloadDir = [System.IO.Path]::GetFullPath($DownloadDir)
    if (-not (Test-Path -LiteralPath $DownloadDir)) {
        New-Item -ItemType Directory -Path $DownloadDir | Out-Null
    }

    $edgePath = Get-PseEdgePath
    $launchUrl = $Url
    if ($null -ne $normalizedOktaOrigin -and $Url -ne 'about:blank') {
        $launchUrl = 'about:blank'
    }
    $arguments = Get-PseEdgeLaunchArguments -Port $Port -UserDataDir $UserDataDir -Headless:$Headless -NoQuietFlags:$NoQuietFlags -ExtraArg $ExtraArg -Url $launchUrl

    $process = Start-Process -FilePath $edgePath -ArgumentList $arguments -PassThru
    $version = $null
    $lastEndpointError = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(15)

    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) {
            throw "Edge exited before opening the CDP endpoint on port $Port (exit code $($process.ExitCode))."
        }
        try {
            $version = Invoke-PseHttpJson -Port $Port -Path '/json/version'
            if ($null -ne $version) {
                break
            }
        } catch {
            $lastEndpointError = $_.Exception.Message
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
        $detail = ''
        if (-not [string]::IsNullOrWhiteSpace($lastEndpointError)) {
            $detail = " Last endpoint error: $lastEndpointError"
        }
        throw "Edge did not start a CDP endpoint on port $Port within 15 seconds.$detail"
    }

    if ($null -ne $normalizedOktaOrigin) {
        try {
            Set-PseOriginPermissions -Version $version -Origin $normalizedOktaOrigin -PermissionNames @('localNetwork', 'localNetworkAccess', 'loopbackNetwork')
            if ($Url -ne 'about:blank') {
                Navigate-PseInitialUrl -Port $Port -Url $Url
            }
        } catch {
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
            throw "could not configure Okta FastPass for '$normalizedOktaOrigin': $($_.Exception.Message)"
        }
    }

    Write-PseState @{
        port = $Port
        pid = $process.Id
        userDataDir = $UserDataDir
        targetId = $null
        attached = $false
        downloadDir = $DownloadDir
        oktaFastPassOrigin = $normalizedOktaOrigin
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
