# Show.ps1 - visual for a folder (walked now) or a drive (from its latest scan): an offline HTML
# page (inline-SVG treemap, or ranked bars when a treemap would mislead) plus proportional bars
# in the terminal. Read-only.

$script:ViewMaxDepth = 4        # levels embedded below the root; deeper: reclaim show <that path>
$script:ViewMaxChildren = 60    # per node; the rest folds into one "smaller items" tile
$script:ViewDominantShare = 0.85
$script:ViewMaxTiles = 2000

function New-ViewNode([string]$Name, [string]$Path, [long]$OnDisk, [long]$Logical, [long]$Files, $Cls, [string]$Kind) {
    return [pscustomobject]@{
        n = $Name; p = $Path; s = $OnDisk; l = $Logical; f = $Files; k = $Cls.Safety; r = $Cls.RuleId
        t = $Kind; cn = 0; c = (New-Object System.Collections.ArrayList)
    }
}

# Safety of a node: its own KB rule, else the classification it inherits from its parent.
function Get-ViewClass([string]$Path, [bool]$IsFile, $Inherited) {
    $rules = (Get-ReclaimKb).Rules
    $i = [Reclaim.Rule]::Best($rules, $IsFile, [IO.Path]::GetFileName($Path.TrimEnd('\')), $Path.TrimEnd('\'))
    if ($i -ge 0) {
        $e = Get-ReclaimEntry $rules[$i].Id
        return [pscustomobject]@{ Safety = $e.safety; RuleId = $e.id }
    }
    return $Inherited
}

function Get-ViewRootClass([string]$Path, [bool]$IsFile) {
    $m = Find-ReclaimRule $Path.TrimEnd('\') $IsFile
    if ($m.Rule) { $e = Get-ReclaimEntry $m.Rule.Id; return [pscustomobject]@{ Safety = $e.safety; RuleId = $e.id } }
    return [pscustomobject]@{ Safety = 'UNKNOWN'; RuleId = $null }
}

# Keeps the largest children, folds the rest into one tile, records the true child count.
function Complete-ViewChildren($Node, [long]$OwnOnDisk, [long]$OwnLogical, [long]$OwnFiles) {
    $kids = @($Node.c | Sort-Object s -Descending)
    $Node.cn = $kids.Count
    $keep = @($kids | Select-Object -First $script:ViewMaxChildren)
    $rest = @($kids | Select-Object -Skip $script:ViewMaxChildren)
    $Node.c.Clear()
    foreach ($k in $keep) { [void]$Node.c.Add($k) }
    if ($rest.Count) {
        $rs = [long]0; $rl = [long]0; $rf = [long]0
        foreach ($k in $rest) { $rs += $k.s; $rl += $k.l; $rf += $k.f }
        $cls = [pscustomobject]@{ Safety = $Node.k; RuleId = $Node.r }
        [void]$Node.c.Add((New-ViewNode "($($rest.Count) smaller items)" $Node.p $rs $rl $rf $cls 'rest'))
    }
    if ($OwnOnDisk -gt 0) {
        $cls = [pscustomobject]@{ Safety = $Node.k; RuleId = $Node.r }
        [void]$Node.c.Add((New-ViewNode '(files directly here)' $Node.p $OwnOnDisk $OwnLogical $OwnFiles $cls 'own'))
    }
}

# Tree from a live walk of $Path.
function Get-ReclaimPathTree([string]$Path) {
    $full = Get-ReclaimNormalizedPath $Path
    $r = [Reclaim.Walker]::Scan($full, (New-ReclaimScanOptions))
    $kidsOf = @{}
    for ($i = 1; $i -lt $r.Dirs.Count; $i++) {
        $d = $r.Dirs[$i]
        if ($d.Depth -gt $script:ViewMaxDepth) { continue }
        if (-not $kidsOf.ContainsKey($d.Parent)) { $kidsOf[$d.Parent] = New-Object System.Collections.ArrayList }
        [void]$kidsOf[$d.Parent].Add($i)
    }
    $bigFiles = @{}
    foreach ($f in $r.Files) {
        $parent = $r.Dirs[$f.Dir]
        if ($parent.Depth -ge $script:ViewMaxDepth) { continue }
        if ($f.OnDisk -lt 104857600 -and $f.OnDisk -lt 0.05 * [math]::Max(1, $parent.OnDisk)) { continue }
        if (-not $bigFiles.ContainsKey($f.Dir)) { $bigFiles[$f.Dir] = New-Object System.Collections.ArrayList }
        [void]$bigFiles[$f.Dir].Add($f)
    }
    $build = $null
    $build = {
        param([int]$Idx, $Cls)
        $d = $r.Dirs[$Idx]
        $node = New-ViewNode ([IO.Path]::GetFileName($d.Path.TrimEnd('\'))) $d.Path $d.OnDisk $d.Logical $d.Files $Cls 'dir'
        if ($Idx -eq 0) { $node.n = $d.Path }
        $ownS = $d.OwnOnDisk; $ownL = $d.OwnLogical; $ownF = $d.OwnFiles
        if ($bigFiles.ContainsKey($Idx)) {
            foreach ($f in $bigFiles[$Idx]) {
                $fc = Get-ViewClass $f.Path $true $Cls
                [void]$node.c.Add((New-ViewNode ([IO.Path]::GetFileName($f.Path)) $f.Path $f.OnDisk $f.Logical 1 $fc 'file'))
                $ownS -= $f.OnDisk; $ownL -= $f.Logical; $ownF -= 1
            }
        }
        if ($kidsOf.ContainsKey($Idx)) {
            foreach ($k in $kidsOf[$Idx]) {
                $kc = Get-ViewClass $r.Dirs[$k].Path $false $Cls
                [void]$node.c.Add((& $build $k $kc))
            }
        } elseif ($d.Depth -eq $script:ViewMaxDepth) {
            $ownS = 0   # deeper levels are not embedded; the node keeps its total
        }
        Complete-ViewChildren $node $ownS $ownL $ownF
        return $node
    }
    $tree = & $build 0 (Get-ViewRootClass $full $false)
    return [pscustomobject]@{ Tree = $tree; Source = "walked now ($(Get-ReclaimMode))"; Denied = $r.Denied.Count }
}

# Tree from the latest scan of a drive (folders >= 1 MB from its .dirs.tsv, plus its largest files).
function Get-ReclaimScanTree([string]$Drive) {
    $scan = Get-LatestScan -Drive $Drive
    if ($null -eq $scan) { throw "No scan of $($Drive): yet. Run: reclaim scan $($Drive):" }
    $tsv = Join-Path (Get-ReclaimPath 'scans') $scan.dirsTsv
    $rootPath = $scan.root.TrimEnd('\')
    $nodes = @{}
    $order = New-Object System.Collections.ArrayList
    foreach ($line in [IO.File]::ReadLines($tsv)) {
        $c = $line.Split("`t")
        if ($c.Length -lt 4) { continue }
        $p = $c[0].TrimEnd('\')
        $rel = if ($p.Length -gt $rootPath.Length) { $p.Substring($rootPath.Length).TrimStart('\') } else { '' }
        $depth = if ($rel) { $rel.Split('\').Count } else { 0 }
        if ($depth -gt $script:ViewMaxDepth) { continue }
        $nodes[$p] = [pscustomobject]@{ Path = $p; S = [long]$c[1]; L = [long]$c[2]; F = [long]$c[3]; Depth = $depth; Kids = (New-Object System.Collections.ArrayList); Files = (New-Object System.Collections.ArrayList) }
        [void]$order.Add($p)
    }
    foreach ($p in $order) {
        if ($p -eq $rootPath) { continue }
        $parent = $p.Substring(0, $p.LastIndexOf('\'))
        if ($parent.Length -eq 2) { $parent = $parent }   # "C:" root key
        if ($nodes.ContainsKey($parent)) { [void]$nodes[$parent].Kids.Add($p) }
    }
    foreach ($f in @($scan.topFiles)) {
        $parent = $f.path.Substring(0, $f.path.LastIndexOf('\'))
        if ($nodes.ContainsKey($parent) -and $nodes[$parent].Depth -lt $script:ViewMaxDepth) { [void]$nodes[$parent].Files.Add($f) }
    }
    $build = $null
    $build = {
        param([string]$P, $Cls)
        $d = $nodes[$P]
        $name = if ($d.Depth -eq 0) { $scan.root } else { $P.Substring($P.LastIndexOf('\') + 1) }
        $node = New-ViewNode $name $P $d.S $d.L $d.F $Cls 'dir'
        $ownS = $d.S; $ownL = $d.L; $ownF = $d.F
        foreach ($f in $d.Files) {
            $fc = Get-ViewClass $f.path $true $Cls
            [void]$node.c.Add((New-ViewNode ([IO.Path]::GetFileName($f.path)) $f.path ([long]$f.onDisk) ([long]$f.logical) 1 $fc 'file'))
            $ownS -= [long]$f.onDisk; $ownL -= [long]$f.logical; $ownF -= 1
        }
        foreach ($k in $d.Kids) {
            $kc = Get-ViewClass $k $false $Cls
            $child = & $build $k $kc
            [void]$node.c.Add($child)
            $ownS -= $child.s; $ownL -= $child.l; $ownF -= $child.f
        }
        if ($d.Depth -eq $script:ViewMaxDepth) { $ownS = 0 }
        Complete-ViewChildren $node ([math]::Max([long]0, $ownS)) ([math]::Max([long]0, $ownL)) ([math]::Max([long]0, $ownF))
        return $node
    }
    $tree = & $build $rootPath (Get-ViewRootClass $scan.root $false)
    return [pscustomobject]@{ Tree = $tree; Source = "scan of $($Drive): taken $($scan.time) ($($scan.mode)); folders under 1 MB are folded into their parent"; Denied = @($scan.denied).Count }
}

# Treemap unless one child dominates or there are too many to read.
function Get-ReclaimChartChoice($Node) {
    $kids = @($Node.c)
    if ($Node.cn -gt $script:ViewMaxTiles) {
        return [pscustomobject]@{ Chart = 'bars'; Reason = "This folder has $($Node.cn) items (more than $($script:ViewMaxTiles)), too many tiles to read, so the largest are shown as ranked bars instead of a treemap." }
    }
    if ($kids.Count -and $Node.s -gt 0) {
        $top = ($kids | Sort-Object s -Descending | Select-Object -First 1)
        $share = $top.s / $Node.s
        if ($share -ge $script:ViewDominantShare) {
            $pct = [int][math]::Floor($share * 100)
            return [pscustomobject]@{ Chart = 'bars'; Reason = "One item ($($top.n)) holds $pct% of the space (85% or more), so a treemap would be one big box. Showing ranked bars instead." }
        }
    }
    return [pscustomobject]@{ Chart = 'treemap'; Reason = 'Treemap: tile area is on-disk size, color is the knowledge-base safety rating.' }
}

function Format-ReclaimBars($Nodes, [int]$Width = 30) {
    $list = @($Nodes | Sort-Object OnDisk -Descending)
    if (-not $list.Count) { return }
    $max = [math]::Max([long]1, [long]$list[0].OnDisk)
    foreach ($n in $list) {
        $w = [int][math]::Round($Width * [double]$n.OnDisk / $max)
        $name = [string]$n.Name
        if ($name.Length -gt 38) { $name = $name.Substring(0, 35) + '...' }
        '  {0,-38} [{1}] {2,10}  {3}' -f $name, (('#' * $w).PadRight($Width, '.')), (Format-Bytes $n.OnDisk), $n.Safety
    }
}

function Get-ReclaimViewKb($Tree) {
    $ids = @{}
    $stack = New-Object System.Collections.Stack
    $stack.Push($Tree)
    while ($stack.Count) {
        $n = $stack.Pop()
        if ($n.r) { $ids[$n.r] = $true }
        foreach ($c in $n.c) { $stack.Push($c) }
    }
    $out = [ordered]@{}
    foreach ($id in $ids.Keys) {
        $e = Get-ReclaimEntry $id
        $out[$id] = [ordered]@{ name = $e.name; safety = $e.safety; creator = $e.creator; purpose = $e.purpose; breaks = $e.breaks; regenerates = $e.regenerates; action = $e.action }
    }
    return $out
}

function ConvertTo-HtmlText([string]$Text) { return [System.Net.WebUtility]::HtmlEncode($Text) }

function New-ReclaimView {
    param([string]$Path, [string]$Drive, [switch]$NoOpen)
    $t = if ($Drive) { Get-ReclaimScanTree (ConvertTo-DriveLetter $Drive) } else { Get-ReclaimPathTree $Path }
    $choice = Get-ReclaimChartChoice $t.Tree
    $data = [ordered]@{
        chart = $choice.Chart; reason = $choice.Reason; source = $t.Source; denied = $t.Denied
        generated = (Get-Date).ToString('s'); mode = (Get-ReclaimMode); maxDepth = $script:ViewMaxDepth
        dominantShare = $script:ViewDominantShare; maxTiles = $script:ViewMaxTiles
        kb = (Get-ReclaimViewKb $t.Tree); root = $t.Tree
    }
    $json = ($data | ConvertTo-Json -Depth 40 -Compress).Replace('</', '<\/')
    $template = [IO.File]::ReadAllText((Join-Path $script:ReclaimSrcDir 'view.html'))
    $title = "Reclaim - $($t.Tree.n)"
    $html = $template.Replace('{{TITLE}}', (ConvertTo-HtmlText $title)).Replace('{{REASON}}', (ConvertTo-HtmlText $choice.Reason)).
        Replace('{{SOURCE}}', (ConvertTo-HtmlText $t.Source)).Replace('{{DATA}}', $json)
    $file = Join-Path (Get-ReclaimPath 'views') ((Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '.html')
    [IO.File]::WriteAllText($file, $html, (New-Object Text.UTF8Encoding $false))
    if (-not $NoOpen) { Start-Process -FilePath $file }
    return [pscustomobject]@{ File = $file; Chart = $choice.Chart; Reason = $choice.Reason; Tree = $t.Tree; Source = $t.Source }
}

function New-ReclaimScanView($Doc, [switch]$Open) {
    $v = New-ReclaimView -Drive $Doc.drive -NoOpen:(-not $Open)
    Write-Host "View: $($v.File)  ($($v.Chart))" -ForegroundColor DarkGray
    return $v
}

function Invoke-ReclaimShow([string]$Target, [switch]$NoOpen) {
    $isDrive = $Target -match '^[A-Za-z]:?\\?$'
    $v = if ($isDrive) { New-ReclaimView -Drive $Target -NoOpen:$NoOpen } else { New-ReclaimView -Path $Target -NoOpen:$NoOpen }
    Write-Host ''
    Write-Host "$($v.Tree.n)   $(Format-Bytes $v.Tree.s) on disk (logical $(Format-Bytes $v.Tree.l))   source: $($v.Source)" -ForegroundColor White
    $rows = @($v.Tree.c | ForEach-Object { [pscustomobject]@{ Name = $_.n; OnDisk = $_.s; Safety = $_.k } } | Sort-Object OnDisk -Descending | Select-Object -First 15)
    foreach ($line in (Format-ReclaimBars -Nodes $rows)) {
        $safety = $line.Substring($line.Length - 14).Trim()
        Write-Host $line -ForegroundColor (Get-SafetyColor $safety)
    }
    Write-Host "Chart: $($v.Chart) - $($v.Reason)"
    Write-Host "View: $($v.File)$(if ($NoOpen) { '' } else { '  (opened in your browser)' })" -ForegroundColor DarkGray
    Write-WorklogStatus (Write-ReclaimWorklog -Command 'show' -Drive $v.Tree.p.Substring(0, 2) -Note "$($v.Tree.p) -> $($v.Chart); $($v.File)")
    return $v
}
