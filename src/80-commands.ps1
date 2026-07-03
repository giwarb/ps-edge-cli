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

function Limit-PseSnapshotText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Snapshot,

        [Parameter(Mandatory = $true)]
        [int]$MaxChars
    )

    if ($MaxChars -eq 0 -or $Snapshot.Length -le $MaxChars) {
        return $Snapshot
    }

    $prefix = ''
    if ($MaxChars -gt 0) {
        $take = $MaxChars
        if ($take -gt $Snapshot.Length) {
            $take = $Snapshot.Length
        }
        $candidate = $Snapshot.Substring(0, $take)
        $lastLineBreak = $candidate.LastIndexOf("`n")
        if ($lastLineBreak -ge 0) {
            $prefix = $candidate.Substring(0, $lastLineBreak).TrimEnd("`r")
        }
    }

    $marker = "[snapshot truncated at $MaxChars chars - narrow with -Selector <css> or raise -MaxChars]"
    if ([string]::IsNullOrEmpty($prefix)) {
        return $marker
    }
    return $prefix + "`n" + $marker
}

function Resolve-PseOutputFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Kind
    )

    $absolutePath = [System.IO.Path]::GetFullPath($Path)
    $parent = [System.IO.Path]::GetDirectoryName($absolutePath)
    if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "$Kind parent directory does not exist: $parent"
    }
    return $absolutePath
}

function Invoke-PseCmdStart {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    $port = [int](Get-PseOptionValue -Parsed $Parsed -Name 'port' -Default 9222)
    $url = Get-PseOptionValue -Parsed $Parsed -Name 'url' -Default 'about:blank'
    $userDataDir = Get-PseOptionValue -Parsed $Parsed -Name 'userdatadir' -Default $null
    $downloadDir = Get-PseOptionValue -Parsed $Parsed -Name 'downloaddir' -Default $null
    $extraArg = @()
    if ($Parsed.Options.ContainsKey('extraarg')) {
        $extraArg = @($Parsed.Options['extraarg'] | ForEach-Object { [string]$_ })
    }
    $headless = $false
    if ($Parsed.Options.ContainsKey('headless')) {
        $headless = [bool]$Parsed.Options['headless']
    }
    $noQuietFlags = $false
    if ($Parsed.Options.ContainsKey('noquietflags')) {
        $noQuietFlags = [bool]$Parsed.Options['noquietflags']
    }
    $attach = $false
    if ($Parsed.Options.ContainsKey('attach')) {
        $attach = [bool]$Parsed.Options['attach']
    }

    if ($attach) {
        if ($Parsed.Options.ContainsKey('headless') -or $Parsed.Options.ContainsKey('url') -or $Parsed.Options.ContainsKey('userdatadir') -or $Parsed.Options.ContainsKey('noquietflags') -or $Parsed.Options.ContainsKey('extraarg')) {
            Write-PseCliError 'Error: -Attach does not launch a browser'
            return 1
        }

        try {
            $version = Attach-PseBrowser -Port $port
        } catch {
            Write-PseCliError "Error: $($_.Exception.Message)"
            return 1
        }
        $state = Read-PseState
        Write-Output "Attached to Edge $($version.Browser) on port $port"
        $targets = @(Get-PseTargets -Port $port)
        for ($i = 0; $i -lt $targets.Count; $i++) {
            Write-Output (Format-PseTabLine -Index ($i + 1) -Target $targets[$i] -CurrentTargetId $state.targetId)
        }
        return 0
    }

    $version = Start-PseBrowser -Port $port -Headless:$headless -NoQuietFlags:$noQuietFlags -ExtraArg $extraArg -Url $url -UserDataDir $userDataDir -DownloadDir $downloadDir
    $state = Read-PseState
    if ($null -ne $version.PSObject.Properties['pseDownloadWarning'] -and $version.pseDownloadWarning) {
        Write-Output '# warning: could not set download dir'
    }
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

    $attached = ($null -ne $info.State.PSObject.Properties['attached'] -and $info.State.attached)
    Stop-PseBrowser
    if ($attached) {
        Write-Output 'Detached (browser left running).'
    } else {
        Write-Output 'Stopped.'
    }
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
    if ($null -ne $info.State.PSObject.Properties['attached'] -and $info.State.attached) {
        Write-Output 'attached: true'
    }
    Write-Output "browser: $($version.Browser)"
    for ($i = 0; $i -lt $info.Targets.Count; $i++) {
        Write-Output (Format-PseTabLine -Index ($i + 1) -Target $info.Targets[$i] -CurrentTargetId $info.State.targetId)
    }
    return 0
}

function Invoke-PseCmdDownloads {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    $dir = Get-PseOptionValue -Parsed $Parsed -Name 'dir' -Default $null
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $state = Read-PseState
        if ($null -ne $state -and $null -ne $state.PSObject.Properties['downloadDir']) {
            $dir = $state.downloadDir
        }
    }

    if ([string]::IsNullOrWhiteSpace($dir)) {
        Write-PseCliError 'Error: no download directory configured (start without -Attach, or pass -Dir)'
        return 1
    }

    $absoluteDir = [System.IO.Path]::GetFullPath([string]$dir)
    if (-not (Test-Path -LiteralPath $absoluteDir -PathType Container)) {
        New-Item -ItemType Directory -Path $absoluteDir | Out-Null
    }

    $files = @(Get-ChildItem -LiteralPath $absoluteDir -File | Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) {
        Write-Output 'No downloads yet.'
    } else {
        foreach ($file in $files) {
            $suffix = ''
            if ($file.Name.EndsWith('.crdownload', [System.StringComparison]::OrdinalIgnoreCase) -or $file.Name.EndsWith('.partial', [System.StringComparison]::OrdinalIgnoreCase)) {
                $suffix = '  [in progress]'
            }
            Write-Output ("{0}  {1}  {2}{3}" -f $file.Length, $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), $file.Name, $suffix)
        }
    }

    Write-Output "# dir: $absoluteDir"
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
    $maxChars = [int](Get-PseOptionValue -Parsed $Parsed -Name 'maxchars' -Default 24000)
    if ($maxChars -lt 0) {
        Write-PseCliError 'Error: -MaxChars must be 0 or a positive integer'
        return 1
    }
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

        Write-Output (Limit-PseSnapshotText -Snapshot ([string]$snapshot) -MaxChars $maxChars)
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

    $absolutePath = Resolve-PseOutputFilePath -Path $path -Kind 'screenshot'

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

function Invoke-PseCmdPdf {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    $path = $null
    if ($Parsed.Positional.Count -ge 1) {
        $path = [string]$Parsed.Positional[0]
    } else {
        $path = 'page-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.pdf'
    }

    $absolutePath = Resolve-PseOutputFilePath -Path $path -Kind 'pdf'

    $session = $null
    try {
        $session = Get-PseSession
        try {
            $result = Send-PseCdp -Conn $session.Conn -Method 'Page.printToPDF' -Params @{ printBackground = $true } -TimeoutSec 30
        } catch {
            Write-PseCliError "Error: pdf requires a headless session ($($_.Exception.Message))"
            return 1
        }
        $bytes = [Convert]::FromBase64String([string]$result.data)
        [System.IO.File]::WriteAllBytes($absolutePath, $bytes)

        Write-Output "Saved pdf: $absolutePath"
        Write-PseLocation -Session $session
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdResize {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    if ($Parsed.Positional.Count -lt 2) {
        Write-PseCliError 'Error: resize requires width and height'
        return 1
    }

    $width = 0
    $height = 0
    if (-not [int]::TryParse([string]$Parsed.Positional[0], [ref]$width) -or -not [int]::TryParse([string]$Parsed.Positional[1], [ref]$height) -or $width -lt 1 -or $height -lt 1) {
        Write-PseCliError 'Error: resize width and height must be positive integers'
        return 1
    }

    $session = $null
    try {
        $session = Get-PseSession
        [void](Send-PseCdp -Conn $session.Conn -Method 'Emulation.setDeviceMetricsOverride' -Params @{
            width = $width
            height = $height
            deviceScaleFactor = 0
            mobile = $false
        })
        Write-Output "Viewport set to $($width)x$($height)"
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

function Invoke-PseCmdClick {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    if ($Parsed.Positional.Count -lt 1) {
        throw 'click requires a ref'
    }

    $ref = [string]$Parsed.Positional[0]
    $button = 'left'
    if ($Parsed.Options.ContainsKey('right')) {
        $button = 'right'
    }
    $clickCount = 1
    if ($Parsed.Options.ContainsKey('double')) {
        $clickCount = 2
    }

    $session = $null
    try {
        $session = Get-PseSession
        $rect = Resolve-PseRef -Session $session -Ref $ref
        Send-PseMouseClick -Session $session -X ([double]$rect.x) -Y ([double]$rect.y) -Button $button -ClickCount $clickCount
        Write-Output "Clicked $ref"
        Write-PseLocation -Session $session
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdHover {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    if ($Parsed.Positional.Count -lt 1) {
        throw 'hover requires a ref'
    }

    $ref = [string]$Parsed.Positional[0]
    $session = $null
    try {
        $session = Get-PseSession
        $rect = Resolve-PseRef -Session $session -Ref $ref
        Send-PseMouseMove -Session $session -X ([double]$rect.x) -Y ([double]$rect.y)
        Write-Output "Hovering $ref"
        Write-PseLocation -Session $session
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdType {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    if ($Parsed.Positional.Count -lt 2) {
        throw 'type requires a ref and text'
    }

    $ref = [string]$Parsed.Positional[0]
    $text = [string]::Join(' ', @($Parsed.Positional | Select-Object -Skip 1 | ForEach-Object { [string]$_ }))
    $submit = $Parsed.Options.ContainsKey('submit')

    $session = $null
    try {
        $session = Get-PseSession
        [void](Resolve-PseRef -Session $session -Ref $ref)
        Focus-PseRef -Session $session -Ref $ref
        [void](Send-PseCdp -Conn $session.Conn -Method 'Input.insertText' -Params @{ text = $text })
        if ($submit) {
            Send-PseKey -Session $session -KeySpec 'Enter'
        }
        Write-Output "Typed into $ref"
        Write-PseLocation -Session $session
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdFill {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    if ($Parsed.Positional.Count -lt 2) {
        throw 'fill requires a ref and value'
    }

    $ref = [string]$Parsed.Positional[0]
    $value = [string]::Join(' ', @($Parsed.Positional | Select-Object -Skip 1 | ForEach-Object { [string]$_ }))
    $session = $null
    try {
        $session = Get-PseSession
        [void](Resolve-PseRef -Session $session -Ref $ref)
        Set-PseRefValue -Session $session -Ref $ref -Value $value
        Write-Output "Filled $ref"
        Write-PseLocation -Session $session
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdPress {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    if ($Parsed.Positional.Count -lt 1) {
        throw 'press requires a key'
    }

    $key = [string]$Parsed.Positional[0]
    $session = $null
    try {
        $session = Get-PseSession
        Send-PseKey -Session $session -KeySpec $key
        Write-Output "Pressed $key"
        Write-PseLocation -Session $session
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdSelect {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    if ($Parsed.Positional.Count -lt 2) {
        throw 'select requires a ref and at least one value'
    }

    $ref = [string]$Parsed.Positional[0]
    $values = @($Parsed.Positional | Select-Object -Skip 1 | ForEach-Object { [string]$_ })
    $session = $null
    try {
        $session = Get-PseSession
        [void](Resolve-PseRef -Session $session -Ref $ref)
        $matched = @(Select-PseRefOptions -Session $session -Ref $ref -Values $values)
        Write-Output "Selected $([string]::Join(', ', $matched)) in $ref"
        Write-PseLocation -Session $session
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdUpload {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    if ($Parsed.Positional.Count -lt 2) {
        throw 'upload requires a ref and at least one path'
    }

    $ref = [string]$Parsed.Positional[0]
    $files = New-Object System.Collections.ArrayList
    foreach ($path in @($Parsed.Positional | Select-Object -Skip 1 | ForEach-Object { [string]$_ })) {
        if (-not (Test-Path -LiteralPath $path)) {
            Write-PseCliError "Error: file not found: $path"
            return 1
        }
        [void]$files.Add([System.IO.Path]::GetFullPath($path))
    }

    $session = $null
    try {
        $session = Get-PseSession
        if (-not (Test-PseRefFileInput -Session $session -Ref $ref)) {
            Write-PseCliError "Error: $ref is not a file input"
            return 1
        }
        Set-PseRefFileInputFiles -Session $session -Ref $ref -Files @($files | ForEach-Object { [string]$_ })
        Write-Output "Uploaded $($files.Count) file(s) to $ref"
        Write-PseLocation -Session $session
        return 0
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdWait {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    $timeValue = Get-PseOptionValue -Parsed $Parsed -Name 'time' -Default $null
    $text = Get-PseOptionValue -Parsed $Parsed -Name 'text' -Default $null
    $gone = Get-PseOptionValue -Parsed $Parsed -Name 'gone' -Default $null
    $selector = Get-PseOptionValue -Parsed $Parsed -Name 'selector' -Default $null
    $selectorGone = Get-PseOptionValue -Parsed $Parsed -Name 'selectorgone' -Default $null
    $timeoutSec = [int](Get-PseOptionValue -Parsed $Parsed -Name 'timeoutsec' -Default 30)

    if ($null -ne $timeValue) {
        $milliseconds = [int]([double]$timeValue * 1000)
        if ($milliseconds -gt 0) {
            Start-Sleep -Milliseconds $milliseconds
        }
    }

    $session = $null
    try {
        $session = Get-PseSession
        $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSec)
        $lastFailed = $null
        while ([DateTime]::UtcNow -le $deadline) {
            $conditionParams = @{ Session = $session }
            if ($null -ne $text) {
                $conditionParams.Text = $text
            }
            if ($null -ne $gone) {
                $conditionParams.Gone = $gone
            }
            if ($null -ne $selector) {
                $conditionParams.Selector = $selector
            }
            if ($null -ne $selectorGone) {
                $conditionParams.SelectorGone = $selectorGone
            }
            $waitResult = Test-PseWaitCondition @conditionParams
            if ($null -ne $waitResult.InvalidSelector) {
                Write-PseCliError "Error: invalid selector '$($waitResult.InvalidSelector)'"
                return 1
            }
            if ($waitResult.Ok) {
                Write-Output 'Wait condition met.'
                Write-PseLocation -Session $session
                return 0
            }
            $lastFailed = $waitResult.Failed
            Start-Sleep -Milliseconds 500
        }

        $target = 'load state complete'
        if (-not [string]::IsNullOrWhiteSpace([string]$lastFailed)) {
            $target = [string]$lastFailed
        }
        Write-PseCliError "Error: timeout waiting for $target"
        return 1
    } finally {
        Close-PseSession -Session $session
    }
}

function Invoke-PseCmdDialog {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    $accept = $Parsed.Options.ContainsKey('accept')
    $dismiss = $Parsed.Options.ContainsKey('dismiss')
    if ($accept -and $dismiss) {
        Write-PseCliError 'Error: -Accept and -Dismiss cannot be used together'
        return 1
    }

    if ($accept -or $dismiss) {
        $state = Read-PseState
        if ($null -eq $state -or -not $state.port) {
            Write-PseCliError "Error: browser is not running - run 'start' first"
            return 1
        }

        $newState = ConvertTo-PseStateHashtable -State $state
        if ($accept) {
            $newState.dialogMode = 'accept'
            if ($Parsed.Options.ContainsKey('text')) {
                $newState.dialogText = [string]$Parsed.Options['text']
            } else {
                $newState.dialogText = $null
            }
        } else {
            $newState.dialogMode = 'dismiss'
            $newState.dialogText = $null
        }
        Write-PseState $newState

        $policy = Get-PseDialogPolicy -State ([pscustomobject]$newState)
        $session = $null
        try {
            $session = Get-PseSession
            Set-PseDialogPolicyInPage -Session $session -Policy $policy
            Write-Output ("Dialog policy: " + ((Format-PseDialogPolicy -Policy $policy) -replace '^policy: ', ''))
            return 0
        } finally {
            Close-PseSession -Session $session
        }
    }

    $stateForPolicy = Read-PseState
    $policyForDisplay = Get-PseDialogPolicy -State $stateForPolicy
    $sessionForRead = $null
    try {
        $sessionForRead = Get-PseSession
        $js = '(function(){ return JSON.stringify(window.__pseDialogs || []); })()'
        $json = Invoke-PseInPage -Session $sessionForRead -JsExpression $js
        $entries = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$json)) {
            $entries = @($json | ConvertFrom-Json | ForEach-Object { $_ })
        }
        Write-Output (Format-PseDialogPolicy -Policy $policyForDisplay)
        if ($entries.Count -eq 0) {
            Write-Output 'No dialogs captured.'
        } else {
            foreach ($entry in $entries) {
                Write-Output "[$($entry.type)] $($entry.message) -> $($entry.response)"
            }
        }
        Write-PseLocation -Session $sessionForRead
        return 0
    } finally {
        Close-PseSession -Session $sessionForRead
    }
}

function Invoke-PseCmdConsole {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parsed
    )

    $session = $null
    try {
        $session = Get-PseSession
        $js = '(function(){ return JSON.stringify(window.__pseConsole || []); })()'
        $json = Invoke-PseInPage -Session $session -JsExpression $js
        $entries = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$json)) {
            $entries = @($json | ConvertFrom-Json | ForEach-Object { $_ })
        }
        if ($entries.Count -eq 0) {
            Write-Output 'No console messages captured.'
        } else {
            foreach ($entry in $entries) {
                Write-Output "[$($entry.level)] $($entry.text)"
            }
        }
        Write-PseLocation -Session $session
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
