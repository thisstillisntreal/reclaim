# Quarantine.ps1 - apply, undo, receipts, pins, purge.
# Explain, then ask, then act, then leave a receipt. Every decision is re-derived at apply time
# from the knowledge base and the live path - the plan file only selects items. The only file
# operation is a hash-verified move (src\Mover.cs) into <dataRoot>\quarantine or <dataRoot>\moved.

# The single call that moves files. A variable so tests can simulate an interruption mid-move.
$script:ReclaimMoveAll = { param($Files, $DestRoot, $Tsv) [Reclaim.Mover]::MoveAll($Files, $DestRoot, $Tsv) }

# Counts rebuilt from the per-file manifest (used when a move run was interrupted).
function Get-ReclaimTsvSummary([string]$Tsv) {
    $s = New-Object Reclaim.MoveSummary
    if (-not (Test-Path -LiteralPath $Tsv)) { return $s }
    $first = $true
    foreach ($line in [IO.File]::ReadLines($Tsv)) {
        if ($first) { $first = $false; continue }
        $c = $line.Split("`t")
        if ($c.Length -lt 6) { continue }
        $s.Files++
        switch -Regex ($c[0]) {
            '^(ok|moved-hash-changed)$' {
                $s.Moved++; $s.Bytes += [long]$c[2]; $s.OnDisk += [long]$c[3]
                if ($c[0] -eq 'moved-hash-changed') { $s.HashChanged++ }
            }
            '^copied-source-locked$' { $s.Locked++ }
            '^skipped' { $s.Skipped++ }
            default { $s.Failed++ }
        }
    }
    return $s
}

# Nested knowledge-base items keep their own decision. Recomputed from the folder as it is now
# (things may have appeared since the plan), plus whatever the plan excluded. 'files' items are
# excluded file by file, never as a whole folder.
function Get-ReclaimLiveExcludes($Pe) {
    $cfg = Get-ReclaimConfig
    $o = New-ReclaimScanOptions
    $o.Progress = $false
    $r = [Reclaim.Walker]::Scan($Pe.path, $o)
    $items = [Reclaim.Classifier]::Classify($r, (Get-ReclaimKb).Rules, [long]$cfg.dirUnknownMinBytes, [long]$cfg.fileUnknownMinBytes)
    $root = $Pe.path.TrimEnd('\')
    $set = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    foreach ($it in $items) {
        if (-not $it.RuleId) { continue }
        if ($it.Kind -eq 'files') { foreach ($m in $it.Members) { [void]$set.Add($m) }; continue }
        if ($it.Path.TrimEnd('\') -ieq $root) { continue }
        [void]$set.Add($it.Path)
    }
    foreach ($x in @($Pe.exclude)) { if ($x) { [void]$set.Add([string]$x) } }
    return @($set)
}

function New-ReclaimReceiptId {
    return ('R-{0}-{1}' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0, 6))
}

function Get-ReclaimReceiptPath([string]$Id) { return (Join-Path (Get-ReclaimPath 'receipts') "$Id.json") }

function Get-ReclaimReceipt([string]$ReceiptId) {
    $p = Get-ReclaimReceiptPath $ReceiptId
    if (-not (Test-Path -LiteralPath $p)) { throw "No receipt $ReceiptId in $(Get-ReclaimPath 'receipts')" }
    return ([IO.File]::ReadAllText($p) | ConvertFrom-Json)
}

function Write-ReclaimJson([string]$Path, $Object) {
    [IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
}

# Places Reclaim never moves, whatever a plan says. Returns the reason, or $null.
function Test-ReclaimProtectedPath([string]$Path) {
    $p = $Path.TrimEnd('\')
    if ($p.Length -le 3) { return 'a drive root' }
    $cfgProtected = (Get-ReclaimConfig).PSObject.Properties['protectedPaths']
    if ($cfgProtected -and $cfgProtected.Value) {
        foreach ($x in @($cfgProtected.Value)) {
            $xx = ([string]$x).TrimEnd('\')
            if (-not $xx) { continue }
            if ($p -ieq $xx -or $p.StartsWith("$xx\", [StringComparison]::OrdinalIgnoreCase)) { return "protected by config (protectedPaths: $x)" }
        }
    }
    foreach ($x in @((Get-ReclaimConfig).dataRoot.TrimEnd('\'), $script:ReclaimRepoDir.TrimEnd('\'))) {
        if ($p -ieq $x -or $p.StartsWith("$x\", [StringComparison]::OrdinalIgnoreCase) -or
            $x.StartsWith("$p\", [StringComparison]::OrdinalIgnoreCase)) { return "Reclaim's own files ($x)" }
    }
    $rel = $p.Substring(2).ToLowerInvariant()
    foreach ($s in '\windows', '\program files', '\program files (x86)', '\programdata', '\users', '\recovery',
        '\boot', '\system volume information', '\$recycle.bin') {
        if ($rel -eq $s) { return "a system root folder ($p)" }
    }
    if ($rel -match '^\\users\\[^\\]+$') { return "a whole user profile ($p)" }
    return $null
}

function New-ApplyResult($Entry, [string]$Status, [string]$Reason, [string]$ReceiptId = $null, [int]$Moved = 0, [long]$OnDisk = 0) {
    return [pscustomobject]@{
        Id = $Entry.id; Path = $Entry.path; Status = $Status; Reason = $Reason
        ReceiptId = $ReceiptId; Moved = $Moved; OnDisk = $OnDisk
    }
}

# Files the entry would move right now, after re-checking the KB still matches every one of them.
function Get-ReclaimApplyFiles($Pe, $Entry) {
    $list = New-Object 'System.Collections.Generic.List[Reclaim.FileRec]'
    $info = [ordered]@{ Files = $list; Excluded = @($Pe.exclude).Count; Skipped = @(); Denied = @(); Mismatch = $null }
    switch ($Pe.kind) {
        'dir' {
            if (-not [IO.Directory]::Exists($Pe.path)) { $info.Mismatch = 'gone'; break }
            $m = Find-ReclaimRule $Pe.path $false
            if ($m.By -ne 'exact' -or $m.Rule.Id -ne $Pe.ruleId) { $info.Mismatch = 'rule'; break }
            $ex = @(Get-ReclaimLiveExcludes $Pe)
            $info.Excluded = $ex.Count
            $fl = [Reclaim.Mover]::ListFiles($Pe.path, [string[]]$ex)
            foreach ($f in $fl.Files) { $list.Add($f) }
            $info.Skipped = @($fl.Skipped); $info.Denied = @($fl.Denied)
        }
        default {
            $paths = if ($Pe.kind -eq 'files') { @($Pe.members) } else { @($Pe.path) }
            foreach ($p in $paths) {
                $f = [Reclaim.Walker]::StatFile($p)
                if ($null -eq $f) { continue }
                $m = Find-ReclaimRule $p $true
                if ($m.By -ne 'exact' -or $m.Rule.Id -ne $Pe.ruleId) { continue }
                $list.Add($f)
            }
            if ($list.Count -eq 0) { $info.Mismatch = if (@($paths | Where-Object { [Reclaim.Walker]::StatFile($_) }).Count) { 'rule' } else { 'gone' } }
        }
    }
    return [pscustomobject]$info
}

function Invoke-ReclaimApplyEntry($Pe, [bool]$YesToSafe, [scriptblock]$Confirm, [hashtable]$Running, [bool]$Elevated, [string]$PlanStamp) {
    $cfg = Get-ReclaimConfig
    $entry = Get-ReclaimEntry $Pe.ruleId
    Write-Host ''
    Write-Host "$($Pe.id)  $($Pe.path)" -ForegroundColor White

    if (-not $Pe.ruleId -or $entry.safety -eq 'UNKNOWN') { return New-ApplyResult $Pe 'refused' 'UNKNOWN items are never applied' }
    if ($entry.action -notin 'DELETE', 'MOVE') {
        $cmd = if ($entry.command) { $entry.command } else { $entry.method }
        Write-Host "  $($entry.action): Reclaim does not run this. Do it yourself: $cmd" -ForegroundColor Cyan
        return New-ApplyResult $Pe 'manual' "$($entry.action): $cmd"
    }
    $protected = Test-ReclaimProtectedPath $Pe.path
    if ($protected) {
        Write-Host "  REFUSED: protected location - $protected" -ForegroundColor Red
        return New-ApplyResult $Pe 'refused' "protected: $protected"
    }
    $files = Get-ReclaimApplyFiles $Pe $entry
    if ($files.Mismatch -eq 'gone') {
        Write-Host '  Skipped: no longer exists.' -ForegroundColor Yellow
        return New-ApplyResult $Pe 'gone' 'no longer exists'
    }
    if ($files.Mismatch -eq 'rule') {
        Write-Host "  REFUSED: the knowledge base no longer matches this path as '$($Pe.ruleId)'. Re-scan and re-plan." -ForegroundColor Red
        return New-ApplyResult $Pe 'refused' "KB rule '$($Pe.ruleId)' does not match this path"
    }
    if ((Test-ReclaimNeedsAdmin $Pe.path $entry) -and -not $Elevated) {
        $cmd = "reclaim apply --only $($Pe.id)"
        Write-Host "  NOT ATTEMPTED: needs an elevated shell. Open Windows PowerShell as Administrator and run: $cmd" -ForegroundColor Magenta
        return New-ApplyResult $Pe 'needs-admin' "elevated shell required: $cmd"
    }
    if ($null -eq $Running) { $Running = Get-ReclaimRunningProcessNames }   # per item, just before acting
    $busy = @(@($entry.processes) | Where-Object { $_ -and $Running.ContainsKey(([string]$_).ToLowerInvariant()) })
    if ($busy.Count) {
        Write-Host "  REFUSED: close $($busy -join ', ') first ($($entry.safety))." -ForegroundColor Yellow
        return New-ApplyResult $Pe 'refused' "running now: $($busy -join ', ')"
    }

    $onDisk = [long]0; $logical = [long]0; $placeholders = 0
    foreach ($f in $files.Files) {
        if ([Reclaim.Walker]::IsPlaceholder($f.Attributes)) { $placeholders++; continue }
        $onDisk += $f.OnDisk; $logical += $f.Logical
    }
    $isMove = $entry.action -eq 'MOVE'
    $destBase = if ($isMove) { Get-ReclaimPath 'moved' } else { Join-Path (Get-ReclaimPath 'quarantine') (Get-Date).ToString('yyyy-MM-dd') }
    Write-Host ('  What          {0} ({1})' -f $entry.name, $entry.safety) -ForegroundColor (Get-SafetyColor $entry.safety)
    Write-Host ('  Created by    {0}' -f $entry.creator)
    Write-Host ('  Why it exists {0}' -f $entry.purpose)
    Write-Host ('  If it goes    {0}' -f $entry.breaks)
    Write-Host ('  Regenerates   {0}' -f $entry.regenerates)
    Write-Host ('  Comes back    {0} on disk (logical {1}) in {2:N0} files, measured now' -f (Format-Bytes $onDisk), (Format-Bytes $logical), ($files.Files.Count - $placeholders))
    $stays = @()
    if ($files.Excluded) { $stays += "$($files.Excluded) nested item(s) with their own plan entry" }
    if ($placeholders) { $stays += "$placeholders cloud-only placeholder(s)" }
    if (@($files.Skipped).Count) { $stays += "$(@($files.Skipped).Count) link(s)" }
    if (@($files.Denied).Count) { $stays += "$(@($files.Denied).Count) denied folder(s)" }
    if ($stays.Count) { Write-Host ('  Stays put     {0}' -f ($stays -join '; ')) }
    Write-Host ('  Goes to       {0}\<receipt>  ({1}; undo: reclaim undo <receipt>)' -f $destBase, $(if ($isMove) { 'moved' } else { 'quarantined, purge only by you after ' + $cfg.purgeDays + ' days' }))

    if (($files.Files.Count - $placeholders) -eq 0) {
        Write-Host '  Nothing to move.' -ForegroundColor Yellow
        return New-ApplyResult $Pe 'nothing' 'no movable files'
    }
    if ($YesToSafe -and $entry.safety -eq 'SAFE') {
        Write-Host '  Approved by --yes-to-safe (SAFE).' -ForegroundColor Green
    } elseif (-not (& $Confirm $Pe)) {
        Write-Host '  Declined - nothing done.' -ForegroundColor Yellow
        return New-ApplyResult $Pe 'declined' 'not confirmed'
    }

    $rid = New-ReclaimReceiptId
    $dest = Join-Path $destBase $rid
    [void](New-Item -ItemType Directory -Force -Path $dest)
    $tsv = Join-Path $dest 'manifest-files.tsv'
    $drives = @($Pe.path.Substring(0, 1).ToUpperInvariant(), $cfg.dataRoot.Substring(0, 1).ToUpperInvariant()) | Select-Object -Unique
    $freeBefore = [ordered]@{}; foreach ($d in $drives) { $freeBefore[$d] = [Reclaim.Native]::FreeBytes("$($d):\") }
    $toMove = New-Object 'System.Collections.Generic.List[Reclaim.FileRec]'
    foreach ($f in $files.Files) { if (-not [Reclaim.Walker]::IsPlaceholder($f.Attributes)) { $toMove.Add($f) } }
    $receipt = [ordered]@{
        id = $rid; created = (Get-Date).ToString('s'); host = $cfg.hostName; mode = (Get-ReclaimMode)
        action = $(if ($isMove) { 'move' } else { 'quarantine' }); status = 'in-progress'; error = $null
        item = [ordered]@{ planId = $Pe.id; planStamp = $PlanStamp; path = $Pe.path; kind = $Pe.kind; ruleId = $Pe.ruleId; name = $entry.name; safety = $entry.safety }
        explanation = [ordered]@{ what = $entry.name; creator = $entry.creator; purpose = $entry.purpose; breaks = $entry.breaks; regenerates = $entry.regenerates; method = $entry.method }
        dest = $dest; filesRoot = (Join-Path $dest 'files'); manifestTsv = $tsv
        counts = [ordered]@{ files = $toMove.Count; moved = 0; failed = 0; skipped = 0; locked = 0; hashChanged = 0; excludedItems = $files.Excluded; placeholders = $placeholders }
        bytes = [ordered]@{ logical = 0; onDisk = 0 }
        free = [ordered]@{ before = $freeBefore; after = $null }
        purgeAfter = $(if ($isMove) { $null } else { (Get-Date).AddDays([int]$cfg.purgeDays).ToString('s') })
        undo = "reclaim undo $rid"
    }
    # Written before the first file moves, so an interrupted run still leaves an undo-able receipt.
    Write-ReclaimJson (Get-ReclaimReceiptPath $rid) $receipt
    Write-ReclaimJson (Join-Path $dest 'manifest.json') $receipt

    $interrupted = $null
    try { $sum = & $script:ReclaimMoveAll $toMove (Join-Path $dest 'files') $tsv }
    catch { $interrupted = $_.Exception.Message; $sum = Get-ReclaimTsvSummary $tsv }
    $freeAfter = [ordered]@{}; foreach ($d in $drives) { $freeAfter[$d] = [Reclaim.Native]::FreeBytes("$($d):\") }
    $status = if ($interrupted) { 'interrupted' } elseif ($sum.Moved -eq $toMove.Count) { 'ok' } elseif ($sum.Moved -gt 0) { 'partial' } else { 'failed' }
    $receipt.status = $status
    $receipt.error = $interrupted
    $receipt.counts = [ordered]@{ files = $toMove.Count; moved = $sum.Moved; failed = $sum.Failed; skipped = $sum.Skipped; locked = $sum.Locked; hashChanged = $sum.HashChanged; excludedItems = $files.Excluded; placeholders = $placeholders }
    $receipt.bytes = [ordered]@{ logical = $sum.Bytes; onDisk = $sum.OnDisk }
    $receipt.free.after = $freeAfter
    Write-ReclaimJson (Get-ReclaimReceiptPath $rid) $receipt
    Write-ReclaimJson (Join-Path $dest 'manifest.json') $receipt
    if ($interrupted) { Write-Host "  INTERRUPTED: $interrupted - $($sum.Moved) file(s) had moved; the receipt lists them and undo works." -ForegroundColor Red }
    if ($sum.HashChanged) { Write-Host "  $($sum.HashChanged) file(s) changed while being moved (they moved; hashes recorded after the move)." -ForegroundColor Yellow }
    Write-ReclaimLog ("apply {0} {1} {2}: {3}/{4} files, {5} on disk -> {6}" -f $rid, $receipt.action, $status, $sum.Moved, $sum.Files, (Format-Bytes $sum.OnDisk), $dest)

    $src = $Pe.path.Substring(0, 1).ToUpperInvariant()
    $color = if ($status -eq 'ok') { 'Green' } elseif ($status -eq 'partial') { 'Yellow' } else { 'Red' }
    Write-Host ('  RESULT {0}: moved {1} of {2} files, {3} on disk; failed {4}, in use {5}, skipped {6}.' -f $status.ToUpperInvariant(),
        $sum.Moved, $sum.Files, (Format-Bytes $sum.OnDisk), $sum.Failed, $sum.Locked, $sum.Skipped) -ForegroundColor $color
    Write-Host ('  Free on {0}: {1} -> {2} (measured). Receipt {3}. Undo: reclaim undo {3}' -f "$($src):", (Format-Bytes $freeBefore[$src]), (Format-Bytes $freeAfter[$src]), $rid)
    if ($sum.Failed -or $sum.Locked) { Write-Host "  Per-file detail: $tsv" -ForegroundColor Yellow }
    return New-ApplyResult $Pe $status "$($sum.Moved)/$($sum.Files) files" $rid $sum.Moved $sum.OnDisk
}

function Invoke-ReclaimApply {
    param(
        [string[]]$Only = @(),
        [switch]$YesToSafe,
        [scriptblock]$Confirm = $null,
        $Plan = $null,
        [hashtable]$Running = $null,
        $Elevated = $null
    )
    $cfg = Get-ReclaimConfig
    if ($null -eq $Plan) { $Plan = Get-LatestPlan }
    if ($null -eq $Plan) { throw 'No plan yet. Run: reclaim plan' }
    if ($null -eq $Elevated) { $Elevated = Test-ReclaimElevated }
    if ($null -eq $Confirm) {
        $interactive = -not [Console]::IsInputRedirected
        $Confirm = {
            param($Pe)
            if (-not $interactive) { Write-Host '  No keyboard (input redirected): not confirmed.' -ForegroundColor Yellow; return $false }
            $verb = if ($Pe.action -eq 'MOVE') { 'Move' } else { 'Quarantine' }
            return ((Read-Host "  $verb $($Pe.id)? Type y to proceed [y/N]") -match '^(y|yes)$')
        }
    }
    Write-Host "Apply - plan $($Plan.stamp) ($($Plan.time)). Nothing is deleted; every move is hash-verified and undo-able." -ForegroundColor White

    $entries = @($Plan.entries)
    $selected = New-Object System.Collections.ArrayList
    $results = New-Object System.Collections.ArrayList
    if ($Only.Count) {
        foreach ($id in $Only) {
            $m = @($entries | Where-Object { $_.id -eq $id })
            if ($m.Count) { [void]$selected.Add($m[0]) }
            else {
                Write-Host "$id is not in plan $($Plan.stamp)." -ForegroundColor Red
                [void]$results.Add([pscustomobject]@{ Id = $id; Path = $null; Status = 'not-in-plan'; Reason = "not in plan $($Plan.stamp)"; ReceiptId = $null; Moved = 0; OnDisk = 0 })
            }
        }
    } else {
        foreach ($e in $entries) { if ($e.executable) { [void]$selected.Add($e) } }
    }
    foreach ($pe in $selected) {
        [void]$results.Add((Invoke-ReclaimApplyEntry $pe ([bool]$YesToSafe) $Confirm $Running ([bool]$Elevated) $Plan.stamp))
    }

    $dataDrive = $cfg.dataRoot.Substring(0, 1).ToUpperInvariant()
    $done = @($results | Where-Object { $_.ReceiptId })
    $freed = [long]0
    foreach ($r in $done) { if ($r.Path.Substring(0, 1).ToUpperInvariant() -ne $dataDrive) { $freed += [long]$r.OnDisk } }
    Write-Host ''
    $counts = ($results | Group-Object Status | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
    Write-Host ("Apply finished: {0}. Moved off the source drives: {1}." -f $(if ($counts) { $counts } else { 'nothing selected' }), (Format-Bytes $freed)) -ForegroundColor White
    $drivesText = (@($done | ForEach-Object { $_.Path.Substring(0, 2) }) | Select-Object -Unique) -join ','
    Write-WorklogStatus (Write-ReclaimWorklog -Command 'apply' -Drive $(if ($drivesText) { $drivesText } else { '-' }) -ReclaimedBytes $freed `
        -Receipts @($done | ForEach-Object { $_.ReceiptId }) -Note $(if ($counts) { $counts } else { 'nothing selected' }))
    return $results
}

function Test-ReclaimUndone([string]$Id) {
    $dir = Get-ReclaimPath 'receipts'
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter "$Id.undo-*.json" -ErrorAction SilentlyContinue)) {
        if (([IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json).status -eq 'ok') { return $true }
    }
    return $false
}

function Test-ReclaimPinned([string]$Id) { return (Test-Path -LiteralPath (Join-Path (Get-ReclaimPath 'receipts') "$Id.pin.json")) }

function Test-ReclaimPurged([string]$Id) { return (Test-Path -LiteralPath (Join-Path (Get-ReclaimPath 'receipts') "$Id.purged.json")) }

function Invoke-ReclaimUndo([string]$ReceiptId) {
    $rc = Get-ReclaimReceipt $ReceiptId
    if (Test-ReclaimPurged $ReceiptId) { throw "$ReceiptId was purged; nothing to restore." }
    if (Test-ReclaimUndone $ReceiptId) { throw "$ReceiptId was already undone." }
    Write-Host "Undo $ReceiptId - $($rc.item.name): $($rc.counts.moved) file(s) back to $($rc.item.path). Existing files are never overwritten." -ForegroundColor White
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $undoTsv = Join-Path $rc.dest "undo-$stamp.tsv"
    $drive = $rc.item.path.Substring(0, 1).ToUpperInvariant()
    $before = [Reclaim.Native]::FreeBytes("$($drive):\")
    $sum = [Reclaim.Mover]::Restore($rc.manifestTsv, $undoTsv)
    $after = [Reclaim.Native]::FreeBytes("$($drive):\")
    $status = if ($sum.Files -eq 0) { 'nothing' } elseif ($sum.Moved -eq $sum.Files) { 'ok' } elseif ($sum.Moved -gt 0) { 'partial' } else { 'failed' }
    $undo = [ordered]@{
        receiptId = $ReceiptId; undoneAt = (Get-Date).ToString('s'); mode = (Get-ReclaimMode); status = $status
        counts = [ordered]@{ files = $sum.Files; restored = $sum.Moved; conflicts = $sum.Conflicts; failed = $sum.Failed; skipped = $sum.Skipped }
        bytes = $sum.Bytes; undoTsv = $undoTsv; free = [ordered]@{ drive = $drive; before = $before; after = $after }
    }
    Write-ReclaimJson (Join-Path (Get-ReclaimPath 'receipts') "$ReceiptId.undo-$stamp.json") $undo
    Write-ReclaimLog "undo $ReceiptId $status : $($sum.Moved)/$($sum.Files) restored, $($sum.Conflicts) conflicts"
    $color = if ($status -eq 'ok') { 'Green' } else { 'Yellow' }
    Write-Host ('RESULT {0}: restored {1} of {2} files ({3}); conflicts {4}; failed {5}. Free on {6}: {7} -> {8}.' -f $status.ToUpperInvariant(),
        $sum.Moved, $sum.Files, (Format-Bytes $sum.Bytes), $sum.Conflicts, $sum.Failed, "$($drive):", (Format-Bytes $before), (Format-Bytes $after)) -ForegroundColor $color
    if ($sum.Conflicts -or $sum.Failed) { Write-Host "Per-file detail: $undoTsv" -ForegroundColor Yellow }
    Write-WorklogStatus (Write-ReclaimWorklog -Command 'undo' -Drive "$($drive):" -Receipts @($ReceiptId) -Note "$status; restored $($sum.Moved)/$($sum.Files) files")
    return [pscustomobject]@{ ReceiptId = $ReceiptId; Status = $status; Restored = $sum.Moved; Conflicts = $sum.Conflicts; Failed = $sum.Failed; Skipped = $sum.Skipped }
}

function Set-ReclaimPin([string]$ReceiptId) {
    [void](Get-ReclaimReceipt $ReceiptId)
    $p = Join-Path (Get-ReclaimPath 'receipts') "$ReceiptId.pin.json"
    if (Test-Path -LiteralPath $p) { Write-Host "$ReceiptId is already pinned."; return }
    Write-ReclaimJson $p ([ordered]@{ receiptId = $ReceiptId; pinnedAt = (Get-Date).ToString('s') })
    Write-Host "Pinned $ReceiptId - it will never be listed for purge." -ForegroundColor Green
    Write-ReclaimLog "pin $ReceiptId"
}

# Quarantine receipts still holding files: not undone, not purged, not pinned.
function Get-ReclaimQuarantineEntries {
    $dir = Get-ReclaimPath 'receipts'
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'R-*.json' | Where-Object { $_.Name -match '^R-[^.]+\.json$' })) {
        $rc = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
        if ($rc.action -ne 'quarantine' -or $rc.status -eq 'failed') { continue }
        if ((Test-ReclaimUndone $rc.id) -or (Test-ReclaimPurged $rc.id)) { continue }
        [pscustomobject]@{
            id = $rc.id; created = $rc.created; purgeAfter = $rc.purgeAfter; dest = $rc.dest
            onDisk = [long]$rc.bytes.onDisk; name = $rc.item.name; path = $rc.item.path; pinned = (Test-ReclaimPinned $rc.id)
        }
    }
}

function Get-ReclaimPurgeCandidates([datetime]$AsOf = (Get-Date)) {
    return @(Get-ReclaimQuarantineEntries | Where-Object { -not $_.pinned -and [datetime]$_.purgeAfter -le $AsOf } | Sort-Object purgeAfter)
}

function Invoke-ReclaimPurge([switch]$Execute, [bool]$Interactive = (-not [Console]::IsInputRedirected), [datetime]$AsOf = (Get-Date)) {
    $c = @(Get-ReclaimPurgeCandidates -AsOf $AsOf)
    Write-Host "Quarantine entries past their purge date and not pinned: $($c.Count)" -ForegroundColor White
    foreach ($x in $c) { Write-Host ('  {0}  {1,10}  created {2}  {3} -> {4}' -f $x.id, (Format-Bytes $x.onDisk), $x.created, $x.name, $x.path) }
    $total = [long]0; foreach ($x in $c) { $total += $x.onDisk }
    if (-not $Execute) {
        Write-Host 'Listing only - nothing was deleted. Permanent deletion is owner-only: reclaim purge --execute (asks you to type a confirmation).' -ForegroundColor Green
        Write-WorklogStatus (Write-ReclaimWorklog -Command 'purge-list' -Note "$($c.Count) eligible, $(Format-Bytes $total)")
        return [pscustomobject]@{ Status = 'listed'; Count = $c.Count }
    }
    if (-not $Interactive) {
        Write-Host 'REFUSED: purge --execute permanently deletes files and needs a person at the keyboard (input is redirected).' -ForegroundColor Red
        Write-WorklogStatus (Write-ReclaimWorklog -Command 'purge' -Note 'refused: not interactive')
        return [pscustomobject]@{ Status = 'refused'; Count = $c.Count }
    }
    if (-not $c.Count) { return [pscustomobject]@{ Status = 'nothing'; Count = 0 } }
    $phrase = "PURGE $($c.Count)"
    $typed = Read-Host "This PERMANENTLY deletes $($c.Count) quarantine entries ($(Format-Bytes $total)). Type '$phrase' to continue"
    if ($typed -cne $phrase) {
        Write-Host 'Not confirmed - nothing deleted.' -ForegroundColor Yellow
        return [pscustomobject]@{ Status = 'declined'; Count = $c.Count }
    }
    $qroot = (Get-ReclaimPath 'quarantine').TrimEnd('\') + '\'
    $done = @()
    foreach ($x in $c) {
        if (-not $x.dest.StartsWith($qroot, [StringComparison]::OrdinalIgnoreCase)) { Write-Host "  skipped $($x.id): not under $qroot" -ForegroundColor Red; continue }
        try { Remove-Item -LiteralPath $x.dest -Recurse -Force -ErrorAction Stop } catch { }
        if (Test-Path -LiteralPath $x.dest) {
            Write-Host "  FAILED to purge $($x.id): some files could not be deleted (in use?). Not marked purged; undo still works for what remains." -ForegroundColor Red
            Write-ReclaimLog "purge FAILED $($x.id) $($x.dest)"
            continue
        }
        Write-ReclaimJson (Join-Path (Get-ReclaimPath 'receipts') "$($x.id).purged.json") ([ordered]@{ receiptId = $x.id; purgedAt = (Get-Date).ToString('s'); onDisk = $x.onDisk })
        Write-ReclaimLog "purge $($x.id) $($x.dest)"
        $done += $x.id
    }
    Write-Host "Purged $($done.Count) entries." -ForegroundColor White
    Write-WorklogStatus (Write-ReclaimWorklog -Command 'purge' -Receipts $done -Note "purged $($done.Count), $(Format-Bytes $total)")
    return [pscustomobject]@{ Status = 'purged'; Count = $done.Count }
}
