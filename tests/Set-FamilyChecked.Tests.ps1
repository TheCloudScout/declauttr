#!/usr/bin/env pwsh
# Dependency-free tests for Set-FamilyChecked.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../Declauttr.ps1"

$script:failures = 0
function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -eq $Actual) {
        Write-Host "PASS: $Name" -ForegroundColor Green
    } else {
        Write-Host "FAIL: $Name`n  expected: [$Expected]`n  actual:   [$Actual]" -ForegroundColor Red
        $script:failures++
    }
}

$sessions = [System.Collections.Generic.List[object]]::new()
$sessions.Add([pscustomobject]@{ Uuid='p'; FamilyId='p'; Checked=$false })
$sessions.Add([pscustomobject]@{ Uuid='c1'; FamilyId='p'; Checked=$false })
$sessions.Add([pscustomobject]@{ Uuid='c2'; FamilyId='p'; Checked=$false })
$sessions.Add([pscustomobject]@{ Uuid='other'; FamilyId=$null; Checked=$false })

Set-FamilyChecked -Sessions $sessions -FamilyId 'p' -State $true
Assert-Equal $true  ($sessions | Where-Object Uuid -eq 'p').Checked  'parent checked'
Assert-Equal $true  ($sessions | Where-Object Uuid -eq 'c1').Checked 'child c1 checked'
Assert-Equal $true  ($sessions | Where-Object Uuid -eq 'c2').Checked 'child c2 checked'
Assert-Equal $false ($sessions | Where-Object Uuid -eq 'other').Checked 'unrelated untouched'

Set-FamilyChecked -Sessions $sessions -FamilyId 'p' -State $false
Assert-Equal $false ($sessions | Where-Object Uuid -eq 'c1').Checked 'uncheck cascades too'

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) failure(s)." -ForegroundColor Red; exit 1 }
Write-Host "`nAll Set-FamilyChecked tests passed." -ForegroundColor Green
