# Kb.ps1 - knowledge base loading and glob-to-regex conversion.
# Patterns: '?:' any drive, '*' characters inside one segment, '**\' any number of whole
# segments, '%USERS%' = '?:\Users\*'. Everything else is literal and case-insensitive.

$script:ReclaimKb = $null

function Expand-ReclaimPattern([string]$Pattern) {
    return $Pattern.Replace('%USERS%', '?:\Users\*')
}

function ConvertTo-SegmentRegex([string]$Text) {
    $sb = New-Object Text.StringBuilder
    $i = 0
    while ($i -lt $Text.Length) {
        if ($Text.Substring($i).StartsWith('**\')) { [void]$sb.Append('(?:[^\\]+\\)*'); $i += 3; continue }
        $c = $Text[$i]
        if ($c -eq '*') { [void]$sb.Append('[^\\]*') } else { [void]$sb.Append([regex]::Escape([string]$c)) }
        $i++
    }
    return $sb.ToString()
}

function ConvertTo-ReclaimRegex([string]$Pattern) {
    $p = Expand-ReclaimPattern $Pattern
    if ($p.StartsWith('?:')) { return '^[A-Za-z]:' + (ConvertTo-SegmentRegex $p.Substring(2)) + '$' }
    return '^' + (ConvertTo-SegmentRegex $p) + '$'
}

# Number of literal characters: the more a pattern spells out, the more specific it is.
function Get-ReclaimPatternSpecificity([string]$Pattern) {
    $p = Expand-ReclaimPattern $Pattern
    return @($p.ToCharArray() | Where-Object { $_ -ne '*' -and $_ -ne '?' }).Count
}

# One Reclaim.Rule per pattern, carrying its entry id. Returned as a single List object.
function ConvertTo-ReclaimRules([object[]]$Entries) {
    $list = New-Object 'System.Collections.Generic.List[Reclaim.Rule]'
    foreach ($e in $Entries) {
        foreach ($pat in @($e.patterns)) {
            $last = ((Expand-ReclaimPattern $pat) -split '\\')[-1]
            $nameRx = '^' + (ConvertTo-SegmentRegex $last) + '$'
            $rule = New-Object Reclaim.Rule -ArgumentList @(
                [string]$e.id, [bool]($e.kind -eq 'file'), (ConvertTo-ReclaimRegex $pat), $nameRx,
                [int](Get-ReclaimPatternSpecificity $pat))
            if ($last -notmatch '\*') { $rule.LiteralName = $last }
            $list.Add($rule)
        }
    }
    return , $list
}

# kb\knowledge-base.json, then kb\local.json (machine-specific, gitignored), then the optional
# kbExtra config file. A later file's entry with the same id replaces the earlier one.
function Get-ReclaimKb {
    if ($null -ne $script:ReclaimKb) { return $script:ReclaimKb }
    $sources = @((Join-Path $script:ReclaimRepoDir 'kb\knowledge-base.json'), (Join-Path $script:ReclaimRepoDir 'kb\local.json'))
    $extra = (Get-ReclaimConfig).PSObject.Properties['kbExtra']
    if ($extra -and $extra.Value) { $sources += [string]$extra.Value }
    $byId = @{}
    $order = New-Object System.Collections.ArrayList
    foreach ($f in $sources) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $doc = [IO.File]::ReadAllText($f) | ConvertFrom-Json
        foreach ($e in @($doc.entries)) {
            if (-not $byId.ContainsKey($e.id)) { [void]$order.Add($e.id) }
            $byId[$e.id] = $e
        }
    }
    $entries = @($order | ForEach-Object { $byId[$_] })
    $script:ReclaimKb = [pscustomobject]@{
        Entries = $entries
        ById    = $byId
        Rules   = (ConvertTo-ReclaimRules $entries)
    }
    return $script:ReclaimKb
}

function Reset-ReclaimKb { $script:ReclaimKb = $null }

# The explanation shown for anything the KB does not cover. Nothing is guessed.
function Get-ReclaimUnknownEntry {
    return [pscustomobject]@{
        id = $null; name = 'UNKNOWN'; kind = ''; creator = 'unknown'; purpose = 'unknown'
        breaks = 'unknown'; safety = 'UNKNOWN'; regenerates = 'unknown'; action = 'KEEP'
        method = 'Not in the knowledge base. Look inside before doing anything (reclaim explain <path> offers to open it), or describe it in kb\local.json.'
        command = ''; processes = @(); hotspot = $false; notes = ''
    }
}

function Get-ReclaimEntry([string]$RuleId) {
    if (-not $RuleId) { return Get-ReclaimUnknownEntry }
    $kb = Get-ReclaimKb
    if ($kb.ById.ContainsKey($RuleId)) { return $kb.ById[$RuleId] }
    return Get-ReclaimUnknownEntry
}
