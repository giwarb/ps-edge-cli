function Write-PseCliError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $host.ui.WriteErrorLine($Message)
}

function ConvertTo-PseHashtable {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $hash = @{}
        foreach ($key in $Value.Keys) {
            $hash[$key] = ConvertTo-PseHashtable -Value $Value[$key]
        }
        return $hash
    }

    if ($Value -is [pscustomobject]) {
        $hash = @{}
        foreach ($prop in $Value.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-PseHashtable -Value $prop.Value
        }
        return $hash
    }

    if ($Value -is [System.Array] -and -not ($Value -is [string])) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            [void]$list.Add((ConvertTo-PseHashtable -Value $item))
        }
        return @($list)
    }

    return $Value
}

function Invoke-PseHttpText {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Method = 'GET'
    )

    $uri = "http://127.0.0.1:$Port$Path"
    $request = [System.Net.WebRequest]::Create($uri)
    $request.Method = $Method
    $request.KeepAlive = $false
    $request.Timeout = 5000

    $response = $null
    $stream = $null
    $reader = $null
    try {
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        } elseif ($null -ne $stream) {
            $stream.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

function Get-PseOptionValue {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        $Default
    )

    $key = $Name.ToLowerInvariant()
    if ($Parsed.Options.ContainsKey($key)) {
        return $Parsed.Options[$key]
    }
    return $Default
}

function Format-PseTabLine {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Index,

        [Parameter(Mandatory = $true)]
        $Target,

        [string]$CurrentTargetId
    )

    $marker = ' '
    if ($Target.id -eq $CurrentTargetId) {
        $marker = '*'
    }
    $title = $Target.title
    if ([string]::IsNullOrEmpty($title)) {
        $title = '(untitled)'
    }
    return "$marker[$Index] $title  $($Target.url)"
}

function Get-PseCurrentStateAndTargets {
    $state = Read-PseState
    if ($null -eq $state -or -not $state.port) {
        return $null
    }

    try {
        [void](Invoke-PseHttpJson -Port ([int]$state.port) -Path '/json/version')
        $targets = @(Get-PseTargets -Port ([int]$state.port))
        return [pscustomobject]@{
            State = $state
            Targets = $targets
        }
    } catch {
        return $null
    }
}

function Wait-PseLoadEventOrWarn {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSec
    )

    try {
        [void](Wait-PseCdpEvent -Conn $Session.Conn -EventName 'Page.loadEventFired' -TimeoutSec $TimeoutSec)
    } catch {
        Write-Output "# warning: load event not fired within $($TimeoutSec)s"
    }
}

function Invoke-PseCmdStart {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    $port = [int](Get-PseOptionValue -Parsed $Parsed -Name 'port' -Default 9222)
    $url = Get-PseOptionValue -Parsed $Parsed -Name 'url' -Default 'about:blank'
    $userDataDir = Get-PseOptionValue -Parsed $Parsed -Name 'userdatadir' -Default $null
    $headless = $false
    if ($Parsed.Options.ContainsKey('headless')) {
        $headless = [bool]$Parsed.Options['headless']
    }

    $version = Start-PseBrowser -Port $port -Headless:$headless -Url $url -UserDataDir $userDataDir
    $state = Read-PseState
    Write-Output "Started Edge $($version.Browser) (pid $($state.pid)) on port $port"
    $targets = @(Get-PseTargets -Port $port)
    for ($i = 0; $i -lt $targets.Count; $i++) {
        Write-Output (Format-PseTabLine -Index ($i + 1) -Target $targets[$i] -CurrentTargetId $state.targetId)
    }
    return 0
}

function Invoke-PseCmdStop {
    $info = Get-PseCurrentStateAndTargets
    if ($null -eq $info) {
        Clear-PseState
        Write-Output 'Not running.'
        return 0
    }

    Stop-PseBrowser
    Write-Output 'Stopped.'
    return 0
}

function Invoke-PseCmdStatus {
    $info = Get-PseCurrentStateAndTargets
    if ($null -eq $info) {
        Write-Output 'Not running.'
        return 0
    }

    $version = Invoke-PseHttpJson -Port ([int]$info.State.port) -Path '/json/version'
    Write-Output "port: $($info.State.port)"
    Write-Output "pid: $($info.State.pid)"
    Write-Output "browser: $($version.Browser)"
    for ($i = 0; $i -lt $info.Targets.Count; $i++) {
        Write-Output (Format-PseTabLine -Index ($i + 1) -Target $info.Targets[$i] -CurrentTargetId $info.State.targetId)
    }
    return 0
}

function Invoke-PseCmdGoto {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    if ($Parsed.Positional.Count -lt 1) {
        throw 'goto requires a URL'
    }

    $url = [string]$Parsed.Positional[0]
    if ($url -notmatch '^[a-z][a-z0-9+.-]*:') {
        $url = "https://$url"
    }
    $timeout = [int](Get-PseOptionValue -Parsed $Parsed -Name 'timeoutsec' -Default 30)
    $session = $null
    try {
        $session = Get-PseSession
        [void](Send-PseCdp -Conn $session.Conn -Method 'Page.navigate' -Params @{ url = $url })
        Wait-PseLoadEventOrWarn -Session $session -TimeoutSec $timeout
        Write-PseLocation -Session $session
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseHistoryNavigation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Direction
    )

    $session = $null
    try {
        $session = Get-PseSession
        $history = Send-PseCdp -Conn $session.Conn -Method 'Page.getNavigationHistory'
        $currentIndex = [int]$history.currentIndex
        if ($Direction -eq 'back') {
            $targetIndex = $currentIndex - 1
            $errorMessage = 'Error: cannot go back'
        } else {
            $targetIndex = $currentIndex + 1
            $errorMessage = 'Error: cannot go forward'
        }

        $entries = @($history.entries | ForEach-Object { $_ })
        if ($targetIndex -lt 0 -or $targetIndex -ge $entries.Count) {
            Write-PseCliError $errorMessage
            return 1
        }

        [void](Send-PseCdp -Conn $session.Conn -Method 'Page.navigateToHistoryEntry' -Params @{ entryId = [int]$entries[$targetIndex].id })
        try {
            [void](Wait-PseCdpEvent -Conn $session.Conn -EventName 'Page.loadEventFired' -TimeoutSec 5)
        } catch {
        }
        Write-PseLocation -Session $session
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdBack {
    Invoke-PseHistoryNavigation -Direction 'back'
}

function Invoke-PseCmdForward {
    Invoke-PseHistoryNavigation -Direction 'forward'
}

function Invoke-PseCmdReload {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    $timeout = [int](Get-PseOptionValue -Parsed $Parsed -Name 'timeoutsec' -Default 30)
    $session = $null
    try {
        $session = Get-PseSession
        [void](Send-PseCdp -Conn $session.Conn -Method 'Page.reload')
        Wait-PseLoadEventOrWarn -Session $session -TimeoutSec $timeout
        Write-PseLocation -Session $session
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    $selector = Get-PseOptionValue -Parsed $Parsed -Name 'selector' -Default $null
    $session = $null
    try {
        $session = Get-PseSession
        $js = Get-PseSnapshotJs -Selector $selector
        $snapshot = Invoke-PseInPage -Session $session -JsExpression $js
        $noMatchPrefix = [string]([char]0) + 'PSE_NO_MATCH' + [string]([char]0)
        if ($null -ne $snapshot -and ([string]$snapshot).StartsWith($noMatchPrefix)) {
            Write-PseCliError "Error: no element matches selector '$selector'"
            return 1
        }

        Write-Output ([string]$snapshot)
        Write-PseLocation -Session $session
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdScreenshot {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    $path = $null
    if ($Parsed.Positional.Count -ge 1) {
        $path = [string]$Parsed.Positional[0]
    } else {
        $path = 'screenshot-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png'
    }

    $absolutePath = [System.IO.Path]::GetFullPath($path)
    $parent = [System.IO.Path]::GetDirectoryName($absolutePath)
    if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "screenshot parent directory does not exist: $parent"
    }

    $fullPage = $false
    if ($Parsed.Options.ContainsKey('fullpage')) {
        $fullPage = [bool]$Parsed.Options['fullpage']
    }

    $session = $null
    try {
        $session = Get-PseSession
        $metrics = Send-PseCdp -Conn $session.Conn -Method 'Page.getLayoutMetrics'
        $params = @{ format = 'png' }
        $width = 0
        $height = 0

        if ($fullPage) {
            $contentSize = $metrics.cssContentSize
            if ($null -eq $contentSize) {
                $contentSize = $metrics.contentSize
            }
            $width = [int][Math]::Ceiling([double]$contentSize.width)
            $height = [int][Math]::Ceiling([double]$contentSize.height)
            if ($width -lt 1) { $width = 1 }
            if ($height -lt 1) { $height = 1 }
            $params.captureBeyondViewport = $true
            $params.clip = @{
                x = 0
                y = 0
                width = $width
                height = $height
                scale = 1
            }
        } else {
            $viewport = $metrics.cssLayoutViewport
            if ($null -eq $viewport) {
                $viewport = $metrics.layoutViewport
            }
            $width = [int][Math]::Ceiling([double]$viewport.clientWidth)
            $height = [int][Math]::Ceiling([double]$viewport.clientHeight)
        }

        $result = Send-PseCdp -Conn $session.Conn -Method 'Page.captureScreenshot' -Params $params -TimeoutSec 30
        $bytes = [Convert]::FromBase64String([string]$result.data)
        [System.IO.File]::WriteAllBytes($absolutePath, $bytes)

        Write-Output "Saved screenshot: $absolutePath ($($width)x$($height))"
        Write-PseLocation -Session $session
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdEval {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    if ($Parsed.Positional.Count -lt 1) {
        throw 'eval requires JavaScript'
    }

    $expression = [string]::Join(' ', @($Parsed.Positional | ForEach-Object { [string]$_ }))
    $session = $null
    try {
        $session = Get-PseSession
        $result = Invoke-PseInPage -Session $session -JsExpression $expression
        if ($null -eq $result) {
            Write-Output 'null'
        } elseif ($result -is [string] -or $result -is [bool] -or $result -is [byte] -or $result -is [int16] -or $result -is [int] -or $result -is [long] -or $result -is [single] -or $result -is [double] -or $result -is [decimal]) {
            Write-Output $result
        } else {
            Write-Output ($result | ConvertTo-Json -Depth 12)
        }
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdCdp {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    if ($Parsed.Positional.Count -lt 1) {
        throw 'cdp requires a method'
    }

    $method = [string]$Parsed.Positional[0]
    $params = @{}
    if ($Parsed.Positional.Count -ge 2) {
        $paramsObject = ([string]$Parsed.Positional[1]) | ConvertFrom-Json
        $params = ConvertTo-PseHashtable -Value $paramsObject
    }

    $session = $null
    try {
        $session = Get-PseSession
        $result = Send-PseCdp -Conn $session.Conn -Method $method -Params $params
        Write-Output ($result | ConvertTo-Json -Depth 12)
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdTabs {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    $info = Get-PseCurrentStateAndTargets
    if ($null -eq $info) {
        throw "browser is not running - run 'start' first"
    }

    $subcommand = 'list'
    if ($Parsed.Positional.Count -ge 1) {
        $subcommand = ([string]$Parsed.Positional[0]).ToLowerInvariant()
    }

    if ($subcommand -eq 'list') {
        for ($i = 0; $i -lt $info.Targets.Count; $i++) {
            Write-Output (Format-PseTabLine -Index ($i + 1) -Target $info.Targets[$i] -CurrentTargetId $info.State.targetId)
        }
        return 0
    }

    if ($subcommand -eq 'new') {
        $url = 'about:blank'
        if ($Parsed.Positional.Count -ge 2) {
            $url = [string]$Parsed.Positional[1]
        }
        $encodedUrl = [Uri]::EscapeDataString($url)
        $beforeIds = @{}
        foreach ($existingTarget in $info.Targets) {
            $beforeIds[$existingTarget.id] = $true
        }
        [void](Invoke-PseHttpText -Port ([int]$info.State.port) -Path "/json/new?$encodedUrl" -Method 'PUT')
        Start-Sleep -Milliseconds 200
        $targets = @(Get-PseTargets -Port ([int]$info.State.port))
        $target = $null
        foreach ($candidate in $targets) {
            if (-not $beforeIds.ContainsKey($candidate.id)) {
                $target = $candidate
                break
            }
        }
        if ($null -eq $target -and $targets.Count -gt 0) {
            $target = $targets[$targets.Count - 1]
        }
        if ($null -eq $target) {
            throw 'new tab was not created'
        }
        $newState = ConvertTo-PseStateHashtable -State $info.State
        $newState.targetId = $target.id
        Write-PseState $newState
        [void](Invoke-PseHttpText -Port ([int]$info.State.port) -Path "/json/activate/$($target.id)")
        $index = 1
        for ($i = 0; $i -lt $targets.Count; $i++) {
            if ($targets[$i].id -eq $target.id) {
                $index = $i + 1
                break
            }
        }
        Write-Output (Format-PseTabLine -Index $index -Target $target -CurrentTargetId $target.id)
        return 0
    }

    if ($subcommand -eq 'select') {
        if ($Parsed.Positional.Count -lt 2) {
            throw 'tabs select requires an index'
        }
        $index = [int]$Parsed.Positional[1]
        if ($index -lt 1 -or $index -gt $info.Targets.Count) {
            throw "tab $index not found"
        }
        $target = $info.Targets[$index - 1]
        $newState = ConvertTo-PseStateHashtable -State $info.State
        $newState.targetId = $target.id
        Write-PseState $newState
        [void](Invoke-PseHttpText -Port ([int]$info.State.port) -Path "/json/activate/$($target.id)")
        Write-Output (Format-PseTabLine -Index $index -Target $target -CurrentTargetId $target.id)
        return 0
    }

    if ($subcommand -eq 'close') {
        $index = $null
        if ($Parsed.Positional.Count -ge 2) {
            $index = [int]$Parsed.Positional[1]
        } else {
            for ($i = 0; $i -lt $info.Targets.Count; $i++) {
                if ($info.Targets[$i].id -eq $info.State.targetId) {
                    $index = $i + 1
                    break
                }
            }
            if ($null -eq $index) {
                $index = 1
            }
        }

        if ($index -lt 1 -or $index -gt $info.Targets.Count) {
            throw "tab $index not found"
        }
        $target = $info.Targets[$index - 1]
        [void](Invoke-PseHttpText -Port ([int]$info.State.port) -Path "/json/close/$($target.id)")
        if ($target.id -eq $info.State.targetId) {
            $newState = ConvertTo-PseStateHashtable -State $info.State
            $newState.targetId = $null
            Write-PseState $newState
        }
        Write-Output "Closed tab $index"
        return 0
    }

    throw "unknown tabs subcommand '$subcommand'"
}
