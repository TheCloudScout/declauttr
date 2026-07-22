#!/usr/bin/env pwsh
# Dependency-free tests for content-search matching. The search corpus must be
# identical to what the preview shows: the resolved session title (preview
# header) plus user/assistant conversation text (preview body), never JSON
# metadata (MCP tool names, cwd, uuids, tool_use/tool_result blocks, command
# markers).
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
$files = @()
function New-JsonlFile {
    param([string]$Name, [string[]]$Lines)
    $p = Join-Path $tmp $Name
    $Lines | Set-Content -LiteralPath $p -Encoding utf8
    $script:files += $p
    return $p
}

# 1. NEGATIVE (the bug): "n8n" appears only in metadata (cwd, tool_use name,
#    tool_result content), never in conversation text.
$fMeta = New-JsonlFile 'declauttr-match-meta.jsonl' @(
    '{"type":"assistant","uuid":"a1","cwd":"/home/n8n-stuff","message":{"content":[{"type":"tool_use","name":"mcp__n8n-mcp__get_node","input":{"x":1}}]}}'
    '{"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","content":"n8n ran ok"}]}}'
    '{"type":"user","uuid":"u2b","message":{"content":"just a benign question with no match"}}'
)
Assert-Equal $false (Test-SessionMatchesQuery -Path $fMeta -Query 'n8n') 'metadata-only n8n does not match'

# 2. POSITIVE user text (string content).
$fUser = New-JsonlFile 'declauttr-match-user.jsonl' @(
    '{"type":"user","uuid":"u3","message":{"content":"how do I use n8n?"}}'
)
Assert-Equal $true (Test-SessionMatchesQuery -Path $fUser -Query 'n8n') 'user text matches'

# 3. POSITIVE assistant text (array with a text block).
$fAsst = New-JsonlFile 'declauttr-match-asst.jsonl' @(
    '{"type":"assistant","uuid":"a2","message":{"content":[{"type":"text","text":"n8n is a workflow tool"}]}}'
)
Assert-Equal $true (Test-SessionMatchesQuery -Path $fAsst -Query 'n8n') 'assistant text matches'

# 4. CASE-SENSITIVITY.
$fCase = New-JsonlFile 'declauttr-match-case.jsonl' @(
    '{"type":"user","uuid":"u5","message":{"content":"talking about n8n here"}}'
)
Assert-Equal $false (Test-SessionMatchesQuery -Path $fCase -Query 'N8N' -CaseSensitive) 'case-sensitive N8N does not match n8n'
Assert-Equal $true  (Test-SessionMatchesQuery -Path $fCase -Query 'N8N') 'case-insensitive N8N matches n8n'

# 5. EMPTY query. NOTE: the spec asks to assert `-Query ''` returns $true, but
#    the required `[Parameter(Mandatory)] [string]$Query` attribute rejects an
#    empty string at binding time (both in the original and the fixed code), so
#    the internal `IsNullOrEmpty` guard is unreachable dead code for ''. The UI
#    enforces the "empty shows all" behavior upstream (call site trims/guards
#    before calling). We therefore assert the actual, preserved behavior: a
#    parameter-binding error is thrown for an empty query.
$emptyThrew = $false
try { Test-SessionMatchesQuery -Path $fUser -Query '' | Out-Null }
catch { $emptyThrew = $true }
Assert-Equal $true $emptyThrew 'empty query rejected by mandatory binding (preserved behavior)'

# 6. COMMAND MARKER excluded from corpus.
$fCmd = New-JsonlFile 'declauttr-match-cmd.jsonl' @(
    '{"type":"user","uuid":"u4","message":{"content":"<command-name>n8n</command-name>"}}'
)
Assert-Equal $false (Test-SessionMatchesQuery -Path $fCmd -Query 'n8n') 'command-marker n8n does not match'

# 7. TITLE is part of the corpus (it shows in the preview header). A session
#    whose title contains the query matches even when the body does not; and the
#    same file without a title passed does not match (proves it's the title, not
#    the body, doing the work). Title matching honours case-sensitivity too.
$fTitle = New-JsonlFile 'declauttr-match-title.jsonl' @(
    '{"type":"user","uuid":"u6","message":{"content":"a body with nothing special in it"}}'
)
Assert-Equal $true  (Test-SessionMatchesQuery -Path $fTitle -Query 'n8n' -Title 'Debugging the n8n webhook')     'title matches when body does not'
Assert-Equal $false (Test-SessionMatchesQuery -Path $fTitle -Query 'n8n')                                        'no match when title not supplied and body lacks it'
Assert-Equal $false (Test-SessionMatchesQuery -Path $fTitle -Query 'N8N' -Title 'Debugging the n8n webhook' -CaseSensitive) 'case-sensitive title miss'
Assert-Equal $true  (Test-SessionMatchesQuery -Path $fTitle -Query 'N8N' -Title 'Debugging the N8N webhook' -CaseSensitive)  'case-sensitive title hit'

foreach ($p in $files) { Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue }
if ($script:failures -gt 0) { Write-Host "`n$($script:failures) failure(s)." -ForegroundColor Red; exit 1 }
Write-Host "`nAll Test-SessionMatchesQuery tests passed." -ForegroundColor Green
