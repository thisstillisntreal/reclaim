# Explain.ps1 - one item, explained from the knowledge base (or "unknown"), measured now, with the
# exact commands that would reclaim it. Read-only.

function Get-ReclaimNormalizedPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

# The path's own rule, else the closest ancestor folder that has one.
function Find-ReclaimRule([string]$Path, [bool]$IsFile) {
    $rules = (Get-ReclaimKb).Rules
    $i = [Reclaim.Rule]::Best($rules, $IsFile, [IO.Path]::GetFileName($Path), $Path)
    if ($i -ge 0) { return @{ Rule = $rules[$i]; By = 'exact'; At = $Path } }
    $p = [IO.Path]::GetDirectoryName($Path)
    while ($p) {
        $leaf = [IO.Path]::GetFileName($p.TrimEnd('\'))
        $i = [Reclaim.Rule]::Best($rules, $false, $leaf, $p.TrimEnd('\'))
        if ($i -ge 0) { return @{ Rule = $rules[$i]; By = 'ancestor'; At = $p.TrimEnd('\') } }
        $p = [IO.Path]::GetDirectoryName($p)
    }
    return @{ Rule = $null; By = 'none'; At = $null }
}

# System locations and other users' profiles need an elevated shell to change.
function Test-ReclaimNeedsAdmin([string]$Path, $Entry) {
    if ($Entry -and $Entry.safety -eq 'ADMIN-ONLY') { return $true }
    $p = $Path.ToLowerInvariant()
    $rel = if ($p.Length -ge 2 -and $p[1] -eq ':') { $p.Substring(2) } else { $p }
    foreach ($s in '\windows', '\program files', '\program files (x86)', '\programdata',
        '\system volume information', '\$recycle.bin', '\recovery', '\config.msi') {
        if ($rel -eq $s -or $rel.StartsWith("$s\")) { return $true }
    }
    if ($rel -match '^\\users\\([^\\]+)') {
        $me = [IO.Path]::GetFileName($env:USERPROFILE).ToLowerInvariant()
        if ($Matches[1] -notin $me, 'public') { return $true }
    }
    return $false
}

function Resolve-ReclaimExplanation([string]$Path) {
    $cfg = Get-ReclaimConfig
    $full = Get-ReclaimNormalizedPath $Path
    $isDir = [IO.Directory]::Exists($full)
    $stat = $null
    if (-not $isDir) {
        $stat = [Reclaim.Walker]::StatFile($full)
        if ($null -eq $stat) { throw "Not found, or not visible in $(Get-ReclaimMode) mode: $full" }
    }
    $m = Find-ReclaimRule $full (-not $isDir)
    $entry = if ($m.Rule) { Get-ReclaimEntry $m.Rule.Id } else { Get-ReclaimUnknownEntry }
    $x = [ordered]@{
        Path = $full; IsDir = $isDir; Entry = $entry; MatchedBy = $m.By; MatchedPath = $m.At
        OnDisk = [long]0; Logical = [long]0; Files = [long]0; NewestWrite = ''; PlaceholderLogical = [long]0
        OwnOnDisk = [long]0; OwnFiles = [long]0
        Denied = @(); Skipped = 0; Children = @(); Nested = @()
        ScanItemId = $null; ScanItemPath = $null; NeedsAdmin = $false; Commands = @(); Mode = (Get-ReclaimMode)
    }
    if ($isDir) {
        $r = [Reclaim.Walker]::Scan($full, (New-ReclaimScanOptions))
        $top = $r.Dirs[0]
        $x.OnDisk = $top.OnDisk; $x.Logical = $top.Logical; $x.Files = $top.Files
        $x.NewestWrite = Format-FileTime $top.NewestWrite; $x.PlaceholderLogical = $top.PlaceholderLogical
        $x.OwnOnDisk = $top.OwnOnDisk; $x.OwnFiles = $top.OwnFiles
        $x.Denied = @($r.Denied); $x.Skipped = $r.Skipped.Count
        $x.Children = @($r.Dirs | Where-Object { $_.Parent -eq 0 } | Sort-Object OnDisk -Descending |
            Select-Object -First 12 | ForEach-Object {
                [pscustomobject]@{ Name = [IO.Path]::GetFileName($_.Path); OnDisk = $_.OnDisk; Logical = $_.Logical; Files = $_.Files }
            })
        $items = [Reclaim.Classifier]::Classify($r, (Get-ReclaimKb).Rules, [long]$cfg.dirUnknownMinBytes, [long]$cfg.fileUnknownMinBytes)
        $x.Nested = @($items | Where-Object { $_.Path -ne $full -and $_.OnDisk -ge 1MB } | Select-Object -First 10 | ForEach-Object {
                $e = Get-ReclaimEntry $_.RuleId
                [pscustomobject]@{ Path = $_.Path; Name = $e.name; Safety = $e.safety; OnDisk = $_.OnDisk }
            })
    } else {
        $x.OnDisk = $stat.OnDisk; $x.Logical = $stat.Logical; $x.Files = 1
        $x.NewestWrite = Format-FileTime $stat.LastWrite
        if ([Reclaim.Walker]::IsPlaceholder($stat.Attributes)) { $x.PlaceholderLogical = $stat.Logical }
    }

    $drive = $full.Substring(0, 1).ToUpperInvariant()
    $scan = Get-LatestScan -Drive $drive
    if ($scan -and $scan.root.Length -le 3) {
        $hit = @($scan.items | Where-Object { $_.path -eq $full -or ($m.At -and $_.path -eq $m.At) }) | Select-Object -First 1
        if ($hit) { $x.ScanItemId = $hit.id; $x.ScanItemPath = $hit.path }
    }
    $x.NeedsAdmin = Test-ReclaimNeedsAdmin $full $entry

    $cmds = New-Object System.Collections.ArrayList
    if ($entry.safety -ne 'UNKNOWN') {
        $elev = if ($x.NeedsAdmin) { '      (elevated)' } else { '' }
        $id = if ($x.ScanItemId) { $x.ScanItemId } else { '<id>' }
        if ($entry.action -in 'DELETE', 'MOVE') {
            if ($x.ScanItemId) { [void]$cmds.Add("reclaim plan $($drive):   then   reclaim apply --only $id$elev") }
            else { [void]$cmds.Add("reclaim scan $($drive):   then   reclaim plan $($drive):   then   reclaim apply --only <id>$elev") }
        }
        if ($entry.command -and $entry.command -notlike 'reclaim apply*') {
            [void]$cmds.Add(($entry.command -replace '<id>', $id -replace '<D>', $drive))
        }
    }
    $x.Commands = @($cmds)
    return [pscustomobject]$x
}

function Write-ReclaimExplanation($X) {
    $e = $X.Entry
    $color = Get-SafetyColor $e.safety
    Write-Host ''
    Write-Host $X.Path -ForegroundColor White
    $src = switch ($X.MatchedBy) {
        'exact'    { "knowledge base: $($e.id)" }
        'ancestor' { "knowledge base: $($e.id), via the folder $($X.MatchedPath)" }
        default    { 'not in the knowledge base' }
    }
    Write-Host ('  {0,-14}{1}   ({2})' -f 'What', $e.name, $src) -ForegroundColor $color
    Write-Host ('  {0,-14}{1}' -f 'Created by', $e.creator)
    Write-Host ('  {0,-14}{1}' -f 'Why it exists', $e.purpose)
    Write-Host ('  {0,-14}{1}' -f 'If it goes', $e.breaks)
    Write-Host ('  {0,-14}{1}' -f 'Regenerates', $e.regenerates)
    Write-Host ('  {0,-14}{1}' -f 'Safety', $e.safety) -ForegroundColor $color
    $size = '{0} on disk   (logical {1}; {2:N0} files; newest write {3})' -f (Format-Bytes $X.OnDisk), (Format-Bytes $X.Logical), $X.Files, $X.NewestWrite
    Write-Host ('  {0,-14}{1}' -f 'Size now', $size)
    if ([long]$X.PlaceholderLogical -gt 0) {
        Write-Host ('  {0,-14}{1} of this is cloud-only OneDrive placeholders (occupies ~0 on disk; never reclaimable)' -f '', (Format-Bytes $X.PlaceholderLogical))
    }
    $reclaim = switch ($e.action) {
        'DELETE'         { 'quarantine: moved to the quarantine folder with a manifest; undo-able; nothing is deleted' }
        'MOVE'           { 'move to the overflow drive with a receipt; undo-able' }
        'DISABLE'        { 'turn the feature off with the command below (Reclaim prints it, never runs it)' }
        'CLEAR-FROM-APP' { 'clear it from the owning program (Reclaim prints how, never runs it)' }
        default          { 'keep - Reclaim will not touch this' }
    }
    Write-Host ('  {0,-14}{1}: {2}' -f 'Reclaim', $e.action, $reclaim)
    Write-Host ('  {0,-14}{1}' -f 'Method', $e.method)
    if ($X.NeedsAdmin) { Write-Host ('  {0,-14}needs an elevated shell (system location or another user''s profile)' -f 'Admin') -ForegroundColor Magenta }
    if ($X.ScanItemId) { Write-Host ('  {0,-14}{1} in the last scan ({2})' -f 'Scan item', $X.ScanItemId, $X.ScanItemPath) }
    $cmds = @($X.Commands)
    if ($cmds.Count) {
        Write-Host ('  {0,-14}{1}' -f 'Commands', $cmds[0]) -ForegroundColor Cyan
        foreach ($c in ($cmds | Select-Object -Skip 1)) { Write-Host ('  {0,-14}{1}' -f '', $c) -ForegroundColor Cyan }
    }
    $notes = Get-EntryValue $e 'notes' ''
    if ($notes) { Write-Host ('  {0,-14}{1}' -f 'Note', $notes) }
    if ($X.IsDir) {
        if (@($X.Children).Count) {
            Write-Host '  Largest subfolders:'
            foreach ($c in $X.Children) { Write-Host ('    {0,10}  {1}' -f (Format-Bytes $c.OnDisk), $c.Name) }
        }
        if ($X.OwnFiles) { Write-Host ('    {0,10}  ({1:N0} files directly in this folder)' -f (Format-Bytes $X.OwnOnDisk), $X.OwnFiles) }
        if (@($X.Nested).Count) {
            Write-Host '  Knowledge-base items inside:'
            foreach ($n in $X.Nested) { Write-Host ('    {0,10}  {1,-14} {2} -> {3}' -f (Format-Bytes $n.OnDisk), $n.Safety, $n.Name, $n.Path) -ForegroundColor (Get-SafetyColor $n.Safety) }
        }
        if (@($X.Denied).Count) {
            Write-Host "  Denied inside ($(@($X.Denied).Count)) - not measured in $($X.Mode) mode:" -ForegroundColor Yellow
            foreach ($d in ($X.Denied | Select-Object -First 20)) { Write-Host "    $d" -ForegroundColor Yellow }
        }
    }
}

function Invoke-OpenFolderOffer([string]$Path, [bool]$IsDir) {
    $explorerArgs = if ($IsDir) { "`"$Path`"" } else { "/select,`"$Path`"" }
    if ([Console]::IsInputRedirected) {
        Write-Host "  Look inside first: explorer.exe $explorerArgs" -ForegroundColor Yellow
        return
    }
    $a = Read-Host '  Unknown. Open it in Explorer to look? [y/N]'
    if ($a -match '^(y|yes)$') { Start-Process explorer.exe -ArgumentList $explorerArgs }
}

function Invoke-ReclaimExplain([string]$Path, [switch]$Ai) {
    $x = Resolve-ReclaimExplanation $Path
    Write-ReclaimExplanation $x
    if ($x.Entry.safety -eq 'UNKNOWN') {
        if ($Ai) { Write-ReclaimAdvice (Invoke-ReclaimAdvisor $x) }
        else { Write-Host "  Ask the LLM advisor (read-only, advisory): reclaim explain `"$($x.Path)`" --ai" -ForegroundColor DarkGray }
        Invoke-OpenFolderOffer $x.Path $x.IsDir
    } elseif ($Ai) {
        Write-Host '  Advisor not asked: the knowledge base already covers this item.' -ForegroundColor DarkGray
    }
    $note = '{0}: {1} ({2})' -f $x.Entry.safety, $x.Entry.name, (Format-Bytes $x.OnDisk)
    Write-WorklogStatus (Write-ReclaimWorklog -Command 'explain' -Drive $x.Path.Substring(0, 2) -Note $note)
}
