#!/usr/bin/env pwsh
# Dependency-free tests for the parent/child Family line in the preview header.
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
function Test-HeaderHas { param($Header, $Needle) (@($Header | Where-Object { $_.Contains($Needle) })).Count -gt 0 }

$tmp = [System.IO.Path]::GetTempPath()
$f = Join-Path $tmp 'declauttr-preview-1.jsonl'
@(
    '{"type":"user","uuid":"u1","message":{"content":"hello there"}}'
) | Set-Content -LiteralPath $f -Encoding utf8

function New-PreviewSession {
    param($IsParent, $IsChild)
    [pscustomobject]@{
        Project = 'project-a'; Uuid = 'abc'; Title = 'Some title'
        Timestamp = [datetime]'2026-07-22T09:03:00'; SizeFormatted = '   1.2 KB'
        Path = $f; IsParent = $IsParent; IsChild = $IsChild
    }
}

$parent = Get-SessionPreviewContent -Session (New-PreviewSession $true $false) -Width 60
Assert-Equal $true  (Test-HeaderHas $parent.Header 'parent (newest; continues older sessions -->)') 'parent line shown'
Assert-Equal $false (Test-HeaderHas $parent.Header 'child (<--') 'parent has no child line'

$child = Get-SessionPreviewContent -Session (New-PreviewSession $false $true) -Width 60
Assert-Equal $true  (Test-HeaderHas $child.Header 'child (<-- continued by a more recent session)') 'child line shown'

$solo = Get-SessionPreviewContent -Session (New-PreviewSession $false $false) -Width 60
Assert-Equal $false (Test-HeaderHas $solo.Header 'Family:') 'solo has no Family line'

Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue
if ($script:failures -gt 0) { Write-Host "`n$($script:failures) failure(s)." -ForegroundColor Red; exit 1 }
Write-Host "`nAll Get-SessionPreviewContent tests passed." -ForegroundColor Green
