$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$helloScript = Join-Path $repoRoot "scripts\hello.ps1"

$actual = & $helloScript
if ($actual -ne "Hello, world!") {
    throw "Expected 'Hello, world!' but got '$actual'."
}

$actual = & $helloScript -Name "Codex"
if ($actual -ne "Hello, Codex!") {
    throw "Expected 'Hello, Codex!' but got '$actual'."
}
