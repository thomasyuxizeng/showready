# Test-Prep.ps1 - test suite for ShowReady Prep orchestrator
# Windows PowerShell 5.1 and pwsh compatible. Pure ASCII source. Never throws unhandled.

[CmdletBinding()]
param(
    [string]$TargetPowerShell = ''
)

$ErrorActionPreference = 'Stop'
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptRoot)) { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$KitRoot = Split-Path -Parent $ScriptRoot
if ([string]::IsNullOrEmpty($KitRoot)) { $KitRoot = (Get-Location).Path }

Write-Host ('[Test-Prep] Kit root: ' + $KitRoot) -ForegroundColor Cyan

function Invoke-PrepProc {
    param(
        [string]$PsExe,
        [string]$PrepFile,
        [string[]]$ArgumentList
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PsExe
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PrepFile`" " + ($ArgumentList -join ' ')
    $psi.Arguments = $argLine
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)

    try {
        $proc.StandardInput.WriteLine('')
        $proc.StandardInput.Flush()
        $proc.StandardInput.Close()
    }
    catch { }

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $exited = $proc.WaitForExit(30000)
    if (-not $exited) {
        try { $proc.Kill() } catch { }
        throw ("Process timed out after 30 seconds: " + $argLine)
    }

    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Get-ParsedJsonArray {
    param([string]$Path)
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $parsed = ConvertFrom-Json $raw
    if ($null -eq $parsed) { return @() }
    if ($parsed -is [System.Array]) { return $parsed }
    return @($parsed)
}

# The real libs return their arrays as ',$arr'. If Prep.ps1 forgets '| ForEach-Object { $_ }' on a
# call, a whole plan or result list arrives as ONE nested array item. Fail on any such item.
function Assert-FlatItems {
    param($Items, [string]$Label)
    foreach ($x in $Items) {
        if ($x -is [System.Array]) {
            throw ($Label + ': an item is a nested array (missing | ForEach-Object { $_ } unroll in Prep.ps1?)')
        }
    }
}

function Run-SuiteOnEngine {
    param([string]$EngineExe)

    Write-Host ("`n[Test-Prep] Running test suite using: " + $EngineExe) -ForegroundColor Cyan

    # Record files in real kit results before running
    $realResultsDir = Join-Path $KitRoot 'results'
    $realFilesBefore = @()
    if (Test-Path -LiteralPath $realResultsDir) {
        $realFilesBefore = @(Get-ChildItem -LiteralPath $realResultsDir -Recurse | ForEach-Object { $_.FullName })
    }

    # Setup isolated temp directory
    $tempDir = Join-Path $env:TEMP ('sr-prep-test-' + [guid]::NewGuid().ToString('N'))
    $tempLib = Join-Path $tempDir 'lib'
    [void][System.IO.Directory]::CreateDirectory($tempLib)

    try {
        # Copy Prep.ps1 and prep-config.json
        Copy-Item -LiteralPath (Join-Path $KitRoot 'Prep.ps1') -Destination (Join-Path $tempDir 'Prep.ps1') -Force
        Copy-Item -LiteralPath (Join-Path $KitRoot 'prep-config.json') -Destination (Join-Path $tempDir 'prep-config.json') -Force

        # Create stub lib\Prep.System.ps1
        $stubSysContent = @'
function Get-SRPrepSystemPlan {
    param($Settings, [string]$Role, $Log)
    if ($null -ne $Log) { & $Log "Stub System: Plan for $Role" }
    return ,@(
        [pscustomobject]@{
            id = 'sys_language'
            section = 'language'
            title = 'Display language'
            status = 'CHANGE'
            current = 'ko-KR'
            target = 'en-US'
            detail = 'Install English pack'
            risk = 'low'
            needs_reboot = $false
            needs_admin = $true
            default_apply = $true
            commands = @('Install-Language en-US')
            undo = @{ lang = 'ko-KR' }
        },
        [pscustomobject]@{
            id = 'sys_drivers'
            section = 'drivers'
            title = 'NVIDIA GPU driver'
            status = 'CHANGE'
            current = '550.00'
            target = '570.00'
            detail = 'Update GPU driver'
            risk = 'low'
            needs_reboot = $false
            needs_admin = $true
            default_apply = $true
            commands = @('wuauclt /detectnow')
            undo = @{ driver = '550.00' }
        },
        [pscustomobject]@{
            id = 'sys_disk'
            section = 'disk'
            title = 'Free disk space'
            status = 'OK'
            current = '120 GB'
            target = '>= 50 GB'
            detail = 'Sufficient space'
            risk = 'low'
            needs_reboot = $false
            needs_admin = $false
            default_apply = $false
            commands = @()
            undo = $null
        },
        [pscustomobject]@{
            id = 'sys_reboot'
            section = 'reboot'
            title = 'Pending reboot'
            status = 'OK'
            current = 'None'
            target = 'None'
            detail = 'No reboot pending'
            risk = 'low'
            needs_reboot = $false
            needs_admin = $false
            default_apply = $false
            commands = @()
            undo = $null
        },
        [pscustomobject]@{
            id = 'sys_updates'
            section = 'updates'
            title = 'Windows Update pause'
            status = 'CHANGE'
            current = 'active'
            target = 'paused 7 days'
            detail = 'Pause automatic updates'
            risk = 'low'
            needs_reboot = $false
            needs_admin = $true
            default_apply = $true
            commands = @('reg add HKLM\...\Settings /v PauseFeatureUpdatesStartTime')
            undo = @{ pause = $false }
        }
    )
}

function Invoke-SRPrepSystemApply {
    param($Items, $Settings, [string]$BackupDir, [switch]$DryRun, $Log)
    if ($null -ne $Log) { & $Log "Stub System: Apply $($Items.Count) item(s)" }
    $d = $BackupDir
    while ($null -ne $d -and -not (Test-Path -LiteralPath (Join-Path $d 'Prep.ps1'))) {
        $parent = Split-Path -Parent $d
        if ($parent -eq $d) { break }
        $d = $parent
    }
    $logPath = Join-Path $d 'call-log.json'
    $record = [ordered]@{
        function   = 'Invoke-SRPrepSystemApply'
        item_ids   = @($Items | ForEach-Object { [string]$_.id })
        sections   = @($Items | ForEach-Object { [string]$_.section })
        backup_dir = $BackupDir
        dry_run    = [bool]$DryRun
    }
    $list = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $logPath) {
        try {
            $parsed = ConvertFrom-Json ([System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::UTF8))
            foreach ($p in @($parsed)) { [void]$list.Add($p) }
        } catch { }
    }
    [void]$list.Add($record)
    [System.IO.File]::WriteAllText($logPath, (ConvertTo-Json $list -Depth 5), [System.Text.Encoding]::UTF8)

    if (Test-Path -LiteralPath $BackupDir) {
        $undoFile = Join-Path $BackupDir 'system-undo.json'
        [System.IO.File]::WriteAllText($undoFile, '{"undo": "system"}', [System.Text.Encoding]::UTF8)
    }

    $ret = @()
    foreach ($it in $Items) {
        $cp = $it.PSObject.Copy()
        $cp.status = 'DONE'
        $ret += $cp
    }
    return ,$ret
}

function Undo-SRPrepSystem {
    param([string]$BackupDir, [switch]$DryRun, $Log)
    if ($null -ne $Log) { & $Log "Stub System: Undo" }
    $d = $BackupDir
    while ($null -ne $d -and -not (Test-Path -LiteralPath (Join-Path $d 'Prep.ps1'))) {
        $parent = Split-Path -Parent $d
        if ($parent -eq $d) { break }
        $d = $parent
    }
    $logPath = Join-Path $d 'call-log.json'
    $record = [ordered]@{
        function   = 'Undo-SRPrepSystem'
        backup_dir = $BackupDir
        dry_run    = [bool]$DryRun
    }
    $list = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $logPath) {
        try {
            $parsed = ConvertFrom-Json ([System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::UTF8))
            foreach ($p in @($parsed)) { [void]$list.Add($p) }
        } catch { }
    }
    [void]$list.Add($record)
    [System.IO.File]::WriteAllText($logPath, (ConvertTo-Json $list -Depth 5), [System.Text.Encoding]::UTF8)

    return ,@(
        [pscustomobject]@{
            id     = 'sys_language'
            title  = 'Display language restore'
            status = 'DONE'
            detail = 'Restored ko-KR'
        }
    )
}
'@
        [System.IO.File]::WriteAllText((Join-Path $tempLib 'Prep.System.ps1'), $stubSysContent, [System.Text.Encoding]::UTF8)

        # Create stub lib\Prep.Tune.ps1
        $stubTuneContent = @'
function Get-SRPrepTunePlan {
    param($Settings, [string]$Role, $Log)
    if ($null -ne $Log) { & $Log "Stub Tune: Plan for $Role" }
    return ,@(
        [pscustomobject]@{
            id = 'tune_power'
            section = 'power'
            title = 'Power scheme'
            status = 'CHANGE'
            current = 'Balanced'
            target = 'Ultimate Performance'
            detail = 'Set Ultimate Performance'
            risk = 'low'
            needs_reboot = $false
            needs_admin = $true
            default_apply = $true
            commands = @('powercfg /setactive ...')
            undo = @{ scheme = 'Balanced' }
        },
        [pscustomobject]@{
            id = 'tune_startup:Discord'
            section = 'startup'
            title = 'Startup Discord'
            status = 'CHANGE'
            current = 'enabled'
            target = 'disabled'
            detail = 'Disable startup Discord'
            risk = 'low'
            needs_reboot = $false
            needs_admin = $false
            default_apply = $true
            commands = @('reg add ...')
            undo = @{ app = 'Discord' }
        },
        [pscustomobject]@{
            id = 'tune_background:Discord'
            section = 'background'
            title = 'Background Discord'
            status = 'CHANGE'
            current = 'running'
            target = 'stop'
            detail = 'Close Discord process'
            risk = 'medium'
            needs_reboot = $false
            needs_admin = $false
            default_apply = $false
            commands = @('Stop-Process -Name Discord')
            undo = $null
        },
        [pscustomobject]@{
            id = 'tune_background:Chrome'
            section = 'background'
            title = 'Background Chrome'
            status = 'CHANGE'
            current = 'running'
            target = 'stop'
            detail = 'Close Google Chrome'
            risk = 'low'
            needs_reboot = $false
            needs_admin = $false
            default_apply = $true
            commands = @('Stop-Process -Name chrome')
            undo = $null
        },
        [pscustomobject]@{
            id = 'tune_network'
            section = 'network'
            title = 'Wi-Fi adapter'
            status = 'OK'
            current = 'disabled'
            target = 'disabled'
            detail = 'Wi-Fi is disabled'
            risk = 'low'
            needs_reboot = $false
            needs_admin = $true
            default_apply = $false
            commands = @()
            undo = $null
        },
        [pscustomobject]@{
            id = 'tune_capture'
            section = 'capture'
            title = 'Game DVR'
            status = 'OK'
            current = 'disabled'
            target = 'disabled'
            detail = 'Game DVR disabled'
            risk = 'low'
            needs_reboot = $false
            needs_admin = $true
            default_apply = $false
            commands = @()
            undo = $null
        },
        [pscustomobject]@{
            id = 'tune_notifications'
            section = 'notifications'
            title = 'Toast notifications'
            status = 'CHANGE'
            current = 'enabled'
            target = 'disabled'
            detail = 'Disable toasts'
            risk = 'low'
            needs_reboot = $false
            needs_admin = $false
            default_apply = $true
            commands = @('reg add ...')
            undo = @{ toasts = 1 }
        }
    )
}

function Invoke-SRPrepTuneApply {
    param($Items, $Settings, [string]$BackupDir, [switch]$DryRun, $Log)
    if ($null -ne $Log) { & $Log "Stub Tune: Apply $($Items.Count) item(s)" }
    $d = $BackupDir
    while ($null -ne $d -and -not (Test-Path -LiteralPath (Join-Path $d 'Prep.ps1'))) {
        $parent = Split-Path -Parent $d
        if ($parent -eq $d) { break }
        $d = $parent
    }
    $logPath = Join-Path $d 'call-log.json'
    $record = [ordered]@{
        function   = 'Invoke-SRPrepTuneApply'
        item_ids   = @($Items | ForEach-Object { [string]$_.id })
        sections   = @($Items | ForEach-Object { [string]$_.section })
        backup_dir = $BackupDir
        dry_run    = [bool]$DryRun
    }
    $list = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $logPath) {
        try {
            $parsed = ConvertFrom-Json ([System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::UTF8))
            foreach ($p in @($parsed)) { [void]$list.Add($p) }
        } catch { }
    }
    [void]$list.Add($record)
    [System.IO.File]::WriteAllText($logPath, (ConvertTo-Json $list -Depth 5), [System.Text.Encoding]::UTF8)

    if (Test-Path -LiteralPath $BackupDir) {
        $undoFile = Join-Path $BackupDir 'tune-undo.json'
        [System.IO.File]::WriteAllText($undoFile, '{"undo": "tune"}', [System.Text.Encoding]::UTF8)
    }

    $ret = @()
    foreach ($it in $Items) {
        $cp = $it.PSObject.Copy()
        $cp.status = 'DONE'
        $ret += $cp
    }
    return ,$ret
}

function Undo-SRPrepTune {
    param([string]$BackupDir, [switch]$DryRun, $Log)
    if ($null -ne $Log) { & $Log "Stub Tune: Undo" }
    $d = $BackupDir
    while ($null -ne $d -and -not (Test-Path -LiteralPath (Join-Path $d 'Prep.ps1'))) {
        $parent = Split-Path -Parent $d
        if ($parent -eq $d) { break }
        $d = $parent
    }
    $logPath = Join-Path $d 'call-log.json'
    $record = [ordered]@{
        function   = 'Undo-SRPrepTune'
        backup_dir = $BackupDir
        dry_run    = [bool]$DryRun
    }
    $list = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $logPath) {
        try {
            $parsed = ConvertFrom-Json ([System.IO.File]::ReadAllText($logPath, [System.Text.Encoding]::UTF8))
            foreach ($p in @($parsed)) { [void]$list.Add($p) }
        } catch { }
    }
    [void]$list.Add($record)
    [System.IO.File]::WriteAllText($logPath, (ConvertTo-Json $list -Depth 5), [System.Text.Encoding]::UTF8)

    return ,@(
        [pscustomobject]@{
            id     = 'tune_power'
            title  = 'Power scheme restore'
            status = 'DONE'
            detail = 'Restored Balanced'
        }
    )
}
'@
        [System.IO.File]::WriteAllText((Join-Path $tempLib 'Prep.Tune.ps1'), $stubTuneContent, [System.Text.Encoding]::UTF8)

        # Create stub lib\Upload.ps1
        $stubUploadContent = @'
function Send-SRResults {
    param([string]$RunDir, [string]$Kind, [string]$Root, $Log)
    return [pscustomobject]@{
        ok    = $true
        url   = 'https://github.com/mock/showready-results/runs/test'
        files = @('prep.json')
        error = $null
    }
}
function Send-SRPendingResults {
    param([string]$Root, $Log)
    return [pscustomobject]@{ ok = $true }
}
'@
        [System.IO.File]::WriteAllText((Join-Path $tempLib 'Upload.ps1'), $stubUploadContent, [System.Text.Encoding]::UTF8)

        $tempPrepScript = Join-Path $tempDir 'Prep.ps1'
        $callLogPath = Join-Path $tempDir 'call-log.json'

        # -------------------------------------------------------------------------------------
        # TEST (a): -PlanOnly -Role prod -NoElevate -NoUpload
        # -------------------------------------------------------------------------------------
        Write-Host '  Test (a): -PlanOnly -Role prod -NoElevate -NoUpload...' -NoNewline
        $resA = Invoke-PrepProc -PsExe $EngineExe -PrepFile $tempPrepScript -ArgumentList @('-PlanOnly', '-Role', 'prod', '-NoElevate', '-NoUpload')
        if ($resA.ExitCode -ne 0) {
            Write-Host (' FAILED (exit code ' + $resA.ExitCode + ')') -ForegroundColor Red
            Write-Host $resA.StdErr
            Write-Host $resA.StdOut
            exit 1
        }

        # Check results folder
        $tempResults = Join-Path $tempDir 'results'
        if (-not (Test-Path -LiteralPath $tempResults)) { throw "Results folder was not created in $tempDir" }
        $prepFoldersA = @(Get-ChildItem -LiteralPath $tempResults -Directory -Filter '*-prep' | Sort-Object Name -Descending)
        if ($prepFoldersA.Count -lt 1) { throw "No *-prep folder created in Test (a)" }
        $folderA = $prepFoldersA[0].FullName
        $jsonPathA = Join-Path $folderA 'prep.json'
        $logPathA = Join-Path $folderA 'prep.log'
        if (-not (Test-Path -LiteralPath $jsonPathA)) { throw "prep.json missing in $folderA" }
        if (-not (Test-Path -LiteralPath $logPathA)) { throw "prep.log missing in $folderA" }

        $jsonA = ConvertFrom-Json ([System.IO.File]::ReadAllText($jsonPathA, [System.Text.Encoding]::UTF8))
        if (-not $jsonA.meta.plan_only) { throw "Test (a): meta.plan_only is not true" }
        if ($jsonA.meta.role -ne 'prod') { throw "Test (a): meta.role is not prod" }
        if ($jsonA.meta.tool_version -ne '1.3.3-prep') { throw "Test (a): meta.tool_version is not 1.3.3-prep" }
        if ($jsonA.plan.Count -ne 12) { throw ("Test (a): plan count was " + $jsonA.plan.Count + ", expected 12") }
        if ($jsonA.applied.Count -ne 0) { throw ("Test (a): applied count was " + $jsonA.applied.Count + ", expected 0") }
        if (Test-Path -LiteralPath $callLogPath) { throw "Test (a): apply stubs should not have been called" }

        Write-Host ' PASSED' -ForegroundColor Green

        # -------------------------------------------------------------------------------------
        # TEST (b): -DryRun -Yes -Role observer -NoElevate -NoUpload
        # -------------------------------------------------------------------------------------
        Write-Host '  Test (b): -DryRun -Yes -Role observer -NoElevate -NoUpload...' -NoNewline
        $resB = Invoke-PrepProc -PsExe $EngineExe -PrepFile $tempPrepScript -ArgumentList @('-DryRun', '-Yes', '-Role', 'observer', '-NoElevate', '-NoUpload')
        if ($resB.ExitCode -ne 0) {
            Write-Host (' FAILED (exit code ' + $resB.ExitCode + ')') -ForegroundColor Red
            Write-Host $resB.StdErr
            Write-Host $resB.StdOut
            exit 1
        }

        $prepFoldersB = @(Get-ChildItem -LiteralPath $tempResults -Directory -Filter '*-prep' | Sort-Object Name -Descending)
        if ($prepFoldersB.Count -lt 2) { throw "Second *-prep folder not created for Test (b)" }
        $folderB = $prepFoldersB[0].FullName
        $backupDirB = Join-Path $folderB 'backup'
        if (-not (Test-Path -LiteralPath $backupDirB)) { throw "backup folder missing in $folderB" }

        $jsonPathB = Join-Path $folderB 'prep.json'
        $jsonB = ConvertFrom-Json ([System.IO.File]::ReadAllText($jsonPathB, [System.Text.Encoding]::UTF8))
        if (-not $jsonB.meta.dry_run) { throw "Test (b): meta.dry_run is not true" }
        if ($jsonB.meta.plan_only) { throw "Test (b): meta.plan_only should be false" }
        if ($jsonB.meta.role -ne 'observer') { throw "Test (b): meta.role is not observer" }
        if ($jsonB.applied.Count -eq 0) { throw "Test (b): applied items should not be empty" }
        Assert-FlatItems -Items $jsonB.applied -Label 'Test (b): applied'
        $appliedIdsB = @($jsonB.applied | ForEach-Object { [string]$_.id }) -join ','
        $expectedIdsB = 'sys_language,sys_drivers,tune_power,tune_startup:Discord,tune_background:Chrome,tune_notifications,sys_updates'
        if ($appliedIdsB -ne $expectedIdsB) { throw ("Test (b): applied ids were '$appliedIdsB', expected '$expectedIdsB'") }

        # Verify that apply calls occurred in the exact phase order:
        # Phase 1: language (Invoke-SRPrepSystemApply)
        # Phase 2: drivers (Invoke-SRPrepSystemApply)
        # Phase 3: power, startup, background, notifications (Invoke-SRPrepTuneApply)
        # Phase 4: updates (Invoke-SRPrepSystemApply)
        if (-not (Test-Path -LiteralPath $callLogPath)) { throw "Test (b): call-log.json was not created" }
        $calls = Get-ParsedJsonArray -Path $callLogPath
        if ($calls.Count -ne 4) { throw ("Test (b): expected 4 apply calls, found " + $calls.Count) }

        # Call 1: Language
        if ($calls[0].function -ne 'Invoke-SRPrepSystemApply') { throw "Call 0 was not Invoke-SRPrepSystemApply" }
        if ((@($calls[0].sections) -join ',') -ne 'language') { throw ("Call 0 sections was " + ($calls[0].sections -join ',') + ", expected language") }
        if (-not $calls[0].dry_run) { throw "Call 0 dry_run was not true" }

        # Call 2: Drivers
        if ($calls[1].function -ne 'Invoke-SRPrepSystemApply') { throw "Call 1 was not Invoke-SRPrepSystemApply" }
        if ((@($calls[1].sections) -join ',') -ne 'drivers') { throw ("Call 1 sections was " + ($calls[1].sections -join ',') + ", expected drivers") }
        if (-not $calls[1].dry_run) { throw "Call 1 dry_run was not true" }

        # Call 3: Tune (power, startup, background, notifications)
        if ($calls[2].function -ne 'Invoke-SRPrepTuneApply') { throw "Call 2 was not Invoke-SRPrepTuneApply" }
        $tuneSecs = @($calls[2].sections) -join ','
        if ($tuneSecs -ne 'power,startup,background,notifications') {
            throw ("Call 2 sections was '$tuneSecs', expected 'power,startup,background,notifications'")
        }
        # Discord background has default_apply false, so only Chrome was selected
        if (@($calls[2].item_ids) -contains 'tune_background:Discord') { throw "tune_background:Discord should not have been selected with -Yes" }
        if (@($calls[2].item_ids) -notcontains 'tune_background:Chrome') { throw "tune_background:Chrome should have been selected" }
        if (-not $calls[2].dry_run) { throw "Call 2 dry_run was not true" }

        # Call 4: Updates
        if ($calls[3].function -ne 'Invoke-SRPrepSystemApply') { throw "Call 3 was not Invoke-SRPrepSystemApply" }
        if ((@($calls[3].sections) -join ',') -ne 'updates') { throw ("Call 3 sections was " + ($calls[3].sections -join ',') + ", expected updates") }
        if (-not $calls[3].dry_run) { throw "Call 3 dry_run was not true" }

        Write-Host ' PASSED' -ForegroundColor Green

        # -------------------------------------------------------------------------------------
        # TEST (c): -Undo latest -DryRun -Yes -NoElevate -NoUpload
        # -------------------------------------------------------------------------------------
        Write-Host '  Test (c): -Undo latest -DryRun -Yes -NoElevate -NoUpload...' -NoNewline
        $resC = Invoke-PrepProc -PsExe $EngineExe -PrepFile $tempPrepScript -ArgumentList @('-Undo', 'latest', '-DryRun', '-Yes', '-NoElevate', '-NoUpload')
        if ($resC.ExitCode -ne 0) {
            Write-Host (' FAILED (exit code ' + $resC.ExitCode + ')') -ForegroundColor Red
            Write-Host $resC.StdErr
            Write-Host $resC.StdOut
            exit 1
        }

        $undoFolders = @(Get-ChildItem -LiteralPath $tempResults -Directory -Filter '*-prep-undo' | Sort-Object Name -Descending)
        if ($undoFolders.Count -lt 1) { throw "No *-prep-undo folder created in Test (c)" }
        $folderC = $undoFolders[0].FullName
        $undoJsonPath = Join-Path $folderC 'undo.json'
        if (-not (Test-Path -LiteralPath $undoJsonPath)) { throw "undo.json missing in $folderC" }

        $jsonC = ConvertFrom-Json ([System.IO.File]::ReadAllText($undoJsonPath, [System.Text.Encoding]::UTF8))
        if (-not $jsonC.meta.dry_run) { throw "Test (c): meta.dry_run is not true" }
        if ($jsonC.meta.backup_dir -ne $backupDirB) { throw ("Test (c): backup_dir was " + $jsonC.meta.backup_dir + ", expected " + $backupDirB) }
        Assert-FlatItems -Items $jsonC.tune -Label 'Test (c): undo tune'
        Assert-FlatItems -Items $jsonC.system -Label 'Test (c): undo system'
        $undoTuneIds = @($jsonC.tune | ForEach-Object { [string]$_.id }) -join ','
        $undoSysIds = @($jsonC.system | ForEach-Object { [string]$_.id }) -join ','
        if ($undoTuneIds -ne 'tune_power') { throw ("Test (c): undo tune ids were '$undoTuneIds', expected 'tune_power'") }
        if ($undoSysIds -ne 'sys_language') { throw ("Test (c): undo system ids were '$undoSysIds', expected 'sys_language'") }

        # Verify calls 4 and 5 in call-log.json: Undo-SRPrepTune then Undo-SRPrepSystem
        $callsAfterUndo = Get-ParsedJsonArray -Path $callLogPath
        if ($callsAfterUndo.Count -ne 6) { throw ("Test (c): expected 6 calls total, found " + $callsAfterUndo.Count) }

        if ($callsAfterUndo[4].function -ne 'Undo-SRPrepTune') { throw "Call 4 was not Undo-SRPrepTune" }
        if ($callsAfterUndo[4].backup_dir -ne $backupDirB) { throw "Call 4 backup_dir mismatch" }
        if (-not $callsAfterUndo[4].dry_run) { throw "Call 4 dry_run was not true" }

        if ($callsAfterUndo[5].function -ne 'Undo-SRPrepSystem') { throw "Call 5 was not Undo-SRPrepSystem" }
        if ($callsAfterUndo[5].backup_dir -ne $backupDirB) { throw "Call 5 backup_dir mismatch" }
        if (-not $callsAfterUndo[5].dry_run) { throw "Call 5 dry_run was not true" }

        Write-Host ' PASSED' -ForegroundColor Green

        # -------------------------------------------------------------------------------------
        # TEST (d): -Only power,startup -PlanOnly -Role prod -NoElevate -NoUpload
        # -------------------------------------------------------------------------------------
        Write-Host '  Test (d): -Only power,startup -PlanOnly -Role prod -NoElevate -NoUpload...' -NoNewline
        $resD = Invoke-PrepProc -PsExe $EngineExe -PrepFile $tempPrepScript -ArgumentList @('-Only', 'power,startup', '-PlanOnly', '-Role', 'prod', '-NoElevate', '-NoUpload')
        if ($resD.ExitCode -ne 0) {
            Write-Host (' FAILED (exit code ' + $resD.ExitCode + ')') -ForegroundColor Red
            Write-Host $resD.StdErr
            Write-Host $resD.StdOut
            exit 1
        }

        $prepFoldersD = @(Get-ChildItem -LiteralPath $tempResults -Directory -Filter '*-prep' | Sort-Object Name -Descending)
        $folderD = $prepFoldersD[0].FullName
        $jsonPathD = Join-Path $folderD 'prep.json'
        $jsonD = ConvertFrom-Json ([System.IO.File]::ReadAllText($jsonPathD, [System.Text.Encoding]::UTF8))

        if ($jsonD.plan.Count -eq 0) { throw "Test (d): filtered plan should not be empty" }
        foreach ($item in $jsonD.plan) {
            $s = [string]$item.section
            if ($s -ne 'power' -and $s -ne 'startup') {
                throw ("Test (d): unexpected section in -Only filtered plan: " + $s)
            }
        }
        Write-Host ' PASSED' -ForegroundColor Green

        # -------------------------------------------------------------------------------------
        # Verify isolation: Nothing outside tempDir was modified in <KIT ROOT>\results
        # -------------------------------------------------------------------------------------
        Write-Host '  Isolation check: ensuring kit results are unmodified...' -NoNewline
        $realFilesAfter = @()
        if (Test-Path -LiteralPath $realResultsDir) {
            $realFilesAfter = @(Get-ChildItem -LiteralPath $realResultsDir -Recurse | ForEach-Object { $_.FullName })
        }
        foreach ($f in $realFilesAfter) {
            if ($realFilesBefore -notcontains $f) {
                throw ("Isolation violation! A file was created in real kit results during temp test: " + $f)
            }
        }
        Write-Host ' PASSED' -ForegroundColor Green
    }
    finally {
        # Cleanup temp directory
        try {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }
}

# Run on specified engine or both
$engines = @()
if ($TargetPowerShell -ne '') {
    $engines += $TargetPowerShell
}
else {
    $ps5 = 'powershell.exe'
    $engines += $ps5

    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -ne $pwshCmd) {
        $engines += 'pwsh.exe'
    }
}

foreach ($eng in $engines) {
    Run-SuiteOnEngine -EngineExe $eng
}

# Check if real libs exist in <KIT ROOT>\lib
$realSys = Join-Path (Join-Path $KitRoot 'lib') 'Prep.System.ps1'
$realTune = Join-Path (Join-Path $KitRoot 'lib') 'Prep.Tune.ps1'
if ((Test-Path -LiteralPath $realSys) -and (Test-Path -LiteralPath $realTune)) {
    Write-Host "`n[Test-Prep] Real libs detected in lib\. Running real kit plan/dryrun verification..." -ForegroundColor Cyan
    $realPrepScript = Join-Path $KitRoot 'Prep.ps1'
    $realPlan = Invoke-PrepProc -PsExe 'powershell.exe' -PrepFile $realPrepScript -ArgumentList @('-PlanOnly', '-Role', 'prod', '-NoElevate', '-NoUpload')
    if ($realPlan.ExitCode -ne 0) {
        Write-Host ('Real kit -PlanOnly FAILED: exit code ' + $realPlan.ExitCode) -ForegroundColor Red
        Write-Host $realPlan.StdErr
        Write-Host $realPlan.StdOut
        exit 1
    }
    Write-Host '  Real kit -PlanOnly PASSED' -ForegroundColor Green

    $realDry = Invoke-PrepProc -PsExe 'powershell.exe' -PrepFile $realPrepScript -ArgumentList @('-DryRun', '-Yes', '-Role', 'observer', '-NoElevate', '-NoUpload')
    if ($realDry.ExitCode -ne 0) {
        Write-Host ('Real kit -DryRun FAILED: exit code ' + $realDry.ExitCode) -ForegroundColor Red
        Write-Host $realDry.StdErr
        Write-Host $realDry.StdOut
        exit 1
    }
    Write-Host '  Real kit -DryRun PASSED' -ForegroundColor Green
}
else {
    Write-Host "`n[Test-Prep] Note: Real lib\Prep.System.ps1 or lib\Prep.Tune.ps1 not present yet. Skipping real kit dryrun." -ForegroundColor Yellow
}

Write-Host "`nALL PREP ORCHESTRATOR TESTS PASSED" -ForegroundColor Green
exit 0
