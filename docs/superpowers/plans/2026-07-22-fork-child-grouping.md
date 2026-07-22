# Fork / child session grouping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group related Claude Code session files (forks, compaction continuations, same-title siblings) into families in the picker, rendering offshoots as indented `∟` children under the most-recent parent, with parent-cascade delete-marking.

**Architecture:** All changes live in the single `Declauttr.ps1` script. Detection is fed by two new fields captured in `Get-SessionMetadata`'s existing streaming pass; a new pure `Group-SessionsIntoFamilies` union-finds each project's sessions into families and returns them display-ordered; `Get-AllSessions` wires it in; `Show-SessionPicker` renders the connector and cascades the checkbox.

**Tech Stack:** PowerShell 7+ (pwsh), no external modules. Tests are dependency-free scripts that dot-source `Declauttr.ps1` and use a local `Assert-Equal`.

## Global Constraints

- PowerShell 7+ (`pwsh`); must run on Windows, macOS, and Linux — no platform-specific APIs.
- Tests follow the existing pattern: `. "$PSScriptRoot/../Declauttr.ps1"` (the script returns early when dot-sourced) plus a local `Assert-Equal`. No Pester, no external deps.
- Run any test with `pwsh <path-to-test>`. The syntax guard is `pwsh tests/Parse.Tests.ps1` and must pass after every code edit.
- **No employer or customer names** anywhere in code, tests, fixtures, or docs. Use neutral names like `project-a`, `session titles` such as `"Set up the deploy workflow"`. (This is a published community project.)
- The child connector glyph is exactly `∟ ` (U+221F LEFT-BOTTOM CORNER, then one space) — a required UI glyph specified by the author.
- Keep the existing brace/indentation style; each list row is still emitted top-to-bottom via `Write-Host` (each call adds one newline).

---

### Task 1: `Get-SessionGroupKey` helper (same-title grouping key)

**Files:**
- Modify: `Declauttr.ps1` (add a new function just above `Get-AllSessions`, ~line 1844)
- Test: `tests/Get-SessionGroupKey.Tests.ps1` (create)

**Interfaces:**
- Produces: `Get-SessionGroupKey -Title <string> -Snippet <string> -> <string|$null>`. Returns `"T:" + lowercased-trimmed title` when a title exists; else `"S:" + lowercased-trimmed snippet` when the snippet is non-trivial; else `$null`.

- [ ] **Step 1: Write the failing test**

Create `tests/Get-SessionGroupKey.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh tests/Get-SessionGroupKey.Tests.ps1`
Expected: FAIL — `The term 'Get-SessionGroupKey' is not recognized` (function not defined yet).

- [ ] **Step 3: Write the function**

In `Declauttr.ps1`, immediately above `function Get-AllSessions {` (~line 1844), insert:

```powershell
function Get-SessionGroupKey {
    # Same-title fallback key used to group sibling sessions within a project.
    # Prefers the (AI/custom) title; falls back to the first user message only
    # when it is substantial. Returns $null for trivial/empty sessions so the
    # empty "resume"-style rows never collapse into one bogus family.
    param(
        [string]$Title,
        [string]$Snippet
    )

    if ($Title -and $Title.Trim()) {
        return 'T:' + $Title.Trim().ToLower()
    }

    if ($Snippet -and $Snippet -ne '(no user message found)') {
        $t = $Snippet.Trim().ToLower().TrimEnd('.', '!', '?', '…')
        $trivial = @('resume', 'config', 'exit', 'quit', 'clear', 'help', 'init', 'test')
        if ($t.Length -ge 15 -and ($trivial -notcontains $t)) {
            return 'S:' + $Snippet.Trim().ToLower()
        }
    }

    return $null
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh tests/Get-SessionGroupKey.Tests.ps1`
Expected: PASS (all 5).

- [ ] **Step 5: Verify the script still parses**

Run: `pwsh tests/Parse.Tests.ps1`
Expected: `Declauttr.ps1 parses cleanly.`

- [ ] **Step 6: Commit**

```bash
git add Declauttr.ps1 tests/Get-SessionGroupKey.Tests.ps1
git commit -m "Add Get-SessionGroupKey helper for same-title grouping"
```

---

### Task 2: `Get-SessionMetadata` captures `FirstMsgUuid` and `CompactRefs`

**Files:**
- Modify: `Declauttr.ps1` — `Get-SessionMetadata` (lines ~95-146)
- Test: `tests/Get-SessionMetadata.Tests.ps1` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Get-SessionMetadata -Path <string> [-MaxLength <int>]` now returns a `pscustomobject` with the existing `Snippet`, `Title`, `HasCustomTitle` **plus** `FirstMsgUuid` (`string` or `$null`, the `uuid` of the first `type:"user"` line) and `CompactRefs` (`string[]`, the deduped `compactMetadata.preservedSegment` head/anchor/tail UUIDs; empty array when none).

- [ ] **Step 1: Write the failing test**

Create `tests/Get-SessionMetadata.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh tests/Get-SessionMetadata.Tests.ps1`
Expected: FAIL — `FirstMsgUuid` / `CompactRefs` are missing (comparisons fail, `.Count` on `$null`).

- [ ] **Step 3: Implement the capture**

Replace the entire body of `Get-SessionMetadata` (lines ~95-146) with:

```powershell
function Get-SessionMetadata {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [int]$MaxLength = 400
    )

    $snippet      = $null
    $aiTitle      = $null
    $customTitle  = $null
    $firstMsgUuid = $null
    $compactRefs  = [System.Collections.Generic.List[string]]::new()

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Fast text pre-filter — parse only lines that might contain what we need.
        # User lines are parsed until BOTH the snippet and the first-message uuid
        # are known; titles ("last wins") and compact metadata are checked on
        # every line but only JSON-parsed when their marker is present.
        $needUser  = (-not $snippet) -or (-not $firstMsgUuid)
        $isUser    = $needUser -and $line.Contains('"type":"user"')
        $isAi      = $line.Contains('"type":"ai-title"')
        $isCustom  = $line.Contains('"type":"custom-title"')
        $isCompact = $line.Contains('"compactMetadata"')
        if (-not ($isUser -or $isAi -or $isCustom -or $isCompact)) { continue }

        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }

        if ($isAi     -and $obj.type -eq 'ai-title'     -and $obj.aiTitle)     { $aiTitle     = $obj.aiTitle }
        if ($isCustom -and $obj.type -eq 'custom-title' -and $obj.customTitle) { $customTitle = $obj.customTitle }

        if ($isCompact -and $obj.compactMetadata -and $obj.compactMetadata.preservedSegment) {
            $seg = $obj.compactMetadata.preservedSegment
            foreach ($k in @('headUuid', 'anchorUuid', 'tailUuid')) {
                $v = $seg.$k
                if ($v -and ($compactRefs -notcontains [string]$v)) { $compactRefs.Add([string]$v) }
            }
        }

        if ($isUser -and $obj.type -eq 'user') {
            if (-not $firstMsgUuid -and $obj.uuid) { $firstMsgUuid = [string]$obj.uuid }

            if (-not $snippet) {
                $content = $obj.message.content
                $text = $null
                if ($content -is [string]) {
                    $text = $content
                } elseif ($content) {
                    foreach ($c in $content) {
                        if ($c.type -eq 'text' -and $c.text) { $text = $c.text; break }
                    }
                }
                if ($text -and -not $text.StartsWith('<local-command') -and -not $text.StartsWith('<command-name>')) {
                    $text = ($text -replace '\s+', ' ').Trim()
                    if ($text.Length -gt $MaxLength) {
                        $text = $text.Substring(0, $MaxLength).TrimEnd() + '…'
                    }
                    $snippet = $text
                }
            }
        }
    }

    return [pscustomobject]@{
        Snippet         = if ($snippet)     { $snippet }     else { '(no user message found)' }
        Title           = if ($customTitle) { $customTitle } elseif ($aiTitle) { $aiTitle } else { $null }
        HasCustomTitle  = [bool]$customTitle
        FirstMsgUuid    = $firstMsgUuid
        CompactRefs     = $compactRefs.ToArray()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh tests/Get-SessionMetadata.Tests.ps1`
Expected: PASS (all assertions).

- [ ] **Step 5: Verify the script still parses**

Run: `pwsh tests/Parse.Tests.ps1`
Expected: `Declauttr.ps1 parses cleanly.`

- [ ] **Step 6: Commit**

```bash
git add Declauttr.ps1 tests/Get-SessionMetadata.Tests.ps1
git commit -m "Capture FirstMsgUuid and CompactRefs in Get-SessionMetadata"
```

---

### Task 3: `Group-SessionsIntoFamilies` (union-find grouping + display order)

**Files:**
- Modify: `Declauttr.ps1` (add function just above `Get-AllSessions`, below `Get-SessionGroupKey`)
- Test: `tests/Group-SessionsIntoFamilies.Tests.ps1` (create)

**Interfaces:**
- Consumes: session objects carrying `Uuid` (string, unique), `Timestamp` (`[datetime]`), `FirstMsgUuid` (string|$null), `CompactRefs` (string[]), `GroupKey` (string|$null), and mutable `IsParent` / `IsChild` / `FamilyId` fields.
- Produces: `Group-SessionsIntoFamilies -Sessions <IList> -> <List[object]>`. **Mutates** each input object's `IsParent`, `IsChild`, `FamilyId`, and **returns** the sessions in display order (families ordered by parent `Timestamp` descending; within a family, parent first then children by `Timestamp` descending). Parent = latest `Timestamp` in a multi-member family (tie-break: `Uuid` descending). Solo sessions get `IsParent=$false`, `IsChild=$false`, `FamilyId=$null`.

- [ ] **Step 1: Write the failing test**

Create `tests/Group-SessionsIntoFamilies.Tests.ps1`:

```powershell
#!/usr/bin/env pwsh
# Dependency-free tests for Group-SessionsIntoFamilies.
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

# Factory for a minimal session object with the fields the grouper needs.
function New-S {
    param($Uuid, $Ts, $First = $null, $Compact = @(), $Group = $null)
    [pscustomobject]@{
        Uuid         = $Uuid
        Timestamp    = [datetime]$Ts
        FirstMsgUuid = $First
        CompactRefs  = @($Compact)
        GroupKey     = $Group
        IsParent     = $false
        IsChild      = $false
        FamilyId     = $null
    }
}
function Get-Row { param($List, $Uuid) $List | Where-Object { $_.Uuid -eq $Uuid } }

# --- 1. Fork pair: shared FirstMsgUuid. Later timestamp is the parent. ---
$fork = [System.Collections.Generic.List[object]]::new()
$fork.Add((New-S 'old' '2026-07-14T13:00:00' -First 'root-1'))
$fork.Add((New-S 'new' '2026-07-22T09:00:00' -First 'root-1'))
$ordered = Group-SessionsIntoFamilies -Sessions $fork
Assert-Equal $true  (Get-Row $ordered 'new').IsParent 'fork: newest is parent'
Assert-Equal $true  (Get-Row $ordered 'old').IsChild  'fork: older is child'
Assert-Equal 'new'  (Get-Row $ordered 'old').FamilyId 'fork: child FamilyId is parent uuid'
Assert-Equal 'new'  $ordered[0].Uuid                  'fork: parent renders first'
Assert-Equal 'old'  $ordered[1].Uuid                  'fork: child renders under parent'

# --- 2. Compaction pair: shared CompactRefs uuid. ---
$comp = [System.Collections.Generic.List[object]]::new()
$comp.Add((New-S 'orig' '2026-06-30T12:00:00' -First 'r-a' -Compact @('seg-9')))
$comp.Add((New-S 'cont' '2026-07-02T13:00:00' -First 'r-b' -Compact @('seg-9')))
$ordered2 = Group-SessionsIntoFamilies -Sessions $comp
Assert-Equal $true  (Get-Row $ordered2 'cont').IsParent 'compaction: newest is parent'
Assert-Equal $true  (Get-Row $ordered2 'orig').IsChild  'compaction: older is child'

# --- 3. Same-title trio (no uuid/compaction links) via GroupKey. ---
$title = [System.Collections.Generic.List[object]]::new()
$title.Add((New-S 'a' '2026-07-09T08:00:00' -First 'r1' -Group 't:set up the deploy workflow'))
$title.Add((New-S 'b' '2026-07-10T08:00:00' -First 'r2' -Group 't:set up the deploy workflow'))
$title.Add((New-S 'c' '2026-07-11T08:00:00' -First 'r3' -Group 't:set up the deploy workflow'))
$ordered3 = Group-SessionsIntoFamilies -Sessions $title
Assert-Equal 'c' $ordered3[0].Uuid 'same-title: newest is parent, renders first'
Assert-Equal $true (Get-Row $ordered3 'a').IsChild 'same-title: a is child'
Assert-Equal $true (Get-Row $ordered3 'b').IsChild 'same-title: b is child'
# children sorted newest-first under parent: c (parent), b, a
Assert-Equal 'b' $ordered3[1].Uuid 'same-title: newest child directly under parent'
Assert-Equal 'a' $ordered3[2].Uuid 'same-title: oldest child last'

# --- 4. Trivial sessions never group (GroupKey null, distinct FirstMsgUuid). ---
$triv = [System.Collections.Generic.List[object]]::new()
$triv.Add((New-S 'e1' '2026-07-01T08:00:00' -First 'x1' -Group $null))
$triv.Add((New-S 'e2' '2026-07-02T08:00:00' -First 'x2' -Group $null))
$ordered4 = Group-SessionsIntoFamilies -Sessions $triv
Assert-Equal $false (Get-Row $ordered4 'e1').IsParent 'trivial: e1 solo (not parent)'
Assert-Equal $false (Get-Row $ordered4 'e1').IsChild  'trivial: e1 solo (not child)'
Assert-Equal $null  (Get-Row $ordered4 'e1').FamilyId 'trivial: solo FamilyId null'

# --- 5. Family ordering: whole family sits at the parent's timestamp. ---
# solo 'z' (2026-07-20) should render before the family whose parent is 'b' (2026-07-10).
$mix = [System.Collections.Generic.List[object]]::new()
$mix.Add((New-S 'a' '2026-07-09T08:00:00' -Group 't:same'))
$mix.Add((New-S 'b' '2026-07-10T08:00:00' -Group 't:same'))
$mix.Add((New-S 'z' '2026-07-20T08:00:00' -Group $null))
$ordered5 = Group-SessionsIntoFamilies -Sessions $mix
Assert-Equal 'z' $ordered5[0].Uuid 'ordering: newer solo before older family'
Assert-Equal 'b' $ordered5[1].Uuid 'ordering: family parent second'
Assert-Equal 'a' $ordered5[2].Uuid 'ordering: family child last'

if ($script:failures -gt 0) { Write-Host "`n$($script:failures) failure(s)." -ForegroundColor Red; exit 1 }
Write-Host "`nAll Group-SessionsIntoFamilies tests passed." -ForegroundColor Green
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh tests/Group-SessionsIntoFamilies.Tests.ps1`
Expected: FAIL — `The term 'Group-SessionsIntoFamilies' is not recognized`.

- [ ] **Step 3: Implement the function**

In `Declauttr.ps1`, directly below the `Get-SessionGroupKey` function (and above `Get-AllSessions`), insert:

```powershell
function Group-SessionsIntoFamilies {
    # Union-finds one project's sessions into families and returns them in
    # display order. Sessions are unioned when they share a first-message uuid
    # (fork), a compactMetadata preserved-segment uuid (compaction lineage), or
    # a same-title GroupKey. In a multi-member family the latest-changed session
    # is the parent; the rest are children. Mutates IsParent/IsChild/FamilyId on
    # each input object. Returns families ordered by parent timestamp (desc),
    # parent first then children (desc) within each.
    param(
        [Parameter(Mandatory)] [System.Collections.IList]$Sessions
    )

    $n = $Sessions.Count
    if ($n -eq 0) { return ,([System.Collections.Generic.List[object]]::new()) }

    # Union-find over positional indices 0..n-1.
    $parent = 0..($n - 1)
    $find = {
        param([int]$x)
        while ($parent[$x] -ne $x) {
            $parent[$x] = $parent[$parent[$x]]   # path halving
            $x = $parent[$x]
        }
        return $x
    }
    $union = {
        param([int]$a, [int]$b)
        $ra = & $find $a; $rb = & $find $b
        if ($ra -ne $rb) { $parent[$ra] = $rb }
    }
    $unionByKey = {
        param([hashtable]$map)
        foreach ($k in $map.Keys) {
            $idxs = $map[$k]
            for ($i = 1; $i -lt $idxs.Count; $i++) { & $union $idxs[0] $idxs[$i] }
        }
    }

    $byFirst = @{}; $byCompact = @{}; $byGroup = @{}
    for ($i = 0; $i -lt $n; $i++) {
        $s = $Sessions[$i]
        if ($s.FirstMsgUuid) {
            if (-not $byFirst.ContainsKey($s.FirstMsgUuid)) { $byFirst[$s.FirstMsgUuid] = [System.Collections.Generic.List[int]]::new() }
            $byFirst[$s.FirstMsgUuid].Add($i)
        }
        if ($s.CompactRefs) {
            foreach ($r in $s.CompactRefs) {
                if (-not $byCompact.ContainsKey($r)) { $byCompact[$r] = [System.Collections.Generic.List[int]]::new() }
                $byCompact[$r].Add($i)
            }
        }
        if ($s.GroupKey) {
            if (-not $byGroup.ContainsKey($s.GroupKey)) { $byGroup[$s.GroupKey] = [System.Collections.Generic.List[int]]::new() }
            $byGroup[$s.GroupKey].Add($i)
        }
    }
    & $unionByKey $byFirst
    & $unionByKey $byCompact
    & $unionByKey $byGroup

    # Bucket indices by their component root.
    $comp = @{}
    for ($i = 0; $i -lt $n; $i++) {
        $r = & $find $i
        if (-not $comp.ContainsKey($r)) { $comp[$r] = [System.Collections.Generic.List[int]]::new() }
        $comp[$r].Add($i)
    }

    # Assign flags per component and record a per-family sort key.
    $families = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $comp.Keys) {
        $members = @(foreach ($ix in $comp[$r]) { $Sessions[$ix] })
        if ($members.Count -eq 1) {
            $m = $members[0]
            $m.IsParent = $false; $m.IsChild = $false; $m.FamilyId = $null
            $families.Add([pscustomobject]@{ SortTs = $m.Timestamp; SortId = $m.Uuid; Ordered = @($m) })
        } else {
            $sorted = @($members | Sort-Object -Property `
                @{ Expression = 'Timestamp'; Descending = $true }, `
                @{ Expression = 'Uuid'; Descending = $true })
            $parentS = $sorted[0]
            foreach ($m in $members) {
                $m.FamilyId = $parentS.Uuid
                if ($m.Uuid -eq $parentS.Uuid) { $m.IsParent = $true;  $m.IsChild = $false }
                else                           { $m.IsParent = $false; $m.IsChild = $true  }
            }
            $families.Add([pscustomobject]@{ SortTs = $parentS.Timestamp; SortId = $parentS.Uuid; Ordered = $sorted })
        }
    }

    # Order families by parent timestamp (desc), tie-break uuid (desc), then flatten.
    $orderedFamilies = @($families | Sort-Object -Property `
        @{ Expression = 'SortTs'; Descending = $true }, `
        @{ Expression = 'SortId'; Descending = $true })
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($fam in $orderedFamilies) {
        foreach ($m in $fam.Ordered) { $out.Add($m) }
    }
    return ,$out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh tests/Group-SessionsIntoFamilies.Tests.ps1`
Expected: PASS (all assertions).

- [ ] **Step 5: Verify the script still parses**

Run: `pwsh tests/Parse.Tests.ps1`
Expected: `Declauttr.ps1 parses cleanly.`

- [ ] **Step 6: Commit**

```bash
git add Declauttr.ps1 tests/Group-SessionsIntoFamilies.Tests.ps1
git commit -m "Add Group-SessionsIntoFamilies union-find grouping"
```

---

### Task 4: Wire grouping into `Get-AllSessions`

**Files:**
- Modify: `Declauttr.ps1` — `Get-AllSessions` (lines ~1844-1882)
- Test: `tests/Get-AllSessions-Grouping.Tests.ps1` (create)

**Interfaces:**
- Consumes: `Get-SessionMetadata` (Task 2), `Get-SessionGroupKey` (Task 1), `Group-SessionsIntoFamilies` (Task 3).
- Produces: `Get-AllSessions` returns the same flat `List[object]`, now with each session object also carrying `FirstMsgUuid`, `CompactRefs`, `GroupKey`, `FamilyId`, `IsParent`, `IsChild`, and ordered per project by family (parent then children).

- [ ] **Step 1: Write the failing test**

Create `tests/Get-AllSessions-Grouping.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh tests/Get-AllSessions-Grouping.Tests.ps1`
Expected: FAIL — objects lack `IsParent`/`IsChild`/`FamilyId`, and order is raw mtime, not grouped.

- [ ] **Step 3: Rewrite `Get-AllSessions`**

Replace the body of `Get-AllSessions` (lines ~1844-1882) with:

```powershell
function Get-AllSessions {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [string]$ProjectFilter,
        [int]$SnippetMax = 400
    )

    $result  = [System.Collections.Generic.List[object]]::new()
    $projects = Get-ChildItem -Path $Root -Directory | Sort-Object Name
    if ($ProjectFilter) {
        $projects = $projects | Where-Object { $_.Name -like "*$ProjectFilter*" }
    }

    foreach ($proj in $projects) {
        $files = Get-ChildItem -Path $proj.FullName -Filter '*.jsonl' -File |
                 Sort-Object LastWriteTime -Descending

        # Build this project's sessions, then group them into families. Grouping
        # is per-project because a family never spans projects.
        $projSessions = [System.Collections.Generic.List[object]]::new()
        foreach ($f in $files) {
            $meta      = Get-SessionMetadata -Path $f.FullName -MaxLength $SnippetMax
            $recommend = Test-RecommendRemoval -SizeBytes $f.Length -Snippet $meta.Snippet
            $projSessions.Add([pscustomobject]@{
                Project        = $proj.Name
                Path           = $f.FullName
                Uuid           = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                Timestamp      = $f.LastWriteTime
                SizeBytes      = $f.Length
                SizeFormatted  = '{0,8:N1} KB' -f ($f.Length / 1KB)
                Title          = $meta.Title
                HasCustomTitle = $meta.HasCustomTitle
                Snippet        = $meta.Snippet
                Recommended    = $recommend
                Checked        = $recommend
                FirstMsgUuid   = $meta.FirstMsgUuid
                CompactRefs    = $meta.CompactRefs
                GroupKey       = Get-SessionGroupKey -Title $meta.Title -Snippet $meta.Snippet
                FamilyId       = $null
                IsParent       = $false
                IsChild        = $false
            })
        }

        $ordered = Group-SessionsIntoFamilies -Sessions $projSessions
        foreach ($s in $ordered) { $result.Add($s) }
    }
    # Comma prefix prevents PowerShell from enumerating the list into an
    # object[] (which is fixed-size and would break later .RemoveAt calls in
    # the picker when sessions are deleted in place).
    return ,$result
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh tests/Get-AllSessions-Grouping.Tests.ps1`
Expected: PASS.

- [ ] **Step 5: Run the full existing suite to check nothing regressed**

Run: `pwsh tests/Parse.Tests.ps1; pwsh tests/Get-SessionCwd.Tests.ps1; pwsh tests/Get-ProjectColumnWidth.Tests.ps1`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Declauttr.ps1 tests/Get-AllSessions-Grouping.Tests.ps1
git commit -m "Group sessions into families in Get-AllSessions"
```

---

### Task 5: Parent-cascade delete-marking (`Set-FamilyChecked` + X handler)

**Files:**
- Modify: `Declauttr.ps1` — add `Set-FamilyChecked` helper (above `Show-SessionPicker`, ~line 1904) and update the `'X'` branch in `Show-SessionPicker` (lines ~2034-2038)
- Test: `tests/Set-FamilyChecked.Tests.ps1` (create)

**Interfaces:**
- Produces: `Set-FamilyChecked -Sessions <IList> -FamilyId <string> -State <bool> -> void`. Sets `.Checked = $State` on every session in `$Sessions` whose `FamilyId` equals `$FamilyId`.
- Consumes (in the X handler): each row's `IsParent`, `FamilyId`, `Checked`.

- [ ] **Step 1: Write the failing test**

Create `tests/Set-FamilyChecked.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh tests/Set-FamilyChecked.Tests.ps1`
Expected: FAIL — `The term 'Set-FamilyChecked' is not recognized`.

- [ ] **Step 3: Add the helper**

In `Declauttr.ps1`, directly above `function Show-SessionPicker {` (~line 1904), insert:

```powershell
function Set-FamilyChecked {
    # Set .Checked on every session sharing $FamilyId. Used by the picker so
    # marking a parent for deletion cascades to its whole family (including
    # members currently filtered out of view).
    param(
        [Parameter(Mandatory)] [System.Collections.IList]$Sessions,
        [Parameter(Mandatory)] [string]$FamilyId,
        [Parameter(Mandatory)] [bool]$State
    )
    foreach ($s in $Sessions) {
        if ($s.FamilyId -eq $FamilyId) { $s.Checked = $State }
    }
}
```

- [ ] **Step 4: Update the X handler**

In `Show-SessionPicker`, replace the `'X'` branch (lines ~2034-2038):

```powershell
                    'X'         {
                        if ($activeSessions.Count -gt 0) {
                            $activeSessions[$cursor].Checked = -not $activeSessions[$cursor].Checked
                        }
                    }
```

with:

```powershell
                    'X'         {
                        if ($activeSessions.Count -gt 0) {
                            $row = $activeSessions[$cursor]
                            $newState = -not $row.Checked
                            $row.Checked = $newState
                            # Marking a parent cascades to its whole family
                            # (across the master list, so filtered-out members
                            # follow too). Children toggle on their own.
                            if ($row.IsParent -and $row.FamilyId) {
                                Set-FamilyChecked -Sessions $Sessions -FamilyId $row.FamilyId -State $newState
                            }
                        }
                    }
```

- [ ] **Step 5: Run test + parse guard**

Run: `pwsh tests/Set-FamilyChecked.Tests.ps1; pwsh tests/Parse.Tests.ps1`
Expected: both pass.

- [ ] **Step 6: Commit**

```bash
git add Declauttr.ps1 tests/Set-FamilyChecked.Tests.ps1
git commit -m "Cascade delete-marking from parent to family children"
```

---

### Task 6: Render the `∟` connector with fixed-during-marquee behaviour

**Files:**
- Modify: `Declauttr.ps1` — the per-row render block in `Show-SessionPicker` (lines ~2234-2268)

**Interfaces:**
- Consumes: each row's `IsChild`, `Title`, `Snippet`, `HasCustomTitle`, `Recommended`, `Checked`.
- Produces: no new function. Child rows get a fixed `∟ ` prefix inside the Title column; the marquee scrolls only the title text.

This task is verified manually (the interactive TUI can't be unit-tested here). The parse guard is the automated check.

- [ ] **Step 1: Replace the per-row render block**

In `Show-SessionPicker`, replace the block that currently starts at `$s = $activeSessions[$idx]` and ends at `$rowBuffer.Add($line)` (lines ~2234-2268) with:

```powershell
                $s    = $activeSessions[$idx]
                $mark = if ($s.Checked) { '[x]' } else { '[ ]' }
                $flag = if ($s.HasCustomTitle) { '!' } else { ' ' }
                $ts   = $s.Timestamp.ToString('yyyy-MM-dd HH:mm')
                $proj = $s.Project
                if ($proj.Length -gt $projColWidth) { $proj = '…' + $proj.Substring($proj.Length - ($projColWidth - 1)) }
                $prefix  = "$flag $mark  $ts  $($s.SizeFormatted)  $($proj.PadRight($projColWidth))  "
                $room    = [Math]::Max(10, $width - $prefix.Length - 1)

                # Children carry a fixed 2-column "∟ " connector at the start of
                # the Title column, lining up under the parent's title. Only the
                # title text after it scrolls during a marquee.
                $connector = if ($s.IsChild) { '∟ ' } else { '' }
                $titleRoom = [Math]::Max(1, $room - $connector.Length)

                $fullDesc = if ($s.Title) { $s.Title } else { $s.Snippet }
                if ($idx -eq $cursor -and $marqueeOffset -gt 0 -and $fullDesc.Length -gt $titleRoom) {
                    $gap   = '   •   '
                    $cycle = $fullDesc + $gap
                    $start = $marqueeOffset % $cycle.Length
                    $sb    = [System.Text.StringBuilder]::new($titleRoom)
                    for ($j = 0; $j -lt $titleRoom; $j++) {
                        [void]$sb.Append($cycle[($start + $j) % $cycle.Length])
                    }
                    $titleText = $sb.ToString()
                } else {
                    $titleText = $fullDesc
                    if ($titleText.Length -gt $titleRoom) { $titleText = $titleText.Substring(0, $titleRoom - 1) + '…' }
                }

                $line = ($prefix + $connector + $titleText).PadRight($width)
                if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }

                if ($idx -eq $cursor) {
                    # Selected row: single bar, connector included in the bar.
                    Write-Host $line -ForegroundColor White -BackgroundColor DarkBlue
                } else {
                    $rowColor = if ($s.HasCustomTitle) { 'DarkCyan' } elseif ($s.Recommended) { 'DarkYellow' } else { $null }
                    if ($s.IsChild) {
                        # Split writes so the connector stays DarkGray (a dim
                        # "branch") while the title keeps the row's own colour.
                        $pad = $width - $prefix.Length - $connector.Length - $titleText.Length
                        if ($pad -lt 0) { $pad = 0 }
                        if ($rowColor) { Write-Host $prefix -NoNewline -ForegroundColor $rowColor }
                        else           { Write-Host $prefix -NoNewline }
                        Write-Host $connector -NoNewline -ForegroundColor DarkGray
                        if ($rowColor) { Write-Host ($titleText + (' ' * $pad)) -ForegroundColor $rowColor }
                        else           { Write-Host ($titleText + (' ' * $pad)) }
                    } elseif ($rowColor) {
                        Write-Host $line -ForegroundColor $rowColor
                    } else {
                        Write-Host $line
                    }
                }
                $rowBuffer.Add($line)
```

- [ ] **Step 2: Verify the script still parses**

Run: `pwsh tests/Parse.Tests.ps1`
Expected: `Declauttr.ps1 parses cleanly.`

- [ ] **Step 3: Manual smoke test**

Run: `pwsh ./Declauttr.ps1`
Verify by eye:
- A project with a fork/compaction/same-title family shows the parent on top and children beneath, each child prefixed with `∟ ` aligned under the parent's title start.
- Arrowing onto a child with a long title: after ~1s the title text marquees while the `∟ ` stays fixed.
- Pressing `X` on a parent checks/unchecks all its children; pressing `X` on a child toggles only that child.
- Non-child rows look exactly as before.
Press `Esc` to exit without deleting anything.

- [ ] **Step 4: Commit**

```bash
git add Declauttr.ps1
git commit -m "Render ∟ connector for child rows with fixed-marquee prefix"
```

---

### Task 7: Documentation

**Files:**
- Modify: `Declauttr.ps1` — the `.SYNOPSIS`/`.DESCRIPTION` "Visual cues" block (lines ~56-66)
- Modify: `README.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Update the in-script help "Visual cues" block**

In the comment-based help, inside the `Visual cues:` list (after the `!` custom-title bullet, ~line 61), add a bullet:

```
      * Sessions that are forks or continuations of the same conversation are
        grouped into a family: the most recent one is shown normally and its
        older siblings appear indented beneath it with a leading "∟ ". Marking
        the family's top (parent) row for deletion also marks all of its
        children; a child can still be marked on its own.
```

- [ ] **Step 2: Add a README note**

In `README.md`, find the section that lists the picker's visual cues / key behaviour (near the `!` custom-title explanation). Add a short paragraph:

```markdown
Related sessions (forks, `/compact` continuations, and same-titled siblings
within a project) are grouped into a **family**. The most recent session is the
parent; its older offshoots are shown indented beneath it with a `∟` connector.
Marking a parent for deletion cascades to its children, so you can prune a whole
stale lineage in one go — while still being able to check an individual child on
its own.
```

- [ ] **Step 3: Verify the script still parses (help block is inside the script)**

Run: `pwsh tests/Parse.Tests.ps1`
Expected: `Declauttr.ps1 parses cleanly.`

- [ ] **Step 4: Run the entire test suite one last time**

Run:
```bash
pwsh tests/Parse.Tests.ps1
pwsh tests/Get-SessionCwd.Tests.ps1
pwsh tests/Get-ProjectColumnWidth.Tests.ps1
pwsh tests/Get-SessionGroupKey.Tests.ps1
pwsh tests/Get-SessionMetadata.Tests.ps1
pwsh tests/Group-SessionsIntoFamilies.Tests.ps1
pwsh tests/Get-AllSessions-Grouping.Tests.ps1
pwsh tests/Set-FamilyChecked.Tests.ps1
```
Expected: every script prints its pass line and exits 0.

- [ ] **Step 5: Commit**

```bash
git add Declauttr.ps1 README.md
git commit -m "Document fork/child session grouping"
```

---

## Self-Review

**Spec coverage:**
- Detection (fork uuid / compaction refs / same-title fallback + triviality guard) → Tasks 1, 2, 3.
- Captured signals in the metadata pass → Task 2.
- Per-project grouping + parent=latest + child ordering + family ordering → Tasks 3, 4.
- `∟ ` connector, indentation, DarkGray dim, lines-up-under-parent → Task 6.
- Fixed connector during marquee → Task 6.
- Parent-cascade marking, child independent, cascade over full family, pre-checks not cascaded (A/R unchanged) → Task 5.
- Docs (.SYNOPSIS + README) → Task 7.
- Filtered-view simplification → no code needed (rows keep computed styling); documented as accepted behaviour in the spec.

**Placeholder scan:** none — every code and test step contains complete content.

**Type consistency:** field names `FirstMsgUuid`, `CompactRefs`, `GroupKey`, `FamilyId`, `IsParent`, `IsChild`, `Checked` are used identically across Tasks 2-6; function names `Get-SessionGroupKey`, `Group-SessionsIntoFamilies`, `Set-FamilyChecked` match their definitions and call sites.
