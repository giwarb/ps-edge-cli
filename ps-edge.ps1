#region PSE-SOURCES
Get-ChildItem -Path (Join-Path $PSScriptRoot 'src') -Filter '*.ps1' |
    Sort-Object Name | ForEach-Object { . $_.FullName }
#endregion PSE-SOURCES
exit (Invoke-PseMain $args)
