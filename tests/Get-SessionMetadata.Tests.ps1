#!/usr/bin/env pwsh
# Dependency-free tests for the FirstMsgUuid / CompactRefs capture in
# Get-SessionMetadata, against temp transcript fixtures.
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

# 1. First user line's uuid is captured; a later user line does not overwrite it.
$f1 = Join-Path $tmp 'declauttr-meta-1.jsonl'
@(
    '{"type":"user","uuid":"u-first","message":{"content":"Help me wire up the release pipeline"}}'
    '{"type":"assistant","uuid":"a-1","message":{"content":[{"type":"text","text":"ok"}]}}'
    '{"type":"user","uuid":"u-second","message":{"content":"more"}}'
) | Set-Content -LiteralPath $f1 -Encoding utf8
$m1 = Get-SessionMetadata -Path $f1
Assert-Equal 'u-first' $m1.FirstMsgUuid 'first user uuid captured'
Assert-Equal 0 $m1.CompactRefs.Count 'no compact refs when absent'

# 2. compactMetadata preservedSegment uuids are captured and deduped.
$f2 = Join-Path $tmp 'declauttr-meta-2.jsonl'
@(
    '{"type":"summary","compactMetadata":{"preservedSegment":{"headUuid":"h1","anchorUuid":"a1","tailUuid":"t1"}}}'
    '{"type":"user","uuid":"u-x","message":{"content":"This session is being continued"}}'
) | Set-Content -LiteralPath $f2 -Encoding utf8
$m2 = Get-SessionMetadata -Path $f2
Assert-Equal 3 $m2.CompactRefs.Count 'three preserved-segment uuids captured'
Assert-Equal $true ($m2.CompactRefs -contains 'h1') 'headUuid captured'
Assert-Equal $true ($m2.CompactRefs -contains 'a1') 'anchorUuid captured'
Assert-Equal $true ($m2.CompactRefs -contains 't1') 'tailUuid captured'

# 3. No user line anywhere -> FirstMsgUuid is $null.
$f3 = Join-Path $tmp 'declauttr-meta-3.jsonl'
@(
    '{"type":"summary","leafUuid":"x"}'
) | Set-Content -LiteralPath $f3 -Encoding utf8
$m3 = Get-SessionMetadata -Path $f3
Assert-Equal $null $m3.FirstMsgUuid 'no user line -> null first uuid'

Remove-Item -LiteralPath $f1, $f2, $f3 -ErrorAction SilentlyContinue

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) failure(s)." -ForegroundColor Red; exit 1 }
Write-Host "`nAll Get-SessionMetadata tests passed." -ForegroundColor Green
