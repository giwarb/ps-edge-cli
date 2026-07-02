# すべての tests\*.Tests.ps1 を実行するランナー。
# 各テストファイルは失敗時に throw する規約。追加依存なし(PowerShell 5.1 互換)。
$ErrorActionPreference = 'Stop'

$testFiles = Get-ChildItem -Path $PSScriptRoot -Filter '*.Tests.ps1' | Sort-Object Name
if ($testFiles.Count -eq 0) {
    Write-Host 'No test files found (tests\*.Tests.ps1).'
    exit 0
}

$failed = 0
foreach ($file in $testFiles) {
    try {
        & $file.FullName
        Write-Host "PASS  $($file.Name)"
    } catch {
        $failed++
        Write-Host "FAIL  $($file.Name): $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host "$($testFiles.Count - $failed)/$($testFiles.Count) test files passed."
if ($failed -gt 0) { exit 1 }
exit 0
