# ShowReady - prep orchestrator
# Updates drivers, switches display language to English, disables startup apps,
# closes background apps, checks disk space, configures power plan and system settings.
#
#   Prep.ps1 [-Role prod|observer] [-Yes] [-PlanOnly] [-DryRun]
#            [-Only <sections>] [-Skip <sections>] [-Undo <latest|folder>]
#            [-NoUpload] [-NoElevate] [-SkipActivation]
#
# Windows PowerShell 5.1 compatible. Pure ASCII source. Never throws to caller.

[CmdletBinding()]
param(
    [ValidateSet('prod', 'observer', '')]
    [string]$Role = '',
    [switch]$Yes,
    [switch]$PlanOnly,
    [switch]$DryRun,
    [string[]]$Only = @(),
    [string[]]$Skip = @(),
    [string]$Undo = '',
    [switch]$NoUpload,
    [switch]$NoElevate,
    [switch]$SkipActivation
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$ToolVersion = '1.3.3-prep'
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

$Root = $PSScriptRoot
if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrEmpty($Root)) { $Root = (Get-Location).Path }

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# Split -Only and -Skip on commas
$OnlySections = New-Object System.Collections.ArrayList
foreach ($o in @($Only)) {
    if ($null -ne $o) {
        foreach ($part in ([string]$o -split '[,;\s]+')) {
            $p = $part.Trim().ToLowerInvariant()
            if ($p -ne '' -and -not $OnlySections.Contains($p)) {
                [void]$OnlySections.Add($p)
            }
        }
    }
}

$SkipSections = New-Object System.Collections.ArrayList
foreach ($s in @($Skip)) {
    if ($null -ne $s) {
        foreach ($part in ([string]$s -split '[,;\s]+')) {
            $p = $part.Trim().ToLowerInvariant()
            if ($p -ne '' -and -not $SkipSections.Contains($p)) {
                [void]$SkipSections.Add($p)
            }
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Console and Logging Helpers (ASCII only)
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

$script:LogLines = New-Object System.Collections.ArrayList

function Write-SRLogLine {
    param([string]$Text = '', [string]$Color = 'Gray', [string]$Back = '')
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $Inv)
    [void]$script:LogLines.Add($stamp + '  ' + (ConvertTo-SRConsole $Text))
    Write-SRLine -Text $Text -Color $Color -Back $Back
}

$LogBlock = {
    param($m)
    $msg = [string]$m
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $Inv)
    [void]$script:LogLines.Add($stamp + '  ' + (ConvertTo-SRConsole $msg))
    $display = ConvertTo-SRConsole $msg
    if ($display.Length -gt 118) { $display = $display.Substring(0, 115) + '...' }
    Write-SRLine ('        ' + $display) 'DarkGray'
}

function Get-SRPrepColor {
    param([string]$Status)
    switch ($Status) {
        'OK'      { return 'Green' }
        'DONE'    { return 'Green' }
        'CHANGE'  { return 'Cyan' }
        'MANUAL'  { return 'Yellow' }
        'WARN'    { return 'Yellow' }
        'ERROR'   { return 'Red' }
        'FAILED'  { return 'Red' }
        'INFO'    { return 'Gray' }
        'SKIPPED' { return 'DarkYellow' }
        default   { return 'Gray' }
    }
}

function ConvertTo-SRAsciiJson {
    param([string]$Json)
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) '\u' + ([int][char]$m.Value[0]).ToString('x4') }
    return [System.Text.RegularExpressions.Regex]::Replace($Json, '[^\x00-\x7E]', $evaluator)
}

function Write-SRFile {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Wait-Close {
    param([bool]$YesOption)
    $nonInteractive = $false
    try {
        if (-not [Environment]::UserInteractive) { $nonInteractive = $true }
    } catch { }
    if ($YesOption -and $nonInteractive) { return }
    try {
        Write-SRLine ''
        Write-SRLine 'Press Enter to close' 'Gray'
        [void](Read-Host)
    }
    catch { }
}

# ---------------------------------------------------------------------------------------------
# Elevation check & self-elevation
# ---------------------------------------------------------------------------------------------
$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    $isAdmin = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
catch { $isAdmin = $false }

if (-not $isAdmin -and -not $NoElevate -and -not $PlanOnly) {
    $scriptFile = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrEmpty($scriptFile)) {
        $scriptFile = Join-Path $Root 'Prep.ps1'
    }
    $elevateArgs = New-Object System.Collections.ArrayList
    [void]$elevateArgs.Add('-NoProfile')
    [void]$elevateArgs.Add('-ExecutionPolicy')
    [void]$elevateArgs.Add('Bypass')
    [void]$elevateArgs.Add('-File')
    [void]$elevateArgs.Add('"' + $scriptFile + '"')

    if ($PSBoundParameters.ContainsKey('Role') -and [string]$Role -ne '') {
        [void]$elevateArgs.Add('-Role')
        [void]$elevateArgs.Add('"' + $Role + '"')
    }
    if ($Yes) { [void]$elevateArgs.Add('-Yes') }
    if ($DryRun) { [void]$elevateArgs.Add('-DryRun') }
    if ($OnlySections.Count -gt 0) {
        [void]$elevateArgs.Add('-Only')
        [void]$elevateArgs.Add('"' + ($OnlySections -join ',') + '"')
    }
    if ($SkipSections.Count -gt 0) {
        [void]$elevateArgs.Add('-Skip')
        [void]$elevateArgs.Add('"' + ($SkipSections -join ',') + '"')
    }
    if ($PSBoundParameters.ContainsKey('Undo') -and [string]$Undo -ne '') {
        [void]$elevateArgs.Add('-Undo')
        [void]$elevateArgs.Add('"' + $Undo + '"')
    }
    if ($NoUpload) { [void]$elevateArgs.Add('-NoUpload') }
    if ($SkipActivation) { [void]$elevateArgs.Add('-SkipActivation') }

    foreach ($extra in $args) {
        if ($null -ne $extra -and [string]$extra -ne '') {
            [void]$elevateArgs.Add('"' + [string]$extra + '"')
        }
    }

    try {
        $argStr = $elevateArgs -join ' '
        [void](Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argStr -ErrorAction Stop)
        exit 0
    }
    catch {
        Write-SRLogLine ('Administrator elevation was refused or unavailable: ' + $_.Exception.Message) 'Yellow'
        Write-SRLogLine 'Continuing in plan-only mode (-PlanOnly)...' 'Yellow'
        $PlanOnly = $true
    }
}

# ---------------------------------------------------------------------------------------------
# Main Orchestration
# ---------------------------------------------------------------------------------------------
$startedAt = [System.DateTimeOffset]::Now
$stamp = $startedAt.ToString('yyyyMMdd-HHmmss', $Inv)
$runDir = Join-Path (Join-Path $Root 'results') ($stamp + '-prep')
$backupDir = Join-Path $runDir 'backup'

$orderedSections = @('language', 'drivers', 'disk', 'reboot', 'power', 'startup', 'background', 'network', 'capture', 'notifications', 'updates')

try {
    # Banner
    Write-SRLogLine ''
    Write-SRLogLine '==========================================================================' 'Cyan'
    Write-SRLogLine ('  ShowReady ' + $ToolVersion + '  -  PC preparation') 'Cyan'
    Write-SRLogLine '==========================================================================' 'Cyan'

    # Ask Role if empty and not -Undo
    if ([string]::IsNullOrEmpty($Undo) -and [string]::IsNullOrEmpty($Role)) {
        while ($Role -notin @('prod', 'observer')) {
            $ans = ''
            try {
                $ans = Read-Host 'Is this the PROD PC (vMix/OBS) or an OBSERVER PC? [P/O]'
            }
            catch {
                $ans = 'P'
            }
            $ans = ([string]$ans).Trim().ToUpperInvariant()
            if ($ans -eq 'P' -or $ans -eq 'PROD') { $Role = 'prod' }
            elseif ($ans -eq 'O' -or $ans -eq 'OBSERVER') { $Role = 'observer' }
            elseif (-not [Environment]::UserInteractive) { $Role = 'prod'; break }
        }
    }

    $modeStr = ''
    if ($Role -eq 'prod') { $modeStr = '  prod PC (vMix/OBS)' }
    elseif ($Role -eq 'observer') { $modeStr = '  observer PC' }
    else { $modeStr = '  ShowReady PC' }

    if ($PlanOnly) { $modeStr += '  |  Plan-only mode' }
    elseif ($DryRun) { $modeStr += '  |  Dry-run mode' }
    if ($Undo -ne '') { $modeStr += '  |  Undo mode (' + $Undo + ')' }

    Write-SRLogLine $modeStr 'Gray'
    Write-SRLogLine ('  ' + $startedAt.ToString('yyyy-MM-dd HH:mm', $Inv) + '  |  ' + $env:COMPUTERNAME) 'Gray'
    Write-SRLogLine ''

    # Check for per-user identity difference
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $consoleUser = $null
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($null -ne $cs) { $consoleUser = [string]$cs.UserName }
    }
    catch { }
    if ($null -ne $consoleUser -and $consoleUser -ne '' -and $currentUser -ne $consoleUser) {
        Write-SRLogLine ('Note: running as ' + $currentUser + ' while console user is ' + $consoleUser + '.') 'Yellow'
        Write-SRLogLine 'Per-user settings (display language, notifications, startup) may require signing in as an administrator.' 'Yellow'
        Write-SRLogLine ''
    }

    # =========================================================================================
    # UNDO WORKFLOW
    # =========================================================================================
    if ($Undo -ne '') {
        $targetBackupDir = $null
        if ($Undo -eq 'latest') {
            $resultsDir = Join-Path $Root 'results'
            if (Test-Path -LiteralPath $resultsDir) {
                $prepDirs = @(Get-ChildItem -LiteralPath $resultsDir -Directory -Filter '*-prep' | Sort-Object -Property Name -Descending)
                foreach ($d in $prepDirs) {
                    $cand = Join-Path $d.FullName 'backup'
                    if (Test-Path -LiteralPath $cand) {
                        $targetBackupDir = $cand
                        break
                    }
                }
            }
        }
        else {
            if (Test-Path -LiteralPath (Join-Path $Undo 'backup')) {
                $targetBackupDir = Join-Path $Undo 'backup'
            }
            elseif (Test-Path -LiteralPath $Undo) {
                $targetBackupDir = $Undo
            }
            elseif (Test-Path -LiteralPath (Join-Path (Join-Path $Root 'results') (Join-Path $Undo 'backup'))) {
                $targetBackupDir = Join-Path (Join-Path $Root 'results') (Join-Path $Undo 'backup')
            }
            elseif (Test-Path -LiteralPath (Join-Path (Join-Path $Root 'results') $Undo)) {
                $targetBackupDir = Join-Path (Join-Path $Root 'results') $Undo
            }
        }

        if ($null -eq $targetBackupDir -or -not (Test-Path -LiteralPath $targetBackupDir)) {
            Write-SRLogLine ('Backup directory not found for -Undo: ' + $Undo) 'Red'
            Wait-Close -YesOption $Yes
            exit 1
        }

        Write-SRLogLine ('Restoring prep changes from backup: ' + $targetBackupDir) 'Cyan'

        $systemLibPath = Join-Path (Join-Path $Root 'lib') 'Prep.System.ps1'
        $tuneLibPath = Join-Path (Join-Path $Root 'lib') 'Prep.Tune.ps1'
        $hasSysLib = $false
        $hasTuneLib = $false

        if (Test-Path -LiteralPath $tuneLibPath) {
            try { . $tuneLibPath; $hasTuneLib = $true }
            catch { Write-SRLogLine ('lib\Prep.Tune.ps1 failed to load: ' + $_.Exception.Message) 'Yellow' }
        }
        else {
            Write-SRLogLine 'lib\Prep.Tune.ps1 not found.' 'Yellow'
        }

        if (Test-Path -LiteralPath $systemLibPath) {
            try { . $systemLibPath; $hasSysLib = $true }
            catch { Write-SRLogLine ('lib\Prep.System.ps1 failed to load: ' + $_.Exception.Message) 'Yellow' }
        }
        else {
            Write-SRLogLine 'lib\Prep.System.ps1 not found.' 'Yellow'
        }

        $tuneUndoResults = @()
        if ($hasTuneLib) {
            try {
                $tuneUndoResults = @(Undo-SRPrepTune -BackupDir $targetBackupDir -DryRun:$DryRun -Log $LogBlock | ForEach-Object { $_ })
            }
            catch {
                Write-SRLogLine ('Error during Undo-SRPrepTune: ' + $_.Exception.Message) 'Red'
            }
        }

        $systemUndoResults = @()
        if ($hasSysLib) {
            try {
                $systemUndoResults = @(Undo-SRPrepSystem -BackupDir $targetBackupDir -DryRun:$DryRun -Log $LogBlock | ForEach-Object { $_ })
            }
            catch {
                Write-SRLogLine ('Error during Undo-SRPrepSystem: ' + $_.Exception.Message) 'Red'
            }
        }

        Write-SRLogLine ''
        Write-SRLogLine '  RESTORE RESULTS:' 'White'
        $allUndo = @($tuneUndoResults) + @($systemUndoResults)
        foreach ($item in $allUndo) {
            $tag = ('[' + $item.status + ']').PadRight(9)
            $line = '  ' + $tag + ' ' + $item.title + ': ' + $item.detail
            Write-SRLogLine $line (Get-SRPrepColor $item.status)
        }

        $undoRunDir = Join-Path (Join-Path $Root 'results') ($stamp + '-prep-undo')
        [void][System.IO.Directory]::CreateDirectory($undoRunDir)
        $undoLogPath = Join-Path $undoRunDir 'prep.log'
        $undoJsonPath = Join-Path $undoRunDir 'undo.json'

        $undoMeta = [ordered]@{
            tool_version = $ToolVersion
            computer     = [string]$env:COMPUTERNAME
            user         = [string][Security.Principal.WindowsIdentity]::GetCurrent().Name
            elevated     = [bool]$isAdmin
            role         = [string]$Role
            started      = [string]$startedAt.ToString('o')
            finished     = [string][System.DateTimeOffset]::Now.ToString('o')
            dry_run      = [bool]$DryRun
            backup_dir   = [string]$targetBackupDir
        }
        $undoObj = [ordered]@{
            meta   = $undoMeta
            tune   = @($tuneUndoResults)
            system = @($systemUndoResults)
        }
        $undoAsciiJson = ConvertTo-SRAsciiJson (ConvertTo-Json $undoObj -Depth 10)
        Write-SRFile -Path $undoJsonPath -Text $undoAsciiJson

        $logText = ($script:LogLines -join "`r`n") + "`r`n"
        Write-SRFile -Path $undoLogPath -Text $logText

        $uploadLib = Join-Path (Join-Path $Root 'lib') 'Upload.ps1'
        if (-not $NoUpload -and (Test-Path -LiteralPath $uploadLib)) {
            try {
                . $uploadLib
                $up = Send-SRResults -RunDir $undoRunDir -Kind 'prep' -Root $Root -Log $LogBlock
                if ($null -ne $up) {
                    if ($up.ok) { Write-SRLogLine ('  Uploaded: ' + [string]$up.url) 'Green' }
                    elseif ([string]$up.error -eq 'upload not set up') { Write-SRLogLine '  Not uploaded: run Setup-Upload.cmd once on this PC to send results online.' 'DarkGray' }
                    else { Write-SRLogLine ('  Not uploaded: ' + [string]$up.error) 'Yellow' }
                }
            }
            catch {
                Write-SRLogLine ('  Upload error: ' + $_.Exception.Message) 'Yellow'
            }
        }

        Wait-Close -YesOption $Yes
        exit 0
    }

    # =========================================================================================
    # PREP PLAN & APPLY WORKFLOW
    # =========================================================================================
    # Load prep-config.json
    $configPath = Join-Path $Root 'prep-config.json'
    $Settings = $null
    if (Test-Path -LiteralPath $configPath) {
        try {
            $rawJson = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
            $Settings = ConvertFrom-Json $rawJson
        }
        catch {
            Write-SRLogLine ('Warning: prep-config.json could not be parsed: ' + $_.Exception.Message) 'Yellow'
            $Settings = $null
        }
    }
    else {
        Write-SRLogLine ('Warning: prep-config.json not found at ' + $configPath) 'Yellow'
        $Settings = $null
    }

    # Dot-source libraries
    $systemLibPath = Join-Path (Join-Path $Root 'lib') 'Prep.System.ps1'
    $tuneLibPath = Join-Path (Join-Path $Root 'lib') 'Prep.Tune.ps1'
    $hasSysLib = $false
    $hasTuneLib = $false

    if (Test-Path -LiteralPath $systemLibPath) {
        try {
            . $systemLibPath
            $hasSysLib = $true
        }
        catch {
            Write-SRLogLine ('Warning: lib\Prep.System.ps1 failed to load: ' + $_.Exception.Message) 'Yellow'
        }
    }
    else {
        Write-SRLogLine 'Warning: lib\Prep.System.ps1 not found. System sections will be skipped.' 'Yellow'
    }

    if (Test-Path -LiteralPath $tuneLibPath) {
        try {
            . $tuneLibPath
            $hasTuneLib = $true
        }
        catch {
            Write-SRLogLine ('Warning: lib\Prep.Tune.ps1 failed to load: ' + $_.Exception.Message) 'Yellow'
        }
    }
    else {
        Write-SRLogLine 'Warning: lib\Prep.Tune.ps1 not found. Tune sections will be skipped.' 'Yellow'
    }

    # Build plans
    $systemPlan = @()
    if ($hasSysLib) {
        try {
            $systemPlan = @(Get-SRPrepSystemPlan -Settings $Settings -Role $Role -Log $LogBlock | ForEach-Object { $_ })
        }
        catch {
            Write-SRLogLine ('Error in Get-SRPrepSystemPlan: ' + $_.Exception.Message) 'Red'
        }
    }

    $tunePlan = @()
    if ($hasTuneLib) {
        try {
            $tunePlan = @(Get-SRPrepTunePlan -Settings $Settings -Role $Role -Log $LogBlock | ForEach-Object { $_ })
        }
        catch {
            Write-SRLogLine ('Error in Get-SRPrepTunePlan: ' + $_.Exception.Message) 'Red'
        }
    }

    $rawPlan = @($systemPlan) + @($tunePlan)

    # Filter plan by -Only / -Skip
    $filteredPlan = New-Object System.Collections.ArrayList
    foreach ($item in $rawPlan) {
        if ($null -eq $item) { continue }
        $sec = ([string]$item.section).ToLowerInvariant()
        if ($OnlySections.Count -gt 0 -and -not $OnlySections.Contains($sec)) { continue }
        if ($SkipSections.Count -gt 0 -and $SkipSections.Contains($sec)) { continue }
        [void]$filteredPlan.Add($item)
    }

    # Display plan grouped by section in exact order
    Write-SRLogLine '  PLAN:' 'White'
    $seenSections = New-Object System.Collections.ArrayList
    foreach ($sec in $orderedSections) {
        $secItems = @($filteredPlan | Where-Object { ([string]$_.section).ToLowerInvariant() -eq $sec })
        if ($secItems.Count -eq 0) { continue }
        [void]$seenSections.Add($sec)

        Write-SRLogLine ''
        Write-SRLogLine ('  === ' + $sec.ToUpperInvariant() + ' ===') 'White'

        $maxTitle = 0
        foreach ($it in $secItems) {
            $tLen = ([string]$it.title).Length
            if ($tLen -gt $maxTitle) { $maxTitle = $tLen }
        }
        $pad = [int][math]::Max([double]$maxTitle, [double]16)

        foreach ($it in $secItems) {
            $tag = ('[' + [string]$it.status + ']').PadRight(9)
            $val = ''
            $cur = [string]$it.current
            $tgt = [string]$it.target
            if ($cur -ne '' -and $tgt -ne '') { $val = $cur + ' -> ' + $tgt }
            elseif ($cur -ne '') { $val = $cur }
            elseif ($tgt -ne '') { $val = '-> ' + $tgt }

            $titlePadded = ([string]$it.title).PadRight($pad)
            $line = '  ' + $tag + ' ' + $titlePadded + ': ' + $val
            Write-SRLogLine $line (Get-SRPrepColor $it.status)
        }
    }

    # Also display any remaining sections not in the standard list
    foreach ($it in $filteredPlan) {
        $sec = ([string]$it.section).ToLowerInvariant()
        if (-not $orderedSections.Contains($sec) -and -not $seenSections.Contains($sec)) {
            [void]$seenSections.Add($sec)
            $secItems = @($filteredPlan | Where-Object { ([string]$_.section).ToLowerInvariant() -eq $sec })
            Write-SRLogLine ''
            Write-SRLogLine ('  === ' + $sec.ToUpperInvariant() + ' ===') 'White'
            $maxTitle = 0
            foreach ($item in $secItems) {
                if (([string]$item.title).Length -gt $maxTitle) { $maxTitle = ([string]$item.title).Length }
            }
            $pad = [int][math]::Max([double]$maxTitle, [double]16)
            foreach ($item in $secItems) {
                $tag = ('[' + [string]$item.status + ']').PadRight(9)
                $cur = [string]$item.current
                $tgt = [string]$item.target
                $val = ''
                if ($cur -ne '' -and $tgt -ne '') { $val = $cur + ' -> ' + $tgt }
                elseif ($cur -ne '') { $val = $cur }
                elseif ($tgt -ne '') { $val = '-> ' + $tgt }
                $titlePadded = ([string]$item.title).PadRight($pad)
                $line = '  ' + $tag + ' ' + $titlePadded + ': ' + $val
                Write-SRLogLine $line (Get-SRPrepColor $item.status)
            }
        }
    }

    # Ensure results and backup directories exist
    [void][System.IO.Directory]::CreateDirectory($backupDir)

    $appliedItems = New-Object System.Collections.ArrayList

    if (-not $PlanOnly) {
        # -------------------------------------------------------------------------------------
        # Selection
        # -------------------------------------------------------------------------------------
        $selectedItems = New-Object System.Collections.ArrayList
        if ($Yes) {
            foreach ($it in $filteredPlan) {
                if ($it.status -eq 'CHANGE' -and [bool]$it.default_apply -eq $true -and $it.id -ne 'sys_edition') {
                    [void]$selectedItems.Add($it)
                }
            }
        }
        else {
            Write-SRLogLine ''
            Write-SRLogLine '--------------------------------------------------------------------------' 'Cyan'
            Write-SRLogLine '  SELECTION' 'Cyan'
            Write-SRLogLine '--------------------------------------------------------------------------' 'Cyan'

            foreach ($sec in $orderedSections) {
                $changeItems = @($filteredPlan | Where-Object { ([string]$_.section).ToLowerInvariant() -eq $sec -and $_.status -eq 'CHANGE' })
                if ($changeItems.Count -eq 0) { continue }

                $recItems = @($changeItems | Where-Object { [bool]$_.default_apply -eq $true -and [string]$_.risk -ne 'medium' })
                $medItems = @($changeItems | Where-Object { [string]$_.risk -eq 'medium' })

                if ($sec -eq 'background' -and ($recItems.Count -gt 0 -or $medItems.Count -gt 0)) {
                    Write-SRLogLine 'This closes apps now. Save your work first.' 'Yellow'
                }

                if ($recItems.Count -gt 0) {
                    $prompt = 'Apply the ' + $recItems.Count + ' recommended changes in ' + $sec + '? [Y/n]'
                    $ans = ''
                    try { $ans = Read-Host $prompt } catch { $ans = 'y' }
                    $ans = ([string]$ans).Trim().ToLowerInvariant()
                    if ($ans -eq '' -or $ans -eq 'y' -or $ans -eq 'yes') {
                        foreach ($r in $recItems) { [void]$selectedItems.Add($r) }
                    }
                }

                foreach ($m in $medItems) {
                    if ($m.id -eq 'sys_edition') {
                        Write-SRLine ''
                        Write-SRLine '  ========================================================================' 'Red'
                        Write-SRLine '  WARNING: WINDOWS EDITION SWITCH (NO UNDO)' 'Red'
                        Write-SRLine '  ========================================================================' 'Red'
                        Write-SRLine '  - Needed before English display language can be installed.' 'Yellow'
                        Write-SRLine '  - Windows will be NOT ACTIVATED: "Activate Windows" watermark in the' 'Yellow'
                        Write-SRLine '    corner (shows in desktop captures); personalisation settings locked.' 'Yellow'
                        Write-SRLine '  - THERE IS NO UNDO: getting activated Windows back requires buying a' 'Yellow'
                        Write-SRLine '    licence or reinstalling factory Windows 11 Home Single Language.' 'Yellow'
                        Write-SRLine '  - Keeps installed applications and personal files.' 'Yellow'
                        Write-SRLine '  - The PC restarts, then run Run-Prep.cmd again for English.' 'Yellow'
                        Write-SRLine '  ========================================================================' 'Red'

                        $isPro = ([string]$m.target -match '(?i)\bPro\b')
                        $word = if ($isPro) { 'PRO' } else { 'HOME' }
                        $prompt = if ($isPro) {
                            'Type PRO to switch this PC to Windows Pro (not activated), or press Enter to skip'
                        } else {
                            'Type HOME to switch this PC to Windows Home (not activated), or press Enter to skip'
                        }

                        $ans = ''
                        try { $ans = Read-Host $prompt } catch { $ans = '' }
                        if (([string]$ans).Trim().ToUpperInvariant() -eq $word) {
                            [void]$selectedItems.Add($m)
                        }
                    } else {
                        $prompt = [string]$m.title
                        if ([string]$m.detail -ne '') { $prompt += ' - ' + [string]$m.detail }
                        $prompt += ' [y/N]'
                        $ans = ''
                        try { $ans = Read-Host $prompt } catch { $ans = 'n' }
                        $ans = ([string]$ans).Trim().ToLowerInvariant()
                        if ($ans -eq 'y' -or $ans -eq 'yes') {
                            [void]$selectedItems.Add($m)
                        }
                    }
                }
            }
        }

        # -------------------------------------------------------------------------------------
        # Apply in 4 phases:
        # Phase 1: language (system lib)
        # Phase 2: drivers (system lib)
        # Phase 3: power, startup, background, network, capture, notifications (tune lib)
        # Phase 4: updates (system lib)
        # -------------------------------------------------------------------------------------
        Write-SRLogLine ''
        Write-SRLogLine '--------------------------------------------------------------------------' 'Cyan'
        Write-SRLogLine '  APPLYING CHANGES' 'Cyan'
        Write-SRLogLine '--------------------------------------------------------------------------' 'Cyan'

        # Separate sys_edition from phase 1 to run last
        $editionItem = $null
        foreach ($it in $selectedItems) {
            if ($it.id -eq 'sys_edition') {
                $editionItem = $it
                break
            }
        }

        # Phase 1: language
        $langItems = @($selectedItems | Where-Object { ([string]$_.section).ToLowerInvariant() -eq 'language' -and $_.id -ne 'sys_edition' })
        if ($langItems.Count -gt 0) {
            Write-SRLogLine 'Downloading English can take 5-30 minutes' 'Yellow'
            Write-SRLogLine ('Applying language (' + $langItems.Count + ' item(s))...') 'Cyan'
            if ($hasSysLib) {
                try {
                    $res = @(Invoke-SRPrepSystemApply -Items $langItems -Settings $Settings -BackupDir $backupDir -DryRun:$DryRun -Log $LogBlock | ForEach-Object { $_ })
                    foreach ($r in $res) { [void]$appliedItems.Add($r) }
                }
                catch {
                    Write-SRLogLine ('Error applying language: ' + $_.Exception.Message) 'Red'
                    foreach ($it in $langItems) {
                        $failedItem = $it.PSObject.Copy()
                        $failedItem.status = 'FAILED'
                        $failedItem.detail = $_.Exception.Message
                        [void]$appliedItems.Add($failedItem)
                    }
                }
            }
            else {
                Write-SRLogLine 'lib\Prep.System.ps1 is missing; language changes skipped.' 'Yellow'
            }
        }

        # Phase 2: drivers
        $driverItems = @($selectedItems | Where-Object { ([string]$_.section).ToLowerInvariant() -eq 'drivers' })
        if ($driverItems.Count -gt 0) {
            Write-SRLogLine 'Windows Update drivers can take 5-20 minutes' 'Yellow'
            Write-SRLogLine ('Applying drivers (' + $driverItems.Count + ' item(s))...') 'Cyan'
            if ($hasSysLib) {
                try {
                    $res = @(Invoke-SRPrepSystemApply -Items $driverItems -Settings $Settings -BackupDir $backupDir -DryRun:$DryRun -Log $LogBlock | ForEach-Object { $_ })
                    foreach ($r in $res) { [void]$appliedItems.Add($r) }
                }
                catch {
                    Write-SRLogLine ('Error applying drivers: ' + $_.Exception.Message) 'Red'
                    foreach ($it in $driverItems) {
                        $failedItem = $it.PSObject.Copy()
                        $failedItem.status = 'FAILED'
                        $failedItem.detail = $_.Exception.Message
                        [void]$appliedItems.Add($failedItem)
                    }
                }
            }
            else {
                Write-SRLogLine 'lib\Prep.System.ps1 is missing; driver changes skipped.' 'Yellow'
            }
        }

        # Phase 3: tune sections (power, startup, background, network, capture, notifications)
        $tuneSections = @('power', 'startup', 'background', 'network', 'capture', 'notifications')
        $tuneItemsList = New-Object System.Collections.ArrayList
        foreach ($tSec in $tuneSections) {
            foreach ($it in $selectedItems) {
                if (([string]$it.section).ToLowerInvariant() -eq $tSec) {
                    [void]$tuneItemsList.Add($it)
                }
            }
        }
        if ($tuneItemsList.Count -gt 0) {
            if (@($tuneItemsList | Where-Object { ([string]$_.section).ToLowerInvariant() -eq 'background' }).Count -gt 0) {
                Write-SRLogLine 'This closes apps now. Save your work first.' 'Yellow'
            }
            Write-SRLogLine ('Applying tuning (' + $tuneItemsList.Count + ' item(s))...') 'Cyan'
            if ($hasTuneLib) {
                try {
                    $res = @(Invoke-SRPrepTuneApply -Items $tuneItemsList.ToArray() -Settings $Settings -BackupDir $backupDir -DryRun:$DryRun -Log $LogBlock | ForEach-Object { $_ })
                    foreach ($r in $res) { [void]$appliedItems.Add($r) }
                }
                catch {
                    Write-SRLogLine ('Error applying tuning: ' + $_.Exception.Message) 'Red'
                    foreach ($it in $tuneItemsList) {
                        $failedItem = $it.PSObject.Copy()
                        $failedItem.status = 'FAILED'
                        $failedItem.detail = $_.Exception.Message
                        [void]$appliedItems.Add($failedItem)
                    }
                }
            }
            else {
                Write-SRLogLine 'lib\Prep.Tune.ps1 is missing; tune changes skipped.' 'Yellow'
            }
        }

        # Phase 4: updates (system lib)
        $updateItems = @($selectedItems | Where-Object { ([string]$_.section).ToLowerInvariant() -eq 'updates' })
        if ($updateItems.Count -gt 0) {
            Write-SRLogLine ('Applying updates pause (' + $updateItems.Count + ' item(s))...') 'Cyan'
            if ($hasSysLib) {
                try {
                    $res = @(Invoke-SRPrepSystemApply -Items $updateItems -Settings $Settings -BackupDir $backupDir -DryRun:$DryRun -Log $LogBlock | ForEach-Object { $_ })
                    foreach ($r in $res) { [void]$appliedItems.Add($r) }
                }
                catch {
                    Write-SRLogLine ('Error applying updates pause: ' + $_.Exception.Message) 'Red'
                    foreach ($it in $updateItems) {
                        $failedItem = $it.PSObject.Copy()
                        $failedItem.status = 'FAILED'
                        $failedItem.detail = $_.Exception.Message
                        [void]$appliedItems.Add($failedItem)
                    }
                }
            }
            else {
                Write-SRLogLine 'lib\Prep.System.ps1 is missing; updates changes skipped.' 'Yellow'
            }
        }

        # Print applied results
        Write-SRLogLine ''
        Write-SRLogLine '  APPLIED RESULTS:' 'White'
        foreach ($it in $appliedItems) {
            $tag = ('[' + [string]$it.status + ']').PadRight(9)
            $msg = [string]$it.title
            if ($it.status -eq 'FAILED' -and [string]$it.detail -ne '') {
                $msg += ': ' + [string]$it.detail
            }
            elseif ([string]$it.target -ne '') {
                $msg += ': ' + [string]$it.target
            }
            Write-SRLogLine ('  ' + $tag + ' ' + $msg) (Get-SRPrepColor $it.status)
        }
    }

    # -----------------------------------------------------------------------------------------
    # Save Results (prep.json and prep.log)
    # -----------------------------------------------------------------------------------------
    $manualItems = @($filteredPlan | Where-Object { [string]$_.status -eq 'MANUAL' })

    $prepJsonPath = Join-Path $runDir 'prep.json'
    $prepLogPath = Join-Path $runDir 'prep.log'

    $prepMeta = [ordered]@{
        tool_version = $ToolVersion
        computer     = [string]$env:COMPUTERNAME
        user         = [string][Security.Principal.WindowsIdentity]::GetCurrent().Name
        elevated     = [bool]$isAdmin
        role         = [string]$Role
        started      = [string]$startedAt.ToString('o')
        finished     = [string][System.DateTimeOffset]::Now.ToString('o')
        dry_run      = [bool]$DryRun
        plan_only    = [bool]$PlanOnly
    }

    $prepObj = [ordered]@{
        meta     = $prepMeta
        settings = $Settings
        plan     = $filteredPlan.ToArray()
        applied  = $appliedItems.ToArray()
        manual   = $manualItems
    }

    $asciiJson = ConvertTo-SRAsciiJson (ConvertTo-Json $prepObj -Depth 10)
    Write-SRFile -Path $prepJsonPath -Text $asciiJson

    $logText = ($script:LogLines -join "`r`n") + "`r`n"
    Write-SRFile -Path $prepLogPath -Text $logText

    # -----------------------------------------------------------------------------------------
    # Upload
    # -----------------------------------------------------------------------------------------
    $uploadLib = Join-Path (Join-Path $Root 'lib') 'Upload.ps1'
    if (-not $NoUpload -and (Test-Path -LiteralPath $uploadLib)) {
        try {
            . $uploadLib
            $up = Send-SRResults -RunDir $runDir -Kind 'prep' -Root $Root -Log $LogBlock
            if ($null -ne $up) {
                if ($up.ok) { Write-SRLogLine ('  Uploaded: ' + [string]$up.url) 'Green' }
                elseif ([string]$up.error -eq 'upload not set up') { Write-SRLogLine '  Not uploaded: run Setup-Upload.cmd once on this PC to send results online.' 'DarkGray' }
                else { Write-SRLogLine ('  Not uploaded: ' + [string]$up.error) 'Yellow' }
            }
        }
        catch {
            Write-SRLogLine ('  Upload error: ' + $_.Exception.Message) 'Yellow'
        }
    }

    # -----------------------------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------------------------
    Write-SRLogLine ''
    Write-SRLogLine '--------------------------------------------------------------------------' 'Cyan'
    Write-SRLogLine '  SUMMARY' 'Cyan'
    Write-SRLogLine '--------------------------------------------------------------------------' 'Cyan'

    $doneCount = @($appliedItems | Where-Object { [string]$_.status -eq 'DONE' }).Count
    $failedCount = @($appliedItems | Where-Object { [string]$_.status -eq 'FAILED' }).Count
    $manualCount = $manualItems.Count

    $appliedIds = @($appliedItems | ForEach-Object { [string]$_.id })
    $skippedPlanCount = @($filteredPlan | Where-Object { [string]$_.status -eq 'CHANGE' -and $appliedIds -notcontains [string]$_.id -and -not ($null -ne $editionItem -and [string]$_.id -eq 'sys_edition') }).Count
    $skippedApplyCount = @($appliedItems | Where-Object { [string]$_.status -eq 'SKIPPED' }).Count
    $skippedCount = $skippedPlanCount + $skippedApplyCount

    Write-SRLogLine ('  Counts: ' + $doneCount + ' DONE, ' + $failedCount + ' FAILED, ' + $skippedCount + ' SKIPPED, ' + $manualCount + ' MANUAL') 'White'

    # List FAILED with details
    $failedItems = @($appliedItems | Where-Object { [string]$_.status -eq 'FAILED' })
    if ($failedItems.Count -gt 0) {
        Write-SRLogLine ''
        Write-SRLogLine '  FAILED ITEMS:' 'Red'
        foreach ($f in $failedItems) {
            $msg = [string]$f.title
            if ([string]$f.detail -ne '') { $msg += ': ' + [string]$f.detail }
            Write-SRLogLine ('   [FAIL] ' + $msg) 'Red'
        }
    }

    # MANUAL checklist
    if ($manualItems.Count -gt 0) {
        Write-SRLogLine ''
        Write-SRLogLine '  MANUAL ACTION REQUIRED:' 'Yellow'
        foreach ($m in $manualItems) {
            $msg = [string]$m.title
            if ([string]$m.detail -ne '') { $msg += ' - ' + [string]$m.detail }
            Write-SRLogLine ('   [ ] ' + $msg) 'Yellow'
        }
    }

    # Edition switch (runs last in place of normal restart prompt)
    $editionLaunched = $false
    if ($null -ne $editionItem) {
        Write-SRLogLine 'Starting Windows edition switch...' 'Yellow'
        if ($hasSysLib) {
            try {
                $editionResult = Invoke-SRPrepEditionSwitch -Item $editionItem -BackupDir $backupDir -DryRun:$DryRun -Log $LogBlock
                if ($null -ne $editionResult) {
                    [void]$appliedItems.Add($editionResult)
                    $tag = ('[' + [string]$editionResult.status + ']').PadRight(9)
                    $resMsg = [string]$editionResult.title
                    if ([string]$editionResult.detail -ne '') { $resMsg += ': ' + [string]$editionResult.detail }
                    Write-SRLogLine ('  ' + $tag + ' ' + $resMsg) (Get-SRPrepColor $editionResult.status)
                    if ([string]$editionResult.status -eq 'DONE') { $editionLaunched = $true }
                }
            }
            catch {
                Write-SRLogLine ('Error during edition switch: ' + $_.Exception.Message) 'Red'
            }
        }
    }

    # -----------------------------------------------------------------------------------------
    # Activation check (Windows may be unactivated after the edition switch)
    # -----------------------------------------------------------------------------------------
    if (-not $SkipActivation -and -not $DryRun -and -not $PlanOnly -and -not $editionLaunched) {
        $windowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
        $lic = Get-CimInstance SoftwareLicensingProduct `
               -Filter "ApplicationID='$windowsAppId' AND PartialProductKey IS NOT NULL" `
               -ErrorAction SilentlyContinue

        if (-not ($lic | Where-Object { $_.LicenseStatus -eq 1 })) {
            Write-SRLogLine ''
            Write-SRLogLine '  Windows is not activated. Launching activation...' 'Yellow'
            try {
                Add-Type -AssemblyName System.Windows.Forms
                if (-not ('SRWin32' -as [type])) {
                    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class SRWin32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
                }

                $before = (Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -ExpandProperty Id)

                # MAS fetches and runs from get.activated.win; it spawns its own elevated CMD window.
                Start-Process powershell -ArgumentList '-NoExit','-Command','irm https://get.activated.win | iex' | Out-Null

                $newProc = $null
                $deadline = (Get-Date).AddSeconds(30)
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Milliseconds 500
                    $newProc = Get-Process |
                        Where-Object { $_.MainWindowHandle -ne 0 -and $before -notcontains $_.Id -and
                                       ($_.ProcessName -in @('cmd','conhost','powershell','WindowsTerminal','OpenConsole')) } |
                        Select-Object -First 1
                    if ($newProc) { break }
                }

                if ($newProc) {
                    Start-Sleep -Seconds 4   # let MAS render its menu
                    $hwnd = $newProc.MainWindowHandle
                    [SRWin32]::ShowWindow($hwnd, 9) | Out-Null
                    [SRWin32]::SetForegroundWindow($hwnd) | Out-Null
                    Start-Sleep -Milliseconds 700
                    [System.Windows.Forms.SendKeys]::SendWait('1')
                    Write-SRLogLine '  Activation window opened; sent key "1".' 'Cyan'
                }
                else {
                    Write-SRLogLine '  Could not detect the activation window; finish it manually.' 'Yellow'
                }
            }
            catch {
                Write-SRLogLine ('  Activation launch failed: ' + $_.Exception.Message) 'Red'
            }
        }
        else {
            Write-SRLogLine '  Windows is activated.' 'Green'
        }
    }

    # Restart check
    $rebootNeeded = $false
    if (@($appliedItems | Where-Object { [bool]$_.needs_reboot -eq $true }).Count -gt 0) {
        $rebootNeeded = $true
    }
    if (@($filteredPlan | Where-Object { ([string]$_.section).ToLowerInvariant() -eq 'reboot' -and [string]$_.status -eq 'MANUAL' }).Count -gt 0) {
        $rebootNeeded = $true
    }
    if ($null -ne $editionItem) {
        $rebootNeeded = $true
    }

    if ($editionLaunched) {
        # changepk may still be upgrading in its own window: never restart from here.
        Write-SRLogLine ''
        Write-SRLogLine '  Follow the Windows edition window. Windows restarts by itself when it is done.' 'Yellow'
        Write-SRLogLine '  Do not restart the PC yourself while it is running.' 'Yellow'
        Write-SRLogLine '  After the restart, run Run-Prep.cmd again to switch to English.' 'Yellow'
    }
    elseif ($rebootNeeded) {
        Write-SRLogLine ''
        Write-SRLogLine '  Restart needed.' 'Yellow'
        if (-not $DryRun -and -not $PlanOnly) {
            $ans = ''
            try { $ans = Read-Host 'Restart now? [y/N]' } catch { $ans = 'n' }
            $ans = ([string]$ans).Trim().ToLowerInvariant()
            if ($ans -eq 'y' -or $ans -eq 'yes') {
                Restart-Computer
            }
        }
    }

    Write-SRLogLine ''
    Write-SRLogLine 'Next: run Run-ShowReady.cmd (prod PC) or Run-Observer.cmd (observer PCs).' 'Cyan'

    # Update log file with final summary lines
    $finalLogText = ($script:LogLines -join "`r`n") + "`r`n"
    Write-SRFile -Path $prepLogPath -Text $finalLogText

    Wait-Close -YesOption $Yes
    exit 0
}
catch {
    Write-SRLogLine ('Prep encountered an unexpected error: ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber + ' (' + $_.ScriptStackTrace + ')') 'Red'
    try {
        if (-not (Test-Path -LiteralPath $runDir)) {
            [void][System.IO.Directory]::CreateDirectory($runDir)
        }
        $prepLogPath = Join-Path $runDir 'prep.log'
        $errLog = ($script:LogLines -join "`r`n") + "`r`n"
        Write-SRFile -Path $prepLogPath -Text $errLog
    }
    catch { }
    Wait-Close -YesOption $Yes
    exit 1
}