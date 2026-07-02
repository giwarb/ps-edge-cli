function ConvertTo-PseStateHashtable {
    param(
        [Parameter(Mandatory = $true)]
        $State
    )

    @{
        port = $State.port
        pid = $State.pid
        userDataDir = $State.userDataDir
        targetId = $State.targetId
    }
}

function Get-PseSession {
    param(
        [string]$TargetId
    )

    $state = Read-PseState
    if ($null -eq $state -or -not $state.port) {
        throw "browser is not running - run 'start' first"
    }

    try {
        [void](Invoke-PseHttpJson -Port ([int]$state.port) -Path '/json/version')
        $targets = @(Get-PseTargets -Port ([int]$state.port))
    } catch {
        throw "browser is not running - run 'start' first"
    }

    if ($targets.Count -lt 1) {
        throw 'no page targets found'
    }

    $selected = $null
    if (-not [string]::IsNullOrWhiteSpace($TargetId)) {
        $selected = $targets | Where-Object { $_.id -eq $TargetId } | Select-Object -First 1
        if ($null -eq $selected) {
            throw "target '$TargetId' not found"
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($state.targetId)) {
        $selected = $targets | Where-Object { $_.id -eq $state.targetId } | Select-Object -First 1
    }

    if ($null -eq $selected) {
        $selected = $targets[0]
        $newState = ConvertTo-PseStateHashtable -State $state
        $newState.targetId = $selected.id
        Write-PseState $newState
    }

    $conn = Connect-PseCdp -WebSocketUrl $selected.webSocketDebuggerUrl
    try {
        [void](Send-PseCdp -Conn $conn -Method 'Page.enable')
        [void](Send-PseCdp -Conn $conn -Method 'Runtime.enable')
    } catch {
        Close-PseCdp -Conn $conn
        throw
    }

    [pscustomobject]@{
        Conn = $conn
        Port = [int]$state.port
        TargetId = $selected.id
        TargetInfo = $selected
    }
}

function Close-PseSession {
    param(
        $Session
    )

    try {
        if ($null -ne $Session -and $null -ne $Session.Conn) {
            Close-PseCdp -Conn $Session.Conn
        }
    } catch {
    }
}

function Invoke-PseInPage {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [string]$JsExpression,

        [int]$TimeoutSec = 30
    )

    $response = Send-PseCdp -Conn $Session.Conn -Method 'Runtime.evaluate' -Params @{
        expression = $JsExpression
        returnByValue = $true
        awaitPromise = $true
        userGesture = $true
    } -TimeoutSec $TimeoutSec

    if ($null -ne $response.PSObject.Properties['exceptionDetails']) {
        $details = $response.exceptionDetails
        $message = $null
        if ($null -ne $details.exception -and $details.exception.description) {
            $message = $details.exception.description
        } elseif ($details.text) {
            $message = $details.text
        } else {
            $message = 'JavaScript evaluation failed'
        }
        throw $message
    }

    if ($null -eq $response.result -or $null -eq $response.result.PSObject.Properties['value']) {
        return $null
    }
    return $response.result.value
}

function Write-PseLocation {
    param(
        [Parameter(Mandatory = $true)]
        $Session
    )

    $url = Invoke-PseInPage -Session $Session -JsExpression 'document.URL'
    $title = Invoke-PseInPage -Session $Session -JsExpression 'document.title'
    Write-Output "# url: $url"
    Write-Output "# title: $title"
}
