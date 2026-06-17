# Dynamic Project column width + live resize

**Date:** 2026-06-17
**Status:** Approved

## Problem

The interactive picker pins the **Project** column to a hardcoded width of 40
characters (`'Project'.PadRight(40)` in the column header, and
`$proj.PadRight(40)` in each row). On wide terminals this is too narrow — long
project names get truncated with a leading `…` even though there is plenty of
unused horizontal space. The "Title / first user message" column already
expands to fill whatever's left, so today *all* surplus width flows to the
Title column and none to Project.

We want the Project column to size itself to the project names actually present
(so wide terminals show them in full), and to re-flow the whole list when the
terminal window is resized.

While in here, we also retire two pre-TUI leftovers the author no longer uses:
the `-List` plain-text output and the `-SnippetLength` knob.

## Goals

- Project column grows to fit the longest project name present, without wasting
  space on narrow lists or starving the Title column on wide names.
- The list re-flows live when the terminal window is resized.
- Remove the `-List` feature entirely.
- Remove the `-SnippetLength` parameter; hardcode the existing 400-char default.

## Non-goals

- No changes to the `-About` static screen (kept).
- No changes to the fixed-width popups (preview / confirm / about) — they
  already size off `$ScreenWidth`.
- Resize handling is not unit-tested (needs a live console); verified manually.

## Design

### Part A — Dynamic Project column

**New pure function `Get-ProjectColumnWidth`:**

```
Get-ProjectColumnWidth -Sessions <active session list> -ScreenWidth <int> -> <int>
```

- `longest` = maximum `.Project` string length across the supplied sessions
  (0 if the list is empty).
- Returns `clamp(longest, floor, cap)` where:
  - `floor = 10` — enough for the `Project` header label plus breathing room.
  - `cap = [Math]::Floor($ScreenWidth * 0.5)` — Project never claims more than
    half the screen, guaranteeing the Title column keeps roughly the other half.
- If `cap < floor` (extremely narrow terminal), `floor` wins so the header label
  still renders; row truncation handles the overflow.

This value replaces the literal `40` in two places in `Show-SessionPicker`:

- The column header (currently `('Project'.PadRight(40))`).
- The per-row prefix (currently `$proj.PadRight(40)`, with the
  `if ($proj.Length -gt 40) { $proj = '…' + $proj.Substring(...) }` truncation).
  Truncation logic is preserved but keyed off the computed width instead of 40.

The Title column continues to absorb the remainder
(`$room = $width - $prefix.Length - 1`), so rows still fill edge-to-edge.

### Part B — Stability

The Project column width is computed **once per active list**, from the full
active (post-filter) session set — not per visible row. It is recomputed only
when:

1. the `F` content filter changes the active set, or
2. the terminal window is resized.

This keeps the column from jittering as the user scrolls.

### Part C — Live resize

`Show-SessionPicker` already runs an idle poll loop that sleeps ~25ms between
keypress checks. Before sleeping (or each loop tick), read
`[Console]::WindowWidth` / `[Console]::WindowHeight`. If either differs from the
stored `$width` / `$height`:

- update `$width` / `$height`,
- recompute `$viewport` and the Project column width,
- `[Console]::Clear()`, reset `$origTop = [Console]::CursorTop`, re-emit the
  blank reservation lines (the same dance the preview-close path already uses),
- set `$needRedraw = $true`.

There is no native resize event in .NET Console, so polling the existing loop is
the right (and only) mechanism. `WindowWidth` reads live under pwsh on macOS.

### Part D — Remove `-List`

- Delete the `[switch]$List` parameter.
- Delete the `Write-SessionsList` function.
- Delete the `if ($List) { Write-SessionsList ... } else { ... }` branch in the
  main block — collapse to the picker path (keep the empty-session guard).
- Comment-based help: drop `.PARAMETER List`, the `./Declauttr.ps1 -List`
  example, and the "Use -List to print a plain, non-interactive listing
  instead." line.
- README: remove the List-mode bullet, the `-List` example, the "Pass `-List`
  if you want plain text output instead." line, and the
  `screenshot-list-view.jpg` reference. `img/screenshot-list-view.jpg` becomes
  orphaned — left on disk (not deleted) unless the author decides otherwise.

### Part E — Remove `-SnippetLength`

- Delete the `[int]$SnippetLength = 400` parameter and its `.PARAMETER` help.
- `Get-AllSessions` already defaults `SnippetMax = 400`, so drop the
  `-SnippetMax $SnippetLength` argument at the call site and let that default
  apply.
- README: remove the `-SnippetLength 250` example and surrounding text.

## Testing

- New `tests/Get-ProjectColumnWidth.Tests.ps1`, following the existing
  dependency-free dot-source pattern (`. "$PSScriptRoot/../Declauttr.ps1"` +
  `Assert-Equal`):
  - all-short names → `floor` (10).
  - one long name on a wide screen → exact fit (`longest`).
  - a very long name → capped at `floor(width * 0.5)`.
  - empty list → `floor`.
- `tests/Parse.Tests.ps1` (syntax guard) must still pass after the edits.
- Live resize verified manually by dragging the terminal window.

## Risks

- `[Console]::WindowWidth` behavior varies by terminal; polling is best-effort.
  Worst case the list simply doesn't re-flow until the next redraw — no crash.
- Removing `-SnippetLength` is a (minor) breaking CLI change; acceptable since
  the author confirmed it's unused.
