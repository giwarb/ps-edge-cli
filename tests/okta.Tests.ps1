$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'src\10-util.ps1')
. (Join-Path $repoRoot 'src\40-browser.ps1')

function Assert-PseOktaTrue {
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

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ps-edge-okta-test-' + [Guid]::NewGuid().ToString('N'))
try {
    $profileDir = Join-Path $testRoot 'Default'
    New-Item -ItemType Directory -Path $profileDir | Out-Null
    $preferencesPath = Join-Path $profileDir 'Preferences'
    $nonAsciiLabel = ([string][char]0x65E5) + ([string][char]0x672C) + ([string][char]0x8A9E)
    $fixture = @'
{
  "existing": { "keep": true, "label": "__LABEL__" },
  "protocol_handler": {
    "allowed_origin_protocol_pairs": {
      "https://other.example": { "custom-scheme": true }
    }
  }
}
'@.Replace('__LABEL__', $nonAsciiLabel)
    [System.IO.File]::WriteAllText($preferencesPath, $fixture, (New-Object System.Text.UTF8Encoding($false)))

    $origin = Initialize-PseOktaFastPassProfile -UserDataDir $testRoot -Origin 'https://Tenant.Okta.com/'
    Assert-PseOktaTrue ($origin -eq 'https://tenant.okta.com') "Expected normalized origin, got '$origin'."

    $preferences = Get-Content -LiteralPath $preferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-PseOktaTrue ([bool]$preferences.existing.keep) 'Existing profile preference was not preserved.'
    Assert-PseOktaTrue ($preferences.existing.label -eq $nonAsciiLabel) 'BOM-less UTF-8 profile text was not preserved.'
    Assert-PseOktaTrue ([bool]$preferences.protocol_handler.allowed_origin_protocol_pairs.'https://other.example'.'custom-scheme') 'Existing protocol allow entry was not preserved.'
    $oktaProtocols = $preferences.protocol_handler.allowed_origin_protocol_pairs.'https://tenant.okta.com'
    Assert-PseOktaTrue ([bool]$oktaProtocols.'com-okta-authenticator') 'com-okta-authenticator was not allowed.'
    Assert-PseOktaTrue ([bool]$oktaProtocols.'okta-verify') 'okta-verify was not allowed.'
    Assert-PseOktaTrue ([bool]$oktaProtocols.'com.okta.mobile') 'com.okta.mobile was not allowed.'

    foreach ($invalidOrigin in @('http://tenant.okta.com', 'https://tenant.okta.com/path', 'not-a-url')) {
        $failed = $false
        try {
            [void](Resolve-PseHttpsOrigin -Origin $invalidOrigin)
        } catch {
            $failed = $true
        }
        Assert-PseOktaTrue $failed "Expected invalid origin '$invalidOrigin' to fail."
    }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
