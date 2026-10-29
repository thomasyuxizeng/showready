# ShowReady - tests\Test-PrepSystem.ps1
# Plain PowerShell assertions (no Pester) for lib\Prep.System.ps1
# Non-elevated, read-only tests.
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-PrepSystem.ps1
#       pwsh -NoProfile -File tests\Test-PrepSystem.ps1
# Exit code 0 = all assertions passed, 1 = at least one failed. Pure ASCII, works on Windows PowerShell 5.1 and pwsh.

$ErrorActionPreference = 'Continue'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $testsDir
$libPath = Join-Path $kitRoot 'lib\Prep.System.ps1'
$fixturesDir = Join-Path $kitRoot 'fixtures'

$script:nPass = 0
$script:nFail = 0

function Assert-That {
    param(
        [string]$Name,
        $Condition,
        [string]$Detail = ''
    )
    if ($Condition -eq $true) {
        $script:nPass++
        Write-Host ('  PASS  ' + $Name) -ForegroundColor Green
    } else {
        $script:nFail++
        $d = ''
        if ($Detail -ne '') { $d = '  -> ' + $Detail }
        Write-Host ('  FAIL  ' + $Name + $d) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host 'ShowReady Prep System tests' -ForegroundColor Cyan
Write-Host ('  PowerShell ' + $PSVersionTable.PSVersion.ToString()) -ForegroundColor DarkGray

# =============================================================================================
# 1. Dot-sourcing and pure ASCII check
# =============================================================================================
Write-Host '1: Dot-sourcing and code checks' -ForegroundColor Cyan
$dotOut = @(. $libPath)
Assert-That '1.1: Dot-sourcing Prep.System.ps1 emits no stdout output' ($dotOut.Count -eq 0) ('output count: ' + $dotOut.Count)
Assert-That '1.2: Get-SRPrepSystemPlan is defined' ($null -ne (Get-Command Get-SRPrepSystemPlan -CommandType Function -ErrorAction SilentlyContinue))
Assert-That '1.3: Invoke-SRPrepSystemApply is defined' ($null -ne (Get-Command Invoke-SRPrepSystemApply -CommandType Function -ErrorAction SilentlyContinue))
Assert-That '1.4: Undo-SRPrepSystem is defined' ($null -ne (Get-Command Undo-SRPrepSystem -CommandType Function -ErrorAction SilentlyContinue))
Assert-That '1.5: Test-SRPrepPerUserMismatch is defined' ($null -ne (Get-Command Test-SRPrepPerUserMismatch -CommandType Function -ErrorAction SilentlyContinue))

$src = [System.IO.File]::ReadAllText($libPath)
Assert-That '1.6: Prep.System.ps1 is pure ASCII' (-not [regex]::IsMatch($src, '[^\x00-\x7F]'))

# =============================================================================================
# 2. Helper unit tests: NVIDIA version converter, pause time, mismatch
# =============================================================================================
Write-Host '2: Helper unit tests' -ForegroundColor Cyan

# NVIDIA version tests from task specification:
# '32.0.15.7270' -> '572.70', '31.0.15.5244' -> '552.44', '32.0.16.1062' -> '610.62'
$nv1 = Convert-SRNvidiaDriverVersion '32.0.15.7270'
Assert-That '2.1: Convert-SRNvidiaDriverVersion 32.0.15.7270 -> 572.70' ($nv1 -eq '572.70') ("Got: $nv1")

$nv2 = Convert-SRNvidiaDriverVersion '31.0.15.5244'
Assert-That '2.2: Convert-SRNvidiaDriverVersion 31.0.15.5244 -> 552.44' ($nv2 -eq '552.44') ("Got: $nv2")

$nv3 = Convert-SRNvidiaDriverVersion '32.0.16.1062'
Assert-That '2.3: Convert-SRNvidiaDriverVersion 32.0.16.1062 -> 610.62' ($nv3 -eq '610.62') ("Got: $nv3")

$nvEmpty = Convert-SRNvidiaDriverVersion ''
Assert-That '2.4: Convert-SRNvidiaDriverVersion empty returns null' ($null -eq $nvEmpty)

# Pause-time formatting test
$testDt = [DateTime]::SpecifyKind([DateTime]'2026-10-16 14:00:00', [DateTimeKind]::Utc)
$pauseStr = Format-SRPauseTime $testDt
Assert-That '2.5: Format-SRPauseTime outputs exact yyyy-MM-ddTHH:mm:ssZ' ($pauseStr -eq '2026-10-16T14:00:00Z') ("Got: $pauseStr")

$parsedBack = [DateTime]::ParseExact($pauseStr, 'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
Assert-That '2.6: Pause-time round-trip parses successfully' ($parsedBack.ToUniversalTime() -eq $testDt)

# Mismatch helper returns a bool
$mismatchVal = Test-SRPrepPerUserMismatch
Assert-That '2.7: Test-SRPrepPerUserMismatch returns a boolean' ($mismatchVal -is [bool]) ("Got type: $($mismatchVal.GetType().FullName)")

# =============================================================================================
# 3. Plan with $null settings
# =============================================================================================
Write-Host '3: Get-SRPrepSystemPlan with $null settings' -ForegroundColor Cyan

$planLog = [System.Collections.Generic.List[string]]::new()
$logSb = { param($msg) $planLog.Add($msg) }

$planNull = Get-SRPrepSystemPlan -Settings $null -Role 'prod' -Log $logSb
Assert-That '3.1: Plan with $null settings returns an array' ($planNull -is [System.Array])
Assert-That '3.2: Plan contains items' ($planNull.Count -gt 0) ("Count: $($planNull.Count)")

$validSections = @('language', 'drivers', 'disk', 'updates', 'reboot', 'power', 'startup', 'background', 'network', 'capture', 'notifications')
$validStatuses = @('OK', 'CHANGE', 'MANUAL', 'INFO', 'ERROR')
$validRisks    = @('low', 'medium')

$schemaOk = $true
$statusOk = $true
$sectionOk = $true
$riskOk = $true
$typesOk = $true
$changeHasCmds = $true

$ids = [System.Collections.Generic.List[string]]::new()

foreach ($item in $planNull) {
    $ids.Add($item.id)

    # Check 13 schema fields
    $fields = @('id', 'section', 'title', 'status', 'current', 'target', 'detail', 'risk', 'needs_reboot', 'needs_admin', 'default_apply', 'commands', 'undo')
    foreach ($f in $fields) {
        if ($null -eq $item.PSObject.Properties[$f]) {
            $schemaOk = $false
        }
    }

    if ($validStatuses -notcontains $item.status) { $statusOk = $false }
    if ($validSections -notcontains $item.section) { $sectionOk = $false }
    if ($validRisks -notcontains $item.risk) { $riskOk = $false }
    if ($item.needs_reboot -isnot [bool] -or $item.needs_admin -isnot [bool] -or $item.default_apply -isnot [bool]) {
        $typesOk = $false
    }
    if ($item.status -eq 'CHANGE' -and (@($item.commands).Count -eq 0)) {
        $changeHasCmds = $false
    }
}

Assert-That '3.3: Every item has all 13 schema fields' $schemaOk
Assert-That '3.4: Every item has valid section' $sectionOk
Assert-That '3.5: Every item has valid plan status' $statusOk
Assert-That '3.6: Every item has valid risk' $riskOk
Assert-That '3.7: Boolean fields are true booleans' $typesOk
Assert-That '3.8: No item has status CHANGE without commands' $changeHasCmds

# Unique IDs
$uniqueIds = @($ids | Select-Object -Unique)
Assert-That '3.9: Item IDs are unique' ($ids.Count -eq $uniqueIds.Count) ("Total: $($ids.Count), Unique: $($uniqueIds.Count)")

# Expected core items presence
$itemIdsStr = $ids -join ', '
Assert-That '3.10: sys_admin item exists' ($ids -contains 'sys_admin') ("IDs: $itemIdsStr")
Assert-That '3.11: sys_language item exists' ($ids -contains 'sys_language')
Assert-That '3.12: sys_disk item exists' ($ids -contains 'sys_disk')
Assert-That '3.13: sys_reboot item exists' ($ids -contains 'sys_reboot')
Assert-That '3.14: sys_wu_pause item exists' ($ids -contains 'sys_wu_pause')

# =============================================================================================
# 4. Plan with custom settings object
# =============================================================================================
Write-Host '4: Get-SRPrepSystemPlan with custom settings object' -ForegroundColor Cyan

$customSettings = [pscustomobject]@{
    language = [pscustomobject]@{
        ui         = 'en-US'
        keep_input = @('ko-KR', 'ja-JP')
    }
    disk     = [pscustomobject]@{
        warn_gb = 100
        fail_gb = 50
    }
    updates  = [pscustomobject]@{
        pause_days = 14
    }
    drivers  = [pscustomobject]@{
        nvidia_min  = '572.00'
        max_age_days = 180
    }
}

$planCustom = Get-SRPrepSystemPlan -Settings $customSettings -Role 'prod'
Assert-That '4.1: Custom plan returns an array' ($planCustom -is [System.Array])
Assert-That '4.2: Custom plan items count > 0' ($planCustom.Count -gt 0)

$customDisk = $planCustom | Where-Object { $_.id -eq 'sys_disk' }
Assert-That '4.3: Custom plan disk target reflects warn_gb threshold (100 GB)' ($customDisk.target -match '100') ("Target: $($customDisk.target)")

$customPause = $planCustom | Where-Object { $_.id -eq 'sys_wu_pause' }
Assert-That '4.4: Custom plan updates pause target reflects pause_days (14 days)' ($customPause.target -match '14') ("Target: $($customPause.target)")

$customSchemaOk = $true
$customIds = [System.Collections.Generic.List[string]]::new()
foreach ($ci in $planCustom) {
    $customIds.Add($ci.id)
    if ($validStatuses -notcontains $ci.status -or $validSections -notcontains $ci.section) {
        $customSchemaOk = $false
    }
    if ($ci.status -eq 'CHANGE' -and (@($ci.commands).Count -eq 0)) {
        $customSchemaOk = $false
    }
}
$customUniqueIds = @($customIds | Select-Object -Unique)
Assert-That '4.5: Custom plan items have valid schema and unique IDs' ($customSchemaOk -and ($customIds.Count -eq $customUniqueIds.Count))

# =============================================================================================
# 5. Invoke-SRPrepSystemApply -DryRun safety tests
# =============================================================================================
Write-Host '5: Invoke-SRPrepSystemApply -DryRun safety verification' -ForegroundColor Cyan

# Read initial system state before DryRun
$initialLangOverride = try { (Get-WinUILanguageOverride) } catch { '' }
$uxPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$initialPauseExpiry = try { (Get-ItemProperty -Path $uxPath -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime } catch { '' }
$initialPauseStart = try { (Get-ItemProperty -Path $uxPath -ErrorAction SilentlyContinue).PauseUpdatesStartTime } catch { '' }

# Select plan's CHANGE items, or create synthetic CHANGE item if none
$changeItems = @($planNull | Where-Object { $_.status -eq 'CHANGE' })
if ($changeItems.Count -eq 0) {
    $changeItems = @(
        (New-SRPrepItem -Id 'sys_wu_pause' -Section 'updates' -Title 'Pause Windows Update' `
            -Status 'CHANGE' -Current 'Not paused' -Target 'Pause for 7 days' `
            -Detail 'Dry run test change' -Commands @("Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseUpdatesStartTime' -Value '2026-10-16T14:00:00Z'") `
            -Undo $null)
    )
}

$dryLog = [System.Collections.Generic.List[string]]::new()
$dryLogSb = { param($msg) $dryLog.Add($msg) }
$tempBackupDir = Join-Path $env:TEMP ("sr-prep-test-backup-" + [Guid]::NewGuid().ToString('N'))

$applied = Invoke-SRPrepSystemApply `
    -Items $changeItems `
    -Settings $null `
    -BackupDir $tempBackupDir `
    -DryRun `
    -Log $dryLogSb

Assert-That '5.1: Apply -DryRun returns results' ($applied.Count -gt 0) ("Applied count: $($applied.Count)")

$allSkipped = $true
$allDryDetail = $true
foreach ($ap in $applied) {
    if ($ap.status -ne 'SKIPPED') { $allSkipped = $false }
    if ($ap.detail -ne 'dry run') { $allDryDetail = $false }
}
Assert-That '5.2: Apply -DryRun sets all item statuses to SKIPPED' $allSkipped
Assert-That '5.3: Apply -DryRun sets detail to "dry run"' $allDryDetail

# Assert all logged command messages have DRYRUN: prefix
$allDryrunPrefix = $true
$hasDryrunLogs = ($dryLog.Count -gt 0)
foreach ($msg in $dryLog) {
    if (-not $msg.StartsWith('DRYRUN: ')) {
        $allDryrunPrefix = $false
    }
}
Assert-That '5.4: Apply -DryRun emits DRYRUN: prefixed log lines' ($hasDryrunLogs -and $allDryrunPrefix) ("Log count: $($dryLog.Count)")

# Assert system state is UNCHANGED before vs after
$afterLangOverride = try { (Get-WinUILanguageOverride) } catch { '' }
$afterPauseExpiry = try { (Get-ItemProperty -Path $uxPath -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime } catch { '' }
$afterPauseStart = try { (Get-ItemProperty -Path $uxPath -ErrorAction SilentlyContinue).PauseUpdatesStartTime } catch { '' }

Assert-That '5.5: UI Language override unchanged after DryRun' ($initialLangOverride -eq $afterLangOverride)
Assert-That '5.6: WU PauseUpdatesExpiryTime unchanged after DryRun' ($initialPauseExpiry -eq $afterPauseExpiry)
Assert-That '5.7: WU PauseUpdatesStartTime unchanged after DryRun' ($initialPauseStart -eq $afterPauseStart)

# Clean up temp backup dir if created
if (Test-Path $tempBackupDir) {
    Remove-Item -Path $tempBackupDir -Recurse -Force -ErrorAction SilentlyContinue
}

# =============================================================================================
# 6. Undo-SRPrepSystem -DryRun safety tests
# =============================================================================================
Write-Host '6: Undo-SRPrepSystem -DryRun safety verification' -ForegroundColor Cyan

$tempUndoDir = Join-Path $env:TEMP ("sr-prep-test-undo-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempUndoDir -Force -ErrorAction SilentlyContinue

$fakeUndoList = @(
    [pscustomobject]@{
        id        = 'sys_wu_pause'
        section   = 'updates'
        undo      = [pscustomobject]@{
            PauseUpdatesStartTime        = 'absent'
            PauseUpdatesExpiryTime       = 'absent'
            PauseFeatureUpdatesStartTime = 'absent'
            PauseFeatureUpdatesEndTime   = 'absent'
            PauseQualityUpdatesStartTime = 'absent'
            PauseQualityUpdatesEndTime   = 'absent'
        }
        timestamp = [DateTime]::UtcNow.ToString('o')
    },
    [pscustomobject]@{
        id        = 'sys_language'
        section   = 'language'
        undo      = [pscustomobject]@{
            win_ui_language_override      = 'en-US'
            user_language_list_tags       = @('en-US', 'ko-KR')
            system_preferred_ui_language  = 'en-US'
        }
        timestamp = [DateTime]::UtcNow.ToString('o')
    }
)
$fakeUndoJson = ConvertTo-Json -InputObject $fakeUndoList -Depth 10
Set-Content -Path (Join-Path $tempUndoDir 'system-undo.json') -Value $fakeUndoJson -Encoding ASCII -Force

$undoLog = [System.Collections.Generic.List[string]]::new()
$undoLogSb = { param($msg) $undoLog.Add($msg) }

$undone = Undo-SRPrepSystem -BackupDir $tempUndoDir -DryRun -Log $undoLogSb
Assert-That '6.1: Undo-SRPrepSystem -DryRun returns undone items' ($undone.Count -eq 2) ("Count: $($undone.Count)")

$undoAllSkipped = $true
$undoAllDryrunLogs = ($undoLog.Count -gt 0)
foreach ($uItem in $undone) {
    if ($uItem.status -ne 'SKIPPED') { $undoAllSkipped = $false }
}
foreach ($uMsg in $undoLog) {
    if (-not $uMsg.StartsWith('DRYRUN: ')) { $undoAllDryrunLogs = $false }
}
Assert-That '6.2: Undo-SRPrepSystem -DryRun sets status to SKIPPED' $undoAllSkipped
Assert-That '6.3: Undo-SRPrepSystem -DryRun logs only DRYRUN: lines' $undoAllDryrunLogs
# Verify reverse order: sys_language restored first, then sys_wu_pause
Assert-That '6.4: Undo restores items in reverse order of undo file' ($undone[0].id -eq 'sys_language' -and $undone[1].id -eq 'sys_wu_pause')

Remove-Item -Path $tempUndoDir -Recurse -Force -ErrorAction SilentlyContinue

# =============================================================================================
# 7. Fixture generation: Save plan to fixtures\prep-system-plan.json
# =============================================================================================
Write-Host '7: Fixture generation' -ForegroundColor Cyan

if (-not (Test-Path $fixturesDir)) {
    $null = New-Item -ItemType Directory -Path $fixturesDir -Force -ErrorAction SilentlyContinue
}
$fixtureFile = Join-Path $fixturesDir 'prep-system-plan.json'
$planJson = ConvertTo-Json -InputObject @($planNull) -Depth 6
Set-Content -Path $fixtureFile -Value $planJson -Encoding ASCII -Force

Assert-That '7.1: Fixture file fixtures\prep-system-plan.json created' (Test-Path $fixtureFile)
$fixtureContent = Get-Content -Path $fixtureFile -Raw -Encoding ASCII
Assert-That '7.2: Fixture is non-empty valid JSON' ($fixtureContent.Length -gt 50 -and (-not [string]::IsNullOrEmpty((ConvertFrom-Json $fixtureContent))))

# =============================================================================================
# 8. Windows edition switch (sys_edition) tests
# =============================================================================================
Write-Host '8: Windows edition switch (sys_edition) tests' -ForegroundColor Cyan

# Save original functions
$origEditionIdFn = (Get-Item function:Get-SRPrepEditionId).ScriptBlock
$origTargetEditionsFn = (Get-Item function:Get-SRPrepTargetEditions).ScriptBlock
$origIsAdminFn = (Get-Item function:Test-SRPrepIsAdmin).ScriptBlock

# (a) CoreSingleLanguage + targets @('Core','Professional') + admin
function Get-SRPrepEditionId { return 'CoreSingleLanguage' }
function Get-SRPrepTargetEditions { return @('Core', 'Professional') }
function Test-SRPrepIsAdmin { return $true }

$planA = Get-SRPrepSystemPlan -Settings $null -Role 'prod'
$itemA = $planA | Where-Object { $_.id -eq 'sys_edition' }
Assert-That '8.a.1: sys_edition item exists' ($null -ne $itemA)
Assert-That '8.a.2: status is CHANGE' ($itemA.status -eq 'CHANGE')
Assert-That '8.a.3: default_apply is false' ($itemA.default_apply -eq $false)
Assert-That '8.a.4: risk is medium' ($itemA.risk -eq 'medium')
Assert-That '8.a.5: needs_reboot is true' ($itemA.needs_reboot -eq $true)
$cmdA = @($itemA.commands) -join ' '
Assert-That '8.a.6: command contains changepk' ($cmdA -match 'changepk')
Assert-That '8.a.7: command contains Home key YTMG3-N6DKC-DKB77-7M9GH-8HVX7' ($cmdA -match 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7')
Assert-That '8.a.8: target is Windows Home (NOT activated) - allows English' ($itemA.target -eq 'Windows Home (NOT activated) - allows English')

# (b) targets @('Professional') gives the Pro key
function Get-SRPrepTargetEditions { return @('Professional') }

$planB = Get-SRPrepSystemPlan -Settings $null -Role 'prod'
$itemB = $planB | Where-Object { $_.id -eq 'sys_edition' }
Assert-That '8.b.1: sys_edition item exists for Pro target' ($null -ne $itemB)
Assert-That '8.b.2: status is CHANGE' ($itemB.status -eq 'CHANGE')
$cmdB = @($itemB.commands) -join ' '
Assert-That '8.b.3: command contains Pro key VK7JG-NPHTM-C97JM-9MPGT-3V66T' ($cmdB -match 'VK7JG-NPHTM-C97JM-9MPGT-3V66T')
Assert-That '8.b.4: target is Windows Pro (NOT activated) - allows English' ($itemB.target -eq 'Windows Pro (NOT activated) - allows English')

# (c) targets $null gives CHANGE with the Home key
function Get-SRPrepTargetEditions { return $null }

$planC = Get-SRPrepSystemPlan -Settings $null -Role 'prod'
$itemC = $planC | Where-Object { $_.id -eq 'sys_edition' }
Assert-That '8.c.1: sys_edition item exists when targets is $null' ($null -ne $itemC)
Assert-That '8.c.2: status is CHANGE' ($itemC.status -eq 'CHANGE')
$cmdC = @($itemC.commands) -join ' '
Assert-That '8.c.3: command contains Home key' ($cmdC -match 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7')
Assert-That '8.c.4: detail contains refuse note' ($itemC.detail -match 'Windows may refuse; if it does, nothing changes')

# (d) targets @('Education') gives MANUAL
function Get-SRPrepTargetEditions { return @('Education') }

$planD = Get-SRPrepSystemPlan -Settings $null -Role 'prod'
$itemD = $planD | Where-Object { $_.id -eq 'sys_edition' }
Assert-That '8.d.1: sys_edition item exists for Education target' ($null -ne $itemD)
Assert-That '8.d.2: status is MANUAL' ($itemD.status -eq 'MANUAL')
Assert-That '8.d.3: detail mentions paid upgrade or reinstall' ($itemD.detail -match 'paid upgrade' -or $itemD.detail -match 'reinstall')

# (e) not admin gives MANUAL
function Get-SRPrepTargetEditions { return $null }
function Test-SRPrepIsAdmin { return $false }

$planE = Get-SRPrepSystemPlan -Settings $null -Role 'prod'
$itemE = $planE | Where-Object { $_.id -eq 'sys_edition' }
Assert-That '8.e.1: sys_edition item exists when not admin' ($null -ne $itemE)
Assert-That '8.e.2: status is MANUAL when not admin' ($itemE.status -eq 'MANUAL')
Assert-That '8.e.3: detail mentions run Prep as administrator to check' ($itemE.detail -match 'run Prep as administrator to check')

# (f) EditionID 'Core' or 'Professional' gives no sys_edition item
function Test-SRPrepIsAdmin { return $true }
function Get-SRPrepEditionId { return 'Core' }
$planF1 = Get-SRPrepSystemPlan -Settings $null -Role 'prod'
$itemF1 = $planF1 | Where-Object { $_.id -eq 'sys_edition' }
Assert-That '8.f.1: EditionID Core gives no sys_edition item' ($null -eq $itemF1)

function Get-SRPrepEditionId { return 'Professional' }
$planF2 = Get-SRPrepSystemPlan -Settings $null -Role 'prod'
$itemF2 = $planF2 | Where-Object { $_.id -eq 'sys_edition' }
Assert-That '8.f.2: EditionID Professional gives no sys_edition item' ($null -eq $itemF2)

# (g) Invoke-SRPrepEditionSwitch -DryRun returns SKIPPED and never calls changepk
$script:testStartProcessCalls = New-Object System.Collections.ArrayList
function Start-Process {
    param([Parameter(ValueFromRemainingArguments=$true)]$allArgs)
    [void]$script:testStartProcessCalls.Add($allArgs)
}

$fakeSwitchItem = New-SRPrepItem `
    -Id 'sys_edition' `
    -Section 'language' `
    -Title 'Windows edition' `
    -Status 'CHANGE' `
    -Current 'Home Single Language (activated)' `
    -Target 'Windows Home (NOT activated) - allows English' `
    -Risk 'medium' `
    -NeedsReboot $true `
    -NeedsAdmin $true `
    -DefaultApply $false `
    -Commands @('changepk.exe /ProductKey YTMG3-N6DKC-DKB77-7M9GH-8HVX7')

$switchLog = [System.Collections.Generic.List[string]]::new()
$switchLogSb = { param($msg) $switchLog.Add($msg) }

$switchRes = Invoke-SRPrepEditionSwitch -Item $fakeSwitchItem -DryRun -Log $switchLogSb
Assert-That '8.g.1: Invoke-SRPrepEditionSwitch -DryRun returns SKIPPED' ($switchRes.status -eq 'SKIPPED')
Assert-That '8.g.2: Start-Process was never called in DryRun' ($script:testStartProcessCalls.Count -eq 0)
Assert-That '8.g.3: DryRun logged DRYRUN: changepk' (@($switchLog | Where-Object { $_ -match 'DRYRUN:\s+changepk' }).Count -gt 0)

Remove-Item function:Start-Process -ErrorAction SilentlyContinue

# (h) the sys_language detail for CoreSingleLanguage mentions the edition switch
function Get-SRPrepEditionId { return 'CoreSingleLanguage' }
function Test-SRPrepIsAdmin { return $true }
$planH = Get-SRPrepSystemPlan -Settings $null -Role 'prod'
$langItemH = $planH | Where-Object { $_.id -eq 'sys_language' }
Assert-That '8.h.1: sys_language exists for CoreSingleLanguage' ($null -ne $langItemH)
Assert-That '8.h.2: sys_language detail mentions edition switch' ($langItemH.detail -match 'edition')

# Undo with sys_edition backup
$tempEditionUndoDir = Join-Path $env:TEMP ("sr-prep-test-edition-undo-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempEditionUndoDir -Force -ErrorAction SilentlyContinue
Set-Content -Path (Join-Path $tempEditionUndoDir 'sys_edition.json') -Value '{"id":"sys_edition","original_edition_id":"CoreSingleLanguage","has_oem_key":true,"timestamp":"2026-10-16T14:00:00Z"}' -Encoding ASCII -Force

$undoneEdition = Undo-SRPrepSystem -BackupDir $tempEditionUndoDir -DryRun
$editionUndoItem = $undoneEdition | Where-Object { $_.id -eq 'sys_edition' }
Assert-That '8.i.1: Undo with sys_edition backup returns MANUAL item' ($null -ne $editionUndoItem -and $editionUndoItem.status -eq 'MANUAL')
Assert-That '8.i.2: Undo item detail explains manual restore' ($editionUndoItem.detail -match 'reinstall' -and $editionUndoItem.detail -match 'Settings > System > Activation')
Assert-That '8.i.3: Undo item has no commands' (@($editionUndoItem.commands).Count -eq 0)

Remove-Item -Path $tempEditionUndoDir -Recurse -Force -ErrorAction SilentlyContinue

# Restore original functions
Set-Item function:Get-SRPrepEditionId $origEditionIdFn
Set-Item function:Get-SRPrepTargetEditions $origTargetEditionsFn
Set-Item function:Test-SRPrepIsAdmin $origIsAdminFn

# =============================================================================================
# 9. Real (non-DryRun) apply and undo path with a fake item that matches no action.
#    Kit 1.3.1 threw "'if' is not recognized" here on every real show PC: -Status (if ...).
# =============================================================================================
Write-Host '9: real apply/undo path records results (fake item, changes nothing)' -ForegroundColor Cyan
$realDir = Join-Path $env:TEMP ("sr-prep-test-real-" + [Guid]::NewGuid().ToString('N'))
$fakeItems = @(
    [pscustomobject]@{ id = 'sys_fake_ok'; section = 'updates'; title = 'fake'; status = 'CHANGE'; current = 'a'; target = 'b'; detail = ''; risk = 'low'
                       needs_reboot = $false; needs_admin = $false; default_apply = $true; commands = @(); undo = [pscustomobject]@{ x = 'absent' } },
    [pscustomobject]@{ id = 'sys_fake_two'; section = 'updates'; title = 'fake 2'; status = 'CHANGE'; current = 'a'; target = 'b'; detail = ''; risk = 'low'
                       needs_reboot = $false; needs_admin = $false; default_apply = $true; commands = @(); undo = [pscustomobject]@{ x = 'absent' } }
)
$realErr = $null
$realRes = @()
try { $realRes = @(Invoke-SRPrepSystemApply -Items $fakeItems -Settings $null -BackupDir $realDir | ForEach-Object { $_ }) }
catch { $realErr = $_.Exception.Message }
Assert-That '9.1: real apply does not throw' ($null -eq $realErr) ([string]$realErr)
Assert-That '9.2: real apply records every item (not just the first)' ($realRes.Count -eq 2) ("count " + $realRes.Count)
Assert-That '9.3: real apply status is DONE' (@($realRes | Where-Object { $_.status -eq 'DONE' }).Count -eq 2) (@($realRes | ForEach-Object { $_.status }) -join ',')
Assert-That '9.4: undo data saved before applying' (Test-Path (Join-Path $realDir 'system-undo.json'))
$undoErr = $null
$undoRes = @()
try { $undoRes = @(Undo-SRPrepSystem -BackupDir $realDir | ForEach-Object { $_ }) }
catch { $undoErr = $_.Exception.Message }
Assert-That '9.5: real undo does not throw' ($null -eq $undoErr) ([string]$undoErr)
Assert-That '9.6: real undo records both entries' ($undoRes.Count -eq 2) ("count " + $undoRes.Count)
if (Test-Path $realDir) { Remove-Item -Path $realDir -Recurse -Force -ErrorAction SilentlyContinue }

# a statement inside plain brackets, "(if ...)", is a command call in PowerShell: never valid
$kitRoot = Split-Path -Parent $PSScriptRoot
$badParen = @(Get-ChildItem -Path $kitRoot -Recurse -Filter '*.ps1' | Select-String -Pattern '[^$@]\(\s*(if|foreach|switch|while)\s*\(' | Where-Object { $_.Line -notmatch '^\s*#' -and $_.Path -notmatch 'Test-PrepSystem' })
Assert-That '9.7: no "(if (" statement-in-brackets anywhere in the kit' ($badParen.Count -eq 0) (@($badParen | ForEach-Object { (Split-Path -Leaf $_.Path) + ':' + $_.LineNumber }) -join ', ')

# =============================================================================================
# Test Summary
# =============================================================================================
Write-Host ''
Write-Host "Prep System Test Results: $($script:nPass) passed, $($script:nFail) failed" -ForegroundColor $(if ($script:nFail -eq 0) { 'Green' } else { 'Red' })

if ($script:nFail -eq 0) {
    Write-Host 'ALL PREP SYSTEM TESTS PASSED' -ForegroundColor Green
    exit 0
} else {
    Write-Host 'SOME PREP SYSTEM TESTS FAILED' -ForegroundColor Red
    exit 1
}
