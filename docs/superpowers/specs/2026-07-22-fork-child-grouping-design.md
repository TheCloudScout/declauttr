# Fork / child session grouping in the picker

**Date:** 2026-07-22
**Status:** Approved

## Problem

Claude Code frequently produces several `.jsonl` session files that all belong
to the same underlying conversation. Three mechanisms cause this:

- **Forks** — resuming a session and continuing branches into a new file that
  copies the earlier history. The branches share the same first message
  (identical `uuid` on the first real user/assistant line).
- **Compaction continuations** — when a conversation runs out of context (auto
  or `/compact`), Claude Code summarizes and continues in a brand-new file
  whose first user message is `"This session is being continued from a previous
  conversation that ran out of context..."`. Parent and child both carry the
  same `compactMetadata.preservedSegment` UUIDs.
- **Same auto-title** — related sessions are typically given the same generated
  `ai-title` (or a user-assigned `custom-title`).

In the picker these show up as a flat run of near-identical rows (same title,
adjacent timestamps), which reads as duplication and makes it hard to see which
one is the live conversation and which are stale offshoots.

We want the picker to recognize these families, render the offshoots as
indented children beneath the most recent session (the "parent"), and make
bulk-pruning a whole lineage a single keystroke.

## Goals

- Detect session families **within a project** and group their rows together.
- Render every child row with a leading `∟ ` connector in the Title column,
  indented so the connectors line up directly under the parent's title.
- Order each family so the most-recently-changed session is the parent and its
  children follow it, newest-first.
- Marking the parent for deletion (X) cascades to all its children; children
  can still be marked individually.
- When a long child title marquees, the `∟ ` connector stays put and only the
  title text scrolls.

## Non-goals

- No new CLI parameters or flags.
- No change to the preview / confirm / about / search popups.
- No re-grouping of the family structure per content-filter (see Simplifications).
- No change to the `-About` static screenshot screen.

## Detection

Grouping is computed **per project** (the union-find runs inside each project's
session set, since a family never spans projects).

### Captured signals

`Get-SessionMetadata` gains two fields, both captured in its existing single
streaming pass over the file (no extra reads):

- `FirstMsgUuid` — the `uuid` of the first real user/assistant message
  (`$null` if the session has no such message).
- `CompactRefs` — the set of `preservedSegment` UUIDs (`headUuid`,
  `anchorUuid`, `tailUuid`) found on any `compactMetadata`-bearing line
  (usually one, a small handful of GUID strings).

### Grouping key (same-title fallback)

Each session gets a `GroupKey` derived in `Get-AllSessions`:

- If `Title` is non-empty: `GroupKey = "T:" + Title.Trim().ToLower()`.
- Else if `Snippet` is **non-trivial** — not the `(no user message found)`
  sentinel, not one of the trivial one-word prompts
  (`resume`/`config`/`exit`/`quit`/`clear`/`help`/`init`/`test`), and length
  ≥ 15 (mirrors `Test-RecommendRemoval`): `GroupKey = "S:" + Snippet.Trim().ToLower()`.
- Else: `GroupKey = $null` (session only groups via UUID/compaction edges;
  otherwise stays solo).

The triviality guard is essential: without it, every empty/`resume`/trivial
session in a project would collapse into one bogus family.

### Family assignment (union-find)

New pure helper:

```
Group-SessionsIntoFamilies -Sessions <session list for one project> -> void
```

Builds a union-find over the project's sessions and unions any pair sharing:

1. a non-null `FirstMsgUuid` (fork), or
2. any `CompactRefs` UUID value (compaction lineage), or
3. a non-null `GroupKey` (same title / same non-trivial first message).

Then, for each connected component:

- If the component has one member: `IsParent = $false`, `IsChild = $false`
  (a "solo" row — no connector, no indent).
- If it has more than one: the member with the **latest `Timestamp`** is the
  parent (`IsParent = $true`); every other member is a child
  (`IsChild = $true`). All members get the same `FamilyId` (the parent's Uuid).

Each session object therefore gains: `FamilyId`, `IsParent`, `IsChild`.

## Ordering & layout

`Get-AllSessions` emits the same flat `List[object]` the picker already consumes
(so navigation, delete-in-place `RemoveAt`, filtering all keep working), but the
per-project order changes:

- Families are ordered by their **parent's** `Timestamp`, descending — preserving
  today's "newest first within a project" feel. Solo rows are single-member
  families and sort by their own timestamp.
- Within a family the parent row comes first, then its children sorted by
  `Timestamp` descending (newest child directly under the parent).

### Child row rendering (`Show-SessionPicker`)

The `∟ ` connector lives inside the existing Title column (the `$room` region
after the fixed prefix), so no fixed-column math or `Get-ProjectColumnWidth`
changes are needed. The connector occupies the first 2 columns of the Title
region, which is exactly where the parent's title begins — so the connectors
line up vertically under the parent.

- **Non-selected child row:** write the row prefix in the row's normal color,
  then `∟ ` in **DarkGray**, then the title text in the row's normal color
  (custom-title cyan / recommended dark-yellow / default). Keeping the connector
  a separate dim span reads as a tree branch without colliding with the existing
  color semantics.
- **Selected child row:** composed as a single White-on-DarkBlue line (prefix +
  `∟ ` + title) like every other selected row; the connector is simply part of
  the bar.
- **Parent / solo rows:** rendered exactly as today.

The full plain text of each composed row is still pushed to `$rowBuffer` (as the
header already does across multiple `Write-Host` calls), so dialog drop-shadow
restoration stays row-aligned.

### Marquee (fixed connector)

The connector is a fixed 2-column prefix. For a child row the scroll/truncate
logic operates on the title text within `room - 2` columns; the final Title-cell
content is `"∟ " + <marqueed-or-truncated title>`. Because the connector is
concatenated *outside* the marquee cycle, it never scrolls — this holds whether
the row is drawn as one selected-bar write or as split dim-connector writes.

## Mark cascade

In the `X` key handler of `Show-SessionPicker`:

- If the current row `IsParent`: compute `newState = -not row.Checked`, then set
  `.Checked = $newState` on **every session with the same `FamilyId`** in the
  master `$Sessions` list — including members currently filtered out of the
  active view (marking the parent means "delete this whole lineage").
- Otherwise (child or solo): toggle only the current row, as today.

`A` (toggle all) and `R` (recommended) already assign `.Checked` on every row
directly, so they need no cascade logic and are unchanged. Load-time
recommended pre-checks are **not** cascaded — a pre-check is a suggestion, and
cascading it could silently mark a keeper-parent's entire family.

Delete is unaffected: it acts on whatever is `Checked`. A cascaded family is all
checked and deletes together; a family where the user re-unchecked one child
keeps that child.

## Testing

New `tests/Group-SessionsIntoFamilies.Tests.ps1`, following the existing
dependency-free dot-source pattern (`. "$PSScriptRoot/../Declauttr.ps1"` +
`Assert-Equal`):

- Fork pair (shared `FirstMsgUuid`) → one family, latest = parent, other = child.
- Compaction pair (shared `CompactRefs`) → one family.
- Same-title trio with no UUID/compaction links → one family via `GroupKey`.
- Trivial sessions (`resume`, `(no user message found)`, empty title) → **not**
  grouped (each stays solo).
- Mixed set mirroring a real multi-session project → the approved shape (one
  large family + two solo rows).
- Child ordering: children sorted newest-first under the parent.

`tests/Parse.Tests.ps1` (syntax guard) must still pass. Marquee connector-fixity
and the child-row rendering are verified manually in a live terminal.

Docs: add a "Visual cues" line to the `.SYNOPSIS` block and a README note about
the `∟` grouping and the parent-cascade behaviour.

## Simplifications / risks

- **Filtered view:** the `F` content filter can match a child but not its
  parent (or vice versa). Rows keep their parent/child styling as computed on
  the full set, so a child may appear indented without its parent visible. The
  family structure is not recomputed per filter. Acceptable for v1.
- **Delete path:** families are computed once in `Get-AllSessions` and not
  recomputed after an in-picker delete. Deleting a parent while leaving a child
  unchecked leaves that child rendered indented under `∟` with no parent above
  it until the next run. Cosmetic only (children never cascade against a dead
  `FamilyId`); same class as the filtered-view simplification above.
- **Compaction linkage** relies on both files carrying the `compactMetadata`
  block (as observed in real data). If only one side has it, the same-title
  fallback still groups them.
- **Same-title false grouping:** two genuinely unrelated conversations that
  happen to receive the identical AI title would be shown as one family. This is
  the accepted trade-off of the user-chosen "Lineage + same-title" definition;
  the triviality guard limits the blast radius to titled sessions only.
