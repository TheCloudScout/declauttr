# Jump Into Session — Design

**Date:** 2026-06-10
**Status:** Approved (pending implementation)

## Summary

Add a "jump into session" feature to DeClauttR. From either the overview list
or the full-screen preview, the user presses `J` to leave DeClauttR and drop
straight back into the highlighted Claude Code conversation. DeClauttR changes
into the session's original working directory and runs `claude --resume <id>`,
then exits so claude takes over the terminal.

Because jumping quits DeClauttR, it is guarded by a deliberate double-tap: the
first `J` opens a confirmation popup, and a second `J` confirms. Any other key
cancels. This makes an accidental jump from a stray keypress effectively
impossible while keeping the action fast.

## Goals

- Jump from the **overview list** (`Show-SessionPicker`) via `J`.
- Jump from the **preview / details view** (`Show-SessionPreview`) via `J`.
- Recover the session's real working directory reliably.
- Never strand the user: if the jump can't work, refuse and stay in DeClauttR.

## Non-goals

- Resuming "the most recent" conversation (`claude --continue`). Jump always
  targets the specific highlighted session.
- Launching claude with extra flags or a custom command. The launch is exactly
  `claude --resume <sessionId>`.
- Preserving or acting on the picker's checkbox selection when jumping. Jumping
  simply abandons the picker.

## Why `J` and a double-tap

`J` is unused in both the picker and the preview key maps. Jumping is
destructive to the DeClauttR session (it quits the app), so unlike navigation it
must not fire on a single accidental press. Unlike deletion — which is
destructive to data and demands typing `yes` — jumping is reversible (the user
can just quit claude and relaunch DeClauttR), so a lighter double-tap confirm is
the right weight.

## Recovering the working directory

`claude --resume <id>` resolves the session within the *current* project, which
Claude Code derives from the current working directory. So DeClauttR must `cd`
into the session's original directory before resuming.

The encoded project-folder name (e.g. `-Users-name-Repos-project`) is **lossy** —
a literal dash in a real folder name is indistinguishable from a path separator,
so it cannot be reliably decoded back to an absolute path.

Instead, every transcript line records a `"cwd"` field with the real absolute
path. The feature reads this directly from the `.jsonl` file. A new pure helper
`Get-SessionCwd -Path` scans the transcript and returns the first `cwd` value it
finds, or `$null` if none is present. It is called lazily — only for the single
session being jumped to — so it adds no cost to the initial directory scan and is
robust regardless of transcript line ordering.

## Architecture

Handoff approach: the key handler records *which* session to jump to and exits
the TUI cleanly; `main` performs the OS-level handoff after the TUI has torn
down. This keeps a single launch site and guarantees the console (cursor
visibility, position) is fully restored — by the picker's existing `finally`
block — before claude takes over the terminal.

Rejected alternatives:
- Launching claude from inside the key handler: duplicates the launch logic in
  both the picker and the preview, and fires before the TUI's `finally` cleanup
  runs, so the console is only half-restored when claude starts.
- Printing the command for the user to run manually: defeats the "jump straight
  in" goal.

## Components

### 1. `Get-SessionCwd -Path` (new, pure)

- Input: path to a session `.jsonl`.
- Streams the file; for each line containing `"cwd"`, parses it and returns the
  first `cwd` value found.
- Returns `$null` if no `cwd` is present (e.g. transcripts with only summary
  lines).
- Pure and side-effect free — the one directly testable unit.

### 2. `Show-ConfirmJump` (new overlay)

Modeled on `Show-ConfirmDelete` / `Show-SearchPrompt`: a centered box drawn over
the current screen with the same border/shadow convention.

- Parameters: `Session`, `ScreenWidth`, `ScreenHeight`, `BaseTop`,
  `BackgroundRows` (for the drop shadow; falls back to blanks when unavailable).
- Content: the target **project** and **title** (or first-message snippet when
  there is no title), the question *"Leave DeClauttR and jump straight back into
  this conversation?"*, and the hint *"Press J again to confirm — any other key
  cancels."*
- Behavior: reads a single key. Returns `$true` only if it is `J`/`j`; returns
  `$false` for anything else (including `Esc`).

### 3. `Show-SessionPicker` — `J` handler (overview)

Added to the existing `switch ($key.Key)` block:

1. Resolve `sessionId = $activeSessions[$cursor].Uuid` and
   `cwd = Get-SessionCwd $activeSessions[$cursor].Path`.
2. Validate (see Error handling). On failure, show a brief error popup and stay.
3. On success, call `Show-ConfirmJump`. If confirmed, set `$script:JumpSession`
   and `return` from the picker. Otherwise redraw and continue.

After any popup, the picker performs its standard post-overlay redraw
(`[Console]::Clear()`, reset `$origTop`, re-emit blank lines, reset marquee).

### 4. `Show-SessionPreview` — `J` handler (details)

Added to the preview's `switch ($key.Key)` block:

1. Resolve `sessionId`/`cwd` from `$Session` the same way.
2. Validate; on failure show an error popup and continue in the preview.
3. On success, call `Show-ConfirmJump`. If confirmed, set `$script:JumpSession`
   and `return` from the preview. The picker, on return from the preview, checks
   `$script:JumpSession` and — if set — `return`s immediately so control reaches
   `main`.

### 5. `main` — the handoff

Checked *before* the existing deleted-summary output:

```powershell
if ($script:JumpSession) {
    Clear-Host
    Set-Location -LiteralPath $script:JumpSession.Cwd
    & claude --resume $script:JumpSession.SessionId
    return
}
```

`Set-Location` affects only this pwsh process, not the parent shell, so the
user's shell cwd is unchanged after claude exits. `& claude` inherits the
terminal; when the user quits claude, the script has already returned and they
land back at their shell prompt.

## Data flow / jump signal

`$script:JumpSession` is a small object set by the `J` handler on confirm:

```powershell
$script:JumpSession = [pscustomobject]@{
    SessionId = <uuid>
    Cwd       = <absolute path>
}
```

It is `$null` until a confirmed jump. The picker and preview both exit once it is
set; `main` reads it and performs the handoff.

## Error handling

The `J` handler validates before offering the confirm popup, so DeClauttR never
exits into a jump that cannot succeed (matches the chosen "refuse and stay"
behavior):

| Condition | Behavior |
|-----------|----------|
| `Get-SessionCwd` returns `$null` | Error popup: "No working directory recorded for this session — can't jump." Stay. |
| Recovered `cwd` fails `Test-Path` | Error popup: "Working directory no longer exists — can't jump." Stay. |
| `claude` not found on `PATH` (`Get-Command claude`) | Error popup: "`claude` CLI not found on PATH — can't jump." Stay. |

The error popup is a minimal dismiss-on-any-key overlay (it may reuse
`Show-ConfirmJump`'s box rendering with a single "press any key" hint, or a
trivial dedicated variant — an implementation detail).

## UI text updates

- Picker header hint: add `J jump` (both the filtered and unfiltered header
  strings).
- Preview hint line: add `J jump`.
- `.SYNOPSIS` help block: document `J` in both views.
- `README.md`: document the jump feature.

## Testing

The repo has no test harness and the interactive flows are `ReadKey`-driven, so:

- **`Get-SessionCwd`** — directly invocable; verify it returns the expected
  absolute path for a real transcript and `$null` for a transcript with no `cwd`.
- **Interactive flows** — manual verification checklist:
  1. From the list, `J` then `J` resumes the highlighted session in its dir.
  2. From the preview, `J` then `J` resumes that session.
  3. `J` then any other key cancels and returns to the list/preview unchanged.
  4. Jumping to a session whose recorded `cwd` was renamed/removed shows the
     refusal popup and stays in DeClauttR.
  5. After quitting the resumed claude session, the shell's cwd is unchanged.
