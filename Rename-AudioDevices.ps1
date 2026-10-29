# ShowReady - rename Korean audio device names to English
# Windows names each audio device ("Speakers", "Headphones", "Microphone") in the display language
# active when the device was installed, and keeps that name after Windows is switched to English.
# vMix/OBS show those names. This renames them the way Sound settings > Rename does.
#
#   Rename-AudioDevices.ps1 [-PlanOnly] [-Yes] [-Undo [-From <audio-names folder>]]
#
# Only the device part of the name changes ("Speakers" in "Speakers (Realtek(R) Audio)");
# the part in brackets comes from the driver. A backup goes to audio-names\<date-time>\ first.
# Windows PowerShell 5.1 compatible. Pure ASCII source. No admin rights needed.

[CmdletBinding()]
param(
    [switch]$PlanOnly,
    [switch]$Yes,
    [switch]$Undo,
    [string]$From = ''
)

$ErrorActionPreference = 'Continue'
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

$Root = $PSScriptRoot
if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrEmpty($Root)) { $Root = (Get-Location).Path }
$BackupRoot = Join-Path $Root 'audio-names'

function Write-SRLine {
    param([string]$Text = '', [string]$Color = 'Gray')
    try { Write-Host $Text -ForegroundColor $Color } catch { Write-Host $Text }
}

function ConvertTo-SRAsciiJson {
    param([string]$Json)
    $bs = [string][char]92
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $bs + 'u' + ([int][char]$m.Value[0]).ToString('x4') }
    return [System.Text.RegularExpressions.Regex]::Replace($Json, '[^\x00-\x7E]', $evaluator)
}

function Get-SRErrorText {
    param($Err)
    $msg = [string]$Err.Exception.Message
    $inner = $Err.Exception.InnerException
    if ($null -ne $inner) { $msg = [string]$inner.Message }
    if ($msg -match '0x80070005|denied') { $msg += ' - right-click Rename-AudioDevices.cmd and choose Run as administrator' }
    return $msg
}

Write-SRLine ''
Write-SRLine 'ShowReady - audio device names in English' 'Cyan'
Write-SRLine '==========================================' 'Cyan'

try { . (Join-Path $Root 'lib\AudioNames.ps1') }
catch {
    Write-SRLine ('Could not load lib\AudioNames.ps1: ' + $_.Exception.Message) 'Red'
    exit 1
}

$all = @()
try { $all = Get-SRAudioEndpoints }
catch {
    Write-SRLine ('Could not list the audio devices: ' + (Get-SRErrorText $_)) 'Red'
    exit 1
}

# ---------------------------------------------------------------------------------------------
# Undo: put back the names saved by the last run (or the given audio-names\<folder>)
# ---------------------------------------------------------------------------------------------
if ($Undo) {
    $dir = $null
    if ($From -eq '') {
        if (Test-Path -LiteralPath $BackupRoot) {
            $last = @(Get-ChildItem -LiteralPath $BackupRoot -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'backup.json') } | Sort-Object Name)
            if ($last.Count -gt 0) { $dir = $last[$last.Count - 1].FullName }
        }
    }
    elseif (Test-Path -LiteralPath (Join-Path $BackupRoot $From)) { $dir = Join-Path $BackupRoot $From }
    elseif (Test-Path -LiteralPath $From) { $dir = (Resolve-Path -LiteralPath $From).Path }

    if ($null -eq $dir) {
        Write-SRLine 'Nothing to undo: no backup found in audio-names\.' 'Yellow'
        exit 1
    }
    $saved = @()
    try { $saved = @([System.IO.File]::ReadAllText((Join-Path $dir 'backup.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json) }
    catch {
        Write-SRLine ('Could not read ' + (Join-Path $dir 'backup.json') + ': ' + $_.Exception.Message) 'Red'
        exit 1
    }
    Write-SRLine ('Putting back the names saved in ' + $dir) 'Gray'
    $fails = 0
    foreach ($s in $saved) {
        $cur = $all | Where-Object { $_.Id -eq [string]$s.id } | Select-Object -First 1
        if ($null -eq $cur) { Write-SRLine ('  [SKIPPED] ' + [string]$s.new + ': device not found') 'DarkYellow'; continue }
        if ([string]$cur.Name -ne [string]$s.new) { Write-SRLine ('  [SKIPPED] ' + [string]$cur.Name + ': renamed since, left as it is') 'DarkYellow'; continue }
        try {
            Set-SRAudioEndpointName -Id ([string]$s.id) -Name ([string]$s.old)
            Write-SRLine ('  [DONE]    ' + [string]$s.new + '  ->  ' + [string]$s.old) 'Green'
        }
        catch { $fails++; Write-SRLine ('  [FAILED]  ' + [string]$s.new + ': ' + (Get-SRErrorText $_)) 'Red' }
    }
    Write-SRLine ''
    Write-SRLine 'Restart vMix/OBS to see the names.' 'Gray'
    if ($fails -gt 0) { exit 1 }
    exit 0
}

# ---------------------------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------------------------
$map = Get-SRAudioNameMap
$plan = New-Object System.Collections.ArrayList
$unknown = New-Object System.Collections.ArrayList
$okCount = 0
foreach ($e in $all) {
    if ([string]::IsNullOrEmpty([string]$e.Name)) { continue }
    $new = ConvertTo-SREnglishAudioName -Name ([string]$e.Name) -Map $map
    if ($null -eq $new) { [void]$unknown.Add($e); continue }
    if ($new -eq '') { $okCount++; continue }
    [void]$plan.Add([pscustomobject]@{
        id = [string]$e.Id; flow = [string]$e.Flow; state = [int]$e.State
        old = [string]$e.Name; new = $new
        old_full = [string]$e.FullName; new_full = (Get-SRNewFullName ([string]$e.FullName) ([string]$e.Name) $new)
    })
}

Write-SRLine ('Found ' + $all.Count + ' audio devices: ' + $plan.Count + ' to rename, ' + $okCount + ' already English, ' + $unknown.Count + ' unknown.') 'Gray'
Write-SRLine ''
foreach ($p in @($plan | Sort-Object flow, new_full)) {
    $where = 'output'
    if ($p.flow -eq 'input') { $where = 'input ' }
    Write-SRLine ('  ' + $where + '  ' + $p.old_full) 'Gray'
    Write-SRLine ('          ->  ' + $p.new_full) 'Cyan'
}
foreach ($u in $unknown) {
    Write-SRLine ('  [UNKNOWN] ' + [string]$u.FullName + ' - has Korean words this script does not know; rename it by hand (Win+R, mmsys.cpl)') 'Yellow'
}
$korBrackets = @($plan | Where-Object { Test-SRHangul ($_.new_full) })
if ($korBrackets.Count -gt 0) {
    Write-SRLine ''
    Write-SRLine '  The part in brackets of some names stays Korean: it is the driver''s name (Device Manager), not the device name.' 'DarkGray'
}

if ($plan.Count -eq 0) {
    Write-SRLine ''
    if ($unknown.Count -eq 0) { Write-SRLine 'All audio device names are already English. Nothing to do.' 'Green' }
    exit 0
}
if ($PlanOnly) {
    Write-SRLine ''
    Write-SRLine 'Plan only: nothing changed.' 'Yellow'
    exit 0
}

if (-not $Yes) {
    Write-SRLine ''
    $ans = 'n'
    try { $ans = Read-Host ('Rename these ' + $plan.Count + ' devices? [y/N]') } catch { $ans = 'n' }
    $ans = ([string]$ans).Trim().ToLowerInvariant()
    if ($ans -ne 'y' -and $ans -ne 'yes') {
        Write-SRLine 'Nothing changed.' 'Yellow'
        exit 0
    }
}

# ---------------------------------------------------------------------------------------------
# Back up, rename, check
# ---------------------------------------------------------------------------------------------
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', $Inv)
$dir = Join-Path $BackupRoot $stamp
try {
    New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
    $json = ConvertTo-Json -InputObject @($plan.ToArray()) -Depth 4
    [System.IO.File]::WriteAllText((Join-Path $dir 'backup.json'), (ConvertTo-SRAsciiJson $json), (New-Object System.Text.UTF8Encoding($false)))
}
catch {
    Write-SRLine ('Could not save the backup in ' + $dir + ': ' + $_.Exception.Message + '. Nothing changed.') 'Red'
    exit 1
}

Write-SRLine ''
$fails = 0
foreach ($p in $plan) {
    try {
        Set-SRAudioEndpointName -Id $p.id -Name $p.new
        Write-SRLine ('  [DONE]    ' + $p.new_full) 'Green'
    }
    catch { $fails++; Write-SRLine ('  [FAILED]  ' + $p.old_full + ': ' + (Get-SRErrorText $_)) 'Red' }
}

# read the names back: Windows is the judge, not the call that returned without error
try {
    $after = Get-SRAudioEndpoints
    foreach ($p in $plan) {
        $cur = $after | Where-Object { $_.Id -eq $p.id } | Select-Object -First 1
        if ($null -ne $cur -and [string]$cur.Name -ne $p.new) {
            $fails++
            Write-SRLine ('  [FAILED]  ' + $p.old_full + ': Windows still shows ' + [string]$cur.FullName) 'Red'
        }
    }
}
catch { }

Write-SRLine ''
Write-SRLine ('Renamed ' + ($plan.Count - $fails) + ' of ' + $plan.Count + '. Backup: ' + $dir) 'Gray'
Write-SRLine 'Restart vMix/OBS (and Discord, browsers) to see the new names.' 'Yellow'
Write-SRLine 'In vMix, check Settings > Audio Outputs: outputs picked before may need picking again.' 'Yellow'
Write-SRLine 'Undo: Rename-AudioDevices.cmd -Undo' 'Gray'
if ($fails -gt 0) { exit 1 }
exit 0
