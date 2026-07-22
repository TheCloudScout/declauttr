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
