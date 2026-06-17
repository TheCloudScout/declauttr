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

function New-Sessions { param([string[]]$Names) ,@($Names | ForEach-Object { [pscustomobject]@{ Project = $_ } }) }

# 1. All names shorter than the floor -> floor (10).
Assert-Equal 10 (Get-ProjectColumnWidth -Sessions (New-Sessions @('abc','de')) -ScreenWidth 120) 'short names clamp up to floor'

# 2. A normal name on a wide screen -> exact fit (longest name length).
Assert-Equal 25 (Get-ProjectColumnWidth -Sessions (New-Sessions @('x','a-project-name-of-len-25!')) -ScreenWidth 120) 'normal name fits exactly'

# 3. A very long name -> capped at floor(width * 0.5).
Assert-Equal 40 (Get-ProjectColumnWidth -Sessions (New-Sessions @(('z' * 200))) -ScreenWidth 80) 'long name capped at half width'

# 4. Empty list -> floor (10).
Assert-Equal 10 (Get-ProjectColumnWidth -Sessions @() -ScreenWidth 120) 'empty list -> floor'

# 5. Very narrow screen where cap < floor -> floor (10).
Assert-Equal 10 (Get-ProjectColumnWidth -Sessions (New-Sessions @(('z' * 50))) -ScreenWidth 14) 'cap below floor -> floor'

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) failure(s)." -ForegroundColor Red; exit 1 }
Write-Host "`nAll Get-ProjectColumnWidth tests passed." -ForegroundColor Green
