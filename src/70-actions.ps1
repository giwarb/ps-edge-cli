function Resolve-PseRef {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [string]$Ref
    )

    $refJson = ConvertTo-PseJson $Ref
    $js = @"
(function() {
  var ref = $refJson;
  if (!window.__pseRefs || !window.__pseRefs[ref]) {
    throw new Error("ref '" + ref + "' not found - run 'snapshot' first (refs are reset by navigation)");
  }
  var el = window.__pseRefs[ref];
  el.scrollIntoView({ block: "center", inline: "center" });
  var rect = el.getBoundingClientRect();
  return JSON.stringify({
    x: rect.left + (rect.width / 2),
    y: rect.top + (rect.height / 2),
    w: rect.width,
    h: rect.height
  });
})()
"@
    $json = Invoke-PseInPage -Session $Session -JsExpression $js
    return ($json | ConvertFrom-Json)
}

function Send-PseMouseClick {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [double]$X,

        [Parameter(Mandatory = $true)]
        [double]$Y,

        [ValidateSet('left', 'right', 'middle')]
        [string]$Button = 'left',

        [int]$ClickCount = 1
    )

    [void](Send-PseCdp -Conn $Session.Conn -Method 'Input.dispatchMouseEvent' -Params @{
        type = 'mouseMoved'
        x = $X
        y = $Y
        button = 'none'
    })
    [void](Send-PseCdp -Conn $Session.Conn -Method 'Input.dispatchMouseEvent' -Params @{
        type = 'mousePressed'
        x = $X
        y = $Y
        button = $Button
        clickCount = $ClickCount
    })
    [void](Send-PseCdp -Conn $Session.Conn -Method 'Input.dispatchMouseEvent' -Params @{
        type = 'mouseReleased'
        x = $X
        y = $Y
        button = $Button
        clickCount = $ClickCount
    })
}

function Send-PseMouseMove {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [double]$X,

        [Parameter(Mandatory = $true)]
        [double]$Y
    )

    [void](Send-PseCdp -Conn $Session.Conn -Method 'Input.dispatchMouseEvent' -Params @{
        type = 'mouseMoved'
        x = $X
        y = $Y
        button = 'none'
    })
}

function Get-PseKeyInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $named = @{
        enter = @{ windowsVirtualKeyCode = 13; key = 'Enter'; code = 'Enter' }
        tab = @{ windowsVirtualKeyCode = 9; key = 'Tab'; code = 'Tab' }
        escape = @{ windowsVirtualKeyCode = 27; key = 'Escape'; code = 'Escape' }
        esc = @{ windowsVirtualKeyCode = 27; key = 'Escape'; code = 'Escape' }
        backspace = @{ windowsVirtualKeyCode = 8; key = 'Backspace'; code = 'Backspace' }
        delete = @{ windowsVirtualKeyCode = 46; key = 'Delete'; code = 'Delete' }
        del = @{ windowsVirtualKeyCode = 46; key = 'Delete'; code = 'Delete' }
        space = @{ windowsVirtualKeyCode = 32; key = ' '; code = 'Space'; text = ' ' }
        arrowup = @{ windowsVirtualKeyCode = 38; key = 'ArrowUp'; code = 'ArrowUp' }
        arrowdown = @{ windowsVirtualKeyCode = 40; key = 'ArrowDown'; code = 'ArrowDown' }
        arrowleft = @{ windowsVirtualKeyCode = 37; key = 'ArrowLeft'; code = 'ArrowLeft' }
        arrowright = @{ windowsVirtualKeyCode = 39; key = 'ArrowRight'; code = 'ArrowRight' }
        home = @{ windowsVirtualKeyCode = 36; key = 'Home'; code = 'Home' }
        end = @{ windowsVirtualKeyCode = 35; key = 'End'; code = 'End' }
        pageup = @{ windowsVirtualKeyCode = 33; key = 'PageUp'; code = 'PageUp' }
        pagedown = @{ windowsVirtualKeyCode = 34; key = 'PageDown'; code = 'PageDown' }
    }

    for ($i = 1; $i -le 12; $i++) {
        $name = "f$i"
        $named[$name] = @{ windowsVirtualKeyCode = 111 + $i; key = "F$i"; code = "F$i" }
    }

    $lower = $Key.ToLowerInvariant()
    if ($named.ContainsKey($lower)) {
        return $named[$lower]
    }

    if ($Key.Length -eq 1) {
        $ch = $Key[0]
        if ($Key -match '^[a-zA-Z]$') {
            $upper = [string]$Key.ToUpperInvariant()
            return @{
                windowsVirtualKeyCode = [int][char]$upper
                key = $Key
                code = "Key$upper"
                text = $Key
            }
        }
        if ($Key -match '^[0-9]$') {
            return @{
                windowsVirtualKeyCode = [int][char]$ch
                key = $Key
                code = "Digit$Key"
                text = $Key
            }
        }
        return @{
            windowsVirtualKeyCode = [int][char]$ch
            key = $Key
            code = ''
            text = $Key
        }
    }

    throw "unsupported key '$Key'"
}

function Send-PseKey {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [string]$KeySpec
    )

    $parts = @($KeySpec -split '\+' | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 1) {
        throw 'key is empty'
    }

    $modifiers = 0
    $keyPart = $parts[$parts.Count - 1]
    for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        $part = $parts[$i].ToLowerInvariant()
        if ($part -eq 'alt') {
            $modifiers = $modifiers -bor 1
        } elseif ($part -eq 'control' -or $part -eq 'ctrl') {
            $modifiers = $modifiers -bor 2
        } elseif ($part -eq 'meta' -or $part -eq 'cmd' -or $part -eq 'command') {
            $modifiers = $modifiers -bor 4
        } elseif ($part -eq 'shift') {
            $modifiers = $modifiers -bor 8
        } else {
            throw "unsupported modifier '$($parts[$i])'"
        }
    }

    $info = Get-PseKeyInfo -Key $keyPart
    $isPrintable = $info.ContainsKey('text') -and $modifiers -eq 0
    $downType = 'keyDown'

    $down = @{
        type = $downType
        windowsVirtualKeyCode = [int]$info.windowsVirtualKeyCode
        nativeVirtualKeyCode = [int]$info.windowsVirtualKeyCode
        key = [string]$info.key
        code = [string]$info.code
        modifiers = $modifiers
    }
    if ($isPrintable) {
        $down.text = [string]$info.text
        $down.unmodifiedText = [string]$info.text
    } elseif ([string]$info.key -eq 'Enter' -and $modifiers -eq 0) {
        $down.text = "`r"
        $down.unmodifiedText = "`r"
    }
    [void](Send-PseCdp -Conn $Session.Conn -Method 'Input.dispatchKeyEvent' -Params $down)

    [void](Send-PseCdp -Conn $Session.Conn -Method 'Input.dispatchKeyEvent' -Params @{
        type = 'keyUp'
        windowsVirtualKeyCode = [int]$info.windowsVirtualKeyCode
        nativeVirtualKeyCode = [int]$info.windowsVirtualKeyCode
        key = [string]$info.key
        code = [string]$info.code
        modifiers = $modifiers
    })
}

function Focus-PseRef {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [string]$Ref
    )

    $refJson = ConvertTo-PseJson $Ref
    $js = @"
(function() {
  var ref = $refJson;
  if (!window.__pseRefs || !window.__pseRefs[ref]) {
    throw new Error("ref '" + ref + "' not found - run 'snapshot' first (refs are reset by navigation)");
  }
  window.__pseRefs[ref].focus();
  return true;
})()
"@
    [void](Invoke-PseInPage -Session $Session -JsExpression $js)
}

function Set-PseRefValue {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [string]$Ref,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $refJson = ConvertTo-PseJson $Ref
    $valueJson = ConvertTo-PseJson $Value
    $js = @"
(function() {
  var ref = $refJson;
  var value = $valueJson;
  if (!window.__pseRefs || !window.__pseRefs[ref]) {
    throw new Error("ref '" + ref + "' not found - run 'snapshot' first (refs are reset by navigation)");
  }
  var el = window.__pseRefs[ref];
  el.focus();
  if ((el.type || "").toLowerCase() === "checkbox") {
    el.checked = /^(true|1|yes|on|checked)$/i.test(String(value));
  } else {
    el.value = value;
  }
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  return true;
})()
"@
    [void](Invoke-PseInPage -Session $Session -JsExpression $js)
}

function Select-PseRefOptions {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [string]$Ref,

        [Parameter(Mandatory = $true)]
        [string[]]$Values
    )

    $refJson = ConvertTo-PseJson $Ref
    $valueList = New-Object System.Collections.ArrayList
    foreach ($value in $Values) {
        [void]$valueList.Add([string]$value)
    }
    $valuesJson = ConvertTo-PseJson -Object $valueList
    $js = @"
(function() {
  var ref = $refJson;
  var values = $valuesJson;
  if (!window.__pseRefs || !window.__pseRefs[ref]) {
    throw new Error("ref '" + ref + "' not found - run 'snapshot' first (refs are reset by navigation)");
  }
  var el = window.__pseRefs[ref];
  if (!el || String(el.tagName || "").toLowerCase() !== "select") {
    throw new Error("ref '" + ref + "' is not a select element");
  }
  var wanted = {};
  values.forEach(function(value) { wanted[String(value)] = true; });
  var matched = [];
  Array.prototype.forEach.call(el.options, function(option) {
    var label = String(option.label || option.text || "").trim();
    var text = String(option.text || "").trim();
    var isMatch = !!(wanted[String(option.value)] || wanted[label] || wanted[text]);
    option.selected = isMatch;
    if (isMatch) {
      matched.push(label || text || String(option.value));
    }
  });
  if (matched.length === 0) {
    throw new Error("no option matched '" + values.join(", ") + "'");
  }
  if (!el.multiple && matched.length > 1) {
    var first = matched[0];
    var kept = false;
    matched = [];
    Array.prototype.forEach.call(el.options, function(option) {
      var label = String(option.label || option.text || "").trim();
      var text = String(option.text || "").trim();
      var name = label || text || String(option.value);
      if (!kept && name === first) {
        option.selected = true;
        kept = true;
        matched.push(name);
      } else {
        option.selected = false;
      }
    });
  }
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  return JSON.stringify(matched);
})()
"@
    $json = Invoke-PseInPage -Session $Session -JsExpression $js
    return @($json | ConvertFrom-Json | ForEach-Object { $_ })
}

function Test-PseRefFileInput {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [string]$Ref
    )

    $refJson = ConvertTo-PseJson $Ref
    $js = @"
(function() {
  var ref = $refJson;
  if (!window.__pseRefs || !window.__pseRefs[ref]) {
    throw new Error("ref '" + ref + "' not found - run 'snapshot' first (refs are reset by navigation)");
  }
  var el = window.__pseRefs[ref];
  return !!(el && String(el.tagName || "").toLowerCase() === "input" && String(el.type || "").toLowerCase() === "file");
})()
"@
    return [bool](Invoke-PseInPage -Session $Session -JsExpression $js)
}

function Set-PseRefFileInputFiles {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [Parameter(Mandatory = $true)]
        [string]$Ref,

        [Parameter(Mandatory = $true)]
        [string[]]$Files
    )

    $refJson = ConvertTo-PseJson $Ref
    $response = Send-PseCdp -Conn $Session.Conn -Method 'Runtime.evaluate' -Params @{
        expression = "window.__pseRefs[$refJson]"
        returnByValue = $false
    }
    if ($null -eq $response -or $null -eq $response.result -or -not $response.result.objectId) {
        throw "ref '$Ref' not found - run 'snapshot' first (refs are reset by navigation)"
    }

    [void](Send-PseCdp -Conn $Session.Conn -Method 'DOM.setFileInputFiles' -Params @{
        files = @($Files | ForEach-Object { [string]$_ })
        objectId = [string]$response.result.objectId
    })
}

function Test-PseWaitCondition {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [AllowNull()]
        [string]$Text,

        [AllowNull()]
        [string]$Gone
    )

    $hasText = $PSBoundParameters.ContainsKey('Text')
    $hasGone = $PSBoundParameters.ContainsKey('Gone')

    if (-not $hasText -and -not $hasGone) {
        $ready = Invoke-PseInPage -Session $Session -JsExpression "(function(){ return document.readyState === 'complete'; })()" -TimeoutSec 5
        return [bool]$ready
    }

    $textJson = 'null'
    if ($hasText) {
        $textJson = ConvertTo-PseJson $Text
    }
    $goneJson = 'null'
    if ($hasGone) {
        $goneJson = ConvertTo-PseJson $Gone
    }
    $js = @"
(function() {
  var text = $textJson;
  var gone = $goneJson;
  var bodyText = document.body ? String(document.body.innerText || document.body.textContent || "") : "";
  if (text !== null && bodyText.indexOf(String(text)) === -1) { return false; }
  if (gone !== null && bodyText.indexOf(String(gone)) !== -1) { return false; }
  return true;
})()
"@
    $matched = Invoke-PseInPage -Session $Session -JsExpression $js -TimeoutSec 5
    return [bool]$matched
}
