# Worklog.ps1 - one summary line per command run, appended to hub KV (default: worklog-reclaim).
# Hub unreachable -> the line is queued in <dataRoot>\worklog-pending.txt and sent with the next
# successful append. The key is only ever appended to (see hubkv.py).

function Get-ReclaimPendingPath { return (Join-Path (Get-ReclaimPath) 'worklog-pending.txt') }

function Invoke-ReclaimHubKv([string]$Verb, [string]$Key, [string]$InputText = '') {
    $cfg = Get-ReclaimConfig
    $bridge = Join-Path $script:ReclaimSrcDir 'hubkv.py'
    $ErrorActionPreference = 'Continue'
    $OutputEncoding = New-Object Text.UTF8Encoding $false
    $out = $InputText | & $cfg.python $bridge $cfg.hubClient $Verb $Key 2>&1
    $code = $LASTEXITCODE
    return [pscustomobject]@{ Code = $code; Output = ((@($out) | ForEach-Object { "$_" }) -join "`n").Trim() }
}

# Hub lines carry drive, mode, sizes and receipt ids - never file paths (fleet rule: no wallet
# or personal paths in shared logs). Paths stay in the local log and receipts.
function Remove-ReclaimPaths([string]$Text) {
    if (-not $Text) { return $Text }
    $t = [regex]::Replace($Text, '\\\\[^\s|;,]+', '<path>')
    return [regex]::Replace($t, '(?i)\b[a-z]:\\[^|;,]*', '<path>')
}

function Write-ReclaimWorklog {
    param(
        [string]$Command,
        [string]$Drive = '-',
        [string]$Mode = (Get-ReclaimMode),
        [long]$ReclaimedBytes = 0,
        [string[]]$Receipts = @(),
        [string]$Note = ''
    )
    $cfg = Get-ReclaimConfig
    $rc = if ($Receipts -and $Receipts.Count) { $Receipts -join ',' } else { '-' }
    $line = '{0} | {1} | {2} | {3} | {4} | reclaimed {5} GB | receipts {6} | {7}' -f `
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $cfg.hostName, $Command, $Drive, $Mode,
        (Format-GB $ReclaimedBytes), $rc, (Remove-ReclaimPaths $Note)
    Write-ReclaimLog "worklog: $line"
    $pending = Get-ReclaimPendingPath

    # The hub has no compare-and-swap, so concurrent local runs would lose lines in the
    # read-modify-write append. One lock serializes the pending file and the hub append.
    $lock = Enter-ReclaimLock 'worklog'
    if ($null -eq $lock) {
        return [pscustomobject]@{ Line = $line; Sent = $false; Error = 'another reclaim run held the worklog lock for 2 minutes; line is only in logs\reclaim.log' }
    }
    try {
        if (-not $cfg.hubEnabled -or -not $cfg.hubClient -or -not (Test-Path -LiteralPath $cfg.hubClient)) {
            [IO.File]::AppendAllText($pending, "$line`n")
            return [pscustomobject]@{ Line = $line; Sent = $false; Error = 'hub disabled or hub client not configured' }
        }
        $queued = if (Test-Path -LiteralPath $pending) { [IO.File]::ReadAllText($pending).Trim() } else { '' }
        $payload = (@($queued, $line) | Where-Object { $_ }) -join "`n"
        $res = Invoke-ReclaimHubKv 'append' $cfg.worklogKey $payload
        if ($res.Code -ne 0) {
            [IO.File]::AppendAllText($pending, "$line`n")
            $err = ($res.Output -split "`n" | Select-Object -Last 1)
            return [pscustomobject]@{ Line = $line; Sent = $false; Error = "hub append failed (exit $($res.Code)): $err" }
        }
        if ($queued) {
            [IO.File]::AppendAllText((Join-Path (Get-ReclaimPath 'logs') 'worklog-flushed.txt'), "$queued`n")
            [IO.File]::WriteAllText($pending, '')
        }
        return [pscustomobject]@{ Line = $line; Sent = $true; Error = $null }
    } finally { $lock.Dispose() }
}

function Write-WorklogStatus($Result) {
    if ($Result.Sent) {
        Write-Host "Hub worklog: line appended to KV '$((Get-ReclaimConfig).worklogKey)'." -ForegroundColor DarkGray
    } else {
        Write-Host "Hub worklog: NOT sent - $($Result.Error). Queued in $(Get-ReclaimPendingPath)." -ForegroundColor Yellow
    }
}

# Last line of the hub worklog, for `reclaim status`.
function Get-ReclaimLastWorklogLine {
    $cfg = Get-ReclaimConfig
    if (-not $cfg.hubEnabled -or -not $cfg.hubClient -or -not (Test-Path -LiteralPath $cfg.hubClient)) {
        return '(hub not configured)'
    }
    $res = Invoke-ReclaimHubKv 'get' $cfg.worklogKey
    if ($res.Code -eq 3) { return '(no worklog lines yet)' }
    if ($res.Code -ne 0) { return "(hub read failed, exit $($res.Code))" }
    return ($res.Output -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
}
