#!/usr/bin/env pwsh
# Dependency-free tests for Get-SessionGroupKey.
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

# 1. Title present -> "T:" + normalized title (case/space-insensitive).
Assert-Equal 't:set up the deploy workflow' `
    (Get-SessionGroupKey -Title '  Set Up The Deploy Workflow ' -Snippet 'anything') `
    'title wins and is normalized'

# 2. No title, non-trivial snippet -> "S:" + normalized snippet.
Assert-Equal 's:help me wire up the release pipeline' `
    (Get-SessionGroupKey -Title '' -Snippet 'Help me wire up the release pipeline') `
    'non-trivial snippet used when no title'

# 3. No title, sentinel snippet -> $null (do not group).
Assert-Equal $null `
    (Get-SessionGroupKey -Title $null -Snippet '(no user message found)') `
    'sentinel snippet is not a group key'

# 4. No title, trivial one-word snippet -> $null.
Assert-Equal $null `
    (Get-SessionGroupKey -Title $null -Snippet 'resume') `
    'trivial one-word snippet is not a group key'

# 5. No title, short (<15 chars) snippet -> $null.
Assert-Equal $null `
    (Get-SessionGroupKey -Title $null -Snippet 'fix the bug') `
    'short snippet is not a group key'

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) failure(s)." -ForegroundColor Red; exit 1 }
Write-Host "`nAll Get-SessionGroupKey tests passed." -ForegroundColor Green
