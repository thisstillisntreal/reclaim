# Advisor.ps1 - optional LLM opinion on UNKNOWN items (explain --ai). Read-only and advisory:
# the reply is printed, never stored in the KB, never read by plan or apply. The model sees
# names and sizes only - never file contents - and has no tools.

function Get-ReclaimAdvisorPrompt($X) {
    $l = New-Object System.Collections.ArrayList
    [void]$l.Add('You are a read-only advisor for a Windows disk cleaner. Identify the item below.')
    [void]$l.Add('Reply with ONLY one JSON object: {"what": "...", "creator": "...", "purpose": "...", "risk": "..."}')
    [void]$l.Add('what = what the item is; creator = the program that creates it; purpose = why it exists; risk = what breaks if it is removed.')
    [void]$l.Add('If you are not confident about a field, its value must be exactly "unknown". Never guess a plausible label.')
    [void]$l.Add('You are given names and sizes only, never file contents.')
    [void]$l.Add('')
    [void]$l.Add("Path: $($X.Path)")
    [void]$l.Add("Kind: $(if ($X.IsDir) { 'folder' } else { 'file' })")
    [void]$l.Add(('On disk: {0}; files: {1:N0}; newest write: {2}' -f (Format-Bytes $X.OnDisk), $X.Files, $X.NewestWrite))
    if ($X.IsDir) {
        try {
            $di = New-Object IO.DirectoryInfo $X.Path
            $dirs = @($di.EnumerateDirectories() | Select-Object -First 25)
            $files = @($di.EnumerateFiles() | Sort-Object Length -Descending | Select-Object -First 25)
            if ($dirs.Count) {
                [void]$l.Add('Subfolders (names only):')
                foreach ($d in $dirs) { [void]$l.Add("  $($d.Name)\") }
            }
            if ($files.Count) {
                [void]$l.Add('Largest files directly inside (names and sizes only):')
                foreach ($f in $files) { [void]$l.Add(('  {0}  {1}' -f $f.Name, (Format-Bytes $f.Length))) }
            }
        } catch { [void]$l.Add("(listing not readable: $($_.Exception.Message))") }
    }
    return ($l -join "`n")
}

function ConvertFrom-ReclaimAdvisorReply([string]$Text) {
    $out = [ordered]@{
        Advisory = $true; Parsed = $false
        what = 'unknown'; creator = 'unknown'; purpose = 'unknown'; risk = 'unknown'
        Raw = $Text; Error = $null
    }
    $s = $Text.IndexOf('{')
    $e = $Text.LastIndexOf('}')
    if ($s -ge 0 -and $e -gt $s) {
        try {
            $j = $Text.Substring($s, $e - $s + 1) | ConvertFrom-Json
            $out.Parsed = $true
            foreach ($f in 'what', 'creator', 'purpose', 'risk') {
                $p = $j.PSObject.Properties[$f]
                if ($null -ne $p -and $null -ne $p.Value -and ([string]$p.Value).Trim()) { $out[$f] = ([string]$p.Value).Trim() }
            }
        } catch { $out.Parsed = $false; $out.Error = 'reply was not valid JSON' }
    }
    return [pscustomobject]$out
}

function Invoke-ReclaimAdvisor($X) {
    $cfg = Get-ReclaimConfig
    $claude = Get-Command claude.cmd, claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $claude) {
        $a = ConvertFrom-ReclaimAdvisorReply ''
        $a.Error = 'claude CLI not found on PATH'
        return $a
    }
    $prompt = Get-ReclaimAdvisorPrompt $X
    # Windows PowerShell 5.1 drops empty arguments; '""' reaches the CLI as an empty string.
    $noTools = if ($PSVersionTable.PSVersion.Major -ge 7) { '' } else { '""' }
    $ErrorActionPreference = 'Continue'
    $OutputEncoding = New-Object Text.UTF8Encoding $false
    Write-Host "  Asking the advisor ($($cfg.advisorModel), no tools, names and sizes only) ..." -ForegroundColor DarkGray
    $reply = $prompt | & $claude.Source -p --model $cfg.advisorModel --tools $noTools --output-format text 2>&1
    $code = $LASTEXITCODE
    $a = ConvertFrom-ReclaimAdvisorReply ((@($reply) | ForEach-Object { "$_" }) -join "`n")
    if ($code -ne 0) { $a.Error = "claude exited $code" }
    return $a
}

function Write-ReclaimAdvice($A) {
    $cfg = Get-ReclaimConfig
    Write-Host ''
    Write-Host "  ADVISORY - LLM opinion ($($cfg.advisorModel)); unverified; not used by plan or apply" -ForegroundColor Yellow
    foreach ($f in 'what', 'creator', 'purpose', 'risk') { Write-Host ('    {0,-9}{1}' -f $f, $A.$f) -ForegroundColor Yellow }
    if (-not $A.Parsed) { Write-Host '    (the reply could not be parsed; nothing was inferred from it)' -ForegroundColor Yellow }
    if ($A.Error) { Write-Host "    error: $($A.Error)" -ForegroundColor Red }
    Write-Host '  Reclaim still treats this item as UNKNOWN. To act on it, describe it yourself in kb\local.json.' -ForegroundColor DarkGray
}
