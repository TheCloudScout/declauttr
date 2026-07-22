#!/usr/bin/env pwsh
# Integration test: Get-AllSessions groups a project's files into families.
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

# Build a temp projects root with one project holding two same-title sessions
# plus one unrelated session. Titles group the first two; the third is solo.
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("declauttr-grp-" + [System.Guid]::NewGuid().ToString('N'))
$proj = Join-Path $root 'project-a'
New-Item -ItemType Directory -Path $proj -Force | Out-Null

$older = Join-Path $proj 'older.jsonl'
@(
    '{"type":"user","uuid":"u1","cwd":"/tmp/project-a","message":{"content":"Help me set up the deploy workflow now"}}'
    '{"type":"ai-title","aiTitle":"Set up the deploy workflow"}'
) | Set-Content -LiteralPath $older -Encoding utf8

$newer = Join-Path $proj 'newer.jsonl'
@(
    '{"type":"user","uuid":"u2","cwd":"/tmp/project-a","message":{"content":"Continue the deploy workflow setup please"}}'
    '{"type":"ai-title","aiTitle":"Set up the deploy workflow"}'
) | Set-Content -LiteralPath $newer -Encoding utf8

$solo = Join-Path $proj 'solo.jsonl'
@(
    '{"type":"user","uuid":"u3","cwd":"/tmp/project-a","message":{"content":"Investigate the flaky integration test"}}'
    '{"type":"ai-title","aiTitle":"Investigate the flaky integration test"}'
) | Set-Content -LiteralPath $solo -Encoding utf8

# Make 'newer' genuinely newer so it becomes the parent.
(Get-Item $older).LastWriteTime = [datetime]'2026-07-10T08:00:00'
(Get-Item $newer).LastWriteTime = [datetime]'2026-07-11T08:00:00'
(Get-Item $solo ).LastWriteTime = [datetime]'2026-07-20T08:00:00'

$all = Get-AllSessions -Root $root

$byUuid = @{}
foreach ($s in $all) { $byUuid[$s.Uuid] = $s }

Assert-Equal $true  $byUuid['newer'].IsParent 'newer is the family parent'
Assert-Equal $true  $byUuid['older'].IsChild  'older is a child'
Assert-Equal 'newer' $byUuid['older'].FamilyId 'child FamilyId points at parent'
Assert-Equal $false $byUuid['solo'].IsParent  'solo is not a parent'
Assert-Equal $false $byUuid['solo'].IsChild   'solo is not a child'

# Display order within the project: solo (newest) first, then parent, then child.
Assert-Equal 'solo'  $all[0].Uuid 'solo renders first (newest)'
Assert-Equal 'newer' $all[1].Uuid 'parent renders second'
Assert-Equal 'older' $all[2].Uuid 'child renders under parent'

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) failure(s)." -ForegroundColor Red; exit 1 }
Write-Host "`nAll Get-AllSessions grouping tests passed." -ForegroundColor Green
