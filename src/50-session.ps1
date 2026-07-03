function ConvertTo-PseStateHashtable {
    param(
        [Parameter(Mandatory = $true)]
        $State
    )

    $hash = @{
        port = $State.port
        pid = $State.pid
        userDataDir = $State.userDataDir
        targetId = $State.targetId
    }
    if ($null -ne $State.PSObject.Properties['consoleHookTargetIds']) {
        $hash.consoleHookTargetIds = @($State.consoleHookTargetIds | ForEach-Object { $_ })
    }
    return $hash
}

function Get-PseConsoleHookJs {
    @'
(function() {
  if (window.__pseConsoleHookInstalled) {
    return;
  }
  window.__pseConsoleHookInstalled = true;
  window.__pseConsole = window.__pseConsole || [];
  function stringify(value) {
    try {
      if (typeof value === "string") { return value; }
      if (value instanceof Error) { return value.stack || value.message || String(value); }
      var json = JSON.stringify(value);
      if (json !== undefined) { return json; }
      return String(value);
    } catch (e) {
      try { return String(value); } catch (e2) { return "[unprintable]"; }
    }
  }
  function append(level, args) {
    try {
      window.__pseConsole.push({
        level: level,
        text: Array.prototype.map.call(args, stringify).join(" "),
        ts: Date.now()
      });
      while (window.__pseConsole.length > 500) {
        window.__pseConsole.shift();
      }
    } catch (e) {
    }
  }
  ["log", "info", "warn", "error", "debug"].forEach(function(level) {
    var original = console[level];
    console[level] = function() {
      append(level, arguments);
      if (typeof original === "function") {
        return original.apply(console, arguments);
      }
    };
  });
  window.addEventListener("error", function(event) {
    append("error", [event.message || "error"]);
  });
})();
'@
}

function Install-PseConsoleHook {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        $State
    )

    $known = @()
    if ($null -ne $State.PSObject.Properties['consoleHookTargetIds']) {
        $known = @($State.consoleHookTargetIds | ForEach-Object { [string]$_ })
    }

    $script = Get-PseConsoleHookJs
    if ($known -notcontains [string]$Session.TargetId) {
        [void](Send-PseCdp -Conn $Session.Conn -Method 'Page.addScriptToEvaluateOnNewDocument' -Params @{ source = $script })
        $newState = ConvertTo-PseStateHashtable -State $State
        $newKnown = New-Object System.Collections.ArrayList
        foreach ($id in $known) {
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                [void]$newKnown.Add($id)
            }
        }
        [void]$newKnown.Add([string]$Session.TargetId)
        $newState.consoleHookTargetIds = @($newKnown | ForEach-Object { $_ })
        Write-PseState $newState
    }

    [void](Invoke-PseInPage -Session $Session -JsExpression $script)
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
        $selected = $targets | Where-Object { $_.url -and $_.url -ne 'about:blank' } | Select-Object -First 1
        if ($null -eq $selected) {
            $selected = $targets[0]
        }
        $newState = ConvertTo-PseStateHashtable -State $state
        $newState.targetId = $selected.id
        Write-PseState $newState
        $state = [pscustomobject]$newState
    }

    $conn = Connect-PseCdp -WebSocketUrl $selected.webSocketDebuggerUrl
    try {
        [void](Send-PseCdp -Conn $conn -Method 'Page.enable')
        [void](Send-PseCdp -Conn $conn -Method 'Runtime.enable')
    } catch {
        Close-PseCdp -Conn $conn
        throw
    }

    $session = [pscustomobject]@{
        Conn = $conn
        Port = [int]$state.port
        TargetId = $selected.id
        TargetInfo = $selected
    }
    Install-PseConsoleHook -Session $session -State $state
    return $session
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
