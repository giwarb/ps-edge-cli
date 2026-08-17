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
    if ($null -ne $State.PSObject.Properties['attached']) {
        $hash.attached = $State.attached
    }
    if ($null -ne $State.PSObject.Properties['downloadDir']) {
        $hash.downloadDir = $State.downloadDir
    }
    if ($null -ne $State.PSObject.Properties['dialogMode']) {
        $hash.dialogMode = $State.dialogMode
    }
    if ($null -ne $State.PSObject.Properties['dialogText']) {
        $hash.dialogText = $State.dialogText
    }
    if ($null -ne $State.PSObject.Properties['consoleHookTargetIds']) {
        $hash.consoleHookTargetIds = @($State.consoleHookTargetIds | ForEach-Object { $_ })
    }
    return $hash
}

function Get-PseDialogPolicy {
    param(
        [AllowNull()]
        $State
    )

    $mode = 'dismiss'
    $text = $null
    if ($null -ne $State) {
        if ($null -ne $State.PSObject.Properties['dialogMode'] -and $State.dialogMode -eq 'accept') {
            $mode = 'accept'
        }
        if ($null -ne $State.PSObject.Properties['dialogText']) {
            $text = $State.dialogText
        }
    }

    return @{
        mode = $mode
        text = $text
    }
}

function Format-PseDialogPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Policy
    )

    $line = "policy: $($Policy.mode)"
    if ($null -ne $Policy.text) {
        $line += " text: $($Policy.text)"
    }
    return $line
}

function Set-PseDialogPolicyInPage {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [hashtable]$Policy
    )

    $policyJson = ConvertTo-PseJson $Policy
    [void](Invoke-PseInPage -Session $Session -JsExpression "window.__pseDialogPolicy = $policyJson; true;")
}

function Get-PsePageHookJs {
    @'
(function() {
  function pseRoot(win) {
    var root = win;
    while (true) {
      try {
        var parentWindow = root.parent;
        if (!parentWindow || parentWindow === root) { break; }
        var parentDocument = parentWindow.document;
        root = parentWindow;
      } catch (e) {
        break;
      }
    }
    return root;
  }
  function installPseHooks(win) {
    if (!win.__pseConsoleHookInstalled) {
      win.__pseConsoleHookInstalled = true;
      win.__pseConsole = win.__pseConsole || [];
      function stringify(value) {
        try {
          if (typeof value === "string") { return value; }
          if (value instanceof win.Error) { return value.stack || value.message || String(value); }
          var json = JSON.stringify(value);
          if (json !== undefined) { return json; }
          return String(value);
        } catch (e) {
          try { return String(value); } catch (e2) { return "[unprintable]"; }
        }
      }
      function append(level, args) {
        try {
          win.__pseConsole.push({
            level: level,
            text: Array.prototype.map.call(args, stringify).join(" "),
            ts: Date.now()
          });
          while (win.__pseConsole.length > 500) {
            win.__pseConsole.shift();
          }
        } catch (e) {
        }
      }
      ["log", "info", "warn", "error", "debug"].forEach(function(level) {
        var original = win.console[level];
        win.console[level] = function() {
          append(level, arguments);
          if (typeof original === "function") {
            return original.apply(win.console, arguments);
          }
        };
      });
      win.addEventListener("error", function(event) {
        append("error", [event.message || "error"]);
      });
    }
    if (win.__pseDialogHookInstalled) {
      return;
    }
    win.__pseDialogHookInstalled = true;
    try {
      var initialRoot = pseRoot(win);
      initialRoot.__pseDialogs = initialRoot.__pseDialogs || [];
    } catch (e) {
      win.__pseDialogs = win.__pseDialogs || [];
    }
    function normalizePolicy(policy) {
      var mode = policy.mode === "accept" ? "accept" : "dismiss";
      var text = Object.prototype.hasOwnProperty.call(policy, "text") ? policy.text : null;
      if (text !== null && text !== undefined) {
        text = String(text);
      } else {
        text = null;
      }
      return { mode: mode, text: text };
    }
    function getPolicy() {
      try {
        return normalizePolicy(pseRoot(win).__pseDialogPolicy || {});
      } catch (e) {
        try {
          return normalizePolicy(win.__pseDialogPolicy || {});
        } catch (e2) {
          return { mode: "dismiss", text: null };
        }
      }
    }
    function responseString(value) {
      if (value === null) { return "null"; }
      if (value === undefined) { return ""; }
      if (value === true) { return "true"; }
      if (value === false) { return "false"; }
      return String(value);
    }
    function appendDialog(target, type, message, response) {
      target.__pseDialogs = target.__pseDialogs || [];
      target.__pseDialogs.push({
        type: type,
        message: String(message),
        response: responseString(response),
        ts: Date.now()
      });
      while (target.__pseDialogs.length > 100) {
        target.__pseDialogs.shift();
      }
    }
    function recordDialog(type, message, response) {
      try {
        appendDialog(pseRoot(win), type, message, response);
      } catch (e) {
        try {
          appendDialog(win, type, message, response);
        } catch (e2) {
        }
      }
    }
    win.alert = function(message) {
      recordDialog("alert", message, undefined);
      return undefined;
    };
    win.confirm = function(message) {
      var response = getPolicy().mode === "accept";
      recordDialog("confirm", message, response);
      return response;
    };
    win.prompt = function(message, defaultValue) {
      var policy = getPolicy();
      var response = null;
      if (policy.mode === "accept") {
        response = policy.text !== null ? policy.text : (defaultValue !== undefined ? defaultValue : "");
      }
      recordDialog("prompt", message, response);
      return response;
    };
  }
  function walk(win) {
    installPseHooks(win);
    for (var i = 0; i < win.frames.length; i++) {
      try { walk(win.frames[i]); } catch (e) { }
    }
  }
  walk(window);
})();
'@
}

function Get-PseConsoleHookJs {
    Get-PsePageHookJs
}

function Install-PseConsoleHook {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        $State
    )

    $policyJson = ConvertTo-PseJson (Get-PseDialogPolicy -State $State)
    $script = (Get-PsePageHookJs) + "`nwindow.__pseDialogPolicy = $policyJson;"

    # CDP new-document registrations belong to the current connection.
    [void](Send-PseCdp -Conn $Session.Conn -Method 'Page.addScriptToEvaluateOnNewDocument' -Params @{ source = $script })
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
    $conn.DialogPolicy = Get-PseDialogPolicy -State $state
    try {
        [void](Send-PseCdp -Conn $conn -Method 'Page.enable')
    } catch {
        $message = $_.Exception.Message
        Close-PseCdp -Conn $conn
        if ($message.IndexOf('Timed out', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "$message A native dialog may be blocking the page - try 'dialog -Rescue'."
        }
        throw
    }
    try {
        [void](Send-PseCdp -Conn $conn -Method 'Target.setAutoAttach' -Params @{
            autoAttach = $true
            waitForDebuggerOnStart = $false
            flatten = $true
        })
    } catch {
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

function Get-PseLocation {
    param(
        [Parameter(Mandatory = $true)]
        $Session
    )

    $json = Invoke-PseInPage -Session $Session -JsExpression '(function(){ return JSON.stringify({ url: document.URL, title: document.title }); })()'
    return ($json | ConvertFrom-Json)
}

function Write-PseHandledDialogs {
    param(
        [Parameter(Mandatory = $true)]
        $Conn
    )

    if ($Conn.HandledDialogs.Count -gt 0) {
        foreach ($dialog in $Conn.HandledDialogs) {
            if (-not $dialog.accept) {
                Write-Output "# dialog: [$($dialog.type)] $($dialog.message) -> dismissed"
            } elseif ($null -ne $dialog.promptText) {
                Write-Output "# dialog: [$($dialog.type)] $($dialog.message) -> accepted text: $($dialog.promptText)"
            } else {
                Write-Output "# dialog: [$($dialog.type)] $($dialog.message) -> accepted"
            }
        }
        [void]$Conn.HandledDialogs.Clear()
    }
}

function Write-PseLocation {
    param(
        [Parameter(Mandatory = $true)]
        $Session
    )

    $location = Get-PseLocation -Session $Session
    Write-Output "# url: $($location.url)"
    Write-Output "# title: $($location.title)"
    Write-PseHandledDialogs -Conn $Session.Conn
}
