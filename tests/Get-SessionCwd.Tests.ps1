#!/usr/bin/env pwsh
# Dependency-free tests for Get-SessionCwd. Dot-sources the main script (which
# returns early when dot-sourced) to load its functions, then asserts behavior
# against temp transcript fixtures.

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

$tmp = [System.IO.Path]::GetTempPath()

# 1. cwd present on the first line
$f1 = Join-Path $tmp 'declauttr-cwd-1.jsonl'
@(
    '{"type":"user","cwd":"/Users/test/project-a","message":{"content":"hi"}}'
) | Set-Content -LiteralPath $f1 -Encoding utf8
Assert-Equal '/Users/test/project-a' (Get-SessionCwd -Path $f1) 'cwd on first line'

# 2. first line has no cwd; later lines do — returns the first occurrence
$f2 = Join-Path $tmp 'declauttr-cwd-2.jsonl'
@(
    '{"type":"summary","leafUuid":"x","sessionId":"y"}'
    '{"type":"user","cwd":"/Users/test/project-b","message":{"content":"hi"}}'
    '{"type":"assistant","cwd":"/Users/test/other","message":{"content":"yo"}}'
) | Set-Content -LiteralPath $f2 -Encoding utf8
Assert-Equal '/Users/test/project-b' (Get-SessionCwd -Path $f2) 'first cwd wins'

# 3. no cwd anywhere — returns $null
$f3 = Join-Path $tmp 'declauttr-cwd-3.jsonl'
@(
    '{"type":"summary","leafUuid":"x","sessionId":"y"}'
) | Set-Content -LiteralPath $f3 -Encoding utf8
Assert-Equal $null (Get-SessionCwd -Path $f3) 'no cwd returns null'

Remove-Item -LiteralPath $f1, $f2, $f3 -ErrorAction SilentlyContinue

if ($script:failures -gt 0) {
    Write-Host "`n$script:failures test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll tests passed." -ForegroundColor Green
