# Plan.ps1 - proposes one action per scanned item, straight from the knowledge base. Runs nothing.
# DELETE = quarantine move (undo-able), MOVE = relocate to the data drive (undo-able),
# DISABLE / CLEAR-FROM-APP = printed commands the owner runs, KEEP = never touched.
# UNKNOWN is always KEEP. A folder item's size is its residual: nested items keep their own entry
# and are excluded when the folder is applied.

function Get-ReclaimRunningProcessNames {
    $set = @{}
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) { $set[$p.ProcessName.ToLowerInvariant()] = $true }
    return $set
}

# Measure-Object -Sum yields nothing usable for an empty input under StrictMode; sum by hand.
function Get-ReclaimSum($Objects, [string]$Property) {
    $s = [long]0
    foreach ($o in @($Objects)) { $s += [long]$o.$Property }
    return $s
}

# The rule an item has under the knowledge base as it is now; the scan may predate KB edits.
# No exact match any more means UNKNOWN (never proposed).
function Get-ReclaimCurrentRuleId($Item) {
    $rules = (Get-ReclaimKb).Rules
    $path = if ($Item.kind -eq 'files' -and @($Item.members).Count) { [string]@($Item.members)[0] } else { [string]$Item.path }
    $path = $path.TrimEnd('\')
    $i = [Reclaim.Rule]::Best($rules, ($Item.kind -ne 'dir'), [IO.Path]::GetFileName($path), $path)
    if ($i -ge 0) { return $rules[$i].Id }
    return $null
}

function ConvertTo-ReclaimPlanEntries($Scan) {
    $dataDrive = (Get-ReclaimConfig).dataRoot.Substring(0, 1).ToUpperInvariant()
    $running = Get-ReclaimRunningProcessNames
    $items = @($Scan.items)
    foreach ($it in $items) {
        $ruleId = Get-ReclaimCurrentRuleId $it
        $e = Get-ReclaimEntry $ruleId
        $safety = if ($ruleId) { $e.safety } else { 'UNKNOWN' }
        $action = if ($safety -eq 'UNKNOWN') { 'KEEP' } else { $e.action }
        $needsAdmin = Test-ReclaimNeedsAdmin $it.path $e
        $executable = $action -in 'DELETE', 'MOVE'
        $drive = $it.path.Substring(0, 1).ToUpperInvariant()

        $command = ''
        if ($executable) {
            $command = "reclaim apply --only $($it.id)" + $(if ($needsAdmin) { '      (elevated)' } else { '' })
        } elseif ($action -ne 'KEEP' -and $e.command) {
            $command = ($e.command -replace '<id>', $it.id) -replace '<D>', $drive
        }

        $frees = [long]0
        $freesNote = ''
        if ($executable) {
            if ($drive -eq $dataDrive) { $freesNote = 'same volume as the quarantine: frees space only after purge' }
            else { $frees = [long]$it.onDisk }
        } elseif ($action -ne 'KEEP') { $freesNote = 'up to its size, done by the owning program' }

        $reason = if ($safety -eq 'UNKNOWN') { 'unknown - not in the knowledge base; never proposed' }
                  else { "$safety; regenerates: $($e.regenerates)" }
        # Protected locations: config protectedPaths are always KEEP; built-in ones block moves.
        $prot = Test-ReclaimProtectedPath $it.path
        if ($prot -and ($prot -like 'protected by config*' -or $executable)) {
            $action = 'KEEP'; $executable = $false; $command = ''; $frees = [long]0; $freesNote = ''
            $reason = "protected: $prot"
        }
        $procs = @(Get-EntryValue $e 'processes' @())
        $runningNow = @($procs | Where-Object { $_ -and $running.ContainsKey($_.ToLowerInvariant()) })

        $exclude = @()
        if ($it.kind -eq 'dir') {
            $prefix = $it.path.TrimEnd('\') + '\'
            $self = $it
            $exclude = @($items | Where-Object {
                    $_.id -ne $self.id -and ($_.path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
                        ($_.kind -eq 'files' -and $_.path.TrimEnd('\') -ieq $self.path.TrimEnd('\')))
                } | ForEach-Object { if ($_.kind -eq 'files') { @($_.members) } else { $_.path } })
        }

        [pscustomobject][ordered]@{
            id = $it.id; drive = $drive; kind = $it.kind; path = $it.path; ruleId = $ruleId; name = $e.name
            safety = $safety; action = $action; executable = $executable; needsAdmin = $needsAdmin
            onDisk = [long]$it.onDisk; logical = [long]$it.logical; frees = $frees; freesNote = $freesNote
            command = $command; method = $e.method; reason = $reason
            processes = $procs; runningNow = $runningNow
            members = @($it.members); exclude = $exclude
        }
    }
}

# Totals per action plus the two headline numbers: what apply can free now, and what the owning
# programs could give back by hand (DISABLE / CLEAR-FROM-APP entries that are not rated KEEP -
# uninstalling software or emptying OneDrive is not counted as reclaimable space).
function Get-ReclaimPlanTotals($Entries) {
    $all = @($Entries)
    $totals = [ordered]@{}
    foreach ($a in 'DELETE', 'MOVE', 'DISABLE', 'CLEAR-FROM-APP', 'KEEP') {
        $g = @($all | Where-Object { $_.action -eq $a })
        $totals[$a] = [ordered]@{ count = $g.Count; onDisk = (Get-ReclaimSum $g 'onDisk'); frees = (Get-ReclaimSum $g 'frees') }
    }
    $totals['byApply'] = [long]$totals['DELETE'].frees + [long]$totals['MOVE'].frees
    $totals['byHand'] = Get-ReclaimSum @($all | Where-Object { $_.action -in 'DISABLE', 'CLEAR-FROM-APP' -and $_.safety -ne 'KEEP' }) 'onDisk'
    return $totals
}

function New-ReclaimPlan([string[]]$Drives) {
    $cfg = Get-ReclaimConfig
    $entries = New-Object System.Collections.ArrayList
    $scans = New-Object System.Collections.ArrayList
    foreach ($d in $Drives) {
        $scan = Get-LatestScan -Drive $d
        if ($null -eq $scan) { Write-Host "No scan of $($d): yet - run: reclaim scan $($d):" -ForegroundColor Yellow; continue }
        [void]$scans.Add([ordered]@{ drive = $d; file = $scan.file; time = $scan.time; mode = $scan.mode })
        foreach ($e in @(ConvertTo-ReclaimPlanEntries -Scan $scan)) { [void]$entries.Add($e) }
    }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $file = Join-Path (Get-ReclaimPath 'plans') "plan-$stamp.json"
    $totals = Get-ReclaimPlanTotals $entries
    $plan = [ordered]@{
        version = 1; kind = 'plan'; stamp = $stamp; time = (Get-Date).ToString('s'); mode = (Get-ReclaimMode)
        host = $cfg.hostName; scans = @($scans); totals = $totals; entries = @($entries); file = $file
    }
    [IO.File]::WriteAllText($file, ($plan | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
    Write-ReclaimLog "plan $stamp : $($entries.Count) entries -> $file"
    return [pscustomobject]$plan
}

function Get-LatestPlan {
    $dir = Get-ReclaimPath 'plans'
    $f = @(Get-ChildItem -LiteralPath $dir -Filter 'plan-*.json' | Sort-Object Name -Descending) | Select-Object -First 1
    if ($null -eq $f) { return $null }
    return ([IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json)
}

function Write-ReclaimPlanReport($Plan) {
    $cfg = Get-ReclaimConfig
    $entries = @($Plan.entries)
    Write-Host ''
    $from = (@($Plan.scans) | ForEach-Object { "$($_.drive): $($_.time) $($_.mode)" }) -join '; '
    Write-Host "Plan $($Plan.stamp)   from scans: $from" -ForegroundColor White
    Write-Host '  NOTHING HAS BEEN DONE. This is a proposal; apply asks about every item.' -ForegroundColor Green
    $groups = @(
        @('DELETE', "DELETE -> quarantine: moved to $(Join-Path $cfg.dataRoot 'quarantine') with a manifest; undo-able; purge only by you"),
        @('MOVE', "MOVE -> $(Join-Path $cfg.dataRoot 'moved'); undo-able"),
        @('DISABLE', 'DISABLE -> Reclaim prints the command; you run it'),
        @('CLEAR-FROM-APP', 'CLEAR-FROM-APP -> done inside the owning program; Reclaim prints how'))
    foreach ($g in $groups) {
        $rows = @($entries | Where-Object { $_.action -eq $g[0] })
        if (-not $rows.Count) { continue }
        $t = $Plan.totals.($g[0])
        Write-Host ''
        Write-Host ("{0}   [{1} items, {2} on disk; frees now {3}]" -f $g[1], $t.count, (Format-Bytes $t.onDisk), (Format-Bytes $t.frees)) -ForegroundColor White
        foreach ($r in ($rows | Select-Object -First 40)) {
            $flags = @()
            if ($r.needsAdmin -and -not (Test-ReclaimElevated)) { $flags += 'ADMIN: elevated only' }
            if (@($r.runningNow).Count) { $flags += "running now: $(@($r.runningNow) -join ', ')" }
            if ($r.freesNote -and $r.executable) { $flags += $r.freesNote }
            $flagText = if ($flags.Count) { '  [' + ($flags -join '; ') + ']' } else { '' }
            Write-Host ('  {0,-7} {1,10}  {2,-14} {3} -> {4}{5}' -f $r.id, (Format-Bytes $r.onDisk), $r.safety, $r.name, $r.path, $flagText) -ForegroundColor (Get-SafetyColor $r.safety)
            if (-not $r.executable -and $r.command) { Write-Host ('  {0,-7} {1,10}  {2}' -f '', '', $r.command) -ForegroundColor Cyan }
        }
        if ($rows.Count -gt 40) { Write-Host "  ... $($rows.Count - 40) more in the plan file" }
    }
    $keep = @($entries | Where-Object { $_.action -eq 'KEEP' })
    $unknown = @($keep | Where-Object { $_.safety -eq 'UNKNOWN' })
    Write-Host ''
    Write-Host ("KEEP   [{0} items, {1} on disk; {2} of them UNKNOWN ({3}) - look with: reclaim explain <path>]" -f $keep.Count,
        (Format-Bytes $Plan.totals.KEEP.onDisk), $unknown.Count, (Format-Bytes (Get-ReclaimSum $unknown 'onDisk'))) -ForegroundColor Gray
    foreach ($r in ($keep | Select-Object -First 8)) {
        Write-Host ('  {0,-7} {1,10}  {2,-14} {3} -> {4}' -f $r.id, (Format-Bytes $r.onDisk), $r.safety, $r.name, $r.path) -ForegroundColor (Get-SafetyColor $r.safety)
    }
    $now = [long]$Plan.totals.byApply
    $byHand = [long]$Plan.totals.byHand
    Write-Host ''
    Write-Host ("Reclaimable by apply (quarantine + move): {0}.   By hand in the owning programs (DISABLE / CLEAR-FROM-APP, KEEP-rated items not counted): up to {1}." -f (Format-Bytes $now), (Format-Bytes $byHand)) -ForegroundColor White
    Write-Host 'Next: reclaim apply --only <id,id>   |   reclaim apply --yes-to-safe   (auto-approves SAFE only; every other item is asked)' -ForegroundColor DarkGray
    Write-Host "Saved: $($Plan.file)" -ForegroundColor DarkGray
}

function Invoke-ReclaimPlan([string[]]$Drives) {
    $plan = New-ReclaimPlan -Drives $Drives
    Write-ReclaimPlanReport $plan
    $now = [long]$plan.totals.DELETE.frees + [long]$plan.totals.MOVE.frees
    $note = '{0} entries; apply could free {1} GB; nothing executed' -f @($plan.entries).Count, (Format-GB $now)
    Write-WorklogStatus (Write-ReclaimWorklog -Command 'plan' -Drive ((@($plan.scans) | ForEach-Object { "$($_.drive):" }) -join ',') -Note $note)
    return $plan
}
