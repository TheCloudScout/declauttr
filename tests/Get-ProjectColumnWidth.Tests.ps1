#!/usr/bin/env pwsh
# Dependency-free tests for Get-ProjectColumnWidth. Dot-sources the main script
# (which returns early when dot-sourced) to load its functions, then asserts the
# column-width clamping behavior.

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

# The Project column gets half of the space left after the fixed columns
# (overhead = 41): floor((ScreenWidth - 41) / 2), with a 10-char floor.

# 1. Wide screen -> even split. floor((120 - 41) / 2) = 39.
Assert-Equal 39 (Get-ProjectColumnWidth -ScreenWidth 120) 'wide screen splits evenly'

# 2. Odd remainder rounds the Project column down. floor((100 - 41) / 2) = 29.
Assert-Equal 29 (Get-ProjectColumnWidth -ScreenWidth 100) 'odd remainder floors'

# 3. Project width never exceeds the Title width by more than the parity bit.
#    width 121: project = floor(80/2) = 40, title room = 121 - 41 - 40 = 40.
$projColWidth = Get-ProjectColumnWidth -ScreenWidth 121
Assert-Equal (121 - 41 - $projColWidth) $projColWidth 'project and title widths match'

# 4. Narrow screen where the split would drop below the floor -> floor (10).
#    floor((50 - 41) / 2) = 4 -> clamped to 10.
Assert-Equal 10 (Get-ProjectColumnWidth -ScreenWidth 50) 'split below floor clamps up'

# 5. Very narrow screen (negative split) -> floor (10).
Assert-Equal 10 (Get-ProjectColumnWidth -ScreenWidth 14) 'tiny screen clamps to floor'

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) failure(s)." -ForegroundColor Red; exit 1 }
Write-Host "`nAll Get-ProjectColumnWidth tests passed." -ForegroundColor Green
