# Reclaim — design (2026-09-11)

Source spec: owner's build prompt v2 (hub-integrated), vault note
`Agents/claude-oauth/2026-09-10 2045 Reclaim - Windows disk cleaner CLI build prompt v2 hub-integrate.md`,
mirrored as hub KV `task-reclaim`. This document records the approved spec plus the
engineering decisions needed to build it. Owner directives added 2026-09-11:
build on this machine, **delete nothing**, publish as a **public** GitHub repo with **no secrets**.

## Core rule
Explain, then ask, then act, then leave a receipt. Unknown means "unknown".

## Runtime
- Windows PowerShell 5.1 (`powershell.exe`), nothing installed.
- Hot paths (directory walk, classification, scan persistence, hashing, moves) live in a
  C# 5 engine (`src/Engine.cs`) compiled with `Add-Type`, cached as a DLL keyed by source hash.
- PowerShell layer (`src/*.ps1`) owns commands, prompts, printing, hub I/O.
- Entry points: `reclaim.ps1`, `reclaim.cmd` shim.

## Measurement
- Directory enumeration via `CreateFileW(FILE_FLAG_BACKUP_SEMANTICS)` +
  `GetFileInformationByHandleEx(FileFullDirectoryInfo)`: gives EndOfFile (logical),
  AllocationSize (on-disk), attributes, LastWriteTime, reparse tag — no per-file open.
- On-disk = AllocationSize. Cloud placeholders (attr 0x400000 / 0x40000 / 0x1000) → on-disk 0.
- Directory reparse points: descend only into cloud-file dirs (tag `0x9000xxxA`); junctions,
  symlinks and mount points are recorded as skipped, never followed (no double counting).
- Access denied → recorded in the denied list with the path.
- Elevated runs enable SeBackupPrivilege so ACL-restricted dirs (System Volume Information,
  other profiles) are listed. Mode banner on every run.
- Hard links (WinSxS) are counted per link; the KB entry says so and points at DISM's analyzer.

## Knowledge base (`kb/knowledge-base.json`)
Entries: `id, name, patterns[], creator, purpose, breaks, safety, regenerates, action,
method, command, processes[], hotspot, notes`. Patterns are globs: `?:` any drive, `*` one
segment, `**` any depth, `%USERS%` = `?:\Users\*`. Safety: SAFE / SAFE-IF-CLOSED / MOVE /
ADMIN-ONLY / KEEP / UNKNOWN. Most specific pattern wins (most literal characters).

## Item model (deterministic)
Bottom-up over the scanned tree. Big files first, then directories deepest-first:
1. A node matching a KB entry becomes an item sized by its **residual** (its bytes minus
   bytes already claimed by items below it). KB items nested in KB items split off.
2. A node with no KB-matched ancestor whose residual ≥ threshold (1 GB dirs, 500 MB files)
   becomes an UNKNOWN item. UNKNOWN is never auto-approved and never proposed for action.
Item ids are `<drive>-<nnn>` ranked by on-disk bytes within a scan.

## Storage (`Y:\_reclaim\`, override with `RECLAIM_HOME`)
`scans\<D>-<ts>.json` (meta, items, denied, skipped, top files, recent files) +
`scans\<D>-<ts>.dirs.tsv` (every dir ≥ 1 MB: path, on-disk, logical, files, newest write)
· `plans\` · `receipts\<id>.json` · `quarantine\<yyyy-MM-dd>\<id>\` (+ `manifest.json`) ·
`moved\<id>\` · `views\<ts>.html` · `logs\reclaim.log` · `pins.json` · `worklog-pending.txt`.

## Commands
- `scan [drive|all]` (default C:) — walk, classify, persist, ranked table, denied list.
- `hotspots [drive|all]` (default all) — fresh walk; largest files written in 24h/48h/7d;
  fastest-growing folders vs the previous scan of that drive (child explains ≥ 90% → parent
  suppressed); KB `hotspot` locations with size and newest write.
- `explain <path> [--ai]` — live measurement + KB explanation + exact commands; UNKNOWN offers
  to open the folder; `--ai` asks the Haiku advisor (labeled ADVISORY, read-only).
- `plan [drive|all]` — actions from the latest scans; writes `plans\plan-<ts>.json`; runs nothing.
- `apply [--only ids] [--yes-to-safe]` — per item: explanation, confirm, act, receipt.
  DELETE → quarantine move; MOVE → `moved\`; DISABLE / CLEAR-FROM-APP / ADMIN-ONLY → print the
  exact command, record as manual, never executed. SAFE-IF-CLOSED refuses while the creator
  process runs. `--yes-to-safe` auto-approves SAFE only.
- `undo <receipt-id>` — moves every file back after hash check; refuses to overwrite.
- `show <path>` — HTML view + terminal bars.
- `status` — free per drive, quarantine size, next purge-eligible receipts, last worklog line.
- `pin <receipt-id>`, `purge` (lists eligible; deletion requires `--execute` + typed confirm;
  never scheduled, never run by an agent).

## Moves (the only state-changing code)
Per file: sha256 source → copy (same volume: rename) → sha256 destination → compare → only then
remove source. Mismatch or failure: source untouched, receipt marks the file failed. Emptied
folders are left in place (nothing is deleted; undo refills them). Real before/after free
space and per-file status go in the receipt.

## Hub
Every command run appends one line to KV `worklog-reclaim` via the local hub client
(path from gitignored `config.local.json`). Read-modify-write that only appends. On failure the
line goes to `worklog-pending.txt` and is flushed on the next success; the failure is printed.

## Advisor (LLM, read-only)
`claude -p --model claude-haiku-4-5` with names/sizes/extensions only (no file contents).
Must return JSON `{what, creator, purpose, risk}` with "unknown" allowed. Output shown as
ADVISORY; never stored in the KB, never used by plan/apply.

## Visuals
Self-contained HTML (no external URLs): data JSON + inline JS that lays out a squarified
treemap as inline SVG, colored by safety, sized by on-disk bytes, hover = explanation, click =
drill in. If one child ≥ 85% of the total or > 2,000 children, a ranked bar chart is used
instead and the page says why. Terminal fallback: proportional bars.

## Tests (`tests/run-tests.ps1`, no Pester dependency)
Scanner exact bytes on a planted tree; KB glob matching; item residual model; quarantine round
trip cross-volume with hash verify; undo; conflict refusal; hotspots detecting a planted growing
file; plan runs nothing; HTML has no external URLs. Fixtures under `.testrun\` (gitignored) and
`Y:\_reclaim-tests\`; nothing outside those is touched.

## Out of scope
Scheduled runs, auto-purge, executing system commands, junction creation after MOVE.
