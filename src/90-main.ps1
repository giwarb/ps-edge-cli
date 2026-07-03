function ConvertFrom-PseArgs {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [AllowNull()]
        [object[]]$Args
    )

    $positionals = New-Object System.Collections.ArrayList
    $options = @{}
    $flags = @{
        headless = $true
        attach = $true
        fullpage = $true
        right = $true
        double = $true
        submit = $true
        accept = $true
        dismiss = $true
    }

    if ($null -ne $Args -and $Args.Count -eq 1 -and $Args[0] -is [System.Array] -and -not ($Args[0] -is [string])) {
        $Args = @($Args[0] | ForEach-Object { $_ })
    }

    $i = 0
    while ($null -ne $Args -and $i -lt $Args.Count) {
        $token = [string]$Args[$i]
        if ($token -match '^--?(.+)$') {
            $name = $Matches[1].ToLowerInvariant()
            if ($flags.ContainsKey($name)) {
                $options[$name] = $true
            } elseif (($i + 1) -lt $Args.Count -and ([string]$Args[$i + 1]) -notmatch '^-') {
                $options[$name] = [string]$Args[$i + 1]
                $i++
            } else {
                $options[$name] = $true
            }
        } else {
            [void]$positionals.Add($token)
        }
        $i++
    }

    @{
        Positional = $positionals
        Options = $options
    }
}

function Get-PseUsage {
    @'
Usage: .\ps-edge.ps1 <command> [args] [options]

Commands:
  start [-Port 9222] [-Headless] [-Url <url>] [-UserDataDir <path>] [-DownloadDir <path>]
  start -Attach [-Port 9222]
  stop
  status
  downloads [-Dir <path>]
  goto <url> [-TimeoutSec 30]
  back
  forward
  reload [-TimeoutSec 30]
  snapshot [-Selector <css>]
  screenshot [<path>] [-FullPage]
  click <ref> [-Right] [-Double]
  type <ref> <text> [-Submit]
  fill <ref> <value>
  press <key>
  hover <ref>
  select <ref> <value> [<value>...]
  upload <ref> <path> [<path>...]
  eval <javascript>
  wait [-Time <sec>] [-Text <str>] [-Gone <str>] [-TimeoutSec 30]
  tabs [list|new|select|close]
  console
  dialog [-Accept [-Text <reply>] | -Dismiss]
  cdp <method> [<params-json>]
  help
'@
}

function Get-PseCommandMap {
    @{
        start = 'Invoke-PseCmdStart'
        stop = 'Invoke-PseCmdStop'
        status = 'Invoke-PseCmdStatus'
        downloads = 'Invoke-PseCmdDownloads'
        goto = 'Invoke-PseCmdGoto'
        back = 'Invoke-PseCmdBack'
        forward = 'Invoke-PseCmdForward'
        reload = 'Invoke-PseCmdReload'
        snapshot = 'Invoke-PseCmdSnapshot'
        screenshot = 'Invoke-PseCmdScreenshot'
        click = 'Invoke-PseCmdClick'
        type = 'Invoke-PseCmdType'
        fill = 'Invoke-PseCmdFill'
        press = 'Invoke-PseCmdPress'
        hover = 'Invoke-PseCmdHover'
        select = 'Invoke-PseCmdSelect'
        upload = 'Invoke-PseCmdUpload'
        eval = 'Invoke-PseCmdEval'
        wait = 'Invoke-PseCmdWait'
        cdp = 'Invoke-PseCmdCdp'
        tabs = 'Invoke-PseCmdTabs'
        console = 'Invoke-PseCmdConsole'
        dialog = 'Invoke-PseCmdDialog'
    }
}

function Invoke-PseMain {
    param(
        [AllowNull()]
        [object[]]$ArgList
    )

    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    } catch {
    }

    try {
        if ($null -eq $ArgList -or $ArgList.Count -eq 0) {
            [Console]::Out.WriteLine((Get-PseUsage))
            return 0
        }

        $command = ([string]$ArgList[0]).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($command) -or $command -eq 'help' -or $command -eq '-h' -or $command -eq '--help') {
            [Console]::Out.WriteLine((Get-PseUsage))
            return 0
        }

        $map = Get-PseCommandMap
        if (-not $map.ContainsKey($command)) {
            $host.ui.WriteErrorLine("Error: unknown command '$command'")
            $host.ui.WriteErrorLine((Get-PseUsage))
            return 1
        }

        $remaining = @()
        if ($ArgList.Count -gt 1) {
            $remaining = @($ArgList[1..($ArgList.Count - 1)])
        }
        $parsed = ConvertFrom-PseArgs -Args $remaining
        $functionName = $map[$command]
        $output = @(& $functionName $parsed)
        if ($output.Count -eq 0) {
            return 0
        }

        $exitCode = $output[$output.Count - 1]
        $lineCount = $output.Count - 1
        for ($i = 0; $i -lt $lineCount; $i++) {
            [Console]::Out.WriteLine([string]$output[$i])
        }
        return [int]$exitCode
    } catch {
        $host.ui.WriteErrorLine("Error: $($_.Exception.Message)")
        return 1
    }
}
