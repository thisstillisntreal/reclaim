# Reclaim

A Windows disk cleaner that explains every item before it touches anything, never deletes, and
leaves a receipt for everything it does.

**Explain, then ask, then act, then leave a receipt.** Before anything moves you see what it is,
which program made it, why it exists, what breaks if it goes, how much on-disk space comes back
and whether it regenerates. Anything the knowledge base cannot identify is reported as
**UNKNOWN** and is never acted on.

```
reclaim scan [drive|all] [--view]        read-only inventory, ranked table, every denied path (default C:)
reclaim hotspots [drive|all]             what is filling the disk right now (default: all fixed drives)
reclaim explain <path> [--ai]            one item, full explanation, exact reclaim command
reclaim plan [drive|all]                 proposes DELETE / MOVE / DISABLE / CLEAR-FROM-APP / KEEP; runs nothing
reclaim apply [--only ids] [--yes-to-safe]   acts on the last plan, one item at a time, confirming each
reclaim undo <receipt-id>                moves a quarantined item back
reclaim show <path|drive>                offline HTML treemap + terminal bars
reclaim status                           free space, quarantine size, next purge, last worklog line
reclaim pin <receipt-id>                 keep a quarantine entry past its purge date
reclaim purge [--execute]                lists entries past their purge date; --execute is owner-only
```

## Safety model

- **Nothing is deleted.** `DELETE` in a plan means *quarantine*: files are moved into
  `<dataRoot>\quarantine\<date>\<receipt-id>\`. `MOVE` relocates them to `<dataRoot>\moved\<receipt-id>\`.
  Both are undo-able.
- **Every move is verified.** Across volumes: copy while hashing (SHA-256), re-hash the copy, and only
  then remove the source. A destination is never overwritten. A file another program is writing is
  not moved. Cloud-only OneDrive placeholders and links are left alone.
- **Receipts.** Each applied item gets `receipts\<id>.json`, a `manifest.json` next to the files, and a
  per-file `manifest-files.tsv` (status, SHA-256, bytes, original path, quarantine path), written before
  and during the move so an interrupted run still leaves an undo-able receipt.
- **Decisions are deterministic.** What may be moved comes only from the knowledge base
  (`kb\knowledge-base.json`) and live checks at apply time: the rule must still match the path, the
  path must not be protected, the creator process must not be running (SAFE-IF-CLOSED), admin-only
  items are never attempted from an unelevated shell (the exact elevated command is printed instead).
  The plan file only selects items.
- **System actions are print-only.** Hibernation, the paging file, DISM, shadow copies, Windows Update
  cleanup: Reclaim prints the exact command and never runs it.
- **Purge is never automatic.** `reclaim purge` lists quarantine entries older than `purgeDays`
  (default 30) that are not pinned. Permanent deletion needs `--execute` and a typed confirmation at a
  keyboard; it refuses when input is redirected.
- **Protected locations.** Drive roots, Windows/Program Files/ProgramData/Users roots, whole user
  profiles, Reclaim's own folders, and anything listed in `protectedPaths` are never moved.
- **No LLM in any decision.** `explain --ai` can ask a model (via the Claude Code CLI, safe mode, no
  tools, names and sizes only) for an opinion on an UNKNOWN item. The answer is labeled ADVISORY and is
  never stored or used by plan or apply.

## Requirements

Windows 10 or 11 with the built-in **Windows PowerShell 5.1**. Nothing to install: the engine is C#
compiled on first run with `Add-Type` and cached under `%LOCALAPPDATA%\Reclaim\bin`.

Optional: Python plus a hub client module (for the run worklog), and the `claude` CLI (for `explain --ai`).

## Setup

```
git clone <this repo>
copy config.example.json config.local.json      # then edit dataRoot, protectedPaths, hubClient
reclaim.cmd help
```

`config.local.json` and `kb\local.json` are gitignored: machine-specific settings and knowledge-base
entries live there. Keys: `dataRoot` (where quarantine, receipts, scans and views go - pick a large
drive), `protectedPaths`, `purgeDays`, `dirUnknownMinBytes` / `fileUnknownMinBytes` (UNKNOWN reporting
thresholds), `tableRows`, `hubClient` / `python` / `hubEnabled` / `worklogKey`, `advisorModel`.

## Typical session

```
reclaim hotspots C:          # what grew recently
reclaim scan C:              # full inventory; run it again from an elevated shell to see everything
reclaim explain "C:\path"    # anything you want to understand
reclaim plan C:              # proposal only
reclaim apply --yes-to-safe  # SAFE items auto-approved, everything else asked one by one
reclaim status
reclaim undo R-...           # if you want something back
```

## How sizes are measured

- Folders are read with `GetFileInformationByHandleEx(FileFullDirectoryInfo)`: every entry's
  **on-disk size** (NTFS allocation) and **logical size** come from the directory listing; files are
  not opened. Every printed size is on-disk first, logical beside it.
- OneDrive Files On-Demand placeholders (RecallOnDataAccess / RecallOnOpen / Offline) occupy ~0 on disk
  and are never counted as reclaimable.
- Junctions, symbolic links and mount points are recorded and not followed (no double counting).
  OneDrive cloud folders are followed.
- Access-denied folders are listed on every run. Unelevated runs cannot see other profiles, System
  Volume Information or other users' recycle bins; elevated runs enable SeBackupPrivilege for
  read-only listing. The report shows the gap between "volume used" and "measured".
- Hard links (WinSxS / System32) are counted once per link, so Windows folder sizes overstate real
  usage; the report says so when measured exceeds used.

## Knowledge base

`kb\knowledge-base.json` maps path patterns to: name, creator, purpose, what breaks, safety
(SAFE / SAFE-IF-CLOSED / MOVE / ADMIN-ONLY / KEEP), regenerates, action, method, exact command, and the
processes that must be closed. Patterns: `?:` any drive, `*` inside one path segment, `**\` any depth,
`%USERS%` = `?:\Users\*`. The most specific pattern wins. `kind: "file"` rules match files.

Items are sized by their **residual**: a folder's bytes minus the bytes of knowledge-base items nested
inside it, which keep their own entry and are excluded when the folder is applied. Space outside any
knowledge-base entry is reported as UNKNOWN once a folder holds at least `dirUnknownMinBytes`
(1 GB by default).

## Data root layout

```
scans\<D>-<stamp>.json + .dirs.tsv    scan results (hotspots compares the last two in the same mode)
plans\plan-<stamp>.json               proposals
receipts\<id>.json (+ .undo-*.json, .pin.json, .purged.json)
quarantine\<date>\<id>\               files\ + manifest.json + manifest-files.tsv
moved\<id>\                           relocated items
views\<stamp>.html                    visuals
logs\reclaim.log                      one line per action
worklog-pending.txt                   worklog lines waiting for the hub
```

## Tests

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1 [-Filter Quarantine]
```

The suite measures planted files to the exact byte, round-trips quarantine and undo across volumes
with hash checks, simulates an interrupted move, detects a planted growing file, and checks the HTML
view has no external references. Fixtures go under `<repo drive>\_reclaim-testrun\` and
`Y:\_reclaim-tests\` (override with `RECLAIM_TEST_XVOL`); they are not removed automatically.

## Limitations

- Local fixed NTFS drives only; network and removable drives are not scanned.
- Walk speed is bound by the disk: an SSD lists thousands of folders per second, a spinning disk with
  millions of files and several antivirus filter drivers can drop to ~100 folders per second, so a full
  walk of such a drive can take an hour. `hotspots` walks every fixed drive by default; name one drive
  (`reclaim hotspots C:`) when you only care about one.
- Alternate data streams are not measured.
- `moved\` items are not purge candidates; move them back with undo or manage them yourself.
- Purge is the one permanent action and needs you at the keyboard.
