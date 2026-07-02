function Get-PseStateDir {
    $dir = Join-Path $env:TEMP 'ps-edge'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    return $dir
}

function Read-PseState {
    $stateFile = Join-Path (Get-PseStateDir) 'state.json'
    if (-not (Test-Path -LiteralPath $stateFile)) {
        return $null
    }

    try {
        $content = Get-Content -LiteralPath $stateFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) {
            return $null
        }
        return $content | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

function Write-PseState {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $stateFile = Join-Path (Get-PseStateDir) 'state.json'
    ConvertTo-PseJson $State | Set-Content -LiteralPath $stateFile -Encoding UTF8
}

function Clear-PseState {
    $stateFile = Join-Path (Get-PseStateDir) 'state.json'
    if (Test-Path -LiteralPath $stateFile) {
        Remove-Item -LiteralPath $stateFile -Force
    }
}
