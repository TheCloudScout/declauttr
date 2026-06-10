#!/usr/bin/env pwsh
<#
.SYNOPSIS
    DeClauttR — list and prune Claude Code sessions with an interactive TUI.

.DESCRIPTION
    Scans ~/.claude/projects/<project>/*.jsonl, parses each transcript, and
    opens an interactive checkbox picker by default. The picker shows one
    row per session with timestamp, size, project, and either the session
    title (custom title from /title or the AI-generated one) or the first
    real user message as a fallback.

    Keys:
      ↑/↓ Home/End PgUp/PgDn   navigate
      Space                    open a full-screen preview of the highlighted
                               session (session details pinned at top, body
                               scrolls; Space/Esc closes). When a content
                               filter is active, every match of the search
                               string is highlighted with a yellow background.
                               Inside the preview, press R to rename the
                               session: the existing title is shown dim as
                               a placeholder, the first keypress clears it
                               for typing (←/→/Home/End/Backspace/Delete to
                               edit, max 120 chars), Enter saves and closes
                               the preview, Esc cancels. Pressing Enter on
                               the untouched placeholder promotes the
                               existing title (AI-generated or otherwise)
                               to a custom title — handy when the AI title
                               is already spot-on and you just want the
                               row to be flagged as a keeper.
      J                        jump into the highlighted session — quit
                               DeClauttR and resume it with
                               `claude --resume`, after changing into the
                               session's original working directory. Press J
                               once for a confirmation popup, then J again to
                               confirm; any other key cancels. Works from the
                               list and from inside the preview.
      X                        toggle the current row's checkbox
      A                        toggle all rows
      R                        re-apply the "recommended for removal"
                               selection
      F                        toggle a content-search filter — opens a
                               prompt for a substring, then narrows the list
                               to sessions whose transcript contains that
                               string. Case-insensitive by default; press
                               Tab inside the prompt to flip the
                               case-sensitive checkbox. Press F again on the
                               picker to clear the filter.
      Del / Backspace          open the delete-confirmation overlay for the
                               checked rows; type yes (case-insensitive) +
                               Enter to commit, Esc to back out
      ?                        about / help overlay (logo + auto-scrolling
                               description, any key to close)
      Esc / Q                  cancel and exit, nothing is touched

    Visual cues:
      * Sessions that look empty or trivial (no user message, very small, or
        just a one-word prompt like "resume") are pre-checked and rendered
        yellow.
      * Sessions with a user-assigned custom title are rendered cyan and
        marked with a leading "!" to flag likely keepers.
      * When the highlighted row's title or first user message is too long
        to fit the column, sitting on it for ~1 second marquees the full
        text horizontally.
      * Yellow `↑` / `↓` indicators appear at the top-left and bottom-left
        of the viewport when there are rows above or below it.

    Use -List to print a plain, non-interactive listing instead.

    Works on Windows, macOS, and Linux under PowerShell 7+ (pwsh).

.PARAMETER SnippetLength
    Maximum characters of the user-message preview in list mode.
    Default 400. Wrapped to terminal width.

.PARAMETER ProjectsRoot
    Override the Claude projects directory. Defaults to ~/.claude/projects.

.PARAMETER Project
    Filter to project directory names matching this substring.

.PARAMETER List
    Print a plain listing of sessions instead of opening the interactive picker.

.PARAMETER About
    Render a clean, static About screen (logo + tagline + credits) and exit.
    Intended for taking screenshots — no title bar text, no "press any key"
    hint, no scrolling.

.EXAMPLE
    ./Declauttr.ps1

.EXAMPLE
    ./Declauttr.ps1 -List

.EXAMPLE
    ./Declauttr.ps1 -Project myrepo
#>

[CmdletBinding()]
param(
    [int]$SnippetLength = 400,
    [string]$ProjectsRoot = (Join-Path $HOME '.claude' 'projects'),
    [string]$Project,
    [switch]$List,
    [switch]$About
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
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if (-not $line.Contains('"cwd"')) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }
        if ($obj.cwd) { return [string]$obj.cwd }
    }
    return $null
}

function Set-SessionCustomTitle {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Title
    )

    # Rewrites the JSONL transcript in place: strips any pre-existing
    # custom-title lines, then appends a fresh one. Matches how
    # Get-SessionMetadata reads — "last custom-title wins" — but keeps the
    # file tidy by leaving exactly one.
    $lines = [System.IO.File]::ReadAllLines($Path)
    $kept  = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line.Contains('"type":"custom-title"')) { continue }
        $kept.Add($line)
    }

    $obj  = [pscustomobject]@{ type = 'custom-title'; customTitle = $Title }
    $json = $obj | ConvertTo-Json -Compress
    $kept.Add($json)

    $temp     = $Path + '.tmp'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($temp, $kept, $utf8NoBom)
    Move-Item -LiteralPath $temp -Destination $Path -Force
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

function Get-SessionPreviewContent {
    param(
        [Parameter(Mandatory)] [object]$Session,
        [Parameter(Mandatory)] [int]$Width
    )

    $w = [Math]::Max(20, $Width)
    $head = [System.Collections.Generic.List[string]]::new()
    $body = [System.Collections.Generic.List[string]]::new()

    $head.Add("Project:  $($Session.Project)")
    $head.Add("UUID:     $($Session.Uuid)")
    # Always emit a Title row so the rename overlay has a predictable
    # anchor, even for sessions that have no AI/custom title yet.
    $titleText = if ($Session.Title) { $Session.Title } else { '' }
    $head.Add("Title:    $titleText")
    $head.Add("When:     $($Session.Timestamp.ToString('yyyy-MM-dd HH:mm'))   Size: $($Session.SizeFormatted.Trim())")
    $head.Add('─' * $w)

    $count = 0
    try {
        foreach ($line in [System.IO.File]::ReadLines($Session.Path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $isUser   = $line.Contains('"type":"user"')
            $isAssist = $line.Contains('"type":"assistant"')
            if (-not ($isUser -or $isAssist)) { continue }

            try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }

            $role = $null
            if     ($obj.type -eq 'user')      { $role = 'USER' }
            elseif ($obj.type -eq 'assistant') { $role = 'AI'   }
            if (-not $role) { continue }

            $content = $obj.message.content
            $text = $null
            if ($content -is [string]) {
                $text = $content
            } elseif ($content) {
                $parts = @()
                foreach ($c in $content) {
                    if ($c.type -eq 'text' -and $c.text) { $parts += $c.text }
                }
                if ($parts.Count -gt 0) { $text = $parts -join "`n" }
            }
            if (-not $text) { continue }
            if ($text.StartsWith('<local-command') -or $text.StartsWith('<command-name>')) { continue }

            if ($count -gt 0) { $body.Add('') }
            $body.Add("${role}:")
            foreach ($paragraph in ($text -split "`n")) {
                $p = $paragraph.TrimEnd()
                if (-not $p) { $body.Add(''); continue }
                foreach ($wrapped in (Format-Wrap -Text $p -Width $w)) {
                    $body.Add($wrapped)
                }
            }
            $count++
        }
    } catch {
        $body.Add('(could not read session file: ' + $_.Exception.Message + ')')
    }

    if ($count -eq 0) {
        $body.Add('(no user or assistant messages found)')
    }
    return [pscustomobject]@{ Header = $head; Body = $body }
}

function Show-SessionPreview {
    param(
        [Parameter(Mandatory)] [object]$Session,
        [Parameter(Mandatory)] [int]$ScreenWidth,
        [Parameter(Mandatory)] [int]$ScreenHeight,
        [Parameter(Mandatory)] [int]$BaseTop,
        [string[]]$BackgroundRows = @(),
        [string]$Query = '',
        [bool]$CaseSensitive = $false
    )

    $boxW = $ScreenWidth - 6
    $boxH = [Math]::Max(15, [int]($ScreenHeight * 0.70))
    if ($boxW -lt 60) { $boxW = [Math]::Max(40, $ScreenWidth - 4) }
    if ($boxW -gt ($ScreenWidth - 4))  { $boxW = $ScreenWidth - 4 }
    if ($boxH -gt ($ScreenHeight - 3)) { $boxH = $ScreenHeight - 3 }

    $contentW = $boxW - 4
    $contentH = $boxH - 2   # top border + bottom border

    $boxLeft = [int](($ScreenWidth - $boxW) / 2)
    $boxTop  = $BaseTop + [Math]::Max(0, [int]((($ScreenHeight - 2) - $boxH) / 2))

    $data = Get-SessionPreviewContent -Session $Session -Width $contentW
    $head = $data.Header
    $body = $data.Body

    $headerH = [Math]::Min($head.Count, [Math]::Max(0, $contentH - 3))
    $bodyH   = [Math]::Max(1, $contentH - $headerH)
    $maxScroll = [Math]::Max(0, $body.Count - $bodyH)
    $scrollTop = 0

    $boxFg     = 'White'
    $boxBg     = 'DarkGray'
    $borderFg  = 'White'
    $headFg    = 'Yellow'
    $hintFg    = 'Black'
    $hintBg    = 'Gray'

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

    # Writes one row of content, highlighting any matches of $Query with a
    # yellow background (black foreground) and padding the rest to $Width
    # using the supplied $Fg/$Bg.
    $cmp = if ($CaseSensitive) {
        [System.StringComparison]::Ordinal
    } else {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    $writeHighlighted = {
        param([string]$Text, [int]$Width, [string]$Fg, [string]$Bg)
        if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, $Width) }
        if (-not $Query) {
            Write-Host $Text.PadRight($Width) -NoNewline -ForegroundColor $Fg -BackgroundColor $Bg
            return
        }
        $pos     = 0
        $written = 0
        while ($pos -lt $Text.Length) {
            $hit = $Text.IndexOf($Query, $pos, $cmp)
            if ($hit -lt 0 -or ($hit + $Query.Length) -gt $Text.Length) {
                $rest = $Text.Substring($pos)
                Write-Host $rest -NoNewline -ForegroundColor $Fg -BackgroundColor $Bg
                $written += $rest.Length
                break
            }
            if ($hit -gt $pos) {
                $pre = $Text.Substring($pos, $hit - $pos)
                Write-Host $pre -NoNewline -ForegroundColor $Fg -BackgroundColor $Bg
                $written += $pre.Length
            }
            $match = $Text.Substring($hit, $Query.Length)
            Write-Host $match -NoNewline -ForegroundColor Black -BackgroundColor Yellow
            $written += $match.Length
            $pos = $hit + $Query.Length
        }
        if ($written -lt $Width) {
            Write-Host (' ' * ($Width - $written)) -NoNewline -ForegroundColor $Fg -BackgroundColor $Bg
        }
    }

    while ($true) {
        # Title bar
        [Console]::SetCursorPosition($boxLeft, $boxTop)
        $title    = ' Session preview '
        $leftBar  = '═' * [int](($boxW - 2 - $title.Length) / 2)
        $rightBar = '═' * ($boxW - 2 - $title.Length - $leftBar.Length)
        Write-Host ('╔' + $leftBar + $title + $rightBar + '╗') `
            -ForegroundColor $borderFg -BackgroundColor $boxBg -NoNewline

        # Pinned header block
        for ($r = 0; $r -lt $headerH; $r++) {
            [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $r)
            $line = if ($r -lt $head.Count) { $head[$r] } else { '' }
            Write-Host '║ ' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
            & $writeHighlighted $line $contentW $headFg $boxBg
            Write-Host ' ║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        }

        # Scrollable body
        for ($r = 0; $r -lt $bodyH; $r++) {
            [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $headerH + $r)
            $idx = $scrollTop + $r
            $line = if ($idx -lt $body.Count) { $body[$idx] } else { '' }
            Write-Host '║ ' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
            & $writeHighlighted $line $contentW $boxFg $boxBg
            Write-Host ' ║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        }

        # Bottom border with embedded hint
        [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $contentH)
        $hint = " SPACE/ESC close   ↑↓ PgUp/PgDn scroll   R rename   J jump "
        if ($body.Count -gt $bodyH) {
            $shown = [Math]::Min($body.Count, $scrollTop + $bodyH)
            $hint += "[$($scrollTop + 1)-$shown/$($body.Count)] "
        }
        $hintMax = $boxW - 4
        if ($hint.Length -gt $hintMax) { $hint = $hint.Substring(0, $hintMax) }
        $padBars = ($boxW - 2 - $hint.Length)
        $leftPad  = '═' * [int]($padBars / 2)
        $rightPad = '═' * ($padBars - $leftPad.Length)
        Write-Host '╚' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host $leftPad -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host $hint -NoNewline -ForegroundColor $hintFg -BackgroundColor $hintBg
        Write-Host $rightPad -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host '╝' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg

        # Dynamic drop shadow: dim the underlying picker text in DarkGray.
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

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'Spacebar'  { return }
            'Escape'    { return }
            'Q'         { return }
            'Enter'     { return }
            'UpArrow'   { if ($scrollTop -gt 0)              { $scrollTop-- } }
            'DownArrow' { if ($scrollTop -lt $maxScroll)     { $scrollTop++ } }
            'PageUp'    { $scrollTop = [Math]::Max(0, $scrollTop - $bodyH) }
            'PageDown'  { $scrollTop = [Math]::Min($maxScroll, $scrollTop + $bodyH) }
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
                # Inline rename: edits the Title row in place. The current
                # title is shown as a dim placeholder; the first keypress
                # wipes it and switches to a black input field. ENTER
                # commits and closes the preview so the caller can refresh
                # the list; ESC leaves everything untouched.
                $titleRowIdx = -1
                for ($i = 0; $i -lt $head.Count; $i++) {
                    if ($head[$i].StartsWith('Title:')) { $titleRowIdx = $i; break }
                }
                if ($titleRowIdx -lt 0 -or $titleRowIdx -ge $headerH) { break }

                $titlePrefix = 'Title:    '
                $prefixLen   = $titlePrefix.Length
                $fieldWidth  = [Math]::Min(120, [Math]::Max(10, $contentW - $prefixLen))
                $maxLen      = [Math]::Min(120, $fieldWidth)
                $current     = if ($Session.Title) { $Session.Title } else { '' }
                $buffer      = ''
                $cursorPos   = 0
                $cleared     = $false
                $rowY        = $boxTop + 1 + $titleRowIdx
                $fieldX      = $boxLeft + 2 + $prefixLen

                # [Console]::CursorVisible getter throws on macOS/Linux;
                # only the setter is portable. The picker hides the cursor
                # while the list is active, so restore to hidden on exit.
                try { [Console]::CursorVisible = $true } catch {}

                $renameDone = $false
                $renameSaved = $false
                while (-not $renameDone) {
                    # Redraw the Title row with placeholder or input field.
                    [Console]::SetCursorPosition($boxLeft, $rowY)
                    Write-Host '║ ' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
                    Write-Host $titlePrefix -NoNewline -ForegroundColor $headFg -BackgroundColor $boxBg
                    if (-not $cleared) {
                        $display = $current
                        if ($display.Length -gt $fieldWidth) { $display = $display.Substring(0, $fieldWidth) }
                        Write-Host $display.PadRight($fieldWidth) -NoNewline `
                            -ForegroundColor DarkYellow -BackgroundColor $boxBg
                    } else {
                        $display = $buffer
                        if ($display.Length -gt $fieldWidth) { $display = $display.Substring(0, $fieldWidth) }
                        Write-Host $display.PadRight($fieldWidth) -NoNewline `
                            -ForegroundColor White -BackgroundColor Black
                    }
                    $tail = $contentW - $prefixLen - $fieldWidth
                    if ($tail -gt 0) {
                        Write-Host (' ' * $tail) -NoNewline -ForegroundColor $headFg -BackgroundColor $boxBg
                    }
                    Write-Host ' ║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg

                    # Rename-mode hint replaces the normal preview hint.
                    [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $contentH)
                    $hintR    = ' ENTER save   ESC cancel   ←→ Home/End edit '
                    $hintMaxR = $boxW - 4
                    if ($hintR.Length -gt $hintMaxR) { $hintR = $hintR.Substring(0, $hintMaxR) }
                    $padBarsR  = $boxW - 2 - $hintR.Length
                    $leftPadR  = '═' * [int]($padBarsR / 2)
                    $rightPadR = '═' * ($padBarsR - $leftPadR.Length)
                    Write-Host '╚' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
                    Write-Host $leftPadR -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
                    Write-Host $hintR -NoNewline -ForegroundColor $hintFg -BackgroundColor $hintBg
                    Write-Host $rightPadR -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
                    Write-Host '╝' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg

                    $cx = if ($cleared) {
                        [Math]::Min($fieldX + $cursorPos, $fieldX + $fieldWidth - 1)
                    } else { $fieldX }
                    try { [Console]::SetCursorPosition($cx, $rowY) } catch {}

                    $rk = [Console]::ReadKey($true)
                    switch ($rk.Key) {
                        'Escape' { $renameDone = $true }
                        'Enter' {
                            # Untouched placeholder + ENTER = promote the
                            # existing title (AI or already-custom) to a
                            # custom title. Useful when the AI title is
                            # spot-on and the user just wants the `!` flag.
                            $trimmed = if ($cleared) { $buffer.Trim() } else { $current.Trim() }
                            if ([string]::IsNullOrEmpty($trimmed)) {
                                # No title to save in either branch — cancel.
                                $renameDone = $true
                            } else {
                                try {
                                    Set-SessionCustomTitle -Path $Session.Path -Title $trimmed
                                    $Session.Title          = $trimmed
                                    $Session.HasCustomTitle = $true
                                    $renameSaved = $true
                                } catch {
                                    # Swallow: silently cancel rather than
                                    # corrupting the TUI with an error blob.
                                }
                                $renameDone = $true
                            }
                        }
                        'LeftArrow' {
                            # First arrow on the placeholder adopts the
                            # existing title as the buffer so the user can
                            # make a minor edit without retyping everything.
                            if (-not $cleared -and $current.Length -gt 0) {
                                $cleared = $true
                                $buffer = if ($current.Length -gt $maxLen) { $current.Substring(0, $maxLen) } else { $current }
                                $cursorPos = $buffer.Length
                            }
                            if ($cleared -and $cursorPos -gt 0) { $cursorPos-- }
                        }
                        'RightArrow' {
                            # Mirror LeftArrow's tail-edit landing with a
                            # head-edit landing: adopt the title and place
                            # the cursor one step in from the start.
                            if (-not $cleared -and $current.Length -gt 0) {
                                $cleared = $true
                                $buffer = if ($current.Length -gt $maxLen) { $current.Substring(0, $maxLen) } else { $current }
                                $cursorPos = [Math]::Min(1, $buffer.Length)
                            } elseif ($cleared -and $cursorPos -lt $buffer.Length) {
                                $cursorPos++
                            }
                        }
                        'Home' {
                            if (-not $cleared -and $current.Length -gt 0) {
                                $cleared = $true
                                $buffer = if ($current.Length -gt $maxLen) { $current.Substring(0, $maxLen) } else { $current }
                            }
                            if ($cleared) { $cursorPos = 0 }
                        }
                        'End' {
                            if (-not $cleared -and $current.Length -gt 0) {
                                $cleared = $true
                                $buffer = if ($current.Length -gt $maxLen) { $current.Substring(0, $maxLen) } else { $current }
                            }
                            if ($cleared) { $cursorPos = $buffer.Length }
                        }
                        'Backspace' {
                            if (-not $cleared) {
                                $cleared = $true; $buffer = ''; $cursorPos = 0
                            } elseif ($cursorPos -gt 0) {
                                $buffer    = $buffer.Substring(0, $cursorPos - 1) + $buffer.Substring($cursorPos)
                                $cursorPos--
                            }
                        }
                        'Delete' {
                            if (-not $cleared) {
                                $cleared = $true; $buffer = ''; $cursorPos = 0
                            } elseif ($cursorPos -lt $buffer.Length) {
                                $buffer = $buffer.Substring(0, $cursorPos) + $buffer.Substring($cursorPos + 1)
                            }
                        }
                        default {
                            $kc = $rk.KeyChar
                            if ($kc -and -not [char]::IsControl($kc)) {
                                if (-not $cleared) { $cleared = $true; $buffer = ''; $cursorPos = 0 }
                                if ($buffer.Length -lt $maxLen) {
                                    $buffer    = $buffer.Substring(0, $cursorPos) + $kc + $buffer.Substring($cursorPos)
                                    $cursorPos++
                                }
                            }
                        }
                    }
                }

                try { [Console]::CursorVisible = $false } catch {}

                if ($renameSaved) {
                    # Close the preview so the caller redraws the list with
                    # the new title + custom-title flag.
                    return
                }
                # Cancelled: refresh the preview header so the dim
                # placeholder is replaced with the normal yellow Title row.
                $data = Get-SessionPreviewContent -Session $Session -Width $contentW
                $head = $data.Header
                $body = $data.Body
            }
        }
    }
}

function Show-ConfirmDelete {
    param(
        [Parameter(Mandatory)] [object[]]$Items,
        [Parameter(Mandatory)] [int]$ScreenWidth,
        [Parameter(Mandatory)] [int]$ScreenHeight,
        [Parameter(Mandatory)] [int]$BaseTop,
        [string[]]$BackgroundRows = @()
    )

    $boxW = [Math]::Min(70, $ScreenWidth - 6)
    if ($boxW -lt 40) { $boxW = [Math]::Max(30, $ScreenWidth - 4) }
    $boxH = [Math]::Max(10, [int]($ScreenHeight * 0.45))
    if ($boxH -gt ($ScreenHeight - 3)) { $boxH = $ScreenHeight - 3 }

    $contentW = $boxW - 4
    $contentH = $boxH - 2

    $boxLeft = [int](($ScreenWidth - $boxW) / 2)
    $boxTop  = $BaseTop + [Math]::Max(0, [int]((($ScreenHeight - 2) - $boxH) / 2))

    $totalKb  = ($Items | Measure-Object SizeBytes -Sum).Sum / 1KB
    $kbRound  = [Math]::Round($totalKb, 1)
    $summary  = "About to permanently delete $($Items.Count) session(s)  ($kbRound KB):"

    $listLines = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $Items) {
        $line = "• $($s.Uuid)  $($s.Project)"
        if ($line.Length -gt $contentW) { $line = $line.Substring(0, $contentW - 1) + '…' }
        $listLines.Add($line)
    }

    $headerH  = 2                    # summary + separator
    $promptH  = 3                    # blank + prompt + input
    $listH    = [Math]::Max(1, $contentH - $headerH - $promptH)
    $maxScroll = [Math]::Max(0, $listLines.Count - $listH)
    $scrollTop = 0
    $typed     = ''

    $boxFg    = 'White'
    $boxBg    = 'DarkGray'
    $borderFg = 'White'
    $warnFg   = 'Yellow'
    $hintFg   = 'Black'
    $hintBg   = 'Gray'
    $inputFg  = 'Black'
    $inputBg  = 'White'

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

    while ($true) {
        # Title bar
        [Console]::SetCursorPosition($boxLeft, $boxTop)
        $title    = ' Confirm deletion '
        $leftBar  = '═' * [int](($boxW - 2 - $title.Length) / 2)
        $rightBar = '═' * ($boxW - 2 - $title.Length - $leftBar.Length)
        Write-Host ('╔' + $leftBar + $title + $rightBar + '╗') `
            -ForegroundColor $borderFg -BackgroundColor $boxBg -NoNewline

        # Pinned summary (centered) + separator
        $rowIdx = 0
        [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $rowIdx)
        Write-Host '║ ' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        if ($summary.Length -ge $contentW) {
            $sLine = $summary.Substring(0, $contentW)
        } else {
            $pad   = $contentW - $summary.Length
            $lpad  = [int]($pad / 2)
            $sLine = (' ' * $lpad) + $summary + (' ' * ($pad - $lpad))
        }
        Write-Host $sLine -NoNewline -ForegroundColor $warnFg -BackgroundColor $boxBg
        Write-Host ' ║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        $rowIdx++

        [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $rowIdx)
        Write-Host '║ ' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host ('─' * $contentW) -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host ' ║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        $rowIdx++

        # List of items (scrollable)
        for ($r = 0; $r -lt $listH; $r++) {
            [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $rowIdx + $r)
            $idx = $scrollTop + $r
            $line = if ($idx -lt $listLines.Count) { $listLines[$idx] } else { '' }
            if ($line.Length -gt $contentW) { $line = $line.Substring(0, $contentW) }
            Write-Host ('║ ' + $line.PadRight($contentW) + ' ║') `
                -NoNewline -ForegroundColor $boxFg -BackgroundColor $boxBg
        }
        $rowIdx += $listH

        # Blank row
        [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $rowIdx)
        Write-Host ('║' + (' ' * ($boxW - 2)) + '║') -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        $rowIdx++

        # Prompt row (centered)
        [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $rowIdx)
        $prompt = 'Type "yes" to confirm, ESC to cancel:'
        if ($prompt.Length -ge $contentW) {
            $promptLine = $prompt.Substring(0, $contentW)
        } else {
            $pad        = $contentW - $prompt.Length
            $lpad       = [int]($pad / 2)
            $promptLine = (' ' * $lpad) + $prompt + (' ' * ($pad - $lpad))
        }
        Write-Host ('║ ' + $promptLine + ' ║') `
            -NoNewline -ForegroundColor $warnFg -BackgroundColor $boxBg
        $rowIdx++

        # Input row: 6-char padding on both sides of a narrow input field.
        [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $rowIdx)
        $leftPadW   = 6
        $rightPadW  = 6
        $fieldW     = [Math]::Max(8, $contentW - $leftPadW - $rightPadW)
        $shown      = $typed + '_'
        if ($shown.Length -gt ($fieldW - 1)) { $shown = $shown.Substring($shown.Length - ($fieldW - 1)) }
        $fieldText  = (' ' + $shown).PadRight($fieldW)
        $leftFill   = ' ' * $leftPadW
        $rightFill  = ' ' * ($contentW - $leftPadW - $fieldW)
        Write-Host '║ ' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host $leftFill -NoNewline -BackgroundColor $boxBg
        Write-Host $fieldText -NoNewline -ForegroundColor $inputFg -BackgroundColor $inputBg
        Write-Host $rightFill -NoNewline -BackgroundColor $boxBg
        Write-Host ' ║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        $rowIdx++

        # Bottom border with embedded hint
        [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $contentH)
        $hint = " ENTER submit   ESC cancel "
        if ($maxScroll -gt 0) { $hint += "  ↑↓ scroll list " }
        $hintMax = $boxW - 4
        if ($hint.Length -gt $hintMax) { $hint = $hint.Substring(0, $hintMax) }
        $padBars  = ($boxW - 2 - $hint.Length)
        $leftPad  = '═' * [int]($padBars / 2)
        $rightPad = '═' * ($padBars - $leftPad.Length)
        Write-Host '╚' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host $leftPad -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host $hint -NoNewline -ForegroundColor $hintFg -BackgroundColor $hintBg
        Write-Host $rightPad -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host '╝' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg

        # Dynamic drop shadow — dim underlying picker text in DarkGray.
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

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'Escape'    { return $false }
            'Enter'     { if ($typed -ieq 'yes') { return $true } }
            'Backspace' { if ($typed.Length -gt 0) { $typed = $typed.Substring(0, $typed.Length - 1) } }
            'UpArrow'   { if ($scrollTop -gt 0)              { $scrollTop-- } }
            'DownArrow' { if ($scrollTop -lt $maxScroll)     { $scrollTop++ } }
            'PageUp'    { $scrollTop = [Math]::Max(0, $scrollTop - $listH) }
            'PageDown'  { $scrollTop = [Math]::Min($maxScroll, $scrollTop + $listH) }
            'Home'      { $scrollTop = 0 }
            'End'       { $scrollTop = $maxScroll }
            default {
                $kc = $key.KeyChar
                if ($kc -and [int][char]$kc -ge 32 -and [int][char]$kc -ne 127 -and $typed.Length -lt 10) {
                    $typed += $kc
                }
            }
        }
    }
}

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
        $line = [string]$rendered[$r]
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

    try {
        $cwd = Get-SessionCwd -Path $Session.Path
    } catch {
        # Transcript unreadable (e.g. deleted in the window since the scan) —
        # treat as "no working directory" so we refuse and stay (per the design)
        # instead of letting a raw error escape the TUI.
        $cwd = $null
    }

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
    $maxLabel = [Math]::Max(10, [Math]::Min(60, $ScreenWidth - 12))
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

    $boxW = [Math]::Min(60, $ScreenWidth - 6)
    if ($boxW -lt 40) { $boxW = [Math]::Max(30, $ScreenWidth - 4) }
    $boxH = 8
    if ($boxH -gt ($ScreenHeight - 3)) { $boxH = $ScreenHeight - 3 }

    $contentW = $boxW - 4
    $contentH = $boxH - 2

    $boxLeft = [int](($ScreenWidth - $boxW) / 2)
    $boxTop  = $BaseTop + [Math]::Max(0, [int]((($ScreenHeight - 2) - $boxH) / 2))

    $borderFg = 'White'
    $boxBg    = 'DarkGray'
    $boxFg    = 'White'
    $hintFg   = 'Black'
    $hintBg   = 'Gray'
    $promptFg = 'Yellow'
    $checkFg  = 'White'
    $checkHotFg = 'Yellow'
    $inputFg  = 'Black'
    $inputBg  = 'White'

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

    # Helper: blank inner row with proper white side borders.
    $blankRow = {
        param([int]$Row)
        [Console]::SetCursorPosition($boxLeft, $Row)
        Write-Host '║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host (' ' * ($boxW - 2)) -NoNewline -ForegroundColor $boxFg -BackgroundColor $boxBg
        Write-Host '║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
    }

    $typed         = $InitialText
    $caretPos      = $typed.Length
    $caseSensitive = $InitialCaseSensitive

    while ($true) {
        # Title bar (row 0)
        [Console]::SetCursorPosition($boxLeft, $boxTop)
        $title    = ' Search '
        $padBars  = $boxW - 2 - $title.Length
        $leftBar  = '═' * [int]($padBars / 2)
        $rightBar = '═' * ($padBars - $leftBar.Length)
        Write-Host ('╔' + $leftBar + $title + $rightBar + '╗') `
            -ForegroundColor $borderFg -BackgroundColor $boxBg -NoNewline

        # Row 1: blank
        & $blankRow ($boxTop + 1)

        # Row 2: prompt (centered, yellow) — split writes so border chars stay white.
        [Console]::SetCursorPosition($boxLeft, $boxTop + 2)
        $prompt = 'Filter by text inside session transcripts:'
        if ($prompt.Length -ge $contentW) {
            $promptLine = $prompt.Substring(0, $contentW)
        } else {
            $pad        = $contentW - $prompt.Length
            $lpad       = [int]($pad / 2)
            $promptLine = (' ' * $lpad) + $prompt + (' ' * ($pad - $lpad))
        }
        Write-Host '║ ' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host $promptLine -NoNewline -ForegroundColor $promptFg -BackgroundColor $boxBg
        Write-Host ' ║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg

        # Row 3: input field. Renders the caret as a reversed cell so the
        # user can see where insertions/deletes will happen.
        [Console]::SetCursorPosition($boxLeft, $boxTop + 3)
        $leftPadW  = 4
        $rightPadW = 4
        $fieldW    = [Math]::Max(8, $contentW - $leftPadW - $rightPadW)
        $leftFill  = ' ' * $leftPadW
        $rightFill = ' ' * ($contentW - $leftPadW - $fieldW)

        # Build a virtual display string: append a space if the caret sits
        # one past the end of the text, so the caret always has a cell to
        # render in.
        $display = $typed
        if ($caretPos -ge $display.Length) { $display = $display + ' ' }

        # Horizontal scroll so the caret is always visible. Reserve one cell
        # for the leading space inside the input field.
        $visibleW = $fieldW - 1
        if ($visibleW -lt 1) { $visibleW = 1 }
        $scrollStart = 0
        if ($display.Length -gt $visibleW) {
            if ($caretPos -ge $visibleW) { $scrollStart = $caretPos - $visibleW + 1 }
            if ($scrollStart + $visibleW -gt $display.Length) {
                $scrollStart = $display.Length - $visibleW
            }
            if ($scrollStart -lt 0) { $scrollStart = 0 }
        }
        $visiblePart = $display.Substring($scrollStart, [Math]::Min($visibleW, $display.Length - $scrollStart))
        $caretInVis  = $caretPos - $scrollStart
        if ($caretInVis -lt 0)                     { $caretInVis = 0 }
        if ($caretInVis -ge $visiblePart.Length)   { $caretInVis = [Math]::Max(0, $visiblePart.Length - 1) }

        $before  = $visiblePart.Substring(0, $caretInVis)
        $caretCh = if ($visiblePart.Length -gt $caretInVis) { $visiblePart.Substring($caretInVis, 1) } else { ' ' }
        $after   = if ($caretInVis + 1 -lt $visiblePart.Length) { $visiblePart.Substring($caretInVis + 1) } else { '' }
        $usedW   = 1 + $before.Length + 1 + $after.Length   # leading space + before + caret + after
        $trailPad = $fieldW - $usedW
        if ($trailPad -lt 0) { $trailPad = 0 }

        Write-Host '║ ' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host $leftFill -NoNewline -ForegroundColor $boxFg -BackgroundColor $boxBg
        Write-Host ' '       -NoNewline -ForegroundColor $inputFg -BackgroundColor $inputBg
        if ($before)  { Write-Host $before -NoNewline -ForegroundColor $inputFg -BackgroundColor $inputBg }
        Write-Host $caretCh -NoNewline -ForegroundColor $inputBg -BackgroundColor $inputFg
        if ($after)   { Write-Host $after  -NoNewline -ForegroundColor $inputFg -BackgroundColor $inputBg }
        if ($trailPad -gt 0) {
            Write-Host (' ' * $trailPad) -NoNewline -ForegroundColor $inputFg -BackgroundColor $inputBg
        }
        Write-Host $rightFill -NoNewline -ForegroundColor $boxFg -BackgroundColor $boxBg
        Write-Host ' ║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg

        # Row 4: blank
        & $blankRow ($boxTop + 4)

        # Row 5: case-sensitive checkbox (centered). Tab toggles it.
        [Console]::SetCursorPosition($boxLeft, $boxTop + 5)
        $cbMark   = if ($caseSensitive) { '[x]' } else { '[ ]' }
        $cbText   = " $cbMark Case-sensitive"
        $cbHint   = '  (Tab to toggle)'
        $cbFull   = $cbText + $cbHint
        $cbPad    = $contentW - $cbFull.Length
        if ($cbPad -lt 0) { $cbPad = 0 }
        $cbLpad   = [int]($cbPad / 2)
        $cbRpad   = $cbPad - $cbLpad
        Write-Host '║ ' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        if ($cbLpad -gt 0) { Write-Host (' ' * $cbLpad) -NoNewline -ForegroundColor $boxFg -BackgroundColor $boxBg }
        $checkColor = if ($caseSensitive) { $checkHotFg } else { $checkFg }
        Write-Host $cbText -NoNewline -ForegroundColor $checkColor -BackgroundColor $boxBg
        Write-Host $cbHint -NoNewline -ForegroundColor DarkGray -BackgroundColor $boxBg
        if ($cbRpad -gt 0) { Write-Host (' ' * $cbRpad) -NoNewline -ForegroundColor $boxFg -BackgroundColor $boxBg }
        Write-Host ' ║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg

        # Row 6: blank
        & $blankRow ($boxTop + 6)

        # Bottom border with hint (row 7)
        [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $contentH)
        $hint = ' ENTER apply   TAB case-sensitive   ESC cancel '
        $hintMax = $boxW - 4
        if ($hint.Length -gt $hintMax) { $hint = $hint.Substring(0, $hintMax) }
        $padBars  = ($boxW - 2 - $hint.Length)
        $leftPad  = '═' * [int]($padBars / 2)
        $rightPad = '═' * ($padBars - $leftPad.Length)
        Write-Host '╚' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host $leftPad -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host $hint -NoNewline -ForegroundColor $hintFg -BackgroundColor $hintBg
        Write-Host $rightPad -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host '╝' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg

        # Dynamic drop shadow
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

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'Escape'    { return $null }
            'Enter'     { return [pscustomobject]@{ Query = $typed; CaseSensitive = $caseSensitive } }
            'Tab'       { $caseSensitive = -not $caseSensitive }
            'LeftArrow'  { if ($caretPos -gt 0)             { $caretPos-- } }
            'RightArrow' { if ($caretPos -lt $typed.Length) { $caretPos++ } }
            'Home'       { $caretPos = 0 }
            'End'        { $caretPos = $typed.Length }
            'Backspace' {
                if ($caretPos -gt 0) {
                    $typed = $typed.Remove($caretPos - 1, 1)
                    $caretPos--
                }
            }
            'Delete' {
                if ($caretPos -lt $typed.Length) {
                    $typed = $typed.Remove($caretPos, 1)
                }
            }
            default {
                $kc = $key.KeyChar
                if ($kc -and [int][char]$kc -ge 32 -and [int][char]$kc -ne 127 -and $typed.Length -lt 60) {
                    $typed = $typed.Insert($caretPos, [string]$kc)
                    $caretPos++
                }
            }
        }
    }
}

function Get-DeClauttRLogo {
    # Composes the broom + DECLAUTTR title + tagline into a list of "rows",
    # where each row is a list of @{Text=...;Color=...} colored spans.
    # Returns @{ Rows; Width } so callers can size their viewport accordingly.

    $assetDir   = Join-Path $PSScriptRoot '.assets'
    $titleLines = @()
    $broomLines = @()
    $dustLines  = @()
    try {
        $titleLines = [System.IO.File]::ReadAllLines((Join-Path $assetDir 'declauttr-title.ascii'))
        $broomLines = [System.IO.File]::ReadAllLines((Join-Path $assetDir 'declauttr-broom.ascii'))
        $dustLines  = [System.IO.File]::ReadAllLines((Join-Path $assetDir 'declauttr-dust.ascii'))
    } catch {
        # Degrade silently if the assets folder is missing.
    }

    $letterBounds = @(0, 8, 16, 24, 32, 40, 49, 58, 67, 75)
    # D,E=cyan ; C,L,A,U=orange (DarkYellow renders as tan/orange) ; T,T,R=cyan
    $titleColors  = @('DarkCyan','DarkCyan','DarkYellow','DarkYellow','DarkYellow','DarkYellow','DarkCyan','DarkCyan','DarkCyan')
    $titleWidth   = 75
    $broomOffset  = 41
    $taglineText  = 'BECAUSE NOT EVERY SESSION DESERVES A COMEBACK'
    $taglineRow   = 5
    $taglineColor = 'Yellow'

    # Dust sits below the title and to the left of the broom head.
    $dustStartRow = 13
    $dustOffset   = 11
    $dustColor    = 'DarkGray'

    $broomHeight   = $broomLines.Count
    $titleHeight   = $titleLines.Count
    $broomBelowTitle = 8
    $titleStartRow = [Math]::Max(0, $broomHeight - $titleHeight - $broomBelowTitle)

    $broomFirst = New-Object 'int[]' $broomHeight
    $broomLast  = New-Object 'int[]' $broomHeight
    for ($r = 0; $r -lt $broomHeight; $r++) {
        $line = $broomLines[$r]
        $f = -1
        $l = -1
        for ($i = 0; $i -lt $line.Length; $i++) {
            if ($line[$i] -ne ' ') {
                if ($f -lt 0) { $f = $i }
                $l = $i
            }
        }
        $broomFirst[$r] = $f
        $broomLast[$r]  = $l
    }

    $rows = [System.Collections.Generic.List[object]]::new()

    for ($r = 0; $r -lt $broomHeight; $r++) {
        $broomRow = $broomLines[$r]
        $titleRow = $null
        $tIdx     = $r - $titleStartRow
        if ($tIdx -ge 0 -and $tIdx -lt $titleHeight) { $titleRow = $titleLines[$tIdx] }

        $spans    = [System.Collections.Generic.List[object]]::new()
        $curText  = ''
        $curColor = $null

        for ($col = 0; $col -lt $titleWidth; $col++) {
            $ch    = $null
            $color = $null

            # The broom owns its bounding rectangle [broomFirst..broomLast]; spaces
            # inside that rectangle stay empty so the title doesn't bleed through.
            $bc = $col - $broomOffset
            $insideBroom = $false
            if ($broomFirst[$r] -ge 0 -and $bc -ge $broomFirst[$r] -and $bc -le $broomLast[$r]) {
                $insideBroom = $true
                if ($bc -lt $broomRow.Length) {
                    $b = $broomRow[$bc]
                    if ($b -ne ' ') {
                        $ch    = [string]$b
                        $color = $taglineColor
                    } else {
                        $ch    = ' '
                        $color = 'Black'
                    }
                } else {
                    $ch    = ' '
                    $color = 'Black'
                }
            }

            if ($null -eq $ch -and -not $insideBroom -and $r -eq $taglineRow -and $col -lt $taglineText.Length) {
                $tagCh = $taglineText[$col]
                if ($tagCh -ne ' ') {
                    $ch    = [string]$tagCh
                    $color = $taglineColor
                }
            }

            # Dust drifting below the title, to the left of the broom.
            if ($null -eq $ch -and -not $insideBroom) {
                $dustRowIdx = $r - $dustStartRow
                if ($dustRowIdx -ge 0 -and $dustRowIdx -lt $dustLines.Count) {
                    $dustRow = $dustLines[$dustRowIdx]
                    $dc = $col - $dustOffset
                    if ($dc -ge 0 -and $dc -lt $dustRow.Length) {
                        $d = $dustRow[$dc]
                        if ($d -ne ' ') {
                            $ch    = [string]$d
                            $color = $dustColor
                        }
                    }
                }
            }

            if ($null -eq $ch -and -not $insideBroom -and $null -ne $titleRow -and $col -lt $titleRow.Length) {
                $tc = $titleRow[$col]
                if ($tc -ne ' ') {
                    $ch = [string]$tc
                    $li = 0
                    for ($i = 1; $i -lt $letterBounds.Count; $i++) {
                        if ($col -lt $letterBounds[$i]) { $li = $i - 1; break }
                    }
                    $color = $titleColors[$li]
                }
            }

            if ($null -eq $ch) {
                $ch    = ' '
                $color = 'Black'
            }

            if ($color -ne $curColor) {
                if ($curText) { [void]$spans.Add(@{ Text = $curText; Color = $curColor }) }
                $curText  = ''
                $curColor = $color
            }
            $curText += $ch
        }
        if ($curText) { [void]$spans.Add(@{ Text = $curText; Color = $curColor }) }
        [void]$rows.Add($spans)
    }

    return [pscustomobject]@{ Rows = $rows; Width = $titleWidth }
}

function Show-About {
    param(
        [Parameter(Mandatory)] [int]$ScreenWidth,
        [Parameter(Mandatory)] [int]$ScreenHeight,
        [Parameter(Mandatory)] [int]$BaseTop,
        [string[]]$BackgroundRows = @()
    )

    $logo        = Get-DeClauttRLogo
    $titleWidth  = $logo.Width
    $broomHeight = $logo.Rows.Count

    # Each content row is a list of @{Text=...;Color=...} spans.
    $content = [System.Collections.Generic.List[object]]::new()

    # One blank row above the logo for breathing room under the title bar.
    $topBlank = [System.Collections.Generic.List[object]]::new()
    [void]$topBlank.Add(@{ Text = ''; Color = 'Black' })
    [void]$content.Add($topBlank)

    foreach ($row in $logo.Rows) { [void]$content.Add($row) }

    $extra = @(
        @{ Text = '';                                                                       Color = 'Black';     Center = $false }
        @{ Text = 'DeClauttR lists every Claude Code session saved under';                  Color = 'White';     Center = $true  }
        @{ Text = '~/.claude/projects/ and lets you bulk-prune the empty, trivial,';        Color = 'White';     Center = $true  }
        @{ Text = 'or just-no-longer-needed ones that pile up in your';                     Color = 'White';     Center = $true  }
        @{ Text = '"claude --resume" picker.';                                              Color = 'White';     Center = $true  }
        @{ Text = '';                                                                       Color = 'Black';     Center = $false }
        @{ Text = 'Use the arrow keys to navigate, SPACE to preview a session,';            Color = 'White';     Center = $true  }
        @{ Text = 'X to mark for removal, and DEL (or Backspace) to delete';                Color = 'White';     Center = $true  }
        @{ Text = 'the marked sessions after confirmation.';                                Color = 'White';     Center = $true  }
        @{ Text = '';                                                                       Color = 'Black';     Center = $false }
        @{ Text = '';                                                                       Color = 'Black';     Center = $false }
        @{ Text = 'Made by Koos Goossens in 2026   ·   https://aka.ms/koos';                Color = 'DarkCyan';  Center = $true  }
        @{ Text = '';                                                                       Color = 'Black';     Center = $false }
        @{ Text = '';                                                                       Color = 'Black';     Center = $false }
    )

    foreach ($l in $extra) {
        $spans = [System.Collections.Generic.List[object]]::new()
        [void]$spans.Add(@{ Text = $l.Text; Color = $l.Color; Center = $l.Center })
        [void]$content.Add($spans)
    }

    # ---- Box sizing ----
    $boxW = [Math]::Min($titleWidth + 6, $ScreenWidth - 4)
    if ($boxW -lt 40) { $boxW = [Math]::Max(30, $ScreenWidth - 4) }
    $boxH = [Math]::Min($broomHeight + 4, $ScreenHeight - 4)
    if ($boxH -lt 12) { $boxH = [Math]::Min(12, $ScreenHeight - 3) }
    if ($boxH -gt ($ScreenHeight - 3)) { $boxH = $ScreenHeight - 3 }

    $contentW = $boxW - 4
    $contentH = $boxH - 2

    $boxLeft = [int](($ScreenWidth - $boxW) / 2)
    $boxTop  = $BaseTop + [Math]::Max(0, [int]((($ScreenHeight - 2) - $boxH) / 2))

    $boxBg    = 'Black'
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

    # ---- Render loop with auto-scroll after 1s (stops at the end) ----
    $idleTimer    = [System.Diagnostics.Stopwatch]::StartNew()
    $tickTimer    = [System.Diagnostics.Stopwatch]::StartNew()
    $scrollOffset = 0
    $needRedraw   = $true
    $total        = $content.Count
    $maxScroll    = [Math]::Max(0, $total - $contentH)

    while ($true) {
        if ($idleTimer.ElapsedMilliseconds -ge 1000 -and
            $tickTimer.ElapsedMilliseconds -ge 400 -and
            $scrollOffset -lt $maxScroll) {
            $scrollOffset++
            $tickTimer.Restart()
            $needRedraw = $true
        }

        if (-not $needRedraw) {
            if (-not [Console]::KeyAvailable) {
                Start-Sleep -Milliseconds 25
                continue
            }
            [void][Console]::ReadKey($true)
            return
        }

        # Title bar
        [Console]::SetCursorPosition($boxLeft, $boxTop)
        $title    = ' About DeClauttR '
        $padBars  = $boxW - 2 - $title.Length
        $leftBar  = '═' * [int]($padBars / 2)
        $rightBar = '═' * ($padBars - $leftBar.Length)
        Write-Host ('╔' + $leftBar + $title + $rightBar + '╗') `
            -ForegroundColor $borderFg -BackgroundColor $boxBg -NoNewline

        # Body — scroll through $content; stops once the end is reached.
        for ($r = 0; $r -lt $contentH; $r++) {
            [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $r)
            $idx = $scrollOffset + $r
            if ($idx -ge $total) {
                Write-Host ('║ ' + (' ' * $contentW) + ' ║') `
                    -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
                continue
            }
            $row = $content[$idx]
            $rowLen = 0
            $rowText = ''
            foreach ($s in $row) { $rowText += $s.Text }
            $center = $false
            if ($row.Count -eq 1 -and $row[0].ContainsKey('Center') -and $row[0]['Center']) { $center = $true }

            $padLeft = 0
            if ($center -and $rowText.Length -lt $contentW) {
                $padLeft = [int](($contentW - $rowText.Length) / 2)
            }

            Write-Host '║ ' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
            if ($padLeft -gt 0) {
                Write-Host (' ' * $padLeft) -NoNewline -BackgroundColor $boxBg
                $rowLen = $padLeft
            }
            foreach ($s in $row) {
                $t = $s.Text
                if ($rowLen + $t.Length -gt $contentW) {
                    $t = $t.Substring(0, $contentW - $rowLen)
                }
                if ($t) {
                    Write-Host $t -NoNewline -ForegroundColor $s.Color -BackgroundColor $boxBg
                    $rowLen += $t.Length
                }
                if ($rowLen -ge $contentW) { break }
            }
            if ($rowLen -lt $contentW) {
                Write-Host (' ' * ($contentW - $rowLen)) -NoNewline -BackgroundColor $boxBg
            }
            Write-Host ' ║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        }

        # Bottom border with embedded hint
        [Console]::SetCursorPosition($boxLeft, $boxTop + 1 + $contentH)
        $hint = ' Press any key to close '
        $padBars  = $boxW - 2 - $hint.Length
        $leftPad  = '═' * [int]($padBars / 2)
        $rightPad = '═' * ($padBars - $leftPad.Length)
        Write-Host '╚' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host $leftPad -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host $hint -NoNewline -ForegroundColor $hintFg -BackgroundColor $hintBg
        Write-Host $rightPad -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host '╝' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg

        # Dynamic drop shadow
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

        $needRedraw = $false
    }
}

function Show-AboutScreenshot {
    # Standalone, static render of the About panel — no title bar text, no hint
    # line, no scroll, no shadow. Intended for capturing a clean repo screenshot.

    Clear-Host

    $logo      = Get-DeClauttRLogo
    $logoWidth = $logo.Width

    $screenW = try { [Console]::WindowWidth } catch { 100 }
    if (-not $screenW -or $screenW -lt 40) { $screenW = 100 }

    $innerW = $logoWidth + 4               # 2 cols of padding on each side of the logo
    $boxW   = $innerW + 2                  # +2 for the side borders
    if ($boxW -gt $screenW) {
        $boxW   = $screenW
        $innerW = $boxW - 2
    }

    $leftMargin = [Math]::Max(0, [int](($screenW - $boxW) / 2))
    $marginStr  = ' ' * $leftMargin

    $borderFg = 'White'
    $boxBg    = 'Black'

    $writeBlankRow = {
        Write-Host -NoNewline $marginStr
        Write-Host '║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        Write-Host (' ' * $innerW) -NoNewline -BackgroundColor $boxBg
        Write-Host '║' -ForegroundColor $borderFg -BackgroundColor $boxBg
    }

    # Top padding outside the box
    Write-Host ''
    Write-Host ''
    Write-Host ''

    # Top border (no title text)
    Write-Host -NoNewline $marginStr
    Write-Host ('╔' + ('═' * $innerW) + '╗') -ForegroundColor $borderFg -BackgroundColor $boxBg

    & $writeBlankRow

    # Logo rows (centered horizontally inside the box)
    $sidePad = [int](($innerW - $logoWidth) / 2)
    $rightPadW = $innerW - $sidePad - $logoWidth
    foreach ($row in $logo.Rows) {
        Write-Host -NoNewline $marginStr
        Write-Host '║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
        if ($sidePad -gt 0) {
            Write-Host (' ' * $sidePad) -NoNewline -BackgroundColor $boxBg
        }
        $written = 0
        foreach ($s in $row) {
            $t = $s.Text
            if ($written + $t.Length -gt $logoWidth) {
                $t = $t.Substring(0, $logoWidth - $written)
            }
            if ($t) {
                Write-Host $t -NoNewline -ForegroundColor $s.Color -BackgroundColor $boxBg
                $written += $t.Length
            }
        }
        if ($written -lt $logoWidth) {
            Write-Host (' ' * ($logoWidth - $written)) -NoNewline -BackgroundColor $boxBg
        }
        if ($rightPadW -gt 0) {
            Write-Host (' ' * $rightPadW) -NoNewline -BackgroundColor $boxBg
        }
        Write-Host '║' -ForegroundColor $borderFg -BackgroundColor $boxBg
    }

    # Spacer rows + credits + spacer
    & $writeBlankRow
    & $writeBlankRow

    $credit = 'Made by Koos Goossens in 2026   ·   https://aka.ms/koos'
    if ($credit.Length -gt $innerW) { $credit = $credit.Substring(0, $innerW) }
    $cPadL = [int](($innerW - $credit.Length) / 2)
    $cPadR = $innerW - $cPadL - $credit.Length
    Write-Host -NoNewline $marginStr
    Write-Host '║' -NoNewline -ForegroundColor $borderFg -BackgroundColor $boxBg
    if ($cPadL -gt 0) { Write-Host (' ' * $cPadL) -NoNewline -BackgroundColor $boxBg }
    Write-Host $credit -NoNewline -ForegroundColor DarkCyan -BackgroundColor $boxBg
    if ($cPadR -gt 0) { Write-Host (' ' * $cPadR) -NoNewline -BackgroundColor $boxBg }
    Write-Host '║' -ForegroundColor $borderFg -BackgroundColor $boxBg

    & $writeBlankRow

    # Bottom border (no hint text)
    Write-Host -NoNewline $marginStr
    Write-Host ('╚' + ('═' * $innerW) + '╝') -ForegroundColor $borderFg -BackgroundColor $boxBg

    # Bottom padding outside the box
    Write-Host ''
    Write-Host ''
    Write-Host ''
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

function Test-SessionMatchesQuery {
    # Stream the .jsonl line-by-line and bail at the first match. Operates on
    # the raw on-disk bytes so it sees both user messages and assistant
    # replies without parsing JSON.
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Query,
        [switch]$CaseSensitive
    )
    if ([string]::IsNullOrEmpty($Query)) { return $true }
    $cmp = if ($CaseSensitive) {
        [System.StringComparison]::Ordinal
    } else {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    try {
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            if ($line.IndexOf($Query, $cmp) -ge 0) { return $true }
        }
    } catch { return $false }
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
                HasCustomTitle = $meta.HasCustomTitle
                Snippet        = $meta.Snippet
                Recommended    = $recommend
                Checked        = $recommend
            })
        }
    }
    # Comma prefix prevents PowerShell from enumerating the list into an
    # object[] (which is fixed-size and would break later .RemoveAt calls in
    # the picker when sessions are deleted in place).
    return ,$result
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
        Write-Host "=== $($g.Name) ($($g.Count) sessions) ===" -ForegroundColor DarkCyan
        foreach ($s in $g.Group) {
            $ts = $s.Timestamp.ToString('yyyy-MM-dd HH:mm')
            Write-Host ("  {0}  " -f $ts) -NoNewline
            Write-Host $s.Uuid -ForegroundColor Yellow -NoNewline
            Write-Host "  $($s.SizeFormatted)"
            if ($s.Title) {
                $titleColor = if ($s.HasCustomTitle) { 'DarkCyan' } else { 'White' }
                Write-Host ($indent + $s.Title) -ForegroundColor $titleColor
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

    $reserved = 7
    $viewport = [Math]::Min($Sessions.Count, [Math]::Max(5, $height - $reserved))

    $cursor = 0
    $top    = 0

    [Console]::CursorVisible = $false
    $origTop = [Console]::CursorTop

    # Reserve screen space by emitting blank lines, so SetCursorPosition stays valid.
    for ($i = 0; $i -lt ($viewport + 5); $i++) { Write-Host '' }

    # Marquee state: when the cursor sits on a row for >1s, scroll its
    # description horizontally so long titles/snippets can be read in full.
    $cursorIdleTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $marqueeTimer    = [System.Diagnostics.Stopwatch]::StartNew()
    $marqueeOffset   = 0
    $lastCursor      = $cursor
    $needRedraw      = $true
    $rowBuffer       = [System.Collections.Generic.List[string]]::new()

    # Active view: $activeSessions is what the picker shows and operates on.
    # When the content-search filter (F) is active, it's a subset of $Sessions.
    $activeSessions       = $Sessions
    $searchQuery          = ''
    $searchCaseSensitive  = $false

    # Sessions successfully deleted during this picker run, accumulated across
    # multiple DEL cycles so the caller can print a final summary on exit.
    $deletedList = [System.Collections.Generic.List[object]]::new()

    # Reset any stale jump signal so a leftover value can't trigger a silent
    # exit on the first keypress. Invoke-JumpAttempt (J / preview) re-arms it.
    $script:JumpSession = $null

    try {
        while ($true) {
            if ($cursor -ne $lastCursor) {
                $marqueeOffset = 0
                $cursorIdleTimer.Restart()
                $lastCursor = $cursor
                $needRedraw = $true
            }

            if ($cursorIdleTimer.ElapsedMilliseconds -ge 1000 -and
                $marqueeTimer.ElapsedMilliseconds   -ge 60) {
                $marqueeOffset++
                $marqueeTimer.Restart()
                $needRedraw = $true
            }

            if ($cursor -lt $top)              { $top = $cursor; $needRedraw = $true }
            if ($cursor -ge $top + $viewport)  { $top = $cursor - $viewport + 1; $needRedraw = $true }

            if (-not $needRedraw) {
                if (-not [Console]::KeyAvailable) {
                    Start-Sleep -Milliseconds 25
                    continue
                }
                $key = [Console]::ReadKey($true)
                $needRedraw = $true
                switch ($key.Key) {
                    'UpArrow'   { if ($cursor -gt 0)                         { $cursor-- } }
                    'DownArrow' { if ($cursor -lt $activeSessions.Count - 1) { $cursor++ } }
                    'Home'      { $cursor = 0 }
                    'End'       { $cursor = [Math]::Max(0, $activeSessions.Count - 1) }
                    'PageUp'    { $cursor = [Math]::Max(0, $cursor - $viewport) }
                    'PageDown'  { $cursor = [Math]::Min([Math]::Max(0, $activeSessions.Count - 1), $cursor + $viewport) }
                    'Spacebar'  {
                        if ($activeSessions.Count -gt 0) {
                            Show-SessionPreview -Session $activeSessions[$cursor] `
                                -ScreenWidth $width -ScreenHeight $height -BaseTop $origTop `
                                -BackgroundRows $rowBuffer.ToArray() `
                                -Query $searchQuery -CaseSensitive $searchCaseSensitive
                            if ($script:JumpSession) { return $deletedList }
                            [Console]::Clear()
                            $origTop = [Console]::CursorTop
                            for ($i = 0; $i -lt ($viewport + 5); $i++) { Write-Host '' }
                            $marqueeOffset = 0
                            $cursorIdleTimer.Restart()
                        }
                    }
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
                    'A'         {
                        $anyUnchecked = @($activeSessions | Where-Object { -not $_.Checked }).Count -gt 0
                        foreach ($s in $activeSessions) { $s.Checked = $anyUnchecked }
                    }
                    'R'         {
                        # Toggle: if the current selection already matches the
                        # recommended preset, clear everything; otherwise apply
                        # the preset.
                        $matchesRecommended = $true
                        foreach ($s in $activeSessions) {
                            if ($s.Checked -ne $s.Recommended) { $matchesRecommended = $false; break }
                        }
                        if ($matchesRecommended) {
                            foreach ($s in $activeSessions) { $s.Checked = $false }
                        } else {
                            foreach ($s in $activeSessions) { $s.Checked = $s.Recommended }
                        }
                    }
                    'F'         {
                        if ($searchQuery) {
                            # Toggle off: clear the filter, restore full view.
                            # Keep $searchCaseSensitive sticky for the next search.
                            $searchQuery    = ''
                            $activeSessions = $Sessions
                            $cursor = 0; $top = 0
                            $marqueeOffset = 0
                            $cursorIdleTimer.Restart()
                        } else {
                            $result = Show-SearchPrompt -ScreenWidth $width -ScreenHeight $height `
                                -BaseTop $origTop -BackgroundRows $rowBuffer.ToArray() `
                                -InitialCaseSensitive $searchCaseSensitive
                            [Console]::Clear()
                            $origTop = [Console]::CursorTop
                            for ($i = 0; $i -lt ($viewport + 5); $i++) { Write-Host '' }

                            if ($null -ne $result -and $result.Query -and $result.Query.Trim()) {
                                $q  = $result.Query.Trim()
                                $cs = [bool]$result.CaseSensitive
                                [Console]::SetCursorPosition(0, $origTop)
                                $scanMsg = " Searching $($Sessions.Count) sessions for `"$q`"... "
                                if ($scanMsg.Length -gt $width) { $scanMsg = $scanMsg.Substring(0, $width) }
                                Write-Host ($scanMsg.PadRight($width)) -ForegroundColor Black -BackgroundColor Yellow
                                $activeSessions      = @($Sessions | Where-Object { Test-SessionMatchesQuery -Path $_.Path -Query $q -CaseSensitive:$cs })
                                $searchQuery         = $q
                                $searchCaseSensitive = $cs
                                $cursor = 0; $top = 0
                            } elseif ($null -ne $result) {
                                # Apply was hit on empty query — just remember any
                                # case-sensitive toggle the user made.
                                $searchCaseSensitive = [bool]$result.CaseSensitive
                            }
                            $marqueeOffset = 0
                            $cursorIdleTimer.Restart()
                        }
                    }
                    { $_ -eq 'Delete' -or $_ -eq 'Backspace' } {
                        $picked = @($activeSessions | Where-Object Checked)
                        if ($picked.Count -gt 0) {
                            $confirmed = Show-ConfirmDelete -Items $picked `
                                -ScreenWidth $width -ScreenHeight $height -BaseTop $origTop `
                                -BackgroundRows $rowBuffer.ToArray()
                            [Console]::Clear()
                            $origTop = [Console]::CursorTop
                            for ($i = 0; $i -lt ($viewport + 5); $i++) { Write-Host '' }
                            $marqueeOffset = 0
                            $cursorIdleTimer.Restart()

                            if ($confirmed) {
                                # Delete on disk, prune the in-memory lists,
                                # and stay in the picker so the user can keep
                                # working.
                                $deletedSet = @{}
                                foreach ($s in $picked) {
                                    try {
                                        Remove-Item -LiteralPath $s.Path -Force -ErrorAction Stop
                                        $deletedSet[$s.Path] = $true
                                        [void]$deletedList.Add($s)
                                    } catch {
                                        # Leave failures in the list; the TUI
                                        # would clobber any inline error here,
                                        # and main prints what actually
                                        # disappeared from disk.
                                    }
                                }
                                if ($deletedSet.Count -gt 0) {
                                    for ($i = $Sessions.Count - 1; $i -ge 0; $i--) {
                                        if ($deletedSet.ContainsKey($Sessions[$i].Path)) {
                                            $Sessions.RemoveAt($i)
                                        }
                                    }
                                    if ($searchQuery) {
                                        $activeSessions = @($activeSessions | Where-Object { -not $deletedSet.ContainsKey($_.Path) })
                                    } else {
                                        $activeSessions = $Sessions
                                    }
                                    if ($activeSessions.Count -eq 0) {
                                        $cursor = 0; $top = 0
                                    } elseif ($cursor -ge $activeSessions.Count) {
                                        $cursor = $activeSessions.Count - 1
                                    }
                                }
                            }
                        }
                    }
                    'Escape'    { return $deletedList }
                    'Q'         { return $deletedList }
                    default {
                        if ($key.KeyChar -eq '?') {
                            Show-About -ScreenWidth $width -ScreenHeight $height -BaseTop $origTop `
                                -BackgroundRows $rowBuffer.ToArray()
                            [Console]::Clear()
                            $origTop = [Console]::CursorTop
                            for ($i = 0; $i -lt ($viewport + 5); $i++) { Write-Host '' }
                            $marqueeOffset = 0
                            $cursorIdleTimer.Restart()
                        }
                    }
                }
                continue
            }

            [Console]::SetCursorPosition(0, $origTop)
            $rowBuffer.Clear()

            $checkedCount = @($activeSessions | Where-Object Checked).Count

            if ($searchQuery) {
                # Header split into three segments so the "F clear filter" pill
                # can pop in a contrasting yellow/black against the cyan bar.
                $headLeft  = " ↑↓ NAV   SPACE preview   J jump   X toggle   A all   R recommended  "
                $headPill  = " F clear filter: `"$searchQuery`" "
                $headRight = "  DEL delete   ? about   ESC cancel    [$checkedCount/$($activeSessions.Count) of $($Sessions.Count) selected]"
                $combined  = $headLeft + $headPill + $headRight
                if ($combined.Length -gt $width) {
                    $over = $combined.Length - $width
                    $headRight = $headRight.Substring(0, [Math]::Max(0, $headRight.Length - $over))
                }
                $padLen = $width - $headLeft.Length - $headPill.Length - $headRight.Length
                if ($padLen -lt 0) { $padLen = 0 }
                Write-Host $headLeft  -NoNewline -ForegroundColor Black -BackgroundColor Cyan
                Write-Host $headPill  -NoNewline -ForegroundColor Black -BackgroundColor Yellow
                Write-Host ($headRight + (' ' * $padLen)) -ForegroundColor Black -BackgroundColor Cyan
                $rowBuffer.Add($headLeft + $headPill + $headRight + (' ' * $padLen))
            } else {
                $header = " ↑↓ NAV   SPACE preview   J jump   X toggle   A all   R recommended   F filter   DEL delete   ? about   ESC cancel    [$checkedCount/$($activeSessions.Count) selected]"
                if ($header.Length -gt $width) { $header = $header.Substring(0, $width) }
                $headerText = $header.PadRight($width)
                Write-Host $headerText -ForegroundColor Black -BackgroundColor Cyan
                $rowBuffer.Add($headerText)
            }

            $colHeader = "{0}  {1}  {2}  {3}  {4}" -f `
                '   ',
                'Last changed    ',
                ('Size'.PadLeft(11)),
                ('Project'.PadRight(40)),
                'Title / first user message'
            $headerRoom = [Math]::Max(0, $width - 2)
            if ($colHeader.Length -gt $headerRoom) { $colHeader = $colHeader.Substring(0, $headerRoom) }
            $colHeader = $colHeader.PadRight($headerRoom)
            $colArrow = if ($top -gt 0) { '↑ ' } else { '  ' }
            if ($top -gt 0) {
                Write-Host '↑ ' -NoNewline -ForegroundColor Yellow
            } else {
                Write-Host '  ' -NoNewline
            }
            Write-Host $colHeader -ForegroundColor DarkGray
            $rowBuffer.Add($colArrow + $colHeader)

            for ($i = 0; $i -lt $viewport; $i++) {
                $idx = $top + $i
                if ($idx -ge $activeSessions.Count) {
                    if ($i -eq 0 -and $activeSessions.Count -eq 0 -and $searchQuery) {
                        $msg = "  (no sessions match `"$searchQuery`" — press F to clear the filter)"
                        if ($msg.Length -gt $width) { $msg = $msg.Substring(0, $width) }
                        $emptyRow = $msg.PadRight($width)
                        Write-Host $emptyRow -ForegroundColor DarkYellow
                        $rowBuffer.Add($emptyRow)
                    } else {
                        $emptyRow = ' ' * $width
                        Write-Host $emptyRow
                        $rowBuffer.Add($emptyRow)
                    }
                    continue
                }
                $s    = $activeSessions[$idx]
                $mark = if ($s.Checked) { '[x]' } else { '[ ]' }
                $flag = if ($s.HasCustomTitle) { '!' } else { ' ' }
                $ts   = $s.Timestamp.ToString('yyyy-MM-dd HH:mm')
                $proj = $s.Project
                if ($proj.Length -gt 40) { $proj = '…' + $proj.Substring($proj.Length - 39) }
                $prefix  = "$flag $mark  $ts  $($s.SizeFormatted)  $($proj.PadRight(40))  "
                $room    = [Math]::Max(10, $width - $prefix.Length - 1)
                $fullDesc = if ($s.Title) { $s.Title } else { $s.Snippet }
                if ($idx -eq $cursor -and $marqueeOffset -gt 0 -and $fullDesc.Length -gt $room) {
                    $gap   = '   •   '
                    $cycle = $fullDesc + $gap
                    $start = $marqueeOffset % $cycle.Length
                    $sb    = [System.Text.StringBuilder]::new($room)
                    for ($j = 0; $j -lt $room; $j++) {
                        [void]$sb.Append($cycle[($start + $j) % $cycle.Length])
                    }
                    $desc = $sb.ToString()
                } else {
                    $desc = $fullDesc
                    if ($desc.Length -gt $room) { $desc = $desc.Substring(0, $room - 1) + '…' }
                }
                $line = ($prefix + $desc).PadRight($width)
                if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }

                if ($idx -eq $cursor) {
                    Write-Host $line -ForegroundColor White -BackgroundColor DarkBlue
                } elseif ($s.HasCustomTitle) {
                    Write-Host $line -ForegroundColor DarkCyan
                } elseif ($s.Recommended) {
                    Write-Host $line -ForegroundColor DarkYellow
                } else {
                    Write-Host $line
                }
                $rowBuffer.Add($line)
            }

            $spacerRoom = [Math]::Max(0, $width - 2)
            $spacerArrow = if (($top + $viewport) -lt $activeSessions.Count) { '↓ ' } else { '  ' }
            if (($top + $viewport) -lt $activeSessions.Count) {
                Write-Host '↓ ' -NoNewline -ForegroundColor Yellow
            } else {
                Write-Host '  ' -NoNewline
            }
            Write-Host (' ' * $spacerRoom)
            $rowBuffer.Add($spacerArrow + (' ' * $spacerRoom))

            $footer = " ! = has a custom title — likely a keeper. Highlighted rows are pre-checked as disposable. Selected items will be permanently deleted."
            if ($footer.Length -gt $width) { $footer = $footer.Substring(0, $width) }
            $footerText = $footer.PadRight($width)
            Write-Host $footerText -ForegroundColor DarkGray
            $rowBuffer.Add($footerText)

            $needRedraw = $false
        }
    } finally {
        [Console]::CursorVisible = $true
        try { [Console]::SetCursorPosition(0, $origTop + $viewport + 4) } catch {}
        Write-Host ''
    }
}

# --- main ---

# When this script is dot-sourced (e.g. by the tests in ./tests), load all the
# function definitions above but skip running the interactive app.
if ($MyInvocation.InvocationName -eq '.') { return }

# Set when the user confirms a jump (J) in the picker or preview; main reads it
# below to cd into the session's directory and resume it with claude.
$script:JumpSession = $null

Clear-Host

if ($About) {
    Show-AboutScreenshot
    return
}

if (-not (Test-Path $ProjectsRoot)) {
    Write-Error "Projects directory not found: $ProjectsRoot"
    exit 1
}

$sessions = Get-AllSessions -Root $ProjectsRoot -ProjectFilter $Project -SnippetMax $SnippetLength

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
