# Reclaim, explained

A disk cleaner for Windows that explains every item before it touches it, never deletes anything,
and can undo whatever it did. Built 2026-09-11 on windows-work.

## The problem it solves

C: was full and nobody could say what was using the space. Normal cleaners either delete things with
a one-word label ("cache"), or show you a pretty chart and leave you guessing. Reclaim's rule is:
**explain, then ask, then act, then leave a receipt.**

For every item it shows what it is, which program made it, why it exists, what breaks if it goes,
how much space actually comes back, and whether it comes back on its own. If it does not know what
something is, it says **UNKNOWN** and refuses to touch it. It never guesses a plausible label.

## Where it lives

| What | Where |
|---|---|
| The program | `Q:\reclaim` - run `Q:\reclaim\reclaim.cmd` |
| Its data (quarantine, receipts, reports, views) | `Y:\_reclaim` |
| Public source | https://github.com/thisstillisntreal/reclaim |
| Machine-only settings (never published) | `Q:\reclaim\config.local.json`, `Q:\reclaim\kb\local.json` |
| Operator guide | `Q:\reclaim\docs\OPERATOR-GUIDE.md`, and the vault note in Agents |

Windows PowerShell 5.1 only. Nothing was installed; the fast part is C# compiled on first run.

## Using it

Open **Windows PowerShell as Administrator** (unelevated it cannot see about 43 GB of C:), then:

```
Q:\reclaim\reclaim.cmd hotspots C:     what is growing right now
Q:\reclaim\reclaim.cmd scan C:         full inventory, ranked, with every folder it could not read
Q:\reclaim\reclaim.cmd explain <path>  one item, in full
Q:\reclaim\reclaim.cmd plan C:         what it proposes; runs nothing
Q:\reclaim\reclaim.cmd apply --yes-to-safe    does the SAFE ones, asks about everything else
Q:\reclaim\reclaim.cmd status          free space, quarantine, what expires when
Q:\reclaim\reclaim.cmd undo R-...      put an item back
Q:\reclaim\reclaim.cmd show C:         visual map in the browser
```

`apply` only ever acts on items from the last `plan`, one at a time, showing the explanation and the
live size before each one. `--yes-to-safe` skips the questions for SAFE items only.

## What "never deletes" means

- Approved items are **moved** to `Y:\_reclaim\quarantine\<date>\<receipt-id>\`, with a manifest that
  records every file's original path, size and SHA-256 hash.
- Across drives it copies, re-reads the copy, compares hashes, and only then removes the original.
  It never overwrites anything at the destination, and it skips files another program is writing.
- `undo <receipt-id>` moves everything back and checks the hashes. If something new appeared at the
  original path it leaves it alone and tells you.
- Quarantined items become "purge-eligible" after 30 days, but **nothing is ever purged
  automatically**. `reclaim purge` only lists; deleting needs `--execute` and a typed confirmation at
  the keyboard, and it refuses to run unattended.
- System-level actions (hibernation, the paging file, Disk Cleanup, DISM, shadow copies, event logs)
  are **printed for you to run**, never executed by the tool.

## What it will not touch

- Any folder you list as **protected** in the local config - never proposed, never moved.
- Anything inside **OneDrive**: moving a file out of a synced folder would delete it from OneDrive on
  every device. Use OneDrive's own "Free up space" instead.
- **Application dependencies**: `node_modules` belonging to installed programs (Adobe, Cursor) and to
  globally installed npm tools. An early version offered these as disposable; that was wrong and is
  fixed.
- Drive roots, Windows, Program Files, ProgramData, whole user profiles, and Reclaim's own folders.
- Anything it cannot identify (UNKNOWN).

## What it found on C:

Elevated, it measures 214.6 GB on a 232 GB drive with 26 GB free.

- **~21 GB it can move for you**, all undo-able: npm cache, old Wireshark captures, a Cursor database
  backup, browser caches, temp folders, crash dumps.
- **~46 GB you free yourself** with the commands it prints: Windows.old 17.6 GB, Windows Search index
  12.9 GB, paging file 9.5 GB, Windows Update downloads 2.9 GB, restore points 2.7 GB.
- OneDrive shows 31 GB on disk; another 139 GB of it is cloud-only and already takes no space.
- Unelevated it cannot see about 43 GB (86 folders refused), and it says so on every run.

Nothing has been applied. The only files it has ever moved are three test files that were created for
that purpose and then restored, byte for byte.

## Trust, and how it was checked

- 55 automated tests: exact byte measurements, a cross-drive quarantine round trip with hash checks,
  undo conflicts, an interrupted move, protected folders, and the offline HTML view.
- Real runs on this machine at every step, elevated and unelevated.
- Two independent code reviews; everything they found was fixed.
- Every run appends one line to the hub key `worklog-reclaim`: time, drive, mode, GB reclaimed and
  receipt ids - never file paths.
- Numbers are always measured at the moment they are printed, and sizes are the space actually used
  on disk, with the "logical" size beside it.

## Two honest caveats

- **Z: is not an SSD.** It is labeled "1 TB SDD" but it is a 7200 rpm spinning disk holding about
  2.1 million files, so a full walk of it takes about 90 minutes. `reclaim hotspots` with no drive
  walks every drive; name the drive you care about for a quick answer.
- Reclaim never proposes or moves anything in a protected folder, but a scan still reads the names and
  sizes inside it into the local scan files. It can be told to skip those folders entirely.
