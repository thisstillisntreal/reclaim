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

# Passed on the command line, so: no double quotes and no cmd.exe metacharacters.
$script:AdvisorSystemPrompt = 'You are a read-only advisor for a Windows disk cleaner. You identify a file or folder from its path, names and sizes. Reply with only one JSON object with the keys what, creator, purpose and risk, and nothing else. For any key you are not confident about, the value must be exactly the word unknown. Never guess a plausible label.'

# npm installs a claude.cmd shim that re-parses arguments through cmd.exe; use the exe behind it.
function Get-ReclaimClaudeExe {
    $cmd = Get-Command claude.cmd, claude.exe, claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $null }
    $exe = Join-Path (Split-Path -Parent $cmd.Source) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
    if ($cmd.Source -like '*.cmd' -and (Test-Path -LiteralPath $exe)) { return $exe }
    return $cmd.Source
}

# --safe-mode: no plugins, hooks, skills or CLAUDE.md. --strict-mcp-config: no MCP servers.
# --tools "": no tools. Without these the user's customizations load into the prompt
# (measured: ~204k tokens, over the limit). Windows PowerShell 5.1 drops empty arguments, so '""'.
function Get-ReclaimAdvisorArgs([string]$Model) {
    $noTools = if ($PSVersionTable.PSVersion.Major -ge 7) { '' } else { '""' }
    return @('-p', '--model', $Model, '--safe-mode', '--strict-mcp-config', '--tools', $noTools,
        '--no-session-persistence', '--output-format', 'json', '--system-prompt', $script:AdvisorSystemPrompt)
}

function Invoke-ReclaimAdvisor($X) {
    $cfg = Get-ReclaimConfig
    $exe = Get-ReclaimClaudeExe
    if (-not $exe) {
        $a = ConvertFrom-ReclaimAdvisorReply ''
        $a.Error = 'claude CLI not found on PATH'
        return $a
    }
    $prompt = Get-ReclaimAdvisorPrompt $X
    $cliArgs = Get-ReclaimAdvisorArgs -Model $cfg.advisorModel
    $ErrorActionPreference = 'Continue'
    $OutputEncoding = New-Object Text.UTF8Encoding $false
    Write-Host "  Asking the advisor ($($cfg.advisorModel); safe mode, no tools, no MCP; names and sizes only) ..." -ForegroundColor DarkGray
    $out = $prompt | & $exe @cliArgs 2>&1
    $code = $LASTEXITCODE
    $text = (@($out) | ForEach-Object { "$_" }) -join "`n"
    $reply = $text
    try {
        $j = $text | ConvertFrom-Json
        if ($j.PSObject.Properties['result']) { $reply = [string]$j.result }
    } catch { }
    $a = ConvertFrom-ReclaimAdvisorReply $reply
    if ($code -ne 0) { $a.Error = "claude exited $code" + $(if ($reply) { ': ' + (($reply -split "`n")[0]) } else { '' }) }
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
