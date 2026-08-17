$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sessionSource = Join-Path $repoRoot 'src\50-session.ps1'
$commandsSource = Join-Path $repoRoot 'src\80-commands.ps1'

$dotSourceOutput = @(
    . $sessionSource
    . $commandsSource
)
if ($dotSourceOutput.Count -ne 0) {
    throw 'Dot-sourcing dialog reporting sources produced output.'
}

function Assert-PseTestLines {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Actual,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ($Actual.Count -ne $Expected.Count) {
        throw "$Label line count mismatch. Expected $($Expected.Count), got $($Actual.Count): $([string]::Join(' | ', @($Actual | ForEach-Object { [string]$_ })))"
    }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ([string]$Actual[$i] -cne $Expected[$i]) {
            throw "$Label line $i mismatch. Expected '$($Expected[$i])', got '$($Actual[$i])'."
        }
    }
}

$dialogs = New-Object System.Collections.ArrayList
[void]$dialogs.Add([pscustomobject]@{
    type = 'alert'
    message = 'Download completed'
    accept = $true
    promptText = $null
})
[void]$dialogs.Add([pscustomobject]@{
    type = 'confirm'
    message = 'Continue?'
    accept = $false
    promptText = $null
})
[void]$dialogs.Add([pscustomobject]@{
    type = 'prompt'
    message = 'Enter a name'
    accept = $true
    promptText = 'typed value'
})
$conn = [pscustomobject]@{ HandledDialogs = $dialogs }

$reported = @(Write-PseHandledDialogs -Conn $conn)
Assert-PseTestLines -Actual $reported -Expected @(
    '# dialog: [alert] Download completed -> accepted'
    '# dialog: [confirm] Continue? -> dismissed'
    '# dialog: [prompt] Enter a name -> accepted text: typed value'
) -Label 'handled dialogs'
if ($conn.HandledDialogs.Count -ne 0) {
    throw 'Write-PseHandledDialogs did not clear the handled dialog list.'
}

$emptyConn = [pscustomobject]@{ HandledDialogs = (New-Object System.Collections.ArrayList) }
$emptyOutput = @(Write-PseHandledDialogs -Conn $emptyConn)
Assert-PseTestLines -Actual $emptyOutput -Expected @() -Label 'empty handled dialogs'

$acceptedResult = [pscustomobject]@{
    ClickedName = 'OK'
    Accepted = $true
    Message = 'Download completed'
}
$acceptedOutput = @(Write-PseNativeDialogRescueResult -Result $acceptedResult)
Assert-PseTestLines -Actual $acceptedOutput -Expected @(
    "Rescued native dialog: clicked 'OK'"
    '# dialog: [native] Download completed -> accepted'
) -Label 'accepted native rescue'

$dismissedResult = [pscustomobject]@{
    ClickedName = 'Cancel'
    Accepted = $false
    Message = 'No results found'
}
$dismissedOutput = @(Write-PseNativeDialogRescueResult -Result $dismissedResult)
Assert-PseTestLines -Actual $dismissedOutput -Expected @(
    "Rescued native dialog: clicked 'Cancel'"
    '# dialog: [native] No results found -> dismissed'
) -Label 'dismissed native rescue'

$messageMissingResult = [pscustomobject]@{
    ClickedName = 'OK'
    Accepted = $true
    Message = $null
}
$messageMissingOutput = @(Write-PseNativeDialogRescueResult -Result $messageMissingResult)
Assert-PseTestLines -Actual $messageMissingOutput -Expected @(
    "Rescued native dialog: clicked 'OK'"
) -Label 'native rescue without message'
