#!/usr/bin/env pwsh
# Asserts Declauttr.ps1 parses without syntax errors. Cheap regression guard
# run after every edit to the script.

$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    "$PSScriptRoot/../Declauttr.ps1", [ref]$null, [ref]$errors) | Out-Null

if ($errors) {
    $errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 1
}
Write-Host 'Declauttr.ps1 parses cleanly.' -ForegroundColor Green
