# Reclaim operator's guide

For whoever runs Reclaim on the machine day to day. The README covers the design; this covers
what to do.

## "The system drive is full" - the five-minute routine

1. `reclaim hotspots C:` - anything growing fast right now (a runaway log, a dump, a download)?
   Growth is only compared with the previous scan taken in the same mode, so run it the same way
   (elevated or not) each time.
2. `reclaim scan C:` from an **elevated** Windows PowerShell - the unelevated view misses other
   profiles, System Volume Information, Windows\Temp and more. The banner says which mode you are in;
   the "Denied" list shows exactly what was not measured.
3. `reclaim plan C:` - read the groups:
   - **DELETE** (quarantine) and **MOVE** - Reclaim can do these.
   - **DISABLE** / **CLEAR-FROM-APP** - Reclaim prints the command; you decide and run it
     (hibernation, paging file, Windows Update cleanup, Docker/WSL disks, shadow copies).
   - **KEEP** - never touched. UNKNOWN items are here: look at them with `reclaim explain`.
4. `reclaim apply --yes-to-safe` - SAFE items go without questions; everything else is asked one by
   one with its full explanation and the live on-disk size. Or pick items: `reclaim apply --only C-012,C-016`.
5. `reclaim status` - free space per drive (measured), quarantine size, what becomes purge-eligible.

## Reading the scan report

- **Measured** - on-disk bytes found by the walk (logical beside it).
- **Unmeasured** - volume used minus measured: denied folders, NTFS metadata, shadow copies.
  **Overcount** instead means hard links (WinSxS) made the Windows folder look bigger than it is.
- **Cloud-only** - OneDrive placeholders: full logical size, ~0 on disk, never reclaimable.
- **[+X in items below]** - that item's own size excludes nested knowledge-base items listed separately.

## Getting something back

`reclaim undo <receipt-id>` moves every file back after a hash check. If something already exists at an
original path it is left alone and reported as a conflict (see the `undo-*.tsv` next to the files).
Receipt ids are printed by apply and listed by `reclaim status`; receipts live in `<dataRoot>\receipts`.

## Purging

Nothing is ever purged automatically. Once a month: `reclaim purge` lists quarantine entries past their
date. To keep one: `reclaim pin <receipt-id>`. To delete permanently: `reclaim purge --execute` at the
keyboard and type the confirmation phrase. A partially failed purge is not marked purged.

## Things Reclaim refuses, and why

| Message | Meaning | What to do |
|---|---|---|
| `NOT ATTEMPTED: needs an elevated shell` | system location or another user's profile | re-run the printed command as Administrator |
| `REFUSED: close X first` | SAFE-IF-CLOSED and the program is running | close it, apply again |
| `REFUSED: protected location` | drive root, system root, Reclaim's own folders, or `protectedPaths` | intended |
| `REFUSED: the knowledge base no longer matches` | the folder changed since the plan | `reclaim scan` + `reclaim plan` again |
| `in use` / `copied-source-locked` in the TSV | a file was open; the verified copy stays in quarantine, the original stays too | close the program; undo skips these rows |

## Teaching it about new things

Add entries to `kb\local.json` (same format as `kb\knowledge-base.json`, gitignored) when `explain`
shows UNKNOWN for something you understand. The advisor (`reclaim explain <path> --ai`) can suggest what
an item is; it is an opinion only - verify it, then write the entry yourself. Folders that must never be
touched go in `protectedPaths` in `config.local.json`.

## Worklog

Every command appends one line to the configured hub key (default `worklog-reclaim`): time, host,
command, drive, mode, GB reclaimed, receipt ids, a short note. Lines never contain file paths. If the
hub is unreachable the line waits in `<dataRoot>\worklog-pending.txt` and goes with the next successful
run; the command says "NOT sent" when that happens.

## Health check

`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1` - all tests should pass.
They use their own fixture folders and never touch real data or the hub.
