#!/usr/bin/env pwsh
# Regression test for the J-jump binding bug. Show-MessageBox's -Lines parameter
# must NOT be Mandatory: a Mandatory [string[]] parameter rejects arrays that
# contain an empty string ("Cannot bind argument ... because it is an empty
# string"), but message boxes legitimately include blank spacer lines (the jump
# confirm popup has one between the question and the Project/Title rows). Keeping
# -Lines optional is what lets those blank lines through.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../Declauttr.ps1"

$failures = 0

$linesParam = (Get-Command Show-MessageBox).Parameters['Lines']
$isMandatory = @(
    $linesParam.Attributes |
        Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
        ForEach-Object { $_.Mandatory }
) -contains $true

if ($isMandatory) {
    Write-Host "FAIL: Show-MessageBox -Lines is Mandatory; it rejects arrays containing blank spacer lines." -ForegroundColor Red
    $failures++
} else {
    Write-Host "PASS: Show-MessageBox -Lines is not Mandatory (accepts blank spacer lines)." -ForegroundColor Green
}

if ($failures -gt 0) {
    Write-Host "`n$failures test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll tests passed." -ForegroundColor Green
