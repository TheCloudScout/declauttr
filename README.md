# declauttr

A small PowerShell utility to **list and prune Claude Code sessions** that pile up
under `~/.claude/projects/` and clutter the `claude --resume` picker.

`/clear` inside a Claude session only wipes the in-memory context — it does
**not** delete the on-disk transcript, so old sessions keep showing up in the
resume list forever. `declauttr` lets you see what's there (with the same
titles Claude shows you in `--resume`) and bulk-delete the ones you don't
want anymore.

Cross-platform: works on **macOS, Linux, and Windows** under PowerShell 7+ (`pwsh`).

## Features

- Walks every project directory under `~/.claude/projects/` and lists each session with:
  - timestamp
  - UUID (the filename — same one `claude --resume` shows internally)
  - size on disk
  - session **title** (custom title set via `/title`, or the AI-generated one)
  - first real user prompt, word-wrapped to the terminal width
- Two display modes:
  - **List mode** (default) — grouped per project, scroll-friendly text output.
  - **Interactive mode** (`-Interactive`) — full-screen checkbox TUI with arrow-key
    navigation, viewport scrolling, and a confirmation step before any file is touched.
- **Auto-recommends** likely-disposable sessions and pre-checks them, including:
  - sessions with no real user message (empty/aborted starts)
  - sessions under 20 KB
  - one-word prompts like `resume`, `config`, `exit`, `help`, `init`
  - prompts shorter than 15 characters
- Safe by default: nothing is deleted without an explicit, case-sensitive `YES` confirmation.

## Requirements

- PowerShell 7 or later (`pwsh`). The script does not run on Windows PowerShell 5.1.
- A terminal that supports ANSI cursor positioning for the interactive picker
  (Windows Terminal, iTerm2, macOS Terminal, most Linux terminals — all fine).

## Install

Clone the repo and (optionally) symlink the script into your `PATH`:

```bash
git clone https://github.com/TheCloudScout/declauttr.git
cd declauttr
chmod +x Declauttr.ps1

# optional: make it callable from anywhere as `declauttr`
ln -s "$PWD/Declauttr.ps1" /usr/local/bin/declauttr
```

Or just run it from wherever you cloned it:

```powershell
pwsh ./Declauttr.ps1
```

### Optional: a shell alias

Drop this in your `$PROFILE` (`pwsh -c 'code $PROFILE'`) so you can call it
from any directory:

```powershell
function declauttr { & "$HOME/path/to/declauttr/Declauttr.ps1" @args }
```

## Usage

### List every session, grouped per project

```powershell
./Declauttr.ps1
```

Output looks like:

```
=== -Users-koos-Repos-Wortell-Usecases (7 sessions) ===
  2026-05-26 15:49  f870f835-0044-4439-b510-e0960748d4b1   2,139.0 KB
     Heijmans SAP-Protect
     I recently onboarded SAP logs for our customer Heijmans into Sentinel.
     We're using SecurityBridge as an intermediary between SAP and Sentinel.
     …
  2026-05-26 15:34  a09f73dc-e060-4a6b-b741-51100cb08a5b      17.2 KB
     (no user message found)
```

### Filter to one project (substring match)

```powershell
./Declauttr.ps1 -Project Wortell
```

### Interactive picker

```powershell
./Declauttr.ps1 -Interactive
```

| Key | Action |
|---|---|
| ↑ / ↓ | move cursor |
| Home / End | jump to top / bottom |
| PgUp / PgDn | page up / down |
| **Space** | toggle the current row |
| **A** | toggle all (check all, or uncheck if everything was checked) |
| **R** | re-apply the "recommended for removal" selection |
| **Enter** | confirm — prints the list and waits for you to type `YES` |
| **Esc** / **Q** | cancel, nothing is touched |

Rows marked with `!` in front of the checkbox and rendered in yellow are the
ones declauttr recommends pruning. They start pre-checked, so for the common
case you can just review and press **Enter**.

### Tune the snippet length

```powershell
./Declauttr.ps1 -SnippetLength 250
```

Affects how much of the first user message is shown in list mode (interactive
mode always uses the title, falling back to a truncated snippet).

### Point at a different Claude root (rare)

```powershell
./Declauttr.ps1 -ProjectsRoot "/some/other/path/.claude/projects"
```

## How it works

Each Claude Code session is stored as a JSONL transcript at:

```
~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl
```

The script streams each file with `[System.IO.File]::ReadLines`, fast-filters
lines with `String.Contains`, and only parses the few entry types it needs:

| Entry type | What declauttr uses it for |
|---|---|
| `user` | first real user message → snippet |
| `ai-title` | last value seen → fallback title |
| `custom-title` | last value seen → preferred title (overrides `ai-title`) |

System messages, slash-command echoes (`<command-name>…`), and local-command
caveats are skipped so the snippet always reflects the first **real** thing
you asked Claude.

Deletion is a plain `Remove-Item -Force` on the matching `.jsonl` file —
the same as if you'd deleted it by hand. Claude Code rebuilds its resume
list from the directory contents on next launch, so the deleted sessions
disappear immediately.

## Safety

- The interactive picker never deletes anything until you type `YES`
  (case-sensitive) at the confirmation prompt.
- The script never touches `~/.claude/projects/*/memory/` or any subdirectory
  that isn't a `.jsonl` file — your auto-memory store is left alone.
- Output is read-only until the final confirmation step. Esc/Q at any point
  exits cleanly.

## License

MIT.
