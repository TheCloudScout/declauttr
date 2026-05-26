#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Declauttr — list and prune Claude Code sessions with an interactive TUI.

.DESCRIPTION
    Scans ~/.claude/projects/<project>/*.jsonl, parses each transcript, and
    prints UUID + timestamp + size + session title + first-user-message preview.

    With -Interactive, opens a checkbox picker:
      ↑/↓        navigate
      Space      toggle current row
      A          toggle all
      R          re-apply 'recommended for removal' selection
      Enter      delete the checked sessions (after confirmation)
      Esc / Q    cancel without deleting

    Sessions that look empty or trivial (no user message, very small, or just
    a one-word prompt like "resume") are pre-checked and highlighted.

    Works on Windows, macOS, and Linux under PowerShell 7+ (pwsh).

.PARAMETER SnippetLength
    Maximum characters of the user-message preview in non-interactive mode.
    Default 400. Wrapped to terminal width.

.PARAMETER ProjectsRoot
    Override the Claude projects directory. Defaults to ~/.claude/projects.

.PARAMETER Project
    Filter to project directory names matching this substring.

.PARAMETER Interactive
    Launch the interactive checkbox picker instead of printing the list.

.EXAMPLE
    ./Declauttr.ps1

.EXAMPLE
    ./Declauttr.ps1 -Interactive

.EXAMPLE
    ./Declauttr.ps1 -Project Wortell -Interactive
#>

[CmdletBinding()]
param(
    [int]$SnippetLength = 400,
    [string]$ProjectsRoot = (Join-Path $HOME '.claude' 'projects'),
    [string]$Project,
    [switch]$Interactive
)

function Get-SessionMetadata {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [int]$MaxLength = 400
    )

    $snippet     = $null
    $aiTitle     = $null
    $customTitle = $null

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Fast text pre-filter — parse only lines that might contain what we need.
        $isUser   = (-not $snippet) -and $line.Contains('"type":"user"')
        $isAi     = $line.Contains('"type":"ai-title"')
        $isCustom = $line.Contains('"type":"custom-title"')
        if (-not ($isUser -or $isAi -or $isCustom)) { continue }

        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }

        if ($isAi     -and $obj.type -eq 'ai-title'     -and $obj.aiTitle)     { $aiTitle     = $obj.aiTitle }
        if ($isCustom -and $obj.type -eq 'custom-title' -and $obj.customTitle) { $customTitle = $obj.customTitle }

        if ($isUser -and -not $snippet -and $obj.type -eq 'user') {
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

    return [pscustomobject]@{
        Snippet = if ($snippet)     { $snippet }     else { '(no user message found)' }
        Title   = if ($customTitle) { $customTitle } elseif ($aiTitle) { $aiTitle } else { $null }
    }
}

function Format-Wrap {
    param(
        [Parameter(Mandatory)] [string]$Text,
        [Parameter(Mandatory)] [int]$Width,
        [string]$Indent = ''
    )

    if ($Width -lt 20) { $Width = 20 }
    $lines = [System.Collections.Generic.List[string]]::new()
    $words = $Text -split ' '
    $current = $Indent

    foreach ($w in $words) {
        if ($current.Length -eq $Indent.Length) {
            $current += $w
        } elseif (($current.Length + 1 + $w.Length) -le $Width) {
            $current += ' ' + $w
        } else {
            $lines.Add($current)
            $current = $Indent + $w
        }
    }
    if ($current.Length -gt $Indent.Length) { $lines.Add($current) }
    return $lines
}

function Test-RecommendRemoval {
    param(
        [Parameter(Mandatory)] [long]$SizeBytes,
        [Parameter(Mandatory)] [string]$Snippet
    )

    if ($Snippet -eq '(no user message found)') { return $true }
    if ($SizeBytes -lt 20KB)                    { return $true }

    $trimmed = $Snippet.Trim().ToLower().TrimEnd('.', '!', '?', '…')
    $trivial = @('resume', 'config', 'exit', 'quit', 'clear', 'help', 'init', 'test')
    if ($trivial -contains $trimmed)            { return $true }
    if ($trimmed.Length -lt 15)                 { return $true }

    return $false
}

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
        foreach ($f in $files) {
            $meta      = Get-SessionMetadata -Path $f.FullName -MaxLength $SnippetMax
            $recommend = Test-RecommendRemoval -SizeBytes $f.Length -Snippet $meta.Snippet
            $result.Add([pscustomobject]@{
                Project        = $proj.Name
                Path           = $f.FullName
                Uuid           = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                Timestamp      = $f.LastWriteTime
                SizeBytes      = $f.Length
                SizeFormatted  = '{0,8:N1} KB' -f ($f.Length / 1KB)
                Title          = $meta.Title
                Snippet        = $meta.Snippet
                Recommended    = $recommend
                Checked        = $recommend
            })
        }
    }
    return $result
}

function Write-SessionsList {
    param(
        [Parameter(Mandatory)] [System.Collections.IList]$Sessions,
        [int]$SnippetMax = 400
    )

    $consoleWidth = try { [Console]::WindowWidth } catch { 100 }
    if (-not $consoleWidth -or $consoleWidth -lt 40) { $consoleWidth = 100 }
    $wrapWidth = $consoleWidth - 1
    $indent    = '     '

    $byProject = $Sessions | Group-Object Project | Sort-Object Name
    $totalBytes = 0L

    foreach ($g in $byProject) {
        $totalBytes += ($g.Group | Measure-Object SizeBytes -Sum).Sum
        Write-Host ''
        Write-Host "=== $($g.Name) ($($g.Count) sessions) ===" -ForegroundColor Cyan
        foreach ($s in $g.Group) {
            $ts = $s.Timestamp.ToString('yyyy-MM-dd HH:mm')
            Write-Host ("  {0}  " -f $ts) -NoNewline
            Write-Host $s.Uuid -ForegroundColor Yellow -NoNewline
            Write-Host "  $($s.SizeFormatted)"
            if ($s.Title) {
                Write-Host ($indent + $s.Title) -ForegroundColor White
            }
            foreach ($wrapped in (Format-Wrap -Text $s.Snippet -Width $wrapWidth -Indent $indent)) {
                Write-Host $wrapped -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ''
    Write-Host ("Total: {0} sessions, {1:N1} MB" -f $Sessions.Count, ($totalBytes / 1MB)) -ForegroundColor Green
}

function Show-SessionPicker {
    param(
        [Parameter(Mandatory)] [System.Collections.IList]$Sessions
    )

    if ($Sessions.Count -eq 0) {
        Write-Host 'No sessions to show.' -ForegroundColor Yellow
        return @()
    }

    $width  = try { [Console]::WindowWidth }  catch { 120 }
    $height = try { [Console]::WindowHeight } catch { 30 }
    if (-not $width  -or $width  -lt 60) { $width  = 120 }
    if (-not $height -or $height -lt 10) { $height = 30 }

    $reserved = 5
    $viewport = [Math]::Min($Sessions.Count, [Math]::Max(5, $height - $reserved))

    $cursor = 0
    $top    = 0

    [Console]::CursorVisible = $false
    $origTop = [Console]::CursorTop

    # Reserve screen space by emitting blank lines, so SetCursorPosition stays valid.
    for ($i = 0; $i -lt ($viewport + 3); $i++) { Write-Host '' }

    try {
        while ($true) {
            if ($cursor -lt $top)              { $top = $cursor }
            if ($cursor -ge $top + $viewport)  { $top = $cursor - $viewport + 1 }

            [Console]::SetCursorPosition(0, $origTop)

            $checkedCount = @($Sessions | Where-Object Checked).Count
            $header = " ↑↓ nav   Space toggle   A all   R recommended   Enter delete   Esc cancel    [$checkedCount/$($Sessions.Count) selected]"
            if ($header.Length -gt $width) { $header = $header.Substring(0, $width) }
            Write-Host $header.PadRight($width) -ForegroundColor Black -BackgroundColor Cyan

            for ($i = 0; $i -lt $viewport; $i++) {
                $idx = $top + $i
                if ($idx -ge $Sessions.Count) {
                    Write-Host (' ' * $width)
                    continue
                }
                $s    = $Sessions[$idx]
                $mark = if ($s.Checked) { '[x]' } else { '[ ]' }
                $flag = if ($s.Recommended) { '!' } else { ' ' }
                $ts   = $s.Timestamp.ToString('yyyy-MM-dd HH:mm')
                $proj = $s.Project
                if ($proj.Length -gt 40) { $proj = '…' + $proj.Substring($proj.Length - 39) }
                $prefix = "$flag $mark  $ts  $($s.SizeFormatted)  $($proj.PadRight(40))  "
                $room   = [Math]::Max(10, $width - $prefix.Length - 1)
                $desc   = if ($s.Title) { $s.Title } else { $s.Snippet }
                if ($desc.Length -gt $room) { $desc = $desc.Substring(0, $room - 1) + '…' }
                $line = ($prefix + $desc).PadRight($width)
                if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }

                if ($idx -eq $cursor) {
                    Write-Host $line -ForegroundColor White -BackgroundColor DarkBlue
                } elseif ($s.Recommended) {
                    Write-Host $line -ForegroundColor DarkYellow
                } else {
                    Write-Host $line
                }
            }

            $footer = " ! = recommended for removal (pre-checked). Selected items will be permanently deleted."
            if ($footer.Length -gt $width) { $footer = $footer.Substring(0, $width) }
            Write-Host $footer.PadRight($width) -ForegroundColor DarkGray

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { if ($cursor -gt 0)                   { $cursor-- } }
                'DownArrow' { if ($cursor -lt $Sessions.Count - 1) { $cursor++ } }
                'Home'      { $cursor = 0 }
                'End'       { $cursor = $Sessions.Count - 1 }
                'PageUp'    { $cursor = [Math]::Max(0, $cursor - $viewport) }
                'PageDown'  { $cursor = [Math]::Min($Sessions.Count - 1, $cursor + $viewport) }
                'Spacebar'  { $Sessions[$cursor].Checked = -not $Sessions[$cursor].Checked }
                'A'         {
                    $anyUnchecked = @($Sessions | Where-Object { -not $_.Checked }).Count -gt 0
                    foreach ($s in $Sessions) { $s.Checked = $anyUnchecked }
                }
                'R'         {
                    foreach ($s in $Sessions) { $s.Checked = $s.Recommended }
                }
                'Enter'     { return @($Sessions | Where-Object Checked) }
                'Escape'    { return @() }
                'Q'         { return @() }
            }
        }
    } finally {
        [Console]::CursorVisible = $true
        try { [Console]::SetCursorPosition(0, $origTop + $viewport + 2) } catch {}
        Write-Host ''
    }
}

# --- main ---

Clear-Host

if (-not (Test-Path $ProjectsRoot)) {
    Write-Error "Projects directory not found: $ProjectsRoot"
    exit 1
}

$sessions = Get-AllSessions -Root $ProjectsRoot -ProjectFilter $Project -SnippetMax $SnippetLength

if ($Interactive) {
    if ($sessions.Count -eq 0) {
        Write-Host 'No sessions found.' -ForegroundColor Yellow
        return
    }

    $picked = Show-SessionPicker -Sessions $sessions
    if (-not $picked -or $picked.Count -eq 0) {
        Write-Host 'Nothing selected. Aborted.' -ForegroundColor Yellow
        return
    }

    $totalKb = ($picked | Measure-Object SizeBytes -Sum).Sum / 1KB
    Write-Host ''
    Write-Host "About to permanently delete $($picked.Count) session(s) ($([Math]::Round($totalKb,1)) KB):" -ForegroundColor Red
    foreach ($s in $picked) {
        Write-Host ("  {0}  {1}" -f $s.Uuid, $s.Project) -ForegroundColor DarkGray
    }
    Write-Host ''
    $confirm = Read-Host 'Type YES to confirm'
    if ($confirm -ceq 'YES') {
        foreach ($s in $picked) {
            try {
                Remove-Item -LiteralPath $s.Path -Force -ErrorAction Stop
                Write-Host "  deleted $($s.Uuid)" -ForegroundColor Green
            } catch {
                Write-Host "  FAILED  $($s.Uuid): $_" -ForegroundColor Red
            }
        }
    } else {
        Write-Host 'Aborted, nothing deleted.' -ForegroundColor Yellow
    }
} else {
    Write-SessionsList -Sessions $sessions -SnippetMax $SnippetLength
}
