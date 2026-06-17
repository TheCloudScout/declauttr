# Dynamic Project Column Width + Live Resize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Size the picker's Project column to the project names actually present (capped at half the screen), re-flow the list on terminal resize, and retire the unused `-List` and `-SnippetLength` features.

**Architecture:** Add a pure `Get-ProjectColumnWidth` helper and call it once per redraw inside `Show-SessionPicker`, replacing the hardcoded `40`. Add a resize check to the picker's existing idle poll loop. Delete the `-List` plain-text path and the `-SnippetLength` parameter, updating help text and the README.

**Tech Stack:** PowerShell 7+ (pwsh). Single script `Declauttr.ps1`. Dependency-free dot-source tests in `tests/`.

## Global Constraints

- Target PowerShell 7+ (pwsh); runs on Windows, macOS, Linux. (verbatim from spec)
- Community/personal project: keep employer (Wortell) and customer names out of code, examples, and docs.
- Tests are dependency-free: dot-source `Declauttr.ps1` (it returns early when dot-sourced) and assert with the existing `Assert-Equal` pattern.
- `tests/Parse.Tests.ps1` (syntax guard) must pass after every task.
- Console-rendering and resize behavior are not unit-testable (need a live console); the only new automated test is for `Get-ProjectColumnWidth`. Rendering/resize/removal tasks are guarded by `Parse.Tests.ps1` plus manual verification.

---

### Task 1: `Get-ProjectColumnWidth` helper + unit tests

**Files:**
- Modify: `Declauttr.ps1` — insert new function immediately before `function Show-SessionPicker {` (currently line 1874).
- Test: `tests/Get-ProjectColumnWidth.Tests.ps1` (create)

**Interfaces:**
- Produces: `Get-ProjectColumnWidth -Sessions <IList> -ScreenWidth <int> -> [int]`. Returns `clamp(longestProjectNameLength, 10, floor(ScreenWidth*0.5))`. Empty list → 10. If the cap is below the floor (very narrow screen), returns 10.

- [ ] **Step 1: Write the failing test**

Create `tests/Get-ProjectColumnWidth.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile tests/Get-ProjectColumnWidth.Tests.ps1`
Expected: FAIL — `Get-ProjectColumnWidth` is not recognized as a command (CommandNotFoundException), or the run aborts before any PASS line.

- [ ] **Step 3: Write the function**

Insert immediately before `function Show-SessionPicker {` in `Declauttr.ps1`:

```powershell
function Get-ProjectColumnWidth {
    # Width for the picker's Project column: wide enough for the longest project
    # name present, but never less than a 10-char floor (so the "Project" header
    # label fits) nor more than half the screen (so the Title column keeps its
    # share). Computed from the active session set, not per visible row, so the
    # column stays put while scrolling.
    param(
        [Parameter(Mandatory)] [System.Collections.IList]$Sessions,
        [Parameter(Mandatory)] [int]$ScreenWidth
    )

    $floor = 10
    $cap   = [int][Math]::Floor($ScreenWidth * 0.5)
    if ($cap -lt $floor) { return $floor }

    $longest = 0
    foreach ($s in $Sessions) {
        $len = "$($s.Project)".Length
        if ($len -gt $longest) { $longest = $len }
    }

    if ($longest -lt $floor) { return $floor }
    if ($longest -gt $cap)   { return $cap }
    return $longest
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile tests/Get-ProjectColumnWidth.Tests.ps1`
Expected: 5 PASS lines, then "All Get-ProjectColumnWidth tests passed."

Run: `pwsh -NoProfile tests/Parse.Tests.ps1`
Expected: "Declauttr.ps1 parses cleanly."

- [ ] **Step 5: Commit**

```bash
git add Declauttr.ps1 tests/Get-ProjectColumnWidth.Tests.ps1
git commit -m "Add Get-ProjectColumnWidth helper with tests"
```

---

### Task 2: Wire dynamic width into the picker rendering

**Files:**
- Modify: `Declauttr.ps1` — `Show-SessionPicker` redraw block (compute near line 2114; column header near lines 2141-2146; row prefix near lines 2180-2181).

**Interfaces:**
- Consumes: `Get-ProjectColumnWidth` (Task 1); `$activeSessions` and `$width` already in scope in the redraw block.
- Produces: local `$projColWidth` used by the header and row formatting.

- [ ] **Step 1: Compute the column width at the top of the redraw block**

The redraw block begins after the idle/key-handling block. Find:

```powershell
            [Console]::SetCursorPosition(0, $origTop)
            $rowBuffer.Clear()

            $checkedCount = @($activeSessions | Where-Object Checked).Count
```

Insert the width computation right after the `$checkedCount` line:

```powershell
            $checkedCount = @($activeSessions | Where-Object Checked).Count

            # Project column sized to the longest name in the active view (capped
            # at half the screen). Recomputed each redraw, but the active set only
            # changes on filter/resize, so it stays stable while scrolling.
            $projColWidth = Get-ProjectColumnWidth -Sessions $activeSessions -ScreenWidth $width
```

- [ ] **Step 2: Use the width in the column header**

Find:

```powershell
            $colHeader = "{0}  {1}  {2}  {3}  {4}" -f `
                '   ',
                'Last changed    ',
                ('Size'.PadLeft(11)),
                ('Project'.PadRight(40)),
                'Title / first user message'
```

Replace the `('Project'.PadRight(40)),` line with:

```powershell
                ('Project'.PadRight($projColWidth)),
```

- [ ] **Step 3: Use the width in the per-row prefix**

Find:

```powershell
                $proj = $s.Project
                if ($proj.Length -gt 40) { $proj = '…' + $proj.Substring($proj.Length - 39) }
                $prefix  = "$flag $mark  $ts  $($s.SizeFormatted)  $($proj.PadRight(40))  "
```

Replace with:

```powershell
                $proj = $s.Project
                if ($proj.Length -gt $projColWidth) { $proj = '…' + $proj.Substring($proj.Length - ($projColWidth - 1)) }
                $prefix  = "$flag $mark  $ts  $($s.SizeFormatted)  $($proj.PadRight($projColWidth))  "
```

- [ ] **Step 4: Verify it parses and runs**

Run: `pwsh -NoProfile tests/Parse.Tests.ps1`
Expected: "Declauttr.ps1 parses cleanly."

Run: `pwsh -NoProfile ./Declauttr.ps1`
Expected: picker opens; on a wide terminal the Project column is wider than before and full project names show without a leading `…` (assuming a real `~/.claude/projects` with sessions). Press `ESC` to exit. If no sessions exist, this prints "No sessions found." — that's fine; the Parse test is the gating check.

- [ ] **Step 5: Commit**

```bash
git add Declauttr.ps1
git commit -m "Size picker Project column to content instead of fixed 40"
```

---

### Task 3: Live re-flow on terminal resize

**Files:**
- Modify: `Declauttr.ps1` — `Show-SessionPicker` idle branch (currently lines 1943-1947).

**Interfaces:**
- Consumes: `$width`, `$height`, `$reserved`, `$viewport`, `$top`, `$cursor`, `$origTop`, `$needRedraw`, `$activeSessions` — all already in scope in the loop.

- [ ] **Step 1: Add a resize check before the idle sleep**

Find:

```powershell
            if (-not $needRedraw) {
                if (-not [Console]::KeyAvailable) {
                    Start-Sleep -Milliseconds 25
                    continue
                }
```

Replace with:

```powershell
            if (-not $needRedraw) {
                if (-not [Console]::KeyAvailable) {
                    # No native resize event exists in .NET Console, so detect a
                    # window resize by polling here and re-flow the whole list.
                    $curW = try { [Console]::WindowWidth }  catch { $width }
                    $curH = try { [Console]::WindowHeight } catch { $height }
                    if (($curW -ge 60 -and $curW -ne $width) -or ($curH -ge 10 -and $curH -ne $height)) {
                        $width    = $curW
                        $height   = $curH
                        $viewport = [Math]::Min($activeSessions.Count, [Math]::Max(5, $height - $reserved))
                        if ($cursor -ge $top + $viewport) { $top = [Math]::Max(0, $cursor - $viewport + 1) }
                        [Console]::Clear()
                        $origTop = [Console]::CursorTop
                        for ($i = 0; $i -lt ($viewport + 5); $i++) { Write-Host '' }
                        $needRedraw = $true
                        continue
                    }
                    Start-Sleep -Milliseconds 25
                    continue
                }
```

- [ ] **Step 2: Verify it parses**

Run: `pwsh -NoProfile tests/Parse.Tests.ps1`
Expected: "Declauttr.ps1 parses cleanly."

- [ ] **Step 3: Manual resize verification**

Run: `pwsh -NoProfile ./Declauttr.ps1` (with a populated `~/.claude/projects`).
Expected: drag the terminal wider/narrower while the picker is open — the list redraws to the new width, the Project column re-fits, and rows fill edge-to-edge. No crash or garbled output. Press `ESC` to exit.

(No automated test — resize requires a live console. The Parse test is the gating automated check.)

- [ ] **Step 4: Commit**

```bash
git add Declauttr.ps1
git commit -m "Re-flow picker list on terminal resize"
```

---

### Task 4: Remove the `-List` feature

**Files:**
- Modify: `Declauttr.ps1` — param block, comment-based help, delete `Write-SessionsList`, collapse the `if ($List)` branch in the main block.
- Modify: `README.md` — remove List sections; preserve the hyphen-encoding note.

**Interfaces:**
- Produces: nothing new. After this task the picker is the only non-`-About` mode.

- [ ] **Step 1: Remove the `-List` parameter**

In the `param(...)` block, find and delete this line:

```powershell
    [switch]$List,
```

- [ ] **Step 2: Remove `-List` from the comment-based help**

Delete the help line (in the `.DESCRIPTION` area):

```
    Use -List to print a plain, non-interactive listing instead.
```

Delete the `.PARAMETER List` block:

```
.PARAMETER List
    Print a plain listing of sessions instead of opening the interactive picker.
```

Delete the `-List` example (the `.EXAMPLE` heading and its command line):

```
.EXAMPLE
    ./Declauttr.ps1 -List
```

- [ ] **Step 3: Delete the `Write-SessionsList` function**

Delete the entire function — from `function Write-SessionsList {` through its closing `}` (the line after `Write-Host ("Total: {0} sessions, {1:N1} MB" ...)`), including the trailing blank line before `function Show-SessionPicker {`.

- [ ] **Step 4: Collapse the `if ($List)` branch in the main block**

Find this block near the end of the script:

```powershell
if ($List) {
    Write-SessionsList -Sessions $sessions -SnippetMax $SnippetLength
} else {
    if ($sessions.Count -eq 0) {
        Write-Host 'No sessions found.' -ForegroundColor Yellow
        return
    }

    $deleted = Show-SessionPicker -Sessions $sessions

    if ($script:JumpSession) {
        # cd into the session's directory before clearing the screen, so if the
        # directory vanished in the brief window since it was validated, the
        # error stays visible and we don't launch claude in the wrong directory.
        # Set-Location only affects this pwsh process, so the parent shell's cwd
        # is unchanged after claude exits.
        try {
            Set-Location -LiteralPath $script:JumpSession.Cwd -ErrorAction Stop
        } catch {
            Write-Host "Can't jump: $($_.Exception.Message)" -ForegroundColor Red
            return
        }
        Clear-Host
        Write-Host ("Resuming session {0}" -f $script:JumpSession.SessionId) -ForegroundColor DarkGray
        Write-Host ("  in {0}`n" -f $script:JumpSession.Cwd) -ForegroundColor DarkGray
        & claude --resume "$($script:JumpSession.SessionId)"
        # claude's exit code is intentionally not forwarded; the user is back at
        # their shell prompt regardless of how claude exited.
        return
    }

    if (-not $deleted -or $deleted.Count -eq 0) { return }

    Write-Host ''
    foreach ($s in $deleted) {
        Write-Host "  deleted $($s.Uuid)" -ForegroundColor Green
    }
    $totalKb = ($deleted | Measure-Object SizeBytes -Sum).Sum / 1KB
    Write-Host ''
    Write-Host ("  total: {0} session(s), {1:N1} KB freed" -f $deleted.Count, $totalKb) -ForegroundColor DarkGray
}
```

Replace the whole block with the de-indented else body (drop the `if ($List) {...} else {` wrapper and its closing brace):

```powershell
if ($sessions.Count -eq 0) {
    Write-Host 'No sessions found.' -ForegroundColor Yellow
    return
}

$deleted = Show-SessionPicker -Sessions $sessions

if ($script:JumpSession) {
    # cd into the session's directory before clearing the screen, so if the
    # directory vanished in the brief window since it was validated, the
    # error stays visible and we don't launch claude in the wrong directory.
    # Set-Location only affects this pwsh process, so the parent shell's cwd
    # is unchanged after claude exits.
    try {
        Set-Location -LiteralPath $script:JumpSession.Cwd -ErrorAction Stop
    } catch {
        Write-Host "Can't jump: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    Clear-Host
    Write-Host ("Resuming session {0}" -f $script:JumpSession.SessionId) -ForegroundColor DarkGray
    Write-Host ("  in {0}`n" -f $script:JumpSession.Cwd) -ForegroundColor DarkGray
    & claude --resume "$($script:JumpSession.SessionId)"
    # claude's exit code is intentionally not forwarded; the user is back at
    # their shell prompt regardless of how claude exited.
    return
}

if (-not $deleted -or $deleted.Count -eq 0) { return }

Write-Host ''
foreach ($s in $deleted) {
    Write-Host "  deleted $($s.Uuid)" -ForegroundColor Green
}
$totalKb = ($deleted | Measure-Object SizeBytes -Sum).Sum / 1KB
Write-Host ''
Write-Host ("  total: {0} session(s), {1:N1} KB freed" -f $deleted.Count, $totalKb) -ForegroundColor DarkGray
```

- [ ] **Step 5: Update the README — remove List mode references**

In `README.md`:

1. In the "Two display modes" bullet list, delete the sub-bullet:
   ```
     - **List mode** (`-List`) — grouped per project, scroll-friendly text output.
   ```
   and change the remaining "Interactive picker (default)" wording so it no longer implies a second mode — change `**Interactive picker** (default) —` to `**Interactive picker** —`.

2. Delete the entire "### List every session, grouped per project" section: the heading, the ` ```powershell / ./Declauttr.ps1 -List / ``` ` block, the "Output looks like:" line, and the example output fenced block — **stop before** the `> **Project names use hyphens, not slashes.**` blockquote.

3. **Keep** the `> **Project names use hyphens...**` blockquote, but move it under the "### Interactive picker" section and reword its sentence `both here and in the interactive picker's "Project" column` to `in the interactive picker's "Project" column`.

4. In the "### Interactive picker" section, delete the line:
   ```
   The picker is the default. Pass `-List` if you want plain text output instead.
   ```
   and delete the now-stale screenshot reference:
   ```
   ![Interactive picker — list view](img/screenshot-list-view.jpg)
   ```
   (Leave `img/screenshot-list-view.jpg` on disk; it is simply no longer referenced.)

- [ ] **Step 6: Verify**

Run: `pwsh -NoProfile tests/Parse.Tests.ps1`
Expected: "Declauttr.ps1 parses cleanly."

Run: `grep -n "List" README.md` and confirm no remaining `-List` references (the word "list" may still appear in unrelated prose — only `-List` / "List mode" must be gone).

Run: `grep -rn "List\b" Declauttr.ps1 | grep -i "switch\|Write-SessionsList\|\$List"`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add Declauttr.ps1 README.md
git commit -m "Remove unused -List plain-text mode"
```

---

### Task 5: Remove the `-SnippetLength` parameter (hardcode 400)

**Files:**
- Modify: `Declauttr.ps1` — param block, comment-based help, the `Get-AllSessions` call site.
- Modify: `README.md` — remove the snippet-length section.

**Interfaces:**
- Consumes: `Get-AllSessions` already defaults `SnippetMax = 400`, so dropping the argument preserves current behavior.

- [ ] **Step 1: Remove the `-SnippetLength` parameter**

In the `param(...)` block, find and delete this line:

```powershell
    [int]$SnippetLength = 400,
```

- [ ] **Step 2: Remove `-SnippetLength` from the comment-based help**

Delete the `.PARAMETER SnippetLength` block:

```
.PARAMETER SnippetLength
    Maximum characters of the user-message preview in list mode.
    Default 400. Wrapped to terminal width.
```

- [ ] **Step 3: Drop the argument at the `Get-AllSessions` call site**

Find:

```powershell
$sessions = Get-AllSessions -Root $ProjectsRoot -ProjectFilter $Project -SnippetMax $SnippetLength
```

Replace with (relies on `Get-AllSessions`'s built-in `SnippetMax = 400` default):

```powershell
$sessions = Get-AllSessions -Root $ProjectsRoot -ProjectFilter $Project
```

- [ ] **Step 4: Update the README — remove the snippet-length section**

In `README.md`, delete the entire "### Tune the snippet length" section: the heading, the ` ```powershell / ./Declauttr.ps1 -SnippetLength 250 / ``` ` block, and the trailing paragraph:

```
Affects how much of the first user message is shown in list mode (interactive
mode always uses the title, falling back to a truncated snippet).
```

- [ ] **Step 5: Verify**

Run: `pwsh -NoProfile tests/Parse.Tests.ps1`
Expected: "Declauttr.ps1 parses cleanly."

Run: `pwsh -NoProfile tests/Get-SessionCwd.Tests.ps1`
Expected: all PASS (confirms the script still dot-sources cleanly after removals).

Run: `grep -rn "SnippetLength" Declauttr.ps1 README.md`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add Declauttr.ps1 README.md
git commit -m "Remove -SnippetLength parameter; hardcode 400 default"
```

---

## Self-Review

**Spec coverage:**
- Part A (dynamic Project column / `Get-ProjectColumnWidth`, floor 10, cap 50%) → Tasks 1 & 2. ✓
- Part B (stable, computed from active set, not per row) → Task 2 Step 1 (computed once per redraw from `$activeSessions`; recomputes on filter/resize because those trigger redraws). ✓
- Part C (live resize via the idle poll loop) → Task 3. ✓
- Part D (remove `-List`: param, function, branch, help, README, orphaned image noted) → Task 4. ✓
- Part E (remove `-SnippetLength`, hardcode 400 via `Get-AllSessions` default) → Task 5. ✓
- Testing (unit tests for `Get-ProjectColumnWidth`, Parse guard, manual resize) → Task 1 tests; Parse run each task; Task 3 manual step. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows full code. ✓

**Type consistency:** `Get-ProjectColumnWidth -Sessions <IList> -ScreenWidth <int> -> [int]` defined in Task 1, consumed identically in Task 2 as `$projColWidth`. `$projColWidth` used consistently in header and row steps. ✓
