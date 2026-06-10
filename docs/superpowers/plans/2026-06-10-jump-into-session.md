# Jump Into Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `J` keybinding to DeClauttR that quits the app and resumes the highlighted Claude Code session (`cd` into its working directory, then `claude --resume <id>`), guarded by a double-tap confirmation, from both the overview list and the preview.

**Architecture:** The `J` handler validates and asks for confirmation, then arms a script-scoped `$script:JumpSession` signal and exits the TUI. The picker's existing `finally` block restores the console, then `main` performs the OS-level handoff. A generic `Show-MessageBox` renders the confirm/error popups; `Get-SessionCwd` recovers the real working directory from the transcript's `cwd` field.

**Tech Stack:** PowerShell 7+ (pwsh), single-file TUI (`Declauttr.ps1`). No existing test framework — we add two small dependency-free test scripts under `tests/`.

> **Note on line numbers:** the line numbers below are hints from the pre-edit file and will drift as edits are applied. Anchor every edit on the exact code shown, not the line number.

**Spec:** `docs/superpowers/specs/2026-06-10-jump-into-session-design.md`

---

## File Structure

- **Modify `Declauttr.ps1`** — all production changes live here (single-file app):
  - dot-source guard (enables testing without running the app)
  - `Get-SessionCwd` — pure helper, recovers the working directory
  - `Show-MessageBox` — generic centered popup (confirm + error variants)
  - `Invoke-JumpAttempt` — validates, confirms, arms `$script:JumpSession`
  - `J` cases in the picker and preview key loops + hint-line updates
  - jump handoff in `main`
  - `.SYNOPSIS` help text
- **Create `tests/Parse.Tests.ps1`** — asserts the script parses cleanly (cheap regression guard for a 2000-line file).
- **Create `tests/Get-SessionCwd.Tests.ps1`** — unit tests for the one pure function.
- **Modify `README.md`** — feature bullet, key table row, and a usage subsection.

---

### Task 1: Make the script dot-sourceable + parse-check harness

Adding a dot-source guard lets the test scripts load the functions without launching the interactive app. The parse test is a cheap safety net we run after every later edit.

**Files:**
- Modify: `Declauttr.ps1` (the `# --- main ---` section, ~line 1957)
- Create: `tests/Parse.Tests.ps1`

- [ ] **Step 1: Add the dot-source guard**

In `Declauttr.ps1`, find:

```powershell
# --- main ---

Clear-Host
```

Replace with:

```powershell
# --- main ---

# When this script is dot-sourced (e.g. by the tests in ./tests), load all the
# function definitions above but skip running the interactive app.
if ($MyInvocation.InvocationName -eq '.') { return }

Clear-Host
```

- [ ] **Step 2: Create the parse test**

Create `tests/Parse.Tests.ps1`:

```powershell
#!/usr/bin/env pwsh
# Asserts Declauttr.ps1 parses without syntax errors. Cheap regression guard
# run after every edit to the script.

$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    "$PSScriptRoot/../Declauttr.ps1", [ref]$null, [ref]$errors) | Out-Null

if ($errors) {
    $errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 1
}
Write-Host 'Declauttr.ps1 parses cleanly.' -ForegroundColor Green
```

- [ ] **Step 3: Run the parse test**

Run: `pwsh -NoProfile -File tests/Parse.Tests.ps1`
Expected: `Declauttr.ps1 parses cleanly.` (exit 0)

- [ ] **Step 4: Verify the guard doesn't break normal launch**

Run: `pwsh -NoProfile -File Declauttr.ps1 -List`
Expected: the normal grouped session listing prints (guard lets direct invocation through).

- [ ] **Step 5: Commit**

```bash
git add Declauttr.ps1 tests/Parse.Tests.ps1
git commit -m "Make Declauttr.ps1 dot-sourceable and add a parse-check test"
```

---

### Task 2: `Get-SessionCwd` (TDD)

Recovers the session's real working directory from the transcript's `cwd` field. Pure function — the one directly testable unit.

**Files:**
- Modify: `Declauttr.ps1` (insert after `Get-SessionMetadata`, ~line 153)
- Create: `tests/Get-SessionCwd.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tests/Get-SessionCwd.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -File tests/Get-SessionCwd.Tests.ps1`
Expected: FAIL — an error like `The term 'Get-SessionCwd' is not recognized as a name of a cmdlet, function, ...` (the function doesn't exist yet).

- [ ] **Step 3: Implement `Get-SessionCwd`**

In `Declauttr.ps1`, find the end of `Get-SessionMetadata` and the start of `Set-SessionCustomTitle`:

```powershell
    return [pscustomobject]@{
        Snippet         = if ($snippet)     { $snippet }     else { '(no user message found)' }
        Title           = if ($customTitle) { $customTitle } elseif ($aiTitle) { $aiTitle } else { $null }
        HasCustomTitle  = [bool]$customTitle
    }
}

function Set-SessionCustomTitle {
```

Replace with (inserts the new function between them):

```powershell
    return [pscustomobject]@{
        Snippet         = if ($snippet)     { $snippet }     else { '(no user message found)' }
        Title           = if ($customTitle) { $customTitle } elseif ($aiTitle) { $aiTitle } else { $null }
        HasCustomTitle  = [bool]$customTitle
    }
}

function Get-SessionCwd {
    param(
        [Parameter(Mandatory)] [string]$Path
    )

    # Recover the session's real working directory from the transcript. Every
    # user/assistant line records a "cwd" field with the absolute path; the
    # encoded project-folder name can't be decoded reliably (a literal dash in a
    # folder name is indistinguishable from a path separator), so we read the
    # cwd straight from the file. Returns the first value found, or $null.
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if (-not $line.Contains('"cwd"')) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }
        if ($obj.cwd) { return [string]$obj.cwd }
    }
    return $null
}

function Set-SessionCustomTitle {
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -File tests/Get-SessionCwd.Tests.ps1`
Expected:
```
PASS: cwd on first line
PASS: first cwd wins
PASS: no cwd returns null

All tests passed.
```

- [ ] **Step 5: Run the parse test**

Run: `pwsh -NoProfile -File tests/Parse.Tests.ps1`
Expected: `Declauttr.ps1 parses cleanly.`

- [ ] **Step 6: Commit**

```bash
git add Declauttr.ps1 tests/Get-SessionCwd.Tests.ps1
git commit -m "Add Get-SessionCwd to recover a session's working directory"
```

---

### Task 3: `Show-MessageBox` + `Invoke-JumpAttempt`

The popup renderer and the jump orchestration. These are `ReadKey`/`Console`-driven, so they're verified by the parse test now and exercised end-to-end in the manual checklist (Task 8) — there is no automated UI test.

**Files:**
- Modify: `Declauttr.ps1` (insert before `Show-SearchPrompt`, ~line 829)

- [ ] **Step 1: Add both functions**

In `Declauttr.ps1`, find the start of `Show-SearchPrompt`:

```powershell
function Show-SearchPrompt {
    param(
        [Parameter(Mandatory)] [int]$ScreenWidth,
        [Parameter(Mandatory)] [int]$ScreenHeight,
        [Parameter(Mandatory)] [int]$BaseTop,
        [string[]]$BackgroundRows = @(),
        [string]$InitialText = '',
        [bool]$InitialCaseSensitive = $false
    )
```

Insert the two new functions *before* it (keep `function Show-SearchPrompt {` and its param block exactly as-is, immediately after the inserted code):

```powershell
function Show-MessageBox {
    # A one-shot centered popup: draws a bordered box with a title, a few lines
    # of body text, and a hint baked into the bottom border, using the same
    # drop-shadow convention as the other overlays. Draws once, waits for a
    # single key, and returns that ConsoleKeyInfo. Callers repaint behind it.
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string[]]$Lines,
        [Parameter(Mandatory)] [string]$Hint,
        [Parameter(Mandatory)] [int]$ScreenWidth,
        [Parameter(Mandatory)] [int]$ScreenHeight,
        [Parameter(Mandatory)] [int]$BaseTop,
        [string[]]$BackgroundRows = @(),
        [string]$AccentColor = 'White'
    )

    $boxW = [Math]::Min(70, $ScreenWidth - 6)
    if ($boxW -lt 40) { $boxW = [Math]::Max(30, $ScreenWidth - 4) }
    $contentW = $boxW - 4

    # One row per line plus a blank pad row above and below.
    $contentH = $Lines.Count + 2
    $boxH = $contentH + 2
    if ($boxH -gt ($ScreenHeight - 3)) {
        $boxH = $ScreenHeight - 3
        $contentH = $boxH - 2
    }

    $boxLeft = [int](($ScreenWidth - $boxW) / 2)
    $boxTop  = $BaseTop + [Math]::Max(0, [int]((($ScreenHeight - 2) - $boxH) / 2))

    $boxBg    = 'DarkGray'
    $borderFg = 'White'
    $hintFg   = 'Black'
    $hintBg   = 'Gray'

    $shadowChar = {
        param([int]$Col, [int]$Row)
        $rel = $Row - $BaseTop
        if ($rel -lt 0 -or $rel -ge $BackgroundRows.Count) { return ' ' }
        $t = $BackgroundRows[$rel]
        if ($Col -lt 0 -or $Col -ge $t.Length) { return ' ' }
        $c = $t[$Col]
        if ([int][char]$c -lt 32) { return ' ' }
        return [string]$c
    }

    # Title bar
    [Console]::SetCursorPosition($boxLeft, $boxTop)
    if ($Title.Length -gt ($boxW - 2)) { $Title = $Title.Substring(0, $boxW - 2) }
    $padBars  = $boxW - 2 - $Title.Length
    $leftBar  = '═' * [int]($padBars / 2)
    $rightBar = '═' * ($padBars - $leftBar.Length)
    Write-Host ('╔' + $leftBar + $Title + $rightBar + '╗') `
        -ForegroundColor $borderFg -BackgroundColor $boxBg -NoNewline

    # Content rows (blank pad, lines, blank pad), clamped/filled to contentH.
    $rendered = @('') + $Lines + @('')
    for ($r = 0; $r -lt $contentH; $r++) {
        [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $r)
        $line = if ($r -lt $rendered.Count) { [string]$rendered[$r] } else { '' }
        if ($line.Length -gt $contentW) { $line = $line.Substring(0, $contentW) }
        Write-Host '║ ' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host $line.PadRight($contentW) -NoNewline -ForegroundColor $AccentColor -BackgroundColor $boxBg
        Write-Host ' ║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
    }

    # Bottom border with embedded hint
    [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $contentH)
    $h = $Hint
    $hintMax = $boxW - 4
    if ($h.Length -gt $hintMax) { $h = $h.Substring(0, $hintMax) }
    $padBars2 = $boxW - 2 - $h.Length
    $leftPad  = '═' * [int]($padBars2 / 2)
    $rightPad = '═' * ($padBars2 - $leftPad.Length)
    Write-Host '╚' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
    Write-Host $leftPad -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
    Write-Host $h -NoNewline -ForegroundColor $hintFg -BackgroundColor $hintBg
    Write-Host $rightPad -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
    Write-Host '╝' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg

    # Drop shadow (same convention as Show-ConfirmDelete / Show-SessionPreview).
    for ($r = 1; $r -le ($contentH + 1); $r++) {
        $sr = $boxTop + $r
        if ($sr -ge $ScreenHeight) { break }
        for ($dc = 0; $dc -lt 2; $dc++) {
            $sc = $boxLeft + $boxW + $dc
            if ($sc -ge $ScreenWidth) { break }
            [Console]::SetCursorPosition($sc, $sr)
            Write-Host (& $shadowChar $sc $sr) -NoNewline -ForegroundColor DarkGray
        }
    }
    $shadowRow = $boxTop + $contentH + 2
    if ($shadowRow -lt $ScreenHeight) {
        $sStart = [Math]::Min($ScreenWidth - 1, $boxLeft + 2)
        $sEnd   = [Math]::Min($ScreenWidth - 1, $boxLeft + $boxW + 1)
        if ($sEnd -ge $sStart) {
            [Console]::SetCursorPosition($sStart, $shadowRow)
            $sb = [System.Text.StringBuilder]::new($sEnd - $sStart + 1)
            for ($sc = $sStart; $sc -le $sEnd; $sc++) {
                [void]$sb.Append((& $shadowChar $sc $shadowRow))
            }
            Write-Host $sb.ToString() -NoNewline -ForegroundColor DarkGray
        }
    }

    try { [Console]::SetCursorPosition(0, [Math]::Min($ScreenHeight - 1, $boxTop + $contentH + 3)) } catch {}

    return [Console]::ReadKey($true)
}

function Invoke-JumpAttempt {
    # Validates that the highlighted session can be resumed and, if so, asks for
    # a single-key confirmation. On confirm it arms the jump by setting
    # $script:JumpSession (which main reads to perform the cd + claude --resume
    # handoff) and returns $true so the caller can exit its loop. Returns $false
    # when the jump can't proceed or the user cancels — the caller stays put.
    param(
        [Parameter(Mandatory)] [object]$Session,
        [Parameter(Mandatory)] [int]$ScreenWidth,
        [Parameter(Mandatory)] [int]$ScreenHeight,
        [Parameter(Mandatory)] [int]$BaseTop,
        [string[]]$BackgroundRows = @()
    )

    $cwd = Get-SessionCwd -Path $Session.Path

    $err = $null
    if (-not $cwd) {
        $err = 'No working directory was recorded for this session, so it cannot be resumed.'
    } elseif (-not (Test-Path -LiteralPath $cwd)) {
        $err = "That session's working directory no longer exists:  $cwd"
    } elseif (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        $err = 'The claude CLI was not found on your PATH, so DeClauttR cannot launch it.'
    }

    if ($err) {
        $wrapped = @(Format-Wrap -Text $err -Width ([Math]::Min(64, $ScreenWidth - 10)))
        [void](Show-MessageBox -Title ' Cannot jump ' -Lines $wrapped `
            -Hint ' press any key to go back ' `
            -ScreenWidth $ScreenWidth -ScreenHeight $ScreenHeight -BaseTop $BaseTop `
            -BackgroundRows $BackgroundRows -AccentColor 'Yellow')
        return $false
    }

    $label = if ($Session.Title) { $Session.Title } else { $Session.Snippet }
    $maxLabel = [Math]::Min(60, $ScreenWidth - 12)
    if ($label.Length -gt $maxLabel) { $label = $label.Substring(0, $maxLabel - 1) + '…' }

    $lines = @(
        'Leave DeClauttR and jump straight back into',
        'this conversation?',
        '',
        "Project:  $($Session.Project)",
        "Title:    $label"
    )

    $key = Show-MessageBox -Title ' Jump to session ' -Lines $lines `
        -Hint ' J again to jump — any other key cancels ' `
        -ScreenWidth $ScreenWidth -ScreenHeight $ScreenHeight -BaseTop $BaseTop `
        -BackgroundRows $BackgroundRows -AccentColor 'White'

    if ($key.Key -eq 'J') {
        $script:JumpSession = [pscustomobject]@{
            SessionId = $Session.Uuid
            Cwd       = $cwd
        }
        return $true
    }
    return $false
}

function Show-SearchPrompt {
    param(
        [Parameter(Mandatory)] [int]$ScreenWidth,
        [Parameter(Mandatory)] [int]$ScreenHeight,
        [Parameter(Mandatory)] [int]$BaseTop,
        [string[]]$BackgroundRows = @(),
        [string]$InitialText = '',
        [bool]$InitialCaseSensitive = $false
    )
```

- [ ] **Step 2: Run the parse test**

Run: `pwsh -NoProfile -File tests/Parse.Tests.ps1`
Expected: `Declauttr.ps1 parses cleanly.`

- [ ] **Step 3: Commit**

```bash
git add Declauttr.ps1
git commit -m "Add Show-MessageBox popup and Invoke-JumpAttempt orchestration"
```

---

### Task 4: Wire the overview picker (`Show-SessionPicker`)

Adds the `J` case, makes the preview's `Spacebar` handler honor a jump armed from inside the preview, and adds `J jump` to both header hints.

**Files:**
- Modify: `Declauttr.ps1` (`Show-SessionPicker`, ~lines 1685–1858)

- [ ] **Step 1: Let the picker exit when the preview arms a jump**

Find (inside the `'Spacebar'` case):

```powershell
                            Show-SessionPreview -Session $activeSessions[$cursor] `
                                -ScreenWidth $width -ScreenHeight $height -BaseTop $origTop `
                                -BackgroundRows $rowBuffer.ToArray() `
                                -Query $searchQuery -CaseSensitive $searchCaseSensitive
                            [Console]::Clear()
```

Replace with:

```powershell
                            Show-SessionPreview -Session $activeSessions[$cursor] `
                                -ScreenWidth $width -ScreenHeight $height -BaseTop $origTop `
                                -BackgroundRows $rowBuffer.ToArray() `
                                -Query $searchQuery -CaseSensitive $searchCaseSensitive
                            if ($script:JumpSession) { return $deletedList }
                            [Console]::Clear()
```

- [ ] **Step 2: Add the `J` case**

Find:

```powershell
                    'X'         {
                        if ($activeSessions.Count -gt 0) {
                            $activeSessions[$cursor].Checked = -not $activeSessions[$cursor].Checked
                        }
                    }
```

Replace with (inserts `J` before `X`):

```powershell
                    'J'         {
                        if ($activeSessions.Count -gt 0) {
                            $jumped = Invoke-JumpAttempt -Session $activeSessions[$cursor] `
                                -ScreenWidth $width -ScreenHeight $height -BaseTop $origTop `
                                -BackgroundRows $rowBuffer.ToArray()
                            if ($jumped) { return $deletedList }
                            # Cancelled or refused: repaint the picker behind the closed popup.
                            [Console]::Clear()
                            $origTop = [Console]::CursorTop
                            for ($i = 0; $i -lt ($viewport + 5); $i++) { Write-Host '' }
                            $marqueeOffset = 0
                            $cursorIdleTimer.Restart()
                        }
                    }
                    'X'         {
                        if ($activeSessions.Count -gt 0) {
                            $activeSessions[$cursor].Checked = -not $activeSessions[$cursor].Checked
                        }
                    }
```

- [ ] **Step 3: Add `J jump` to the unfiltered header hint**

Find:

```powershell
                $header = " ↑↓ NAV   SPACE preview   X toggle   A all   R recommended   F filter   DEL delete   ? about   ESC cancel    [$checkedCount/$($activeSessions.Count) selected]"
```

Replace with:

```powershell
                $header = " ↑↓ NAV   SPACE preview   J jump   X toggle   A all   R recommended   F filter   DEL delete   ? about   ESC cancel    [$checkedCount/$($activeSessions.Count) selected]"
```

- [ ] **Step 4: Add `J jump` to the filtered header hint**

Find:

```powershell
                $headLeft  = " ↑↓ NAV   SPACE preview   X toggle   A all   R recommended  "
```

Replace with:

```powershell
                $headLeft  = " ↑↓ NAV   SPACE preview   J jump   X toggle   A all   R recommended  "
```

- [ ] **Step 5: Run the parse test**

Run: `pwsh -NoProfile -File tests/Parse.Tests.ps1`
Expected: `Declauttr.ps1 parses cleanly.`

- [ ] **Step 6: Commit**

```bash
git add Declauttr.ps1
git commit -m "Wire J jump into the overview picker"
```

---

### Task 5: Wire the preview (`Show-SessionPreview`)

Adds the `J` case to the preview key loop and `J jump` to the preview hint. Passing `-BackgroundRows @()` gives the popup a blank shadow; the preview repaints itself on the next loop iteration, so a cancelled jump leaves no artifacts.

**Files:**
- Modify: `Declauttr.ps1` (`Show-SessionPreview`, ~lines 398 and 452)

- [ ] **Step 1: Add `J jump` to the preview hint**

Find:

```powershell
        $hint = " SPACE/ESC close   ↑↓ PgUp/PgDn scroll   R rename "
```

Replace with:

```powershell
        $hint = " SPACE/ESC close   ↑↓ PgUp/PgDn scroll   R rename   J jump "
```

- [ ] **Step 2: Add the `J` case**

Find:

```powershell
            'Home'      { $scrollTop = 0 }
            'End'       { $scrollTop = $maxScroll }
            'R' {
```

Replace with (inserts `J` between `End` and `R`):

```powershell
            'Home'      { $scrollTop = 0 }
            'End'       { $scrollTop = $maxScroll }
            'J' {
                # Jump straight into this session. On confirm, Invoke-JumpAttempt
                # arms $script:JumpSession; returning here closes the preview, and
                # the picker (which checks $script:JumpSession right after the
                # preview returns) exits too so main can hand off to claude.
                if (Invoke-JumpAttempt -Session $Session `
                        -ScreenWidth $ScreenWidth -ScreenHeight $ScreenHeight -BaseTop $BaseTop) {
                    return
                }
            }
            'R' {
```

- [ ] **Step 3: Run the parse test**

Run: `pwsh -NoProfile -File tests/Parse.Tests.ps1`
Expected: `Declauttr.ps1 parses cleanly.`

- [ ] **Step 4: Commit**

```bash
git add Declauttr.ps1
git commit -m "Wire J jump into the session preview"
```

---

### Task 6: Handoff in `main`

Initializes the signal and performs the `cd` + `claude --resume` after the picker exits, before the delete-summary path.

**Files:**
- Modify: `Declauttr.ps1` (`# --- main ---` section, ~lines 1957 and 1981)

- [ ] **Step 1: Initialize the signal**

Find:

```powershell
if ($MyInvocation.InvocationName -eq '.') { return }

Clear-Host
```

Replace with:

```powershell
if ($MyInvocation.InvocationName -eq '.') { return }

# Set when the user confirms a jump (J) in the picker or preview; main reads it
# below to cd into the session's directory and resume it with claude.
$script:JumpSession = $null

Clear-Host
```

- [ ] **Step 2: Add the handoff**

Find:

```powershell
    $deleted = Show-SessionPicker -Sessions $sessions
    if (-not $deleted -or $deleted.Count -eq 0) { return }
```

Replace with:

```powershell
    $deleted = Show-SessionPicker -Sessions $sessions

    if ($script:JumpSession) {
        Clear-Host
        Write-Host ("Resuming session {0}" -f $script:JumpSession.SessionId) -ForegroundColor DarkGray
        Write-Host ("  in {0}`n" -f $script:JumpSession.Cwd) -ForegroundColor DarkGray
        # Set-Location only affects this pwsh process, so the parent shell's cwd
        # is unchanged after claude exits. claude inherits the terminal.
        Set-Location -LiteralPath $script:JumpSession.Cwd
        & claude --resume $script:JumpSession.SessionId
        return
    }

    if (-not $deleted -or $deleted.Count -eq 0) { return }
```

- [ ] **Step 3: Run the parse test**

Run: `pwsh -NoProfile -File tests/Parse.Tests.ps1`
Expected: `Declauttr.ps1 parses cleanly.`

- [ ] **Step 4: Commit**

```bash
git add Declauttr.ps1
git commit -m "Hand off to claude --resume when a jump is confirmed"
```

---

### Task 7: Documentation

Updates the in-script `.SYNOPSIS` help and the README.

**Files:**
- Modify: `Declauttr.ps1` (`.SYNOPSIS` Keys block, ~line 30)
- Modify: `README.md` (~lines 38, 138, 186)

- [ ] **Step 1: Document `J` in the `.SYNOPSIS` Keys block**

Find:

```
                               row to be flagged as a keeper.
      X                        toggle the current row's checkbox
```

Replace with:

```
                               row to be flagged as a keeper.
      J                        jump into the highlighted session — quit
                               DeClauttR and resume it with
                               `claude --resume`, after changing into the
                               session's original working directory. Press J
                               once for a confirmation popup, then J again to
                               confirm; any other key cancels. Works from the
                               list and from inside the preview.
      X                        toggle the current row's checkbox
```

- [ ] **Step 2: Add the README feature bullet**

Find:

```
- **Rename from the preview**: press **R** inside a session preview to set a
  custom title without leaving DeClauttR — useful for promoting a spot-on
  AI-generated title to a custom one (so the row becomes a `!`-flagged
  keeper) or for relabelling a session into something you'll recognise later.
```

Replace with:

```
- **Rename from the preview**: press **R** inside a session preview to set a
  custom title without leaving DeClauttR — useful for promoting a spot-on
  AI-generated title to a custom one (so the row becomes a `!`-flagged
  keeper) or for relabelling a session into something you'll recognise later.
- **Jump into a session**: press **J** (then **J** again to confirm) to leave
  DeClauttR and drop straight back into the highlighted conversation via
  `claude --resume`, with the working directory restored. Works from the list
  and from inside the preview.
```

- [ ] **Step 3: Add the README key-table row**

Find:

```
| **X** | toggle the current row's checkbox |
```

Replace with:

```
| **J** | jump into the highlighted session: quit DeClauttR and resume it with `claude --resume`, after `cd`-ing into the session's original working directory (recovered from the transcript). Press **J** once for a confirmation popup, then **J** again to confirm — any other key cancels. Also available from inside the preview. If the directory no longer exists or `claude` isn't on your `PATH`, DeClauttR shows a brief notice and stays put. |
| **X** | toggle the current row's checkbox |
```

- [ ] **Step 4: Add the README usage subsection**

Find:

```
#### Content search (F)
```

Replace with:

```
#### Jump into a session (J)

Press **J** on the highlighted row — or **J** inside an open preview — to leave
DeClauttR and resume that conversation. A small popup confirms *"Leave DeClauttR
and jump straight back into this conversation?"*; press **J** again to confirm,
or any other key to cancel. On confirm, DeClauttR changes into the session's
original working directory (read from the transcript's recorded `cwd`, since the
encoded project-folder name can't be decoded reliably) and runs
`claude --resume <id>`, then exits so claude takes over the terminal. When you
quit claude you're back at your shell, in the directory you started from.

If the recorded working directory no longer exists, or the `claude` CLI isn't on
your `PATH`, DeClauttR shows a brief notice and stays open instead of jumping.

#### Content search (F)
```

- [ ] **Step 5: Commit**

```bash
git add Declauttr.ps1 README.md
git commit -m "Document the J jump feature in help text and README"
```

---

### Task 8: Full manual verification

The interactive flows can't be unit-tested (they block on `ReadKey` and draw to the console), so verify them by hand. Use this repo's own sessions as test data.

- [ ] **Step 1: Re-run the automated tests**

```bash
pwsh -NoProfile -File tests/Parse.Tests.ps1
pwsh -NoProfile -File tests/Get-SessionCwd.Tests.ps1
```
Expected: parse clean; all Get-SessionCwd tests pass.

- [ ] **Step 2: Jump from the list**

Run `pwsh -NoProfile -File Declauttr.ps1`. Highlight a session whose project still exists, press `J`, confirm the popup shows the right **Project**/**Title**, press `J` again.
Expected: DeClauttR prints "Resuming session …", and claude opens resumed in that session's directory. Quit claude; confirm your shell's cwd is unchanged.

- [ ] **Step 3: Jump from the preview**

Relaunch, press **Space** on a session to open the preview, press `J`, then `J`.
Expected: same handoff as Step 2.

- [ ] **Step 4: Cancel the confirm**

Relaunch, press `J`, then press a non-`J` key (e.g. `Esc`, then separately try a letter).
Expected: popup closes, you stay in DeClauttR, the list/preview redraws cleanly with no leftover popup artifacts.

- [ ] **Step 5: Refuse on a missing directory**

Temporarily simulate a moved repo: copy a real `.jsonl` whose `cwd` points at a non-existent path into a project dir under `~/.claude/projects/`, or rename a project dir on disk. Highlight that session and press `J`.
Expected: the "Cannot jump" popup explains the directory no longer exists; any key returns to the list; DeClauttR does not exit. (Clean up the test fixture afterward.)

- [ ] **Step 6: Confirm no regressions in existing keys**

In the picker, exercise `Space`, `X`, `A`, `R`, `F`, `Del`/`Esc` to confirm the new `J` case and header text didn't disturb them.
Expected: all behave as before.
