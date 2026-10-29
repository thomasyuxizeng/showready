# ShowReady - orchestrator
# Prod PC:     Hardware -> Network -> LAN -> Load test -> Verdict.
# Observer PC: Hardware -> Sender test -> Verdict, then waits as the iperf3 server for the prod PC's LAN test.
# Writes results\<stamp>\results.json + report.html and prints the verdict.
#
#   ShowReady.ps1 [-Mode quick|full] [-Skip network,hardware,lan,load] [-NoOpen] [-SrtHost <partner IP or host>]
#                 [-LanHosts <observer PC IP>[,<IP>...]]   (PCs running Run-Observer.cmd or Run-LanPartner.cmd)
#   ShowReady.ps1 -Role observer [-Mode quick|full] [-Skip hardware,sender] [-NoOpen] [-NoPrompt] [-ServerMinutes <n>]
#
# Windows PowerShell 5.1 compatible (the show PC has no PowerShell 7). Pure ASCII source. Never throws to the caller:
# every step is wrapped, a missing/broken lib file just turns that step into "skipped" and the run continues.

[CmdletBinding()]
param(
    [ValidateSet('quick', 'full')]
    [string]$Mode = 'quick',
    [string[]]$Skip = @(),
    [switch]$NoOpen,
    [string]$SrtHost = '',
    [string[]]$LanHosts = @(),
    [string]$Role = 'prod',
    [switch]$NoPrompt,
    [int]$ServerMinutes = -1,
    [switch]$NoUpload
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$ToolVersion = '1.3.3'
$IsObserver = (@('observer', 'source', 'obs') -contains ([string]$Role).Trim().ToLowerInvariant())
$RoleName = 'prod'
if ($IsObserver) { $RoleName = 'observer' }
$Root = $PSScriptRoot
if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$BinDir = Join-Path $Root 'bin'
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------------------------------------------------------------------------------------------
# Console helpers (ASCII only: a Korean/OEM console may not render typographic characters)
# ---------------------------------------------------------------------------------------------
function ConvertTo-SRConsole {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $map = @{ 0x2014 = '-'; 0x2013 = '-'; 0x2265 = '>='; 0x2264 = '<='; 0x00D7 = 'x'; 0x00B7 = '|'; 0x2192 = '->'; 0x2248 = '~'; 0x2018 = "'"; 0x2019 = "'"; 0x201C = '"'; 0x201D = '"'; 0x2122 = ''; 0x00AE = ''; 0x2026 = '...'; 0x00A0 = ' ' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $code = [int]$ch
        if ($map.ContainsKey($code)) { [void]$sb.Append($map[$code]) } else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Write-SRLine {
    param([string]$Text = '', [string]$Color = 'Gray', [string]$Back = '')
    $t = ConvertTo-SRConsole $Text
    try {
        if ($Back -ne '') { Write-Host $t -ForegroundColor $Color -BackgroundColor $Back }
        else { Write-Host $t -ForegroundColor $Color }
    }
    catch { Write-Host $t }
}

function Get-SRStatusColor {
    param([string]$Status)
    if ($Status -eq 'PASS') { return 'Green' }
    if ($Status -eq 'WARN') { return 'Yellow' }
    if ($Status -eq 'FAIL') { return 'Red' }
    if ($Status -eq 'INFO') { return 'Cyan' }
    return 'DarkGray'
}

# ---------------------------------------------------------------------------------------------
# JSON / HTML helpers
# ---------------------------------------------------------------------------------------------
# Escape every non-ASCII char as \uXXXX so results.json and report.html are pure ASCII (no encoding trouble anywhere).
function ConvertTo-SRAsciiJson {
    param([string]$Json)
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) '\u' + ([int][char]$m.Value[0]).ToString('x4') }
    return [System.Text.RegularExpressions.Regex]::Replace($Json, '[^\x00-\x7E]', $evaluator)
}

function Write-SRFile {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-SRFallbackHtml {
    param($Results, [string]$AsciiJson)
    $enc = { param($x) [System.Net.WebUtility]::HtmlEncode([string]$x) }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>ShowReady report</title>')
    [void]$sb.AppendLine('<style>body{font:15px/1.45 system-ui,Segoe UI,sans-serif;margin:24px;max-width:960px}table{border-collapse:collapse;width:100%}td,th{border:1px solid #bbb;padding:4px 8px;text-align:left;vertical-align:top}pre{background:#f3f3f3;padding:12px;overflow:auto;max-height:60vh}.PASS{color:#0a7a2f}.WARN{color:#a86400}.FAIL{color:#b00020}</style></head><body>')
    [void]$sb.AppendLine('<h1>ShowReady report</h1><p>The report template (report-template.html) was not found, so this is the plain fallback. The full data is below.</p>')
    $v = $Results.verdict
    if ($null -ne $v) {
        [void]$sb.AppendLine('<h2>' + (& $enc $v.overall) + '</h2><p>' + (& $enc $v.headline) + '</p><table><tr><th>Status</th><th>Check</th><th>Value</th><th>Limit</th><th>Fix</th></tr>')
        foreach ($c in @($v.checks)) {
            [void]$sb.AppendLine('<tr><td class="' + (& $enc $c.status) + '">' + (& $enc $c.status) + '</td><td>' + (& $enc $c.title) + '</td><td>' + (& $enc $c.value) + '</td><td>' + (& $enc $c.limit) + '</td><td>' + (& $enc $c.fix) + '</td></tr>')
        }
        [void]$sb.AppendLine('</table><h2>Settings</h2><ul>')
        foreach ($s in @($v.settings)) { [void]$sb.AppendLine('<li><b>' + (& $enc $s.label) + ':</b> ' + (& $enc $s.value) + '<br><small>' + (& $enc $s.why) + '</small></li>') }
        [void]$sb.AppendLine('</ul>')
    }
    [void]$sb.AppendLine('<h2>Raw JSON</h2><pre>' + (& $enc $AsciiJson) + '</pre></body></html>')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------------------------
# Observer helpers: big IP digits, iperf3 server phase
# ---------------------------------------------------------------------------------------------
function Write-SRBigText {
    param([string]$Text, [string]$Color = 'White')
    $font = @{
        '0' = @('###', '# #', '# #', '# #', '###'); '1' = @(' # ', '## ', ' # ', ' # ', '###')
        '2' = @('###', '  #', '###', '#  ', '###'); '3' = @('###', '  #', '###', '  #', '###')
        '4' = @('# #', '# #', '###', '  #', '  #'); '5' = @('###', '#  ', '###', '  #', '###')
        '6' = @('###', '#  ', '###', '# #', '###'); '7' = @('###', '  #', '  #', '  #', '  #')
        '8' = @('###', '# #', '###', '# #', '###'); '9' = @('###', '# #', '###', '  #', '###')
        '.' = @(' ', ' ', ' ', ' ', '#')
    }
    for ($row = 0; $row -lt 5; $row++) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('    ')
        foreach ($ch in $Text.ToCharArray()) {
            $g = $font[[string]$ch]
            if ($null -eq $g) { continue }
            # Each font pixel is two characters wide so the digits read as roughly square.
            [void]$sb.Append(($g[$row] -replace '#', '##' -replace ' ', '  ') + ' ')
        }
        Write-SRLine $sb.ToString() $Color
    }
}

# Runs iperf3 -s for the prod PC's LAN test until a key is pressed or $Minutes pass. Never throws.
function Invoke-SRObserverServer {
    param([string]$Exe, [int]$Port, [int]$Minutes, $Ip)
    Write-SRLine ''
    Write-SRLine '==========================================================================' 'Cyan'
    Write-SRLine '  WAITING FOR THE PROD PC (LAN speed test server)' 'Cyan'
    Write-SRLine '==========================================================================' 'Cyan'
    if (-not (Test-Path -LiteralPath $Exe)) {
        Write-SRLine '  bin\iperf3.exe is missing, so the prod PC cannot test the network to this PC. Copy the whole ShowReady folder and run again.' 'Red'
        return
    }
    Write-SRLine '  If Windows Firewall asks about iperf3: tick "Private networks" and click "Allow access".' 'Yellow'
    Write-SRLine '  That may need an administrator password. If you click Cancel, the prod PC cannot connect;' 'Yellow'
    Write-SRLine ('  then ask IT to allow TCP and UDP port ' + $Port + ' for bin\iperf3.exe.') 'Yellow'
    $outFile = Join-Path $env:TEMP ('showready-iperf-server-' + [guid]::NewGuid().ToString('N') + '.txt')
    $errFile = $outFile + '.err'
    $proc = $null
    try {
        $proc = Start-Process -FilePath $Exe -ArgumentList @('-s', '-p', [string]$Port, '--forceflush') -WorkingDirectory $env:TEMP -WindowStyle Hidden -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        Start-Sleep -Milliseconds 1200
        if ($proc.HasExited) {
            $why = ''
            foreach ($f in @($errFile, $outFile)) { try { if (Test-Path -LiteralPath $f) { $why = $why + ' ' + [System.IO.File]::ReadAllText($f).Trim() } } catch { } }
            $why = ($why -replace '\s+', ' ').Trim()
            Write-SRLine ('  iperf3 could not start: ' + $why) 'Red'
            Write-SRLine ('  Close any other iperf3 / Run-LanPartner.cmd window (port ' + $Port + ' must be free) and run Run-Observer.cmd again.') 'Red'
            return
        }
        Write-SRLine ''
        if ($null -ne $Ip -and [string]$Ip -ne '') {
            Write-SRLine '  This PC''s IP address (type it on the prod PC):' 'White'
            Write-SRLine ''
            Write-SRBigText ([string]$Ip) 'Green'
            Write-SRLine ''
            Write-SRLine ('  ' + [string]$Ip) 'Green'
            Write-SRLine ''
            Write-SRLine '  Now run the prod PC test:' 'White'
            Write-SRLine ('     Run-ShowReady.cmd -LanHosts ' + [string]$Ip + ',<other observer''s ip>') 'White'
        }
        else {
            Write-SRLine '  No wired or default-route IPv4 address was found on this PC. Connect it to the production network.' 'Red'
            Write-SRLine '  Now run the prod PC test: Run-ShowReady.cmd -LanHosts <this PC''s ip>,<other observer''s ip>' 'White'
        }
        Write-SRLine ''
        $minWord = 'minutes'
        if ($Minutes -eq 1) { $minWord = 'minute' }
        Write-SRLine ('  Waiting up to ' + $Minutes + ' ' + $minWord + '. Press any key to stop once the prod PC has finished.') 'Gray'
        $keyOk = $true
        try { $keyOk = -not [Console]::IsInputRedirected } catch { $keyOk = $false }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $seen = 0
        $lastNote = 0
        $stopWhy = 'time limit reached'
        while ($sw.Elapsed.TotalMinutes -lt $Minutes) {
            Start-Sleep -Milliseconds 400
            # New output lines (iperf3 keeps the file open, so read with sharing).
            try {
                if (Test-Path -LiteralPath $outFile) {
                    $fs = New-Object System.IO.FileStream($outFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $rd = New-Object System.IO.StreamReader($fs)
                    $all = $rd.ReadToEnd()
                    $rd.Close()
                    $lines = @($all -split "`r?`n")
                    for ($i = $seen; $i -lt $lines.Count - 1; $i++) {
                        $m = [regex]::Match($lines[$i], 'Accepted connection from ([0-9a-fA-F\.:]+), port')
                        if ($m.Success) { Write-SRLine ('  ' + (Get-Date).ToString('HH:mm:ss', $Inv) + '  Prod PC ' + $m.Groups[1].Value + ' connected - testing') 'Cyan' }
                    }
                    if ($lines.Count - 1 -gt $seen) { $seen = $lines.Count - 1 }
                }
            }
            catch { }
            if ($proc.HasExited) { $stopWhy = 'iperf3 stopped by itself'; break }
            if ($keyOk) {
                $pressed = $false
                try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); $pressed = $true } } catch { $keyOk = $false }
                if ($pressed) { $stopWhy = 'key pressed'; break }
            }
            $mins = [int][math]::Floor($sw.Elapsed.TotalMinutes)
            if ($mins -ge $lastNote + 5) {
                $lastNote = $mins
                Write-SRLine ('  ... still waiting (' + ($Minutes - $mins) + ' min left; press any key to stop)') 'DarkGray'
            }
        }
        Write-SRLine ('  LAN test server stopped (' + $stopWhy + ').') 'Gray'
    }
    catch { Write-SRLine ('  LAN test server error: ' + $_.Exception.Message) 'Red' }
    finally {
        if ($null -ne $proc) { try { if (-not $proc.HasExited) { $proc.Kill() } } catch { } }
        Start-Sleep -Milliseconds 200
        foreach ($f in @($outFile, $errFile)) { try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } catch { } }
    }
}

# ---------------------------------------------------------------------------------------------
# Step runner
# ---------------------------------------------------------------------------------------------
$Steps = New-Object System.Collections.ArrayList
$LogBlock = {
    param($m)
    $line = [string]$m
    if ($line.Length -gt 118) { $line = $line.Substring(0, 115) + '...' }
    Write-SRLine ('        ' + $line) 'DarkGray'
}

function Invoke-SRStep {
    param(
        [string]$Key, [string]$Title, [int]$Index, [int]$Total,
        [string]$FuncName, [hashtable]$Params,
        [bool]$SkipIt = $false, [string]$SkipWhy = ''
    )
    $prefix = '[' + $Index + '/' + $Total + '] ' + $Title.PadRight(11)
    $rec = [ordered]@{ key = $Key; title = $Title; status = 'ok'; seconds = 0; message = $null; collector_errors = 0 }
    $result = $null

    if ($SkipIt) {
        $rec.status = 'skipped'
        $rec.message = $SkipWhy
        Write-SRLine ($prefix + ' skipped (' + $SkipWhy + ')') 'DarkYellow'
        [void]$Steps.Add([pscustomobject]$rec)
        return $null
    }
    $cmd = Get-Command -Name $FuncName -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        $rec.status = 'skipped'
        $rec.message = $FuncName + ' is not available (its lib file is missing or failed to load)'
        Write-SRLine ($prefix + ' SKIPPED: ' + $rec.message) 'Yellow'
        [void]$Steps.Add([pscustomobject]$rec)
        return $null
    }

    Write-SRLine ($prefix + ' running...') 'Cyan'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $splat = @{}
        foreach ($k in $Params.Keys) { if ($cmd.Parameters.ContainsKey($k)) { $splat[$k] = $Params[$k] } }
        $out = @(& $FuncName @splat)
        foreach ($o in $out) {
            if ($null -ne $o -and ($o -is [System.Management.Automation.PSCustomObject] -or $o -is [System.Collections.IDictionary])) { $result = $o }
        }
        if ($null -eq $result) {
            $rec.status = 'error'
            $rec.message = $FuncName + ' returned no result object'
        }
    }
    catch {
        $rec.status = 'error'
        $rec.message = $_.Exception.Message
        $result = $null
    }
    $sw.Stop()
    $rec.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    if ($null -ne $result) {
        $errList = @()
        try { if ($null -ne $result.errors) { $errList = @($result.errors | Where-Object { $null -ne $_ -and ([string]$_) -ne '' }) } } catch { $errList = @() }
        $rec.collector_errors = $errList.Count
        $shown = 0
        foreach ($e in $errList) {
            if ($shown -ge 5) { break }
            $line = [string]$e
            if ($line.Length -gt 112) { $line = $line.Substring(0, 109) + '...' }
            Write-SRLine ('        note: ' + $line) 'DarkYellow'
            $shown++
        }
        if ($errList.Count -gt 5) { Write-SRLine ('        note: ... and ' + ($errList.Count - 5) + ' more (see results.json)') 'DarkYellow' }
    }

    $secTxt = $rec.seconds.ToString('0.0', $Inv) + ' s'
    if ($rec.status -eq 'ok') { Write-SRLine ($prefix + ' done in ' + $secTxt) 'Green' }
    else { Write-SRLine ($prefix + ' FAILED after ' + $secTxt + ': ' + $rec.message) 'Red' }
    [void]$Steps.Add([pscustomobject]$rec)
    return $result
}

# ---------------------------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------------------------
$startedAt = [System.DateTimeOffset]::Now
$overallSw = [System.Diagnostics.Stopwatch]::StartNew()
$stamp = $startedAt.ToString('yyyyMMdd-HHmmss', $Inv)

Write-SRLine ''
Write-SRLine '==========================================================================' 'Cyan'
if ($IsObserver) { Write-SRLine ('  ShowReady ' + $ToolVersion + '  -  observer PC: can this PC send its feed?') 'Cyan' }
else { Write-SRLine ('  ShowReady ' + $ToolVersion + '  -  can this PC and line run the show?') 'Cyan' }
Write-SRLine '==========================================================================' 'Cyan'

# ---- config ----
$configPath = Join-Path $Root 'config.json'
$config = $null
try {
    $config = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}
catch {
    Write-SRLine ('Cannot read ' + $configPath + ': ' + $_.Exception.Message) 'Red'
    Write-SRLine 'ShowReady needs config.json next to ShowReady.ps1. Restore it from the kit and run again.' 'Red'
    exit 2
}
if ($null -eq $config) {
    Write-SRLine ('config.json is empty: ' + $configPath) 'Red'
    exit 2
}

# ---- -SrtHost: set as destination and add it as a france probe target ----
$srt = ([string]$SrtHost).Trim()
if ($srt -ne '') {
    try {
        if ($null -eq $config.show.PSObject.Properties['srt_destination_host']) {
            Add-Member -InputObject $config.show -MemberType NoteProperty -Name 'srt_destination_host' -Value $srt -Force
        }
        else { $config.show.srt_destination_host = $srt }
        $dest = [pscustomobject]@{ name = 'SRT destination'; host = $srt; group = 'france'; tcp_port = 443 }
        $config.network.targets = @($config.network.targets) + $dest
    }
    catch { Write-SRLine ('Could not add the SRT destination ' + $srt + ': ' + $_.Exception.Message) 'Yellow' }
}

# ---- -LanHosts: source PCs running Run-LanPartner.cmd, stored as config.lan.cli_hosts ----
$lanHostList = New-Object System.Collections.ArrayList
foreach ($h in @($LanHosts)) {
    foreach ($part in (([string]$h) -split '[,;\s]+')) {
        $p = $part.Trim()
        if ($p -ne '' -and -not $lanHostList.Contains($p)) { [void]$lanHostList.Add($p) }
    }
}
if ($lanHostList.Count -gt 0) {
    try {
        if ($null -eq $config.PSObject.Properties['lan'] -or $null -eq $config.lan) {
            Add-Member -InputObject $config -MemberType NoteProperty -Name 'lan' -Value ([pscustomobject]@{}) -Force
        }
        Add-Member -InputObject $config.lan -MemberType NoteProperty -Name 'cli_hosts' -Value ($lanHostList.ToArray()) -Force
    }
    catch { Write-SRLine ('Could not use -LanHosts: ' + $_.Exception.Message) 'Yellow' }
}

# ---- -Skip ----
$skipSet = @{}
foreach ($s in @($Skip)) {
    foreach ($part in (([string]$s) -split '[,;\s]+')) {
        $k = $part.Trim().ToLowerInvariant()
        if ($k -eq '') { continue }
        if ($k -eq 'hardware' -or $k -eq 'hw') { $skipSet['hardware'] = $true }
        elseif ($IsObserver -and ($k -eq 'sender' -or $k -eq 'encode' -or $k -eq 'load' -or $k -eq 'loadtest')) { $skipSet['sender'] = $true }
        elseif ($IsObserver -and ($k -eq 'network' -or $k -eq 'net' -or $k -eq 'lan' -or $k -eq 'local' -or $k -eq 'localnetwork')) { continue }
        elseif ($IsObserver) { Write-SRLine ('Ignoring unknown -Skip value "' + $part + '" (use hardware, sender).') 'Yellow' }
        elseif ($k -eq 'network' -or $k -eq 'net') { $skipSet['network'] = $true }
        elseif ($k -eq 'load' -or $k -eq 'loadtest' -or $k -eq 'load-test') { $skipSet['load'] = $true }
        elseif ($k -eq 'lan' -or $k -eq 'local' -or $k -eq 'localnetwork') { $skipSet['lan'] = $true }
        else { Write-SRLine ('Ignoring unknown -Skip value "' + $part + '" (use hardware, network, lan, load).') 'Yellow' }
    }
}

$showName = ''
try { $showName = [string]$config.show.name } catch { $showName = '' }
$modeLine = '  ' + $Mode + ' mode'
if ($IsObserver) { $modeLine = '  observer PC  |  ' + $Mode + ' mode' }
if ($showName -ne '') { $modeLine = $modeLine + '  |  ' + $showName }
if ($srt -ne '' -and -not $IsObserver) { $modeLine = $modeLine + '  |  SRT destination ' + $srt }
Write-SRLine $modeLine 'Gray'
Write-SRLine ('  ' + $startedAt.ToString('yyyy-MM-dd HH:mm', $Inv) + '  |  ' + $env:COMPUTERNAME) 'Gray'
Write-SRLine ''

# ---- dot-source libs (each guarded: a broken lib only skips its step) ----
$libErrors = New-Object System.Collections.ArrayList
foreach ($lib in @('Hardware.ps1', 'Network.ps1', 'Lan.ps1', 'LoadTest.ps1', 'Rules.ps1', 'ObserverRules.ps1')) {
    $libPath = Join-Path (Join-Path $Root 'lib') $lib
    if (-not (Test-Path -LiteralPath $libPath)) {
        [void]$libErrors.Add($lib + ' not found')
        Write-SRLine ('lib\' + $lib + ' not found - the matching step will be skipped.') 'Yellow'
        continue
    }
    try { . $libPath }
    catch {
        $em = (([string]$_.Exception.Message) -replace '\s+', ' ')
        if ($em.Length -gt 200) { $em = $em.Substring(0, 197) + '...' }
        [void]$libErrors.Add($lib + ': ' + $em)
        Write-SRLine ('lib\' + $lib + ' failed to load (' + $em + ') - the matching step will be skipped.') 'Yellow'
    }
}

# ---- steps ----
$loadSeconds = 0
try {
    $ls = $config.loadtest.seconds.$Mode
    if ($null -ne $ls) { $loadSeconds = [int]$ls }
}
catch { $loadSeconds = 0 }

$stepTotal = 5
if ($IsObserver) { $stepTotal = 3 }
$hw = Invoke-SRStep -Key 'hardware' -Title 'Hardware' -Index 1 -Total $stepTotal -FuncName 'Get-SRHardware' -Params @{ Log = $LogBlock } -SkipIt ([bool]$skipSet['hardware']) -SkipWhy 'by -Skip'
if ($null -ne $hw) {
    try {
        $gpuNames = @(@($hw.gpus) | ForEach-Object { [string]$_.name }) -join ', '
        Write-SRLine ('        ' + [string]$hw.computer.name + ' | ' + [string]$hw.cpu.name + ' | ' + [string]$hw.ram_gb + ' GB | ' + $gpuNames) 'Gray'
    }
    catch { }
}

$net = $null
$lan = $null
$load = $null
$sender = $null
$obsIp = $null
$obsIpKind = $null
if ($IsObserver) {
    # The address the prod PC should test against: wired first, else the default-route adapter (same pick as the LAN step).
    try {
        if ($null -ne (Get-Command -Name 'SRL_SelectAdapter' -CommandType Function -ErrorAction SilentlyContinue)) {
            $selErrs = New-Object System.Collections.ArrayList
            $sel = SRL_SelectAdapter $selErrs
            if ($null -ne $sel -and $null -ne $sel[0]) { $obsIp = [string]$sel[0].ipv4; $obsIpKind = [string]$sel[0].kind }
        }
    }
    catch { }
    if (-not [bool]$skipSet['sender'] -and -not $NoPrompt) {
        $canAsk = $true
        try { $canAsk = -not [Console]::IsInputRedirected } catch { $canAsk = $false }
        if ($canAsk) {
            Write-SRLine ''
            Write-SRLine '  Start the game / observer client now, as on show day, then press Enter' 'Black' 'Yellow'
            try { [void](Read-Host) } catch { }
        }
    }
    $senderSeconds = 0
    try {
        $ss = $config.observer.sender_seconds.$Mode
        if ($null -ne $ss) { $senderSeconds = [int]$ss }
    }
    catch { $senderSeconds = 0 }
    $sender = Invoke-SRStep -Key 'sender' -Title 'Sender test' -Index 2 -Total $stepTotal -FuncName 'Invoke-SRSenderTest' -Params @{ Config = $config; BinDir = $BinDir; Seconds = $senderSeconds; Log = $LogBlock } -SkipIt ([bool]$skipSet['sender']) -SkipWhy 'by -Skip'
    if ($null -ne $sender) {
        try {
            $sl = '        one 1080p60 SpeedHQ feed: slowest ' + [string]$sender.stream.speed_min + ' x real time'
            if ($null -ne $sender.max_speed) { $sl = $sl + ' (top speed ' + [string]$sender.max_speed + ' x)' }
            if ($null -ne $sender.system) { $sl = $sl + ' | CPU p95 ' + [string]$sender.system.cpu_p95 + ' %' }
            Write-SRLine $sl 'Gray'
        }
        catch { }
    }
    $verdict = Invoke-SRStep -Key 'verdict' -Title 'Verdict' -Index 3 -Total $stepTotal -FuncName 'Get-SRObserverVerdict' -Params @{ Config = $config; Hardware = $hw; Sender = $sender }
}
else {
    $net = Invoke-SRStep -Key 'network' -Title 'Network' -Index 2 -Total 5 -FuncName 'Invoke-SRNetwork' -Params @{ Config = $config; BinDir = $BinDir; Mode = $Mode; Log = $LogBlock } -SkipIt ([bool]$skipSet['network']) -SkipWhy 'by -Skip'
    if ($null -ne $net) {
        try {
            if ($null -ne $net.public -and $null -ne $net.public.ip) { Write-SRLine ('        public IP ' + [string]$net.public.ip + ' | ' + [string]$net.public.city + ' ' + [string]$net.public.country + ' | ' + [string]$net.public.org) 'Gray' }
        }
        catch { }
    }

    # LAN after Network (its 400 Mbps iperf3 can't skew the France numbers) and before the load test (which would skew it).
    $lan = Invoke-SRStep -Key 'lan' -Title 'LAN' -Index 3 -Total 5 -FuncName 'Invoke-SRLan' -Params @{ Config = $config; BinDir = $BinDir; Mode = $Mode; Log = $LogBlock } -SkipIt ([bool]$skipSet['lan']) -SkipWhy 'by -Skip'
    if ($null -ne $lan) {
        try {
            $srcs = @($lan.sources)
            $line = '        ' + @($srcs | Where-Object { $_.protocol -eq 'OMT' }).Count + ' OMT + ' + @($srcs | Where-Object { $_.protocol -eq 'NDI' }).Count + ' NDI source(s)'
            if ($null -ne $lan.sweep -and $null -ne $lan.sweep.cidr -and $null -eq $lan.sweep.skipped_reason) { $line = $line + ' | ' + [string]$lan.sweep.alive + ' device(s) on ' + [string]$lan.sweep.cidr }
            foreach ($pt in @($lan.partners)) {
                if ($null -ne $pt.error) { $line = $line + ' | ' + [string]$pt.host + ': ' + [string]$pt.error; continue }
                $tcpTxt = 'n/a'
                if ($null -ne $pt.tcp -and $null -ne $pt.tcp.mbps) { $tcpTxt = ([double]$pt.tcp.mbps).ToString('0', $Inv) }
                $lossTxt = 'n/a'
                if ($null -ne $pt.udp -and $null -ne $pt.udp.loss_pct) { $lossTxt = ([double]$pt.udp.loss_pct).ToString('0.00', $Inv) }
                $line = $line + ' | ' + [string]$pt.host + ': ' + $tcpTxt + ' Mbps TCP, ' + $lossTxt + ' % UDP loss'
            }
            Write-SRLine $line 'Gray'
        }
        catch { }
    }

    $load = Invoke-SRStep -Key 'load' -Title 'Load test' -Index 4 -Total 5 -FuncName 'Invoke-SRLoadTest' -Params @{ Config = $config; BinDir = $BinDir; Seconds = $loadSeconds; Log = $LogBlock } -SkipIt ([bool]$skipSet['load']) -SkipWhy 'by -Skip'
    if ($null -ne $load) {
        try {
            if ($null -ne $load.encoders -and $null -ne $load.encoders.chosen) { Write-SRLine ('        encoder used: ' + [string]$load.encoders.chosen + ' | CPU p95 ' + [string]$load.system.cpu_p95 + ' %') 'Gray' }
        }
        catch { }
    }

    $verdict = Invoke-SRStep -Key 'verdict' -Title 'Verdict' -Index 5 -Total 5 -FuncName 'Get-SRVerdict' -Params @{ Config = $config; Hardware = $hw; Network = $net; LoadTest = $load; Lan = $lan }
}

# ---------------------------------------------------------------------------------------------
# Results files
# ---------------------------------------------------------------------------------------------
$overallSw.Stop()
$finishedAt = [System.DateTimeOffset]::Now

$compName = $env:COMPUTERNAME
try { if ($null -ne $hw -and $null -ne $hw.computer -and $hw.computer.name) { $compName = [string]$hw.computer.name } } catch { }

$results = [ordered]@{
    schema   = 'showready/1'
    meta     = [ordered]@{
        tool_version = $ToolVersion
        role         = $RoleName
        mode         = $Mode
        started      = $startedAt.ToString('yyyy-MM-ddTHH:mm:sszzz', $Inv)
        finished     = $finishedAt.ToString('yyyy-MM-ddTHH:mm:sszzz', $Inv)
        computer     = $compName
        duration_s   = [math]::Round($overallSw.Elapsed.TotalSeconds, 1)
        srt_host     = $srt
        lan_hosts    = $lanHostList.ToArray()
        skipped      = @($skipSet.Keys | Sort-Object)
        steps        = $Steps.ToArray()
        lib_errors   = $libErrors.ToArray()
    }
    profile  = $config.show
    hardware = $hw
    network  = $net
    lan      = $lan
    loadtest = $load
    verdict  = $verdict
}
if ($IsObserver) {
    $obsMeta = [ordered]@{
        tool_version     = $ToolVersion
        role             = $RoleName
        mode             = $Mode
        started          = $results.meta.started
        finished         = $results.meta.finished
        computer         = $compName
        duration_s       = $results.meta.duration_s
        observer_ip      = $obsIp
        observer_ip_kind = $obsIpKind
        skipped          = @($skipSet.Keys | Sort-Object)
        steps            = $Steps.ToArray()
        lib_errors       = $libErrors.ToArray()
    }
    $results = [ordered]@{
        schema   = 'showready/1'
        meta     = $obsMeta
        profile  = $config.show
        hardware = $hw
        sender   = $sender
        verdict  = $verdict
    }
}

$runDir = Join-Path (Join-Path $Root 'results') $stamp
try { New-Item -ItemType Directory -Force -Path $runDir -ErrorAction Stop | Out-Null }
catch {
    $alt = Join-Path (Join-Path $env:TEMP 'ShowReady-results') $stamp
    Write-SRLine ('Cannot write to ' + $runDir + ' (' + $_.Exception.Message + '); using ' + $alt) 'Yellow'
    $runDir = $alt
    try { New-Item -ItemType Directory -Force -Path $runDir -ErrorAction Stop | Out-Null } catch { }
}
$jsonPath = Join-Path $runDir 'results.json'
$reportPath = Join-Path $runDir 'report.html'

$asciiJson = 'null'
try {
    $rawJson = ConvertTo-Json -InputObject $results -Depth 12
    $asciiJson = ConvertTo-SRAsciiJson $rawJson
}
catch {
    Write-SRLine ('Could not serialise results to JSON: ' + $_.Exception.Message) 'Red'
}

$jsonWritten = $false
try { Write-SRFile $jsonPath $asciiJson; $jsonWritten = $true }
catch { Write-SRLine ('Could not write ' + $jsonPath + ': ' + $_.Exception.Message) 'Red' }

$reportWritten = $false
try {
    $tplPath = Join-Path $Root 'report-template.html'
    $token = '/*__SHOWREADY_DATA__*/null'
    $html = $null
    if (Test-Path -LiteralPath $tplPath) {
        $tpl = [System.IO.File]::ReadAllText($tplPath, [System.Text.Encoding]::UTF8)
        if ($tpl.Contains($token)) {
            $embed = $asciiJson.Replace('</', '<\/').Replace('<!--', '<!--')
            $html = $tpl.Replace($token, $embed)
        }
        else { Write-SRLine 'report-template.html has no data marker; writing the plain fallback report.' 'Yellow' }
    }
    else { Write-SRLine 'report-template.html not found; writing the plain fallback report.' 'Yellow' }
    if ($null -eq $html) { $html = New-SRFallbackHtml $results $asciiJson }
    Write-SRFile $reportPath $html
    $reportWritten = $true
}
catch { Write-SRLine ('Could not write ' + $reportPath + ': ' + $_.Exception.Message) 'Red' }

# ---------------------------------------------------------------------------------------------
# Console summary
# ---------------------------------------------------------------------------------------------
Write-SRLine ''
Write-SRLine '==========================================================================' 'Cyan'
if ($null -eq $verdict) {
    Write-SRLine '  VERDICT UNAVAILABLE - the rules step did not run (see messages above).' 'Red'
}
else {
    $ov = [string]$verdict.overall
    $ovColor = 'Yellow'
    $ovBack = ''
    if ($ov -eq 'GO') { $ovColor = 'White'; $ovBack = 'DarkGreen' }
    elseif ($ov -eq 'CAUTION') { $ovColor = 'Black'; $ovBack = 'DarkYellow' }
    elseif ($ov -eq 'NO-GO') { $ovColor = 'White'; $ovBack = 'DarkRed' }
    Write-SRLine ('   OVERALL:  ' + $ov + '   ') $ovColor $ovBack
    Write-SRLine ('  ' + [string]$verdict.headline) 'White'
    Write-SRLine '==========================================================================' 'Cyan'

    $checks = @($verdict.checks)
    $bad = @($checks | Where-Object { $_.status -eq 'FAIL' })
    $warn = @($checks | Where-Object { $_.status -eq 'WARN' })
    $skipped = @($checks | Where-Object { $_.status -eq 'SKIP' })
    $passN = @($checks | Where-Object { $_.status -eq 'PASS' }).Count

    Write-SRLine ''
    Write-SRLine ('  ' + $passN + ' passed, ' + $warn.Count + ' warning(s), ' + $bad.Count + ' failed, ' + $skipped.Count + ' not measured') 'Gray'

    if ($bad.Count -gt 0) {
        Write-SRLine ''
        Write-SRLine '  MUST FIX (these block the show):' 'Red'
        foreach ($c in $bad) {
            $line = '   [FAIL] ' + [string]$c.title + ': ' + [string]$c.value
            if ([string]$c.limit -ne '') { $line = $line + '   (needs ' + [string]$c.limit + ')' }
            Write-SRLine $line 'Red'
            if ([string]$c.fix -ne '') { Write-SRLine ('          Fix: ' + [string]$c.fix) 'White' }
        }
    }
    if ($warn.Count -gt 0) {
        Write-SRLine ''
        Write-SRLine '  SHOULD FIX (risky but not blocking):' 'Yellow'
        foreach ($c in $warn) {
            $line = '   [WARN] ' + [string]$c.title + ': ' + [string]$c.value
            if ([string]$c.limit -ne '') { $line = $line + '   (needs ' + [string]$c.limit + ')' }
            Write-SRLine $line 'Yellow'
            if ([string]$c.fix -ne '') { Write-SRLine ('          Fix: ' + [string]$c.fix) 'White' }
        }
    }
    if ($skipped.Count -gt 0) {
        Write-SRLine ''
        Write-SRLine ('  Not measured: ' + ((@($skipped | ForEach-Object { [string]$_.title })) -join ', ')) 'DarkGray'
    }

    $sets = @($verdict.settings)
    if ($sets.Count -gt 0) {
        Write-SRLine ''
        Write-SRLine '--------------------------------------------------------------------------' 'Cyan'
        Write-SRLine '  SETTINGS TO USE' 'Cyan'
        foreach ($s in $sets) {
            Write-SRLine ('   ' + ([string]$s.label).PadRight(26) + ' ' + [string]$s.value) 'White'
            if ([string]$s.why -ne '') { Write-SRLine ('        ' + [string]$s.why) 'DarkGray' }
        }
    }
    $manual = @($verdict.manual_checks)
    if ($manual.Count -gt 0) {
        Write-SRLine ''
        Write-SRLine '--------------------------------------------------------------------------' 'Cyan'
        Write-SRLine '  STILL TO DO BY HAND' 'Cyan'
        foreach ($m in $manual) { Write-SRLine ('   [ ] ' + [string]$m.text) 'Gray' }
    }
}

Write-SRLine ''
Write-SRLine '--------------------------------------------------------------------------' 'Cyan'
if ($reportWritten) { Write-SRLine ('  Report:  ' + $reportPath) 'Green' }
if ($jsonWritten) { Write-SRLine ('  Data:    ' + $jsonPath) 'Gray' }
Write-SRLine ('  Took ' + $overallSw.Elapsed.TotalSeconds.ToString('0', $Inv) + ' s') 'Gray'

# ---- upload the results folder (upload.json from Setup-Upload.cmd); before the observer waits, so it always happens ----
$uploadLib = Join-Path $Root 'lib\Upload.ps1'
if (-not $NoUpload -and $jsonWritten -and (Test-Path -LiteralPath $uploadLib)) {
    try {
        . $uploadLib
        $upKind = 'showready'
        if ($IsObserver) { $upKind = 'observer' }
        $up = Send-SRResults -RunDir $runDir -Kind $upKind -Root $Root -Log { param($m) }
        if ($up.ok) { Write-SRLine ('  Uploaded: ' + [string]$up.url) 'Green' }
        elseif ([string]$up.error -eq 'upload not set up') { Write-SRLine '  Not uploaded: run Setup-Upload.cmd once on this PC to send results online.' 'DarkGray' }
        else { Write-SRLine ('  Not uploaded: ' + [string]$up.error + ' (run Upload-Results.cmd to retry)') 'Yellow' }
    }
    catch { Write-SRLine ('  Not uploaded: ' + $_.Exception.Message) 'Yellow' }
}
Write-SRLine ''

if ($reportWritten -and -not $NoOpen) {
    try { Start-Process -FilePath $reportPath }
    catch { Write-SRLine ('Could not open the report automatically: ' + $_.Exception.Message) 'Yellow' }
}

# ---- observer: wait as the iperf3 server for the prod PC's LAN test ----
if ($IsObserver) {
    $srvMinutes = $ServerMinutes
    if ($srvMinutes -lt 0) {
        $srvMinutes = 30
        try { if ($null -ne $config.observer.server_minutes) { $srvMinutes = [int]$config.observer.server_minutes } } catch { }
    }
    $srvPort = 5201
    try { if ($null -ne $config.observer.port) { $srvPort = [int]$config.observer.port } } catch { }
    if ($srvMinutes -gt 0) { Invoke-SRObserverServer -Exe (Join-Path $BinDir 'iperf3.exe') -Port $srvPort -Minutes $srvMinutes -Ip $obsIp }
    else { Write-SRLine '  LAN test server skipped (-ServerMinutes 0).' 'DarkGray' }
    Write-SRLine ''
}
exit 0
