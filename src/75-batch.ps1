function Get-PseRequiredStepValue {
    param(
        [Parameter(Mandatory = $true)]
        $Step,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $Step.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "missing '$Name'"
    }
    return $property.Value
}

function Get-PseOptionalStepValue {
    param(
        [Parameter(Mandatory = $true)]
        $Step,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        $Default
    )

    $property = $Step.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
}

function New-PseBatchStepValue {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        $Value
    )

    return [pscustomobject]@{ Value = $Value }
}

function Wait-PseCondition {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [AllowNull()]
        [string]$Text,

        [AllowNull()]
        [string]$Gone,

        [AllowNull()]
        [string]$Selector,

        [AllowNull()]
        [string]$SelectorGone,

        [int]$TimeoutSec = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $lastFailed = $null
    while ([DateTime]::UtcNow -le $deadline) {
        $conditionParams = @{ Session = $Session }
        if ($PSBoundParameters.ContainsKey('Text')) { $conditionParams.Text = $Text }
        if ($PSBoundParameters.ContainsKey('Gone')) { $conditionParams.Gone = $Gone }
        if ($PSBoundParameters.ContainsKey('Selector')) { $conditionParams.Selector = $Selector }
        if ($PSBoundParameters.ContainsKey('SelectorGone')) { $conditionParams.SelectorGone = $SelectorGone }
        $waitResult = Test-PseWaitCondition @conditionParams
        if ($null -ne $waitResult.InvalidSelector) {
            throw "invalid selector '$($waitResult.InvalidSelector)'"
        }
        if ($waitResult.Ok) {
            return 'condition met'
        }
        $lastFailed = $waitResult.Failed
        Start-Sleep -Milliseconds 500
    }

    $target = 'load state complete'
    if (-not [string]::IsNullOrWhiteSpace([string]$lastFailed)) {
        $target = [string]$lastFailed
    }
    throw "timeout waiting for $target"
}

function Invoke-PseBatchStep {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        $Step
    )

    $action = ([string](Get-PseRequiredStepValue -Step $Step -Name 'action')).ToLowerInvariant()
    if ($action -eq 'eval') {
        $expression = [string](Get-PseRequiredStepValue -Step $Step -Name 'expression')
        $response = Send-PseCdp -Conn $Session.Conn -Method 'Runtime.evaluate' -Params @{
            expression = $expression
            returnByValue = $true
            awaitPromise = $true
            userGesture = $true
        }
        if ($null -ne $response.PSObject.Properties['exceptionDetails']) {
            $details = $response.exceptionDetails
            if ($null -ne $details.exception -and $details.exception.description) {
                throw $details.exception.description
            }
            if ($details.text) { throw $details.text }
            throw 'JavaScript evaluation failed'
        }
        $value = $null
        if ($null -ne $response.result -and $null -ne $response.result.PSObject.Properties['value']) {
            $value = $response.result.value
        }
        return (New-PseBatchStepValue -Value $value)
    }
    if ($action -eq 'snapshot') {
        $selector = Get-PseOptionalStepValue -Step $Step -Name 'selector' -Default $null
        $maxChars = [int](Get-PseOptionalStepValue -Step $Step -Name 'maxChars' -Default 24000)
        return (New-PseBatchStepValue -Value (Get-PseSnapshot -Session $Session -Selector $selector -MaxChars $maxChars))
    }
    if ($action -eq 'inspect') {
        $selector = Get-PseOptionalStepValue -Step $Step -Name 'selector' -Default $null
        $maxItems = [int](Get-PseOptionalStepValue -Step $Step -Name 'maxItems' -Default 200)
        $items = [object[]]@(Get-PseInspection -Session $Session -Selector $selector -MaxItems $maxItems)
        return (New-PseBatchStepValue -Value $items)
    }
    if ($action -eq 'click') {
        $ref = [string](Get-PseRequiredStepValue -Step $Step -Name 'ref')
        $button = 'left'
        if ([bool](Get-PseOptionalStepValue -Step $Step -Name 'right' -Default $false)) { $button = 'right' }
        $clickCount = 1
        if ([bool](Get-PseOptionalStepValue -Step $Step -Name 'double' -Default $false)) { $clickCount = 2 }
        $rect = Resolve-PseRef -Session $Session -Ref $ref
        Send-PseMouseClick -Session $Session -X ([double]$rect.x) -Y ([double]$rect.y) -Button $button -ClickCount $clickCount
        return (New-PseBatchStepValue -Value "clicked $ref")
    }
    if ($action -eq 'fill') {
        $ref = [string](Get-PseRequiredStepValue -Step $Step -Name 'ref')
        $value = [string](Get-PseRequiredStepValue -Step $Step -Name 'value')
        Set-PseRefValue -Session $Session -Ref $ref -Value $value
        return (New-PseBatchStepValue -Value "filled $ref")
    }
    if ($action -eq 'type') {
        $ref = [string](Get-PseRequiredStepValue -Step $Step -Name 'ref')
        $text = [string](Get-PseRequiredStepValue -Step $Step -Name 'text')
        [void](Resolve-PseRef -Session $Session -Ref $ref)
        Focus-PseRef -Session $Session -Ref $ref
        [void](Send-PseCdp -Conn $Session.Conn -Method 'Input.insertText' -Params @{ text = $text })
        if ([bool](Get-PseOptionalStepValue -Step $Step -Name 'submit' -Default $false)) {
            Send-PseKey -Session $Session -KeySpec 'Enter'
        }
        return (New-PseBatchStepValue -Value "typed into $ref")
    }
    if ($action -eq 'press') {
        $key = [string](Get-PseRequiredStepValue -Step $Step -Name 'key')
        Send-PseKey -Session $Session -KeySpec $key
        return (New-PseBatchStepValue -Value "pressed $key")
    }
    if ($action -eq 'select') {
        $ref = [string](Get-PseRequiredStepValue -Step $Step -Name 'ref')
        $rawValues = Get-PseRequiredStepValue -Step $Step -Name 'values'
        $values = @($rawValues | ForEach-Object { [string]$_ })
        if ($values.Count -eq 0) { throw "missing 'values'" }
        $matched = [object[]]@(Select-PseRefOptions -Session $Session -Ref $ref -Values $values)
        return (New-PseBatchStepValue -Value $matched)
    }
    if ($action -eq 'wait') {
        $params = @{
            Session = $Session
            TimeoutSec = [int](Get-PseOptionalStepValue -Step $Step -Name 'timeoutSec' -Default 30)
        }
        foreach ($name in @('text', 'gone', 'selector', 'selectorGone')) {
            $property = $Step.PSObject.Properties[$name]
            if ($null -ne $property) { $params[$name] = [string]$property.Value }
        }
        return (New-PseBatchStepValue -Value (Wait-PseCondition @params))
    }
    if ($action -eq 'goto') {
        $url = [string](Get-PseRequiredStepValue -Step $Step -Name 'url')
        if ($url -notmatch '^[a-z][a-z0-9+.-]*:') { $url = "https://$url" }
        $timeoutSec = [int](Get-PseOptionalStepValue -Step $Step -Name 'timeoutSec' -Default 30)
        [void](Send-PseCdp -Conn $Session.Conn -Method 'Page.navigate' -Params @{ url = $url })
        $warnings = @(Wait-PseLoadEventOrWarn -Session $Session -TimeoutSec $timeoutSec)
        return (New-PseBatchStepValue -Value ([pscustomobject]@{ url = $url; warnings = $warnings }))
    }
    if ($action -eq 'reload') {
        $timeoutSec = [int](Get-PseOptionalStepValue -Step $Step -Name 'timeoutSec' -Default 30)
        [void](Send-PseCdp -Conn $Session.Conn -Method 'Page.reload')
        $warnings = @(Wait-PseLoadEventOrWarn -Session $Session -TimeoutSec $timeoutSec)
        return (New-PseBatchStepValue -Value ([pscustomobject]@{ reloaded = $true; warnings = $warnings }))
    }
    throw "unknown action '$action'"
}

function Invoke-PseBatch {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Steps
    )

    $session = $null
    try {
        $session = Get-PseSession
        $results = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $Steps.Count; $i++) {
            $step = $Steps[$i]
            $action = ''
            if ($null -ne $step -and $null -ne $step.PSObject.Properties['action']) {
                $action = [string]$step.action
            }
            try {
                $stepValue = Invoke-PseBatchStep -Session $session -Step $step
                [void]$results.Add([pscustomobject]@{
                    index = $i
                    action = $action
                    result = $stepValue.Value
                })
            } catch {
                throw "batch step $i ($action): $($_.Exception.Message)"
            }
        }
        $location = Get-PseLocation -Session $session
        return [pscustomobject]@{
            ok = $true
            steps = @($results | ForEach-Object { $_ })
            url = $location.url
            title = $location.title
        }
    } finally {
        Close-PseSession -Session $session
    }
}
