function Initialize-PseUia {
    [void](Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop)
    [void](Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop)
}

function Get-PseUiaEdgeWindows {
    param(
        [AllowNull()]
        $BrowserPid = $null
    )

    Initialize-PseUia

    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $children = $root.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition
    )
    $found = New-Object System.Collections.ArrayList
    foreach ($window in $children) {
        try {
            $windowPid = [int]$window.GetCurrentPropertyValue(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty
            )
        } catch {
            continue
        }

        if ($null -ne $BrowserPid) {
            if ($windowPid -eq [int]$BrowserPid) {
                [void]$found.Add($window)
            }
            continue
        }

        try {
            $process = Get-Process -Id $windowPid -ErrorAction Stop
            if ($process.ProcessName -ieq 'msedge') {
                [void]$found.Add($window)
            }
        } catch {
        }
    }

    return @($found | ForEach-Object { $_ })
}

function Find-PseNativeDialogButton {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Windows,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    Initialize-PseUia

    $documentCondition = New-Object -TypeName System.Windows.Automation.PropertyCondition -ArgumentList @(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Document
    )
    $buttonCondition = New-Object -TypeName System.Windows.Automation.PropertyCondition -ArgumentList @(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button
    )

    # Native JS dialog windows have no Document control. Search them before the
    # main browser window to avoid matching similarly named page controls.
    $dialogWindows = New-Object System.Collections.ArrayList
    $browserWindows = New-Object System.Collections.ArrayList
    foreach ($window in @($Windows)) {
        $document = $null
        try {
            $document = $window.FindFirst(
                [System.Windows.Automation.TreeScope]::Descendants,
                $documentCondition
            )
        } catch {
        }

        if ($null -eq $document) {
            [void]$dialogWindows.Add($window)
        } else {
            [void]$browserWindows.Add($window)
        }
    }

    $orderedWindows = @(
        $dialogWindows | ForEach-Object { $_ }
        $browserWindows | ForEach-Object { $_ }
    )
    foreach ($window in $orderedWindows) {
        try {
            $buttons = $window.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                $buttonCondition
            )
            foreach ($button in $buttons) {
                $buttonName = [string]$button.Current.Name
                foreach ($name in $Names) {
                    if ([string]::Equals($buttonName, [string]$name, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return $button
                    }
                }
            }
        } catch {
        }
    }

    return $null
}

function Get-PseUiaContainingWindow {
    param(
        [Parameter(Mandatory = $true)]
        $Element
    )

    Initialize-PseUia

    $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
    $current = $Element
    while ($null -ne $current) {
        try {
            $controlType = $current.GetCurrentPropertyValue(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty
            )
            if ($controlType -eq [System.Windows.Automation.ControlType]::Window) {
                return $current
            }
            $current = $walker.GetParent($current)
        } catch {
            return $null
        }
    }

    return $null
}

function Invoke-PseNativeDialogRescue {
    param(
        [AllowNull()]
        $State,

        [Parameter(Mandatory = $true)]
        [bool]$Accept,

        [AllowNull()]
        $Text
    )

    Initialize-PseUia

    $browserPid = $null
    if ($null -ne $State) {
        if ($State -is [System.Collections.IDictionary]) {
            if ($State.Contains('pid') -and $null -ne $State['pid']) {
                $browserPid = [int]$State['pid']
            }
        } elseif ($null -ne $State.PSObject.Properties['pid'] -and $null -ne $State.pid) {
            $browserPid = [int]$State.pid
        }
    }

    $windows = @(Get-PseUiaEdgeWindows -BrowserPid $browserPid)
    if ($windows.Count -eq 0) {
        throw 'no Edge window found - rescue requires a visible (non-headless) browser'
    }

    if ($Accept) {
        $button = Find-PseNativeDialogButton -Windows $windows -Names @('OK')
    } else {
        # Build the Japanese Cancel label from code points because these source
        # files intentionally use UTF-8 without a BOM for PowerShell 5.1.
        $japaneseCancel = -join @(
            [char]0x30AD,
            [char]0x30E3,
            [char]0x30F3,
            [char]0x30BB,
            [char]0x30EB
        )
        $button = Find-PseNativeDialogButton -Windows $windows -Names @('Cancel', $japaneseCancel)
        if ($null -eq $button) {
            $button = Find-PseNativeDialogButton -Windows $windows -Names @('OK')
        }
    }

    if ($null -eq $button) {
        throw 'no native dialog found'
    }

    if ($Accept -and $null -ne $Text) {
        try {
            $window = Get-PseUiaContainingWindow -Element $button
            if ($null -ne $window) {
                $editCondition = New-Object -TypeName System.Windows.Automation.PropertyCondition -ArgumentList @(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Edit
                )
                $edit = $window.FindFirst(
                    [System.Windows.Automation.TreeScope]::Descendants,
                    $editCondition
                )
                if ($null -ne $edit) {
                    $valuePattern = $edit.GetCurrentPattern(
                        [System.Windows.Automation.ValuePattern]::Pattern
                    )
                    $valuePattern.SetValue([string]$Text)
                }
            }
        } catch {
        }
    }

    $message = $null
    try {
        $window = Get-PseUiaContainingWindow -Element $button
        if ($null -ne $window) {
            $textCondition = New-Object -TypeName System.Windows.Automation.PropertyCondition -ArgumentList @(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Text
            )
            $textElements = $window.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                $textCondition
            )
            $textNames = New-Object System.Collections.ArrayList
            foreach ($textElement in $textElements) {
                $textName = [string]$textElement.Current.Name
                if (-not [string]::IsNullOrWhiteSpace($textName)) {
                    [void]$textNames.Add($textName)
                }
            }
            if ($textNames.Count -gt 0) {
                $message = [string]::Join(' ', @($textNames | ForEach-Object { [string]$_ })).Trim()
                if ([string]::IsNullOrWhiteSpace($message)) {
                    $message = $null
                }
            }
        }
    } catch {
        $message = $null
    }

    $clickedName = [string]$button.Current.Name
    $invokePattern = $button.GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern
    )
    [void]$invokePattern.Invoke()
    return [pscustomobject]@{
        ClickedName = $clickedName
        Accepted = [string]::Equals($clickedName, 'OK', [System.StringComparison]::OrdinalIgnoreCase)
        Message = $message
    }
}
