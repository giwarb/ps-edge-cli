$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'src\10-util.ps1')
. (Join-Path $repoRoot 'src\40-browser.ps1')

function Assert-PseTrue {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-PseDisableFeaturesArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    return @($Arguments | Where-Object { $_ -like '--disable-features=*' })
}

$defaultArgs = @(Get-PseEdgeLaunchArguments -Port 9333 -UserDataDir 'C:\Temp\pse-profile' -Url 'https://example.test/')
Assert-PseTrue ($defaultArgs[0] -eq '--remote-debugging-port=9333') "Expected first argument to be the debugging port, got '$($defaultArgs[0])'."
Assert-PseTrue ($defaultArgs -contains '--disable-sync') 'Default arguments did not contain --disable-sync.'
Assert-PseTrue ($defaultArgs -contains '--no-first-run') 'Default arguments did not contain --no-first-run.'
Assert-PseTrue ($defaultArgs[$defaultArgs.Count - 1] -eq 'https://example.test/') "Expected URL to be last, got '$($defaultArgs[$defaultArgs.Count - 1])'."

$defaultDisableFeatures = @(Get-PseDisableFeaturesArguments -Arguments $defaultArgs)
Assert-PseTrue ($defaultDisableFeatures.Count -eq 1) "Expected exactly one --disable-features argument, got $($defaultDisableFeatures.Count)."
Assert-PseTrue ($defaultDisableFeatures[0] -match 'msForceBrowserSignIn') 'Default --disable-features did not contain msForceBrowserSignIn.'

$minimalArgs = @(Get-PseEdgeLaunchArguments -Port 9334 -UserDataDir 'C:\Temp\pse-profile' -NoQuietFlags)
Assert-PseTrue ($minimalArgs -contains '--no-first-run') '-NoQuietFlags arguments did not contain --no-first-run.'
Assert-PseTrue ($minimalArgs -contains '--no-default-browser-check') '-NoQuietFlags arguments did not contain --no-default-browser-check.'
Assert-PseTrue (-not ($minimalArgs -contains '--disable-sync')) '-NoQuietFlags arguments unexpectedly contained --disable-sync.'
Assert-PseTrue (@(Get-PseDisableFeaturesArguments -Arguments $minimalArgs).Count -eq 0) '-NoQuietFlags arguments unexpectedly contained --disable-features.'

$headlessArgs = @(Get-PseEdgeLaunchArguments -Port 9335 -UserDataDir 'C:\Temp\pse-profile' -Headless)
Assert-PseTrue ($headlessArgs -contains '--headless') '-Headless arguments did not contain --headless.'
Assert-PseTrue (-not ($defaultArgs -contains '--headless')) 'Default arguments unexpectedly contained --headless.'

$extraArgs = @(Get-PseEdgeLaunchArguments -Port 9336 -UserDataDir 'C:\Temp\pse-profile' -ExtraArg @('--lang=ja', '--mute-audio') -Url 'about:blank')
$langIndex = [Array]::IndexOf($extraArgs, '--lang=ja')
$muteIndex = [Array]::IndexOf($extraArgs, '--mute-audio')
$urlIndex = $extraArgs.Count - 1
Assert-PseTrue ($langIndex -ge 0) 'Extra arguments did not contain --lang=ja.'
Assert-PseTrue ($muteIndex -ge 0) 'Extra arguments did not contain --mute-audio.'
Assert-PseTrue ($langIndex -lt $muteIndex) 'Extra arguments were not kept in order.'
Assert-PseTrue ($muteIndex -lt $urlIndex) 'Extra arguments did not appear before the URL.'
