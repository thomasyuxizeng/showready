<#
.SYNOPSIS
    ShowReady Prep - System Library (lib\Prep.System.ps1)
.DESCRIPTION
    Provides plan, apply, and undo functions for system-level settings:
    elevation/user context, Windows display language, GPU drivers, wired NIC drivers,
    Windows Update offered drivers, disk space thresholds, pending reboot state,
    and Windows Update pause.
    Complies with ShowReady PREP-CONTRACT.md and works under Windows PowerShell 5.1 and pwsh 7.
#>

# -------------------------------------------------------------------------------------------------
# Helper: Item Factory
# -------------------------------------------------------------------------------------------------
function New-SRPrepItem {
    param(
        [string]$Id,
        [string]$Section,
        [string]$Title,
        [string]$Status,
        [string]$Current,
        [string]$Target,
        [string]$Detail,
        [string]$Risk = 'low',
        [bool]$NeedsReboot = $false,
        [bool]$NeedsAdmin = $false,
        [bool]$DefaultApply = $false,
        [string[]]$Commands = @(),
        $Undo = $null
    )

    $cmdList = @()
    if ($null -ne $Commands) {
        foreach ($c in $Commands) {
            if ($null -ne $c) { $cmdList += [string]$c }
        }
    }

    return [pscustomobject]@{
        id            = [string]$Id
        section       = [string]$Section
        title         = [string]$Title
        status        = [string]$Status
        current       = [string]$Current
        target        = [string]$Target
        detail        = [string]$Detail
        risk          = [string]$Risk
        needs_reboot  = [bool]$NeedsReboot
        needs_admin   = [bool]$NeedsAdmin
        default_apply = [bool]$DefaultApply
        commands      = $cmdList
        undo          = $Undo
    }
}

# -------------------------------------------------------------------------------------------------
# Generic Product Keys
# Microsoft's public generic installation keys for edition switching.
# These keys install the specified Windows edition but never activate it.
# -------------------------------------------------------------------------------------------------
$script:GENERIC_KEY_HOME = 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7' # target EditionID Core
$script:GENERIC_KEY_PRO  = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T' # target EditionID Professional
$GENERIC_KEY_HOME = $script:GENERIC_KEY_HOME
$GENERIC_KEY_PRO  = $script:GENERIC_KEY_PRO

# -------------------------------------------------------------------------------------------------
# Helpers: Edition ID, Admin Check, Target Editions
# -------------------------------------------------------------------------------------------------
function Get-SRPrepEditionId {
    [CmdletBinding()]
    param()

    try {
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        if ($cv -and $cv.EditionID) { return [string]$cv.EditionID }
    } catch { }
    return ''
}

function Test-SRPrepIsAdmin {
    [CmdletBinding()]
    param()

    try {
        $winId = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]$winId
        return [bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-SRPrepTargetEditions {
    [CmdletBinding()]
    param()

    try {
        if (-not (Test-SRPrepIsAdmin)) {
            return $null
        }

        $dismPath = Join-Path $env:SystemRoot 'System32\dism.exe'
        if (-not (Test-Path $dismPath)) {
            $dismPath = 'dism.exe'
        }

        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $dismPath
        $pinfo.Arguments = '/Online /Get-TargetEditions /English'
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        $pinfo.WorkingDirectory = $env:TEMP

        $proc = [System.Diagnostics.Process]::Start($pinfo)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        if ($proc.ExitCode -ne 0) {
            return $null
        }

        $editions = [System.Collections.Generic.List[string]]::new()
        foreach ($line in ($stdout -split "`r?`n")) {
            if ($line -match '(?i)^\s*Target\s+Edition\s*:\s*(\w+)') {
                $ed = $matches[1].Trim()
                if ($ed -ne '' -and -not $editions.Contains($ed)) {
                    $editions.Add($ed)
                }
            }
        }

        if ($editions.Count -eq 0) {
            return $null
        }

        return ,$editions.ToArray()
    } catch {
        return $null
    }
}

# -------------------------------------------------------------------------------------------------
# Helper: Safe Config Value Extractor
# -------------------------------------------------------------------------------------------------
function Get-SRSetting {
    param(
        $Settings,
        [string]$Section,
        [string]$Key,
        $Default
    )

    if ($null -eq $Settings) { return $Default }

    $sec = $null
    if ($Settings -is [System.Collections.IDictionary]) {
        if ($Settings.Contains($Section)) { $sec = $Settings[$Section] }
    } elseif ($Settings.PSObject.Properties.Match($Section).Count -gt 0) {
        $sec = $Settings.$Section
    }

    if ($null -eq $sec) { return $Default }

    if ($sec -is [System.Collections.IDictionary]) {
        if ($sec.Contains($Key) -and $null -ne $sec[$Key]) { return $sec[$Key] }
    } elseif ($sec.PSObject.Properties.Match($Key).Count -gt 0 -and $null -ne $sec.$Key) {
        return $sec.$Key
    }

    return $Default
}

# -------------------------------------------------------------------------------------------------
# Helper: Driver Date Parser
# -------------------------------------------------------------------------------------------------
function Convert-SRDriverDate {
    param($RawDate)
    if ($null -eq $RawDate) { return $null }
    if ($RawDate -is [DateTime]) { return $RawDate }
    $str = [string]$RawDate
    if ([string]::IsNullOrEmpty($str)) { return $null }
    if ($str.Length -ge 8 -and $str.Substring(0, 8) -match '^\d{8}$') {
        try {
            return [DateTime]::ParseExact($str.Substring(0, 8), 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
        } catch { }
    }
    try {
        return [DateTime]::Parse($str, [System.Globalization.CultureInfo]::InvariantCulture)
    } catch { }
    try {
        return [DateTime]::Parse($str)
    } catch { }
    return $null
}

# -------------------------------------------------------------------------------------------------
# Helper: NVIDIA Driver Version Converter
# Win32_VideoController.DriverVersion like '32.0.15.7270' -> '572.70'
# -------------------------------------------------------------------------------------------------
function Convert-SRNvidiaDriverVersion {
    [CmdletBinding()]
    param([string]$Version)

    if ([string]::IsNullOrEmpty($Version)) { return $null }
    $clean = $Version -replace '[^0-9]', ''
    if ($clean.Length -lt 5) { return $null }
    $last5 = $clean.Substring($clean.Length - 5)
    return ($last5.Substring(0, 3) + '.' + $last5.Substring(3, 2))
}

# -------------------------------------------------------------------------------------------------
# Helper: Format Pause Time String (UTC yyyy-MM-ddTHH:mm:ssZ)
# -------------------------------------------------------------------------------------------------
function Format-SRPauseTime {
    [CmdletBinding()]
    param([DateTime]$DateTime)

    return $DateTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

# -------------------------------------------------------------------------------------------------
# Helper / Export: Test-SRPrepPerUserMismatch
# Returns $true if process elevated identity differs from console user
# -------------------------------------------------------------------------------------------------
function Test-SRPrepPerUserMismatch {
    [CmdletBinding()]
    param()

    try {
        $elevated = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ([string]::IsNullOrEmpty($elevated)) { return $false }

        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        $console = if ($cs -and $cs.UserName) { [string]$cs.UserName } else { '' }
        if ([string]::IsNullOrEmpty($console)) { return $false }

        if ($elevated.Trim().ToLowerInvariant() -eq $console.Trim().ToLowerInvariant()) {
            return $false
        }

        $elevatedUser = $elevated.Split('\')[-1].Trim().ToLowerInvariant()
        $consoleUser = $console.Split('\')[-1].Trim().ToLowerInvariant()

        if ($elevated.Contains('\') -and -not $console.Contains('\')) {
            return ($elevatedUser -ne $consoleUser)
        }
        if ($console.Contains('\') -and -not $elevated.Contains('\')) {
            return ($elevatedUser -ne $consoleUser)
        }

        return $true
    } catch {
        return $false
    }
}

# -------------------------------------------------------------------------------------------------
# Get-SRPrepSystemPlan
# -------------------------------------------------------------------------------------------------
function Get-SRPrepSystemPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $Settings,

        [Parameter(Mandatory = $false)]
        [string]$Role = 'prod',

        [Parameter(Mandatory = $false)]
        [scriptblock]$Log
    )

    if ([string]::IsNullOrEmpty($Role)) { $Role = 'prod' }

    # Built-in defaults per PREP-CONTRACT.md / Task specification
    $targetLang = [string](Get-SRSetting $Settings 'language' 'ui' 'en-US')
    $rawKeepInput = Get-SRSetting $Settings 'language' 'keep_input' @('ko-KR')
    $keepInput = @()
    if ($null -ne $rawKeepInput) {
        foreach ($ki in $rawKeepInput) {
            if ($null -ne $ki -and [string]$ki -ne '') { $keepInput += [string]$ki }
        }
    }
    if ($keepInput.Count -eq 0) { $keepInput = @('ko-KR') }

    $warnGb     = [double](Get-SRSetting $Settings 'disk' 'warn_gb' 50)
    $failGb     = [double](Get-SRSetting $Settings 'disk' 'fail_gb' 20)
    $pauseDays  = [int](Get-SRSetting $Settings 'updates' 'pause_days' 7)
    $nvidiaMin  = [string](Get-SRSetting $Settings 'drivers' 'nvidia_min' '570.00')
    $maxAgeDays = [int](Get-SRSetting $Settings 'drivers' 'max_age_days' 365)

    $items = [System.Collections.Generic.List[object]]::new()

    # =============================================================================================
    # 1. sys_admin (section 'drivers', status INFO)
    # =============================================================================================
    if ($Log) { & $Log "Checking process elevation and user context..." }
    try {
        $isElevated = $false
        try {
            $winId = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [Security.Principal.WindowsPrincipal]$winId
            $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { }

        $isMismatch = Test-SRPrepPerUserMismatch
        $elevatedUser = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { 'unknown' }
        $consoleUser = try {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
            if ($cs -and $cs.UserName) { [string]$cs.UserName } else { 'none' }
        } catch { 'unknown' }

        $adminDetail = if ($isMismatch) {
            "Running elevated as $elevatedUser, but console user is $consoleUser. Per-user settings will target the elevated account."
        } elseif ($isElevated) {
            "Running elevated as $elevatedUser matching console user ($consoleUser)."
        } else {
            "Running non-elevated as $elevatedUser (console: $consoleUser)."
        }

        $items.Add((New-SRPrepItem `
            -Id 'sys_admin' `
            -Section 'drivers' `
            -Title 'Process elevation and user context' `
            -Status 'INFO' `
            -Current ("Elevated: $(if ($isElevated) {'Yes'} else {'No'}), User: $elevatedUser, Console: $consoleUser") `
            -Target 'Elevated with matching console user' `
            -Detail $adminDetail `
            -Risk 'low' `
            -NeedsReboot $false `
            -NeedsAdmin $false `
            -DefaultApply $false `
            -Commands @() `
            -Undo $null))
    } catch {
        $items.Add((New-SRPrepItem `
            -Id 'sys_admin' `
            -Section 'drivers' `
            -Title 'Process elevation and user context' `
            -Status 'ERROR' `
            -Current 'query failed' `
            -Target 'Elevated with matching console user' `
            -Detail ("Elevation probe failed: $($_.Exception.Message)") `
            -Risk 'low' `
            -NeedsReboot $false `
            -NeedsAdmin $false `
            -DefaultApply $false `
            -Commands @() `
            -Undo $null))
    }

    # =============================================================================================
    # 2. sys_edition (section 'language') - Only when EditionID is CoreSingleLanguage
    # =============================================================================================
    $editionId = Get-SRPrepEditionId
    if ($editionId -eq 'CoreSingleLanguage') {
        if ($Log) { & $Log "Checking Windows edition upgrade targets for Home Single Language..." }
        try {
            $isAdmin = Test-SRPrepIsAdmin
            if (-not $isAdmin) {
                $items.Add((New-SRPrepItem `
                    -Id 'sys_edition' `
                    -Section 'language' `
                    -Title 'Windows edition' `
                    -Status 'MANUAL' `
                    -Current 'Home Single Language (activated)' `
                    -Target 'Windows Home (NOT activated) - allows English' `
                    -Detail 'Run Prep as administrator to check possible Windows edition upgrade targets.' `
                    -Risk 'medium' `
                    -NeedsReboot $false `
                    -NeedsAdmin $true `
                    -DefaultApply $false `
                    -Commands @() `
                    -Undo $null))
            } else {
                $targets = Get-SRPrepTargetEditions
                $hasCore = $false
                $hasPro = $false
                if ($null -ne $targets) {
                    foreach ($t in $targets) {
                        if ([string]$t -eq 'Core') { $hasCore = $true }
                        if ([string]$t -eq 'Professional') { $hasPro = $true }
                    }
                }

                if ($null -ne $targets -and -not $hasCore -and -not $hasPro) {
                    $items.Add((New-SRPrepItem `
                        -Id 'sys_edition' `
                        -Section 'language' `
                        -Title 'Windows edition' `
                        -Status 'MANUAL' `
                        -Current 'Home Single Language (activated)' `
                        -Target 'Windows Home or Pro (paid upgrade)' `
                        -Detail 'This PC cannot switch directly to Windows Home or Pro. Needs a paid upgrade (Settings > System > Activation) or a Windows reinstall.' `
                        -Risk 'medium' `
                        -NeedsReboot $false `
                        -NeedsAdmin $true `
                        -DefaultApply $false `
                        -Commands @() `
                        -Undo $null))
                } else {
                    $targetEdition = 'Core'
                    $targetKey = $script:GENERIC_KEY_HOME
                    $targetTitle = 'Windows Home (NOT activated) - allows English'
                    $refuseNote = ''

                    if ($hasCore) {
                        $targetEdition = 'Core'
                        $targetKey = $script:GENERIC_KEY_HOME
                        $targetTitle = 'Windows Home (NOT activated) - allows English'
                    } elseif ($hasPro) {
                        $targetEdition = 'Professional'
                        $targetKey = $script:GENERIC_KEY_PRO
                        $targetTitle = 'Windows Pro (NOT activated) - allows English'
                    } else {
                        # $targets is $null: still offer Core with Home key
                        $targetEdition = 'Core'
                        $targetKey = $script:GENERIC_KEY_HOME
                        $targetTitle = 'Windows Home (NOT activated) - allows English'
                        $refuseNote = ' (Windows may refuse; if it does, nothing changes.)'
                    }

                    $detailMsg = "An edition switch is needed before English can be installed. Windows will be NOT activated: an 'Activate Windows' watermark in the corner, which shows in full-screen/desktop captures. There is NO undo, and getting activated Windows back means buying a licence or reinstalling. It keeps apps and files. The PC restarts, then run Run-Prep.cmd again for English.$refuseNote"

                    $items.Add((New-SRPrepItem `
                        -Id 'sys_edition' `
                        -Section 'language' `
                        -Title 'Windows edition' `
                        -Status 'CHANGE' `
                        -Current 'Home Single Language (activated)' `
                        -Target $targetTitle `
                        -Detail $detailMsg `
                        -Risk 'medium' `
                        -NeedsReboot $true `
                        -NeedsAdmin $true `
                        -DefaultApply $false `
                        -Commands @("changepk.exe /ProductKey $targetKey") `
                        -Undo $null))
                }
            }
        } catch {
            $items.Add((New-SRPrepItem `
                -Id 'sys_edition' `
                -Section 'language' `
                -Title 'Windows edition' `
                -Status 'ERROR' `
                -Current 'Home Single Language (activated)' `
                -Target 'Windows Home (NOT activated) - allows English' `
                -Detail ("Edition probe failed: $($_.Exception.Message)") `
                -Risk 'medium' `
                -NeedsReboot $false `
                -NeedsAdmin $true `
                -DefaultApply $false `
                -Commands @() `
                -Undo $null))
        }
    }

    # =============================================================================================
    # 2b. sys_language (section 'language')
    # =============================================================================================
    if ($Log) { & $Log "Inspecting Windows display language and international settings..." }
    try {
        $wsusConfigured = $false
        try {
            $wuPol = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
            if ($wuPol) {
                if ($wuPol.WUServer -or $wuPol.DoNotConnectToWindowsUpdateInternetLocations -eq 1) {
                    $wsusConfigured = $true
                }
            }
        } catch { }

        $installedLanguages = [System.Collections.Generic.List[object]]::new()
        if ($null -ne (Get-Command Get-InstalledLanguage -ErrorAction SilentlyContinue)) {
            try {
                $rawInst = Get-InstalledLanguage -ErrorAction SilentlyContinue
                if ($rawInst) {
                    foreach ($ri in $rawInst) { $installedLanguages.Add($ri) }
                }
            } catch { }
        }

        $preferredUI = ''
        if ($null -ne (Get-Command Get-SystemPreferredUILanguage -ErrorAction SilentlyContinue)) {
            try { $preferredUI = [string](Get-SystemPreferredUILanguage -ErrorAction SilentlyContinue) } catch { }
        }

        $uiOverride = ''
        if ($null -ne (Get-Command Get-WinUILanguageOverride -ErrorAction SilentlyContinue)) {
            try { $uiOverride = [string](Get-WinUILanguageOverride -ErrorAction SilentlyContinue) } catch { }
        }

        $currentCulture = try { (Get-UICulture).Name } catch { 'unknown' }

        $userLangList = [System.Collections.Generic.List[object]]::new()
        if ($null -ne (Get-Command Get-WinUserLanguageList -ErrorAction SilentlyContinue)) {
            try {
                $rawUser = Get-WinUserLanguageList -ErrorAction SilentlyContinue
                if ($rawUser) {
                    foreach ($ru in $rawUser) { $userLangList.Add($ru) }
                }
            } catch { }
        }

        $hasInstallLanguage = ($null -ne (Get-Command Install-Language -ErrorAction SilentlyContinue))
        $isPerUserMismatch = Test-SRPrepPerUserMismatch

        if ($isPerUserMismatch) {
            $items.Add((New-SRPrepItem `
                -Id 'sys_language' `
                -Section 'language' `
                -Title 'Windows display language' `
                -Status 'MANUAL' `
                -Current ("$currentCulture (override: $uiOverride)") `
                -Target "$targetLang display language" `
                -Detail "Sign in to Windows as an administrator account and run Prep again. Elevated process identity differs from console user." `
                -Risk 'low' `
                -NeedsReboot $false `
                -NeedsAdmin $true `
                -DefaultApply $false `
                -Commands @() `
                -Undo $null))
        } elseif ($editionId -eq 'CoreSingleLanguage') {
            $items.Add((New-SRPrepItem `
                -Id 'sys_language' `
                -Section 'language' `
                -Title 'Windows display language' `
                -Status 'MANUAL' `
                -Current ("$currentCulture (Windows Home Single Language)") `
                -Target "$targetLang display language" `
                -Detail "This PC has Windows Home Single Language, which cannot show English. Switch the edition first (the 'Windows edition' item above), restart, then run Prep again. The other option is to run the show with the Korean UI." `
                -Risk 'low' `
                -NeedsReboot $false `
                -NeedsAdmin $false `
                -DefaultApply $false `
                -Commands @() `
                -Undo $null))
        } elseif (([string]$currentCulture -like 'en-*') -or ([string]$uiOverride -like 'en-*')) {
            # Any English display language (en-GB, en-US, ...) is good enough for the crew.
            $items.Add((New-SRPrepItem `
                -Id 'sys_language' `
                -Section 'language' `
                -Title 'Windows display language' `
                -Status 'OK' `
                -Current ("$currentCulture (override: $uiOverride)") `
                -Target 'English display language' `
                -Detail "Windows is already in English ($currentCulture) for the signed-in user." `
                -Risk 'low' `
                -NeedsReboot $false `
                -NeedsAdmin $false `
                -DefaultApply $false `
                -Commands @() `
                -Undo $null))
        } elseif (-not $hasInstallLanguage) {
            $items.Add((New-SRPrepItem `
                -Id 'sys_language' `
                -Section 'language' `
                -Title 'Windows display language' `
                -Status 'MANUAL' `
                -Current ("$currentCulture (override: $uiOverride)") `
                -Target "$targetLang display language" `
                -Detail "Open Settings > Time & Language > Language & region > Add a language > English (United States), tick 'Set as my Windows display language', then sign out." `
                -Risk 'low' `
                -NeedsReboot $true `
                -NeedsAdmin $true `
                -DefaultApply $false `
                -Commands @('start ms-settings:regionlanguage') `
                -Undo $null))
        } else {
            # Check if target language pack is already installed
            $isTargetInstalled = $false
            if ($installedLanguages.Count -gt 0) {
                foreach ($il in $installedLanguages) {
                    $langId = if ($il.LanguageId) { [string]$il.LanguageId } elseif ($il.Language) { [string]$il.Language } elseif ($il.LanguageTag) { [string]$il.LanguageTag } else { [string]$il }
                    if ($langId -eq $targetLang) {
                        $packs = if ($il.LanguagePacks) { [string]$il.LanguagePacks } else { '' }
                        if ($packs -and $packs -ne 'None') {
                            $isTargetInstalled = $true
                            break
                        }
                    }
                }
            }

            # Build ordered commands
            $cmdList = @()
            if (-not $isTargetInstalled) {
                $cmdList += "Install-Language -Language $targetLang -CopyToSettings"
            }
            if ($null -ne (Get-Command Set-SystemPreferredUILanguage -ErrorAction SilentlyContinue)) {
                $cmdList += "Set-SystemPreferredUILanguage -Language $targetLang"
            }
            $cmdList += "Set-WinUILanguageOverride -Language $targetLang"

            # Build language list preserving existing tags and keep_input
            $tags = @($targetLang)
            foreach ($ul in $userLangList) {
                $t = [string]$ul.LanguageTag
                if ($tags -notcontains $t) { $tags += $t }
            }
            foreach ($ki in $keepInput) {
                if ($tags -notcontains $ki) { $tags += $ki }
            }
            $cmdList += ("Set-WinUserLanguageList " + ($tags -join ', ') + " -Force")

            if ($null -ne (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue)) {
                $cmdList += 'Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true'
            }

            $detailMsg = "Switch Windows display language to $targetLang while keeping $($keepInput -join ', ') keyboard."
            if ($wsusConfigured) {
                $detailMsg += " Note: WSUS or Windows Update internet restriction is configured (WUServer or DoNotConnectToWindowsUpdateInternetLocations); language download may be blocked by venue IT policy."
            }

            $undoData = [pscustomobject]@{
                win_ui_language_override     = [string]$uiOverride
                user_language_list_tags      = @($userLangList | ForEach-Object { [string]$_.LanguageTag })
                system_preferred_ui_language = [string]$preferredUI
            }

            $items.Add((New-SRPrepItem `
                -Id 'sys_language' `
                -Section 'language' `
                -Title 'Windows display language' `
                -Status 'CHANGE' `
                -Current ("$currentCulture (override: $uiOverride)") `
                -Target "$targetLang display language" `
                -Detail $detailMsg `
                -Risk 'low' `
                -NeedsReboot $true `
                -NeedsAdmin $true `
                -DefaultApply $true `
                -Commands $cmdList `
                -Undo $undoData))
        }
    } catch {
        $items.Add((New-SRPrepItem `
            -Id 'sys_language' `
            -Section 'language' `
            -Title 'Windows display language' `
            -Status 'ERROR' `
            -Current 'query failed' `
            -Target "$targetLang display language" `
            -Detail ("Language probe failed: $($_.Exception.Message)") `
            -Risk 'low' `
            -NeedsReboot $false `
            -NeedsAdmin $false `
            -DefaultApply $false `
            -Commands @() `
            -Undo $null))
    }

    # =============================================================================================
    # 3. sys_gpu_driver (section 'drivers')
    # =============================================================================================
    if ($Log) { & $Log "Inspecting GPU controllers and driver versions..." }
    try {
        $rawGpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
        $gpus = [System.Collections.Generic.List[object]]::new()
        foreach ($g in $rawGpus) {
            $gName = [string]$g.Name
            if ($gName -match '(?i)Microsoft Basic Display|Microsoft Remote Display|Parsec|Virtual') {
                continue
            }
            $gpus.Add($g)
        }

        if ($gpus.Count -eq 0) {
            $items.Add((New-SRPrepItem `
                -Id 'sys_gpu_driver' `
                -Section 'drivers' `
                -Title 'Graphics card driver' `
                -Status 'INFO' `
                -Current 'No non-virtual GPU found' `
                -Target 'Discrete/integrated GPU driver' `
                -Detail 'No physical graphics controllers found in Win32_VideoController.' `
                -Risk 'low' `
                -NeedsReboot $false `
                -NeedsAdmin $false `
                -DefaultApply $false `
                -Commands @() `
                -Undo $null))
        } else {
            for ($i = 0; $i -lt $gpus.Count; $i++) {
                $gpu = $gpus[$i]
                $gpuId = if ($gpus.Count -eq 1) { 'sys_gpu_driver' } else { "sys_gpu_driver:$i" }
                $gpuName = [string]$gpu.Name
                $drvVer = [string]$gpu.DriverVersion
                $drvDate = Convert-SRDriverDate $gpu.DriverDate
                $dateStr = if ($drvDate) { $drvDate.ToString('yyyy-MM-dd') } else { 'unknown date' }
                $ageDays = if ($drvDate) { ([DateTime]::UtcNow - $drvDate.ToUniversalTime()).TotalDays } else { 0 }

                if ($gpuName -match '(?i)NVIDIA') {
                    $nvVer = Convert-SRNvidiaDriverVersion $drvVer
                    $displayVer = if ($nvVer) { $nvVer } else { $drvVer }
                    $currentStr = "$gpuName driver $displayVer ($dateStr)"

                    $isOlderThanMin = $false
                    if ($nvVer) {
                        try {
                            $isOlderThanMin = ([version]$nvVer -lt [version]$nvidiaMin)
                        } catch { }
                    }

                    if ($isOlderThanMin) {
                        $items.Add((New-SRPrepItem `
                            -Id $gpuId `
                            -Section 'drivers' `
                            -Title "$gpuName driver" `
                            -Status 'MANUAL' `
                            -Current $currentStr `
                            -Target ">= $nvidiaMin (NVIDIA Studio Driver)" `
                            -Detail "NVIDIA driver $displayVer is older than $nvidiaMin, which the kit's GPU encoder test needs. Install the current NVIDIA Studio Driver from https://www.nvidia.com/en-us/drivers/ (or the NVIDIA App). Not on show day: test vMix/OBS after updating." `
                            -Risk 'low' `
                            -NeedsReboot $false `
                            -NeedsAdmin $false `
                            -DefaultApply $false `
                            -Commands @() `
                            -Undo $null))
                    } elseif ($ageDays -gt $maxAgeDays) {
                        $items.Add((New-SRPrepItem `
                            -Id $gpuId `
                            -Section 'drivers' `
                            -Title "$gpuName driver" `
                            -Status 'MANUAL' `
                            -Current $currentStr `
                            -Target "Current NVIDIA Studio Driver (< $maxAgeDays days old)" `
                            -Detail "NVIDIA driver $displayVer is older than $maxAgeDays days ($dateStr). Consider updating to the latest NVIDIA Studio Driver from https://www.nvidia.com/en-us/drivers/ (or the NVIDIA App). Not on show day: test vMix/OBS after updating." `
                            -Risk 'low' `
                            -NeedsReboot $false `
                            -NeedsAdmin $false `
                            -DefaultApply $false `
                            -Commands @() `
                            -Undo $null))
                    } else {
                        $items.Add((New-SRPrepItem `
                            -Id $gpuId `
                            -Section 'drivers' `
                            -Title "$gpuName driver" `
                            -Status 'OK' `
                            -Current $currentStr `
                            -Target ">= $nvidiaMin (NVIDIA Studio Driver)" `
                            -Detail "NVIDIA driver $displayVer meets minimum version requirement ($nvidiaMin) and is current ($dateStr)." `
                            -Risk 'low' `
                            -NeedsReboot $false `
                            -NeedsAdmin $false `
                            -DefaultApply $false `
                            -Commands @() `
                            -Undo $null))
                    }
                } elseif ($gpuName -match '(?i)Radeon|AMD') {
                    $currentStr = "$gpuName driver $drvVer ($dateStr)"
                    if ($ageDays -gt $maxAgeDays) {
                        $items.Add((New-SRPrepItem `
                            -Id $gpuId `
                            -Section 'drivers' `
                            -Title "$gpuName driver" `
                            -Status 'MANUAL' `
                            -Current $currentStr `
                            -Target "Current AMD driver (< $maxAgeDays days old)" `
                            -Detail "AMD driver is older than $maxAgeDays days ($dateStr). Install current drivers from https://www.amd.com/en/support/download/drivers.html." `
                            -Risk 'low' `
                            -NeedsReboot $false `
                            -NeedsAdmin $false `
                            -DefaultApply $false `
                            -Commands @() `
                            -Undo $null))
                    } else {
                        $items.Add((New-SRPrepItem `
                            -Id $gpuId `
                            -Section 'drivers' `
                            -Title "$gpuName driver" `
                            -Status 'OK' `
                            -Current $currentStr `
                            -Target "Current AMD driver (< $maxAgeDays days old)" `
                            -Detail "AMD graphics driver is up to date ($dateStr)." `
                            -Risk 'low' `
                            -NeedsReboot $false `
                            -NeedsAdmin $false `
                            -DefaultApply $false `
                            -Commands @() `
                            -Undo $null))
                    }
                } elseif ($gpuName -match '(?i)Intel') {
                    $currentStr = "$gpuName driver $drvVer ($dateStr)"
                    if ($ageDays -gt $maxAgeDays) {
                        $items.Add((New-SRPrepItem `
                            -Id $gpuId `
                            -Section 'drivers' `
                            -Title "$gpuName driver" `
                            -Status 'MANUAL' `
                            -Current $currentStr `
                            -Target "Current Intel driver (< $maxAgeDays days old)" `
                            -Detail "Intel graphics driver is older than $maxAgeDays days ($dateStr). Consider updating via Intel Driver & Support Assistant: https://www.intel.com/content/www/us/en/support/detect.html." `
                            -Risk 'low' `
                            -NeedsReboot $false `
                            -NeedsAdmin $false `
                            -DefaultApply $false `
                            -Commands @() `
                            -Undo $null))
                    } else {
                        $items.Add((New-SRPrepItem `
                            -Id $gpuId `
                            -Section 'drivers' `
                            -Title "$gpuName driver" `
                            -Status 'OK' `
                            -Current $currentStr `
                            -Target "Current Intel driver (< $maxAgeDays days old)" `
                            -Detail "Intel graphics driver is up to date ($dateStr)." `
                            -Risk 'low' `
                            -NeedsReboot $false `
                            -NeedsAdmin $false `
                            -DefaultApply $false `
                            -Commands @() `
                            -Undo $null))
                    }
                } else {
                    $currentStr = "$gpuName driver $drvVer ($dateStr)"
                    if ($ageDays -gt $maxAgeDays) {
                        $items.Add((New-SRPrepItem `
                            -Id $gpuId `
                            -Section 'drivers' `
                            -Title "$gpuName driver" `
                            -Status 'MANUAL' `
                            -Current $currentStr `
                            -Target "Current GPU driver (< $maxAgeDays days old)" `
                            -Detail "GPU driver is older than $maxAgeDays days ($dateStr). Check vendor site for updates." `
                            -Risk 'low' `
                            -NeedsReboot $false `
                            -NeedsAdmin $false `
                            -DefaultApply $false `
                            -Commands @() `
                            -Undo $null))
                    } else {
                        $items.Add((New-SRPrepItem `
                            -Id $gpuId `
                            -Section 'drivers' `
                            -Title "$gpuName driver" `
                            -Status 'OK' `
                            -Current $currentStr `
                            -Target "Current GPU driver (< $maxAgeDays days old)" `
                            -Detail "Graphics driver is up to date ($dateStr)." `
                            -Risk 'low' `
                            -NeedsReboot $false `
                            -NeedsAdmin $false `
                            -DefaultApply $false `
                            -Commands @() `
                            -Undo $null))
                    }
                }
            }
        }
    } catch {
        $items.Add((New-SRPrepItem `
            -Id 'sys_gpu_driver' `
            -Section 'drivers' `
            -Title 'Graphics card driver' `
            -Status 'ERROR' `
            -Current 'query failed' `
            -Target 'GPU driver inspection' `
            -Detail ("GPU driver probe failed: $($_.Exception.Message)") `
            -Risk 'low' `
            -NeedsReboot $false `
            -NeedsAdmin $false `
            -DefaultApply $false `
            -Commands @() `
            -Undo $null))
    }

    # =============================================================================================
    # 4. sys_nic_driver (section 'drivers')
    # =============================================================================================
    if ($Log) { & $Log "Inspecting wired network adapter drivers..." }
    try {
        $wiredAdapters = [System.Collections.Generic.List[object]]::new()
        $physicalAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
        foreach ($pa in $physicalAdapters) {
            $mType = [string]$pa.MediaType
            $pmType = [string]$pa.PhysicalMediaType
            $isWired = ($mType -match '802\.3') -or (
                $mType -notmatch '(?i)802\.11|Wireless|Wi-Fi' -and
                $pmType -notmatch '(?i)802\.11|Wireless|Wi-Fi'
            )
            if ($isWired) {
                $wiredAdapters.Add($pa)
            }
        }

        if ($wiredAdapters.Count -eq 0) {
            $items.Add((New-SRPrepItem `
                -Id 'sys_nic_driver' `
                -Section 'drivers' `
                -Title 'Wired network adapter driver' `
                -Status 'INFO' `
                -Current 'No physical wired network adapters detected' `
                -Target 'Wired Ethernet adapter driver' `
                -Detail 'No physical 802.3 wired network adapters found on this system.' `
                -Risk 'low' `
                -NeedsReboot $false `
                -NeedsAdmin $false `
                -DefaultApply $false `
                -Commands @() `
                -Undo $null))
        } else {
            $threeYearsDays = 3 * 365
            for ($j = 0; $j -lt $wiredAdapters.Count; $j++) {
                $adapter = $wiredAdapters[$j]
                $nicId = if ($wiredAdapters.Count -eq 1) { 'sys_nic_driver' } else { "sys_nic_driver:$($adapter.Name)" }
                $desc = [string]$adapter.InterfaceDescription
                $drvVer = if ($adapter.DriverVersion) { [string]$adapter.DriverVersion } elseif ($adapter.DriverVersionString) { [string]$adapter.DriverVersionString } else { 'unknown' }
                $drvDate = Convert-SRDriverDate $adapter.DriverDate
                if ($null -eq $drvDate -and $adapter.PnPDeviceID) {
                    try {
                        $pnp = Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceID = '$($adapter.PnPDeviceID -replace '\\', '\\')'" -ErrorAction SilentlyContinue
                        if ($pnp -and $pnp.DriverDate) { $drvDate = Convert-SRDriverDate $pnp.DriverDate }
                        if ($drvVer -eq 'unknown' -and $pnp -and $pnp.DriverVersion) { $drvVer = [string]$pnp.DriverVersion }
                    } catch { }
                }

                $dateStr = if ($drvDate) { $drvDate.ToString('yyyy-MM-dd') } else { 'unknown date' }
                $currentStr = "$desc driver $drvVer ($dateStr)"
                $isOlderThan3Y = $false
                if ($drvDate) {
                    $isOlderThan3Y = (([DateTime]::UtcNow - $drvDate.ToUniversalTime()).TotalDays -gt $threeYearsDays)
                }

                if ($isOlderThan3Y) {
                    $detailMsg = if ($desc -match '(?i)Realtek' -or $adapter.Name -match '(?i)Realtek') {
                        "Driver is older than 3 years ($dateStr). Recommended to install the latest vendor driver: https://www.realtek.com/Download/List?cate_id=584"
                    } elseif ($desc -match '(?i)Intel' -or $adapter.Name -match '(?i)Intel') {
                        "Driver is older than 3 years ($dateStr). Recommended to install the latest vendor driver: https://www.intel.com/content/www/us/en/download/15084/intel-ethernet-adapter-complete-driver-pack.html"
                    } else {
                        "Driver is older than 3 years ($dateStr). Check vendor site for updated wired network adapter drivers."
                    }

                    $items.Add((New-SRPrepItem `
                        -Id $nicId `
                        -Section 'drivers' `
                        -Title ("Wired adapter driver: " + $adapter.Name) `
                        -Status 'MANUAL' `
                        -Current $currentStr `
                        -Target 'Vendor driver (< 3 years old)' `
                        -Detail $detailMsg `
                        -Risk 'low' `
                        -NeedsReboot $false `
                        -NeedsAdmin $false `
                        -DefaultApply $false `
                        -Commands @() `
                        -Undo $null))
                } else {
                    $items.Add((New-SRPrepItem `
                        -Id $nicId `
                        -Section 'drivers' `
                        -Title ("Wired adapter driver: " + $adapter.Name) `
                        -Status 'INFO' `
                        -Current $currentStr `
                        -Target 'Vendor driver (< 3 years old)' `
                        -Detail "Wired network adapter driver is up to date ($dateStr, version $drvVer)." `
                        -Risk 'low' `
                        -NeedsReboot $false `
                        -NeedsAdmin $false `
                        -DefaultApply $false `
                        -Commands @() `
                        -Undo $null))
                }
            }
        }
    } catch {
        $items.Add((New-SRPrepItem `
            -Id 'sys_nic_driver' `
            -Section 'drivers' `
            -Title 'Wired network adapter driver' `
            -Status 'ERROR' `
            -Current 'query failed' `
            -Target 'Wired Ethernet adapter driver' `
            -Detail ("NIC driver probe failed: $($_.Exception.Message)") `
            -Risk 'low' `
            -NeedsReboot $false `
            -NeedsAdmin $false `
            -DefaultApply $false `
            -Commands @() `
            -Undo $null))
    }

    # =============================================================================================
    # 5. sys_wu_drivers (section 'drivers')
    # =============================================================================================
    try {
        if ($null -eq $script:CachedWUDriverUpdates -or $null -eq $script:CachedWUDriverSearchTime -or ([DateTime]::UtcNow - $script:CachedWUDriverSearchTime).TotalMinutes -gt 5) {
            if ($Log) { & $Log "Searching Windows Update for drivers (can take a few minutes)..." }
            $s = New-Object -ComObject Microsoft.Update.Session
            $searcher = $s.CreateUpdateSearcher()
            $r = $searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")

            $wuUpdates = @()
            if ($r -and $r.Updates) {
                $wuUpdates = @($r.Updates)
            }
            $script:CachedWUDriverUpdates = $wuUpdates
            $script:CachedWUDriverSearchTime = [DateTime]::UtcNow
        } else {
            $wuUpdates = $script:CachedWUDriverUpdates
        }

        if ($wuUpdates.Count -eq 0) {
            $items.Add((New-SRPrepItem `
                -Id 'sys_wu_drivers' `
                -Section 'drivers' `
                -Title 'Windows Update drivers' `
                -Status 'OK' `
                -Current 'No pending driver updates' `
                -Target 'Drivers up to date' `
                -Detail 'No driver updates offered by Windows Update' `
                -Risk 'low' `
                -NeedsReboot $false `
                -NeedsAdmin $false `
                -DefaultApply $false `
                -Commands @() `
                -Undo $null))
        } else {
            foreach ($u in $wuUpdates) {
                $uId = [string]$u.Identity.UpdateID
                $uTitle = [string]$u.Title
                $dDate = Convert-SRDriverDate $u.DriverVerDate
                $dDateStr = if ($dDate) { $dDate.ToString('yyyy-MM-dd') } else { '' }
                $dClass = [string]$u.DriverClass
                $targetStr = ("$dDateStr $dClass").Trim()

                $needsReboot = $false
                if ($u.InstallationBehavior -and $u.InstallationBehavior.RebootBehavior -ne 0) {
                    $needsReboot = $true
                }

                $isDisplay = ($dClass -eq 'Display')
                $risk = if ($isDisplay) { 'medium' } else { 'low' }
                $defaultApply = if ($isDisplay) { $false } else { $true }
                $detail = if ($isDisplay) {
                    "Windows Update graphics drivers are often older OEM builds; the vendor driver (see GPU item) is usually better."
                } else {
                    "Available driver update from Windows Update ($dClass)."
                }

                $items.Add((New-SRPrepItem `
                    -Id ("sys_wu_drivers:$uId") `
                    -Section 'drivers' `
                    -Title $uTitle `
                    -Status 'CHANGE' `
                    -Current 'not installed' `
                    -Target $targetStr `
                    -Detail $detail `
                    -Risk $risk `
                    -NeedsReboot $needsReboot `
                    -NeedsAdmin $true `
                    -DefaultApply $defaultApply `
                    -Commands @("Windows Update: download and install $uTitle") `
                    -Undo $null))
            }
        }
    } catch {
        $items.Add((New-SRPrepItem `
            -Id 'sys_wu_drivers' `
            -Section 'drivers' `
            -Title 'Windows Update driver search' `
            -Status 'ERROR' `
            -Current 'Search failed' `
            -Target 'Available driver updates' `
            -Detail ("Windows Update driver search failed: $($_.Exception.Message)") `
            -Risk 'low' `
            -NeedsReboot $false `
            -NeedsAdmin $false `
            -DefaultApply $false `
            -Commands @() `
            -Undo $null))
    }

    # =============================================================================================
    # 6. sys_disk (section 'disk')
    # =============================================================================================
    if ($Log) { & $Log "Inspecting disk space..." }
    try {
        $sysDriveLetter = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
        $disks = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType = 3" -ErrorAction SilentlyContinue)

        $sysDisk = $null
        $otherDisks = [System.Collections.Generic.List[object]]::new()

        foreach ($d in $disks) {
            if ([string]$d.DeviceID -eq $sysDriveLetter) {
                $sysDisk = $d
            } else {
                $otherDisks.Add($d)
            }
        }

        if ($sysDisk) {
            $freeGb = [math]::Round(([double]$sysDisk.FreeSpace / 1GB), 1)
            $totalGb = [math]::Round(([double]$sysDisk.Size / 1GB), 1)
            $currentStr = "$freeGb GB free of $totalGb GB"

            if ($freeGb -lt $failGb) {
                $items.Add((New-SRPrepItem `
                    -Id 'sys_disk' `
                    -Section 'disk' `
                    -Title 'Low disk space' `
                    -Status 'MANUAL' `
                    -Current $currentStr `
                    -Target (">= $warnGb GB free") `
                    -Detail "Critically low disk space on $sysDriveLetter ($freeGb GB free of $totalGb GB). Free space via Settings > System > Storage > Temporary files, empty the Recycle Bin, and move old recordings to another drive." `
                    -Risk 'low' `
                    -NeedsReboot $false `
                    -NeedsAdmin $false `
                    -DefaultApply $false `
                    -Commands @() `
                    -Undo $null))
            } elseif ($freeGb -lt $warnGb) {
                $items.Add((New-SRPrepItem `
                    -Id 'sys_disk' `
                    -Section 'disk' `
                    -Title 'Low disk space warning' `
                    -Status 'MANUAL' `
                    -Current $currentStr `
                    -Target (">= $warnGb GB free") `
                    -Detail "Low disk space on $sysDriveLetter ($freeGb GB free of $totalGb GB, recommended >= $warnGb GB). Consider freeing space via Settings > System > Storage > Temporary files or moving recordings to another drive." `
                    -Risk 'low' `
                    -NeedsReboot $false `
                    -NeedsAdmin $false `
                    -DefaultApply $false `
                    -Commands @() `
                    -Undo $null))
            } else {
                $items.Add((New-SRPrepItem `
                    -Id 'sys_disk' `
                    -Section 'disk' `
                    -Title 'System disk space' `
                    -Status 'OK' `
                    -Current $currentStr `
                    -Target (">= $warnGb GB free") `
                    -Detail "Sufficient disk space on $sysDriveLetter ($freeGb GB free of $totalGb GB)." `
                    -Risk 'low' `
                    -NeedsReboot $false `
                    -NeedsAdmin $false `
                    -DefaultApply $false `
                    -Commands @() `
                    -Undo $null))
            }
        } else {
            $items.Add((New-SRPrepItem `
                -Id 'sys_disk' `
                -Section 'disk' `
                -Title 'System disk space' `
                -Status 'ERROR' `
                -Current 'drive not found' `
                -Target (">= $warnGb GB free") `
                -Detail "Could not locate system drive $sysDriveLetter in Win32_LogicalDisk." `
                -Risk 'low' `
                -NeedsReboot $false `
                -NeedsAdmin $false `
                -DefaultApply $false `
                -Commands @() `
                -Undo $null))
        }

        # Other fixed drives (e.g. recording drives)
        foreach ($od in $otherDisks) {
            $dId = [string]$od.DeviceID
            $cleanLetter = $dId.TrimEnd(':')
            $oFree = [math]::Round(([double]$od.FreeSpace / 1GB), 1)
            $oTotal = [math]::Round(([double]$od.Size / 1GB), 1)

            $items.Add((New-SRPrepItem `
                -Id ("sys_disk:$cleanLetter") `
                -Section 'disk' `
                -Title ("Disk space on $dId") `
                -Status 'INFO' `
                -Current "$oFree GB free of $oTotal GB" `
                -Target 'Fixed drive capacity' `
                -Detail "Drive $dId has $oFree GB free of $oTotal GB total capacity." `
                -Risk 'low' `
                -NeedsReboot $false `
                -NeedsAdmin $false `
                -DefaultApply $false `
                -Commands @() `
                -Undo $null))
        }
    } catch {
        $items.Add((New-SRPrepItem `
            -Id 'sys_disk' `
            -Section 'disk' `
            -Title 'System disk space' `
            -Status 'ERROR' `
            -Current 'query failed' `
            -Target 'Disk space check' `
            -Detail ("Disk probe failed: $($_.Exception.Message)") `
            -Risk 'low' `
            -NeedsReboot $false `
            -NeedsAdmin $false `
            -DefaultApply $false `
            -Commands @() `
            -Undo $null))
    }

    # =============================================================================================
    # 7. sys_reboot (section 'reboot')
    # =============================================================================================
    if ($Log) { & $Log "Checking for pending system reboots..." }
    try {
        $pendingReboot = $false
        $rebootReasons = [System.Collections.Generic.List[string]]::new()

        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
            $pendingReboot = $true
            $rebootReasons.Add('Component Based Servicing')
        }

        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
            $pendingReboot = $true
            $rebootReasons.Add('Windows Update')
        }

        try {
            $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
            if ($sm -and $sm.PendingFileRenameOperations) {
                $pendingReboot = $true
                $rebootReasons.Add('PendingFileRenameOperations')
            }
        } catch { }

        if ($pendingReboot) {
            $reasonsStr = ($rebootReasons -join ', ')
            $items.Add((New-SRPrepItem `
                -Id 'sys_reboot' `
                -Section 'reboot' `
                -Title 'Pending system reboot' `
                -Status 'MANUAL' `
                -Current "Pending reboot ($reasonsStr)" `
                -Target 'No pending reboot' `
                -Detail 'Restart the PC before testing (a pending reboot was detected from component servicing, Windows Update, or pending file operations).' `
                -Risk 'low' `
                -NeedsReboot $true `
                -NeedsAdmin $false `
                -DefaultApply $false `
                -Commands @() `
                -Undo $null))
        } else {
            $items.Add((New-SRPrepItem `
                -Id 'sys_reboot' `
                -Section 'reboot' `
                -Title 'Pending system reboot' `
                -Status 'OK' `
                -Current 'No pending reboot' `
                -Target 'No pending reboot' `
                -Detail 'No pending system reboots detected.' `
                -Risk 'low' `
                -NeedsReboot $false `
                -NeedsAdmin $false `
                -DefaultApply $false `
                -Commands @() `
                -Undo $null))
        }
    } catch {
        $items.Add((New-SRPrepItem `
            -Id 'sys_reboot' `
            -Section 'reboot' `
            -Title 'Pending system reboot' `
            -Status 'ERROR' `
            -Current 'check failed' `
            -Target 'No pending reboot' `
            -Detail ("Reboot check failed: $($_.Exception.Message)") `
            -Risk 'low' `
            -NeedsReboot $false `
            -NeedsAdmin $false `
            -DefaultApply $false `
            -Commands @() `
            -Undo $null))
    }

    # =============================================================================================
    # 8. sys_wu_pause (section 'updates')
    # =============================================================================================
    if ($Log) { & $Log "Checking Windows Update pause state..." }
    try {
        $uxPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        $uxProps = $null
        try {
            $uxProps = Get-ItemProperty -Path $uxPath -ErrorAction SilentlyContinue
        } catch { }

        $valExpiry = if ($uxProps -and $uxProps.PauseUpdatesExpiryTime) { [string]$uxProps.PauseUpdatesExpiryTime } else { '' }
        $valStartTime = if ($uxProps -and $uxProps.PauseUpdatesStartTime) { [string]$uxProps.PauseUpdatesStartTime } else { '' }
        $valFeatStart = if ($uxProps -and $uxProps.PauseFeatureUpdatesStartTime) { [string]$uxProps.PauseFeatureUpdatesStartTime } else { '' }
        $valFeatEnd = if ($uxProps -and $uxProps.PauseFeatureUpdatesEndTime) { [string]$uxProps.PauseFeatureUpdatesEndTime } else { '' }
        $valQualStart = if ($uxProps -and $uxProps.PauseQualityUpdatesStartTime) { [string]$uxProps.PauseQualityUpdatesStartTime } else { '' }
        $valQualEnd = if ($uxProps -and $uxProps.PauseQualityUpdatesEndTime) { [string]$uxProps.PauseQualityUpdatesEndTime } else { '' }

        $expiryDate = $null
        if ($valExpiry -ne '') {
            try {
                $expiryDate = [DateTime]::Parse($valExpiry, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
            } catch { }
        }

        $nowUtc = [DateTime]::UtcNow
        $thresholdDate = $nowUtc.AddDays($pauseDays - 1)
        $isAlreadyPaused = ($null -ne $expiryDate -and $expiryDate -ge $thresholdDate)

        if ($isAlreadyPaused) {
            $items.Add((New-SRPrepItem `
                -Id 'sys_wu_pause' `
                -Section 'updates' `
                -Title 'Pause Windows Update' `
                -Status 'OK' `
                -Current ("Paused until $valExpiry") `
                -Target ("Paused for at least $pauseDays days") `
                -Detail ("Windows Update is already paused until $valExpiry.") `
                -Risk 'low' `
                -NeedsReboot $false `
                -NeedsAdmin $false `
                -DefaultApply $false `
                -Commands @() `
                -Undo $null))
        } else {
            $targetStartTimeStr = Format-SRPauseTime $nowUtc
            $targetEndTimeStr = Format-SRPauseTime ($nowUtc.AddDays($pauseDays))

            $pauseCommands = @(
                "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseUpdatesStartTime' -Value '$targetStartTimeStr'",
                "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseUpdatesExpiryTime' -Value '$targetEndTimeStr'",
                "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseFeatureUpdatesStartTime' -Value '$targetStartTimeStr'",
                "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseFeatureUpdatesEndTime' -Value '$targetEndTimeStr'",
                "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseQualityUpdatesStartTime' -Value '$targetStartTimeStr'",
                "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseQualityUpdatesEndTime' -Value '$targetEndTimeStr'"
            )

            $pauseUndo = [pscustomobject]@{
                PauseUpdatesStartTime        = if ($valStartTime -ne '') { $valStartTime } else { 'absent' }
                PauseUpdatesExpiryTime       = if ($valExpiry -ne '') { $valExpiry } else { 'absent' }
                PauseFeatureUpdatesStartTime = if ($valFeatStart -ne '') { $valFeatStart } else { 'absent' }
                PauseFeatureUpdatesEndTime   = if ($valFeatEnd -ne '') { $valFeatEnd } else { 'absent' }
                PauseQualityUpdatesStartTime = if ($valQualStart -ne '') { $valQualStart } else { 'absent' }
                PauseQualityUpdatesEndTime   = if ($valQualEnd -ne '') { $valQualEnd } else { 'absent' }
            }

            $currentStatusStr = if ($valExpiry -ne '') { "Paused until $valExpiry" } else { 'Not paused' }

            $items.Add((New-SRPrepItem `
                -Id 'sys_wu_pause' `
                -Section 'updates' `
                -Title 'Pause Windows Update' `
                -Status 'CHANGE' `
                -Current $currentStatusStr `
                -Target ("Pause for $pauseDays days (until $targetEndTimeStr)") `
                -Detail ("Pause Windows Update for $pauseDays days to prevent downloads and reboots during tests and the show.") `
                -Risk 'low' `
                -NeedsReboot $false `
                -NeedsAdmin $true `
                -DefaultApply $true `
                -Commands $pauseCommands `
                -Undo $pauseUndo))
        }
    } catch {
        $items.Add((New-SRPrepItem `
            -Id 'sys_wu_pause' `
            -Section 'updates' `
            -Title 'Pause Windows Update' `
            -Status 'ERROR' `
            -Current 'check failed' `
            -Target 'Pause Windows Update' `
            -Detail ("Windows Update pause check failed: $($_.Exception.Message)") `
            -Risk 'low' `
            -NeedsReboot $false `
            -NeedsAdmin $false `
            -DefaultApply $false `
            -Commands @() `
            -Undo $null))
    }

    return ,$items.ToArray()
}

# -------------------------------------------------------------------------------------------------
# Helper: Save Undo Entry to BackupDir\system-undo.json
# -------------------------------------------------------------------------------------------------
function Save-SRPrepSystemUndoEntry {
    param(
        [string]$BackupDir,
        [string]$ItemId,
        [string]$Section,
        $UndoData
    )

    if ([string]::IsNullOrEmpty($BackupDir)) { return }
    try {
        if (-not (Test-Path $BackupDir)) {
            $null = New-Item -ItemType Directory -Path $BackupDir -Force -ErrorAction SilentlyContinue
        }

        $undoFile = Join-Path $BackupDir 'system-undo.json'
        $entries = [System.Collections.Generic.List[object]]::new()

        if (Test-Path $undoFile) {
            try {
                $raw = Get-Content -Path $undoFile -Raw -Encoding ASCII -ErrorAction SilentlyContinue
                if ($raw) {
                    $parsed = ConvertFrom-Json $raw -ErrorAction SilentlyContinue
                    if ($parsed -is [System.Collections.IEnumerable]) {
                        foreach ($p in $parsed) { $entries.Add($p) }
                    } elseif ($null -ne $parsed) {
                        $entries.Add($parsed)
                    }
                }
            } catch { }
        }

        # Replace existing entry for same ItemId or add new
        $existingIdx = -1
        for ($i = 0; $i -lt $entries.Count; $i++) {
            if ($entries[$i].id -eq $ItemId) {
                $existingIdx = $i
                break
            }
        }

        $newEntry = [pscustomobject]@{
            id        = [string]$ItemId
            section   = [string]$Section
            undo      = $UndoData
            timestamp = [DateTime]::UtcNow.ToString('o')
        }

        if ($existingIdx -ge 0) {
            $entries[$existingIdx] = $newEntry
        } else {
            $entries.Add($newEntry)
        }

        $json = ConvertTo-Json -InputObject @($entries) -Depth 10
        Set-Content -Path $undoFile -Value $json -Encoding ASCII -Force -ErrorAction SilentlyContinue
    } catch { }
}

# -------------------------------------------------------------------------------------------------
# Invoke-SRPrepEditionSwitch
# -------------------------------------------------------------------------------------------------
function Invoke-SRPrepEditionSwitch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Item,

        [Parameter(Mandatory = $false)]
        [string]$BackupDir = '',

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [scriptblock]$Log
    )

    if ($null -eq $Item) { return $null }

    # Extract product key from item commands: "changepk.exe /ProductKey <key>"
    $key = ''
    if ($Item.commands) {
        foreach ($c in $Item.commands) {
            if ($c -match '(?i)/ProductKey\s+([A-Z0-9-]+)') {
                $key = $matches[1].Trim()
                break
            }
        }
    }
    if ([string]::IsNullOrEmpty($key)) {
        $key = $script:GENERIC_KEY_HOME
    }

    # ---------------------------------------------------------------------------------------------
    # DRYRUN: only prints "DRYRUN: changepk.exe /ProductKey <key>" and returns SKIPPED
    # ---------------------------------------------------------------------------------------------
    if ($DryRun) {
        $dryCmd = "changepk.exe /ProductKey $key"
        if ($Log) {
            & $Log "DRYRUN: $dryCmd"
        } else {
            Write-Host "DRYRUN: $dryCmd"
        }

        return (New-SRPrepItem `
            -Id $Item.id `
            -Section $Item.section `
            -Title $Item.title `
            -Status 'SKIPPED' `
            -Current $Item.current `
            -Target $Item.target `
            -Detail 'dry run' `
            -Risk $Item.risk `
            -NeedsReboot $Item.needs_reboot `
            -NeedsAdmin $Item.needs_admin `
            -DefaultApply $Item.default_apply `
            -Commands $Item.commands `
            -Undo $Item.undo)
    }

    # ---------------------------------------------------------------------------------------------
    # REAL SWITCH PATH
    # ---------------------------------------------------------------------------------------------
    # 1. Record before state in backup folder: backup\sys_edition.json
    $origEdition = Get-SRPrepEditionId
    if (-not [string]::IsNullOrEmpty($BackupDir)) {
        try {
            if (-not (Test-Path $BackupDir)) {
                $null = New-Item -ItemType Directory -Path $BackupDir -Force -ErrorAction SilentlyContinue
            }
            $hasOem = $false
            try {
                $lic = Get-CimInstance SoftwareLicensingService -ErrorAction SilentlyContinue
                if ($lic -and -not [string]::IsNullOrEmpty($lic.OA3xOriginalProductKey)) {
                    $hasOem = $true
                }
            } catch { }

            $backupData = [ordered]@{
                id                  = 'sys_edition'
                original_edition_id = $origEdition
                has_oem_key         = [bool]$hasOem
                timestamp           = [DateTime]::UtcNow.ToString('o')
            }
            $json = ConvertTo-Json -InputObject $backupData -Depth 5
            Set-Content -Path (Join-Path $BackupDir 'sys_edition.json') -Value $json -Encoding ASCII -Force -ErrorAction SilentlyContinue
        } catch { }
    }

    # 2. Print notification and wait for Enter
    $msg = "Switching Windows edition now. The PC may restart by itself. After the restart, run Run-Prep.cmd again to switch to English."
    if ($Log) { & $Log $msg }
    Write-Host $msg -ForegroundColor Yellow
    [void](Read-Host 'Press Enter to start')

    # 3. Start changepk.exe /ProductKey <key>
    $changepk = Join-Path $env:SystemRoot 'System32\changepk.exe'
    if (-not (Test-Path $changepk)) { $changepk = 'changepk.exe' }

    $exitCode = -1
    try {
        $p = Start-Process -FilePath $changepk -ArgumentList '/ProductKey', $key -Wait -PassThru
        if ($p) { $exitCode = $p.ExitCode }
    } catch {
        if ($Log) { & $Log ("changepk execution error: " + $_.Exception.Message) }
    }

    # 4. Check EditionID again
    $afterEdition = Get-SRPrepEditionId
    $isDone = ($afterEdition -ne 'CoreSingleLanguage' -and $afterEdition -ne '') -or ($exitCode -eq 0)

    $status = if ($isDone) { 'DONE' } else { 'FAILED' }
    $detail = if ($isDone) {
        'Edition switch started (Windows accepted the key). Windows finishes it and restarts by itself; then run Run-Prep.cmd again for English.'
    } else {
        "Edition switch failed (exit code $exitCode). Manual fallback: Settings > System > Activation > Change product key, enter $key"
    }

    return (New-SRPrepItem `
        -Id $Item.id `
        -Section $Item.section `
        -Title $Item.title `
        -Status $status `
        -Current $Item.current `
        -Target $Item.target `
        -Detail $detail `
        -Risk $Item.risk `
        -NeedsReboot $Item.needs_reboot `
        -NeedsAdmin $Item.needs_admin `
        -DefaultApply $Item.default_apply `
        -Commands $Item.commands `
        -Undo $Item.undo)
}

# -------------------------------------------------------------------------------------------------
# Invoke-SRPrepSystemApply
# -------------------------------------------------------------------------------------------------
function Invoke-SRPrepSystemApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Items,

        [Parameter(Mandatory = $false)]
        $Settings,

        [Parameter(Mandatory = $false)]
        [string]$BackupDir,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [scriptblock]$Log
    )

    $appliedItems = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Items) { return ,$appliedItems.ToArray() }

    $targetLang = [string](Get-SRSetting $Settings 'language' 'ui' 'en-US')
    $rawKeepInput = Get-SRSetting $Settings 'language' 'keep_input' @('ko-KR')
    $keepInput = @()
    if ($null -ne $rawKeepInput) {
        foreach ($ki in $rawKeepInput) {
            if ($null -ne $ki -and [string]$ki -ne '') { $keepInput += [string]$ki }
        }
    }
    if ($keepInput.Count -eq 0) { $keepInput = @('ko-KR') }

    foreach ($item in $Items) {
        if ($null -eq $item) { continue }

        # Only apply items with status CHANGE, or MANUAL items with start ms-settings
        $canApply = ($item.status -eq 'CHANGE') -or (
            $item.status -eq 'MANUAL' -and $item.commands -contains 'start ms-settings:regionlanguage'
        )
        if (-not $canApply) { continue }

        # -----------------------------------------------------------------------------------------
        # DRYRUN Path: Log every command with 'DRYRUN: ' prefix and return SKIPPED item
        # -----------------------------------------------------------------------------------------
        if ($DryRun) {
            if ($item.commands) {
                foreach ($cmd in $item.commands) {
                    if ($Log) { & $Log "DRYRUN: $cmd" }
                }
            }

            $appliedItems.Add((New-SRPrepItem `
                -Id $item.id `
                -Section $item.section `
                -Title $item.title `
                -Status 'SKIPPED' `
                -Current $item.current `
                -Target $item.target `
                -Detail 'dry run' `
                -Risk $item.risk `
                -NeedsReboot $item.needs_reboot `
                -NeedsAdmin $item.needs_admin `
                -DefaultApply $item.default_apply `
                -Commands $item.commands `
                -Undo $item.undo))
            continue
        }

        # -----------------------------------------------------------------------------------------
        # REAL APPLY PATH: (Guarded: only runs on actual show PCs, never without DryRun in tests)
        # -----------------------------------------------------------------------------------------
        # Write undo before changing state
        if ($item.undo -ne $null -and -not [string]::IsNullOrEmpty($BackupDir)) {
            Save-SRPrepSystemUndoEntry -BackupDir $BackupDir -ItemId $item.id -Section $item.section -UndoData $item.undo
        }

        $applySuccess = $true
        $applyDetail = 'Applied successfully.'
        $needsReboot = $item.needs_reboot

        try {
            if ($item.id -eq 'sys_language') {
                if ($item.commands -contains 'start ms-settings:regionlanguage') {
                    if ($Log) { & $Log "Opening Windows language settings..." }
                    Start-Process 'ms-settings:regionlanguage'
                    $applyDetail = 'Opened language settings for manual configuration.'
                } else {
                    # 1. Install-Language job with 30s heartbeat
                    $needsInstall = $false
                    foreach ($c in $item.commands) {
                        if ($c -match '^Install-Language') { $needsInstall = $true }
                    }

                    if ($needsInstall) {
                        if ($Log) { & $Log "Starting Install-Language for $targetLang (can take 5-30 minutes)..." }
                        $job = Start-Job -ScriptBlock {
                            param($lang)
                            Import-Module LanguagePackManagement -ErrorAction SilentlyContinue
                            Install-Language -Language $lang -CopyToSettings
                        } -ArgumentList $targetLang

                        while ($job.State -eq 'Running') {
                            $null = Wait-Job $job -Timeout 30
                            if ($job.State -eq 'Running') {
                                if ($Log) { & $Log "Installing language $targetLang... still in progress" }
                            }
                        }
                        $jobOut = Receive-Job $job
                        Remove-Job $job -Force -ErrorAction SilentlyContinue
                        if ($Log) { & $Log "Language pack installation completed." }
                    }

                    # 2. Set-SystemPreferredUILanguage
                    if ($null -ne (Get-Command Set-SystemPreferredUILanguage -ErrorAction SilentlyContinue)) {
                        Set-SystemPreferredUILanguage -Language $targetLang -ErrorAction SilentlyContinue
                    }

                    # 3. Set-WinUILanguageOverride
                    if ($null -ne (Get-Command Set-WinUILanguageOverride -ErrorAction SilentlyContinue)) {
                        Set-WinUILanguageOverride -Language $targetLang -ErrorAction SilentlyContinue
                    }

                    # 4. Set-WinUserLanguageList
                    if ($null -ne (Get-Command Set-WinUserLanguageList -ErrorAction SilentlyContinue)) {
                        $currentList = @(Get-WinUserLanguageList -ErrorAction SilentlyContinue)
                        $newList = New-WinUserLanguageList $targetLang
                        foreach ($cul in $currentList) {
                            if ($cul.LanguageTag -ne $targetLang) {
                                $newList.Add($cul)
                            }
                        }
                        foreach ($ki in $keepInput) {
                            $alreadyIn = $false
                            foreach ($nl in $newList) {
                                if ($nl.LanguageTag -eq $ki) { $alreadyIn = $true; break }
                            }
                            if (-not $alreadyIn) {
                                $newList.Add($ki)
                            }
                        }
                        Set-WinUserLanguageList -LanguageList $newList -Force -ErrorAction SilentlyContinue
                    }

                    # 5. Copy-UserInternationalSettingsToSystem
                    if ($null -ne (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue)) {
                        Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true -ErrorAction SilentlyContinue
                    }

                    $applyDetail = "Display language set to $targetLang; reboot or sign out required."
                    $needsReboot = $true
                }
            } elseif ($item.id -like 'sys_wu_drivers:*') {
                $targetUpdateId = $item.id.Substring('sys_wu_drivers:'.Length)
                if ($Log) { & $Log "Searching Windows Update for update $targetUpdateId..." }

                $wuSession = New-Object -ComObject Microsoft.Update.Session
                $wuSearcher = $wuSession.CreateUpdateSearcher()
                $searchResult = $wuSearcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")

                $targetUpdate = $null
                if ($searchResult -and $searchResult.Updates) {
                    foreach ($u in $searchResult.Updates) {
                        if ([string]$u.Identity.UpdateID -eq $targetUpdateId) {
                            $targetUpdate = $u
                            break
                        }
                    }
                }

                if ($null -eq $targetUpdate) {
                    $applySuccess = $false
                    $applyDetail = "Update $targetUpdateId not found in current Windows Update offers."
                } else {
                    $targetUpdate.AcceptEula()
                    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
                    $coll.Add($targetUpdate)

                    if ($Log) { & $Log "Downloading Windows Update driver: $($targetUpdate.Title)..." }
                    $downloader = $wuSession.CreateUpdateDownloader()
                    $downloader.Updates = $coll
                    $downloader.Download()

                    if ($Log) { & $Log "Installing Windows Update driver: $($targetUpdate.Title)..." }
                    $installer = $wuSession.CreateUpdateInstaller()
                    $installer.Updates = $coll
                    $installResult = $installer.Install()

                    $resCode = $installResult.GetUpdateResult(0).ResultCode
                    # 2 = succeeded, 3 = succeeded with errors, 4 = failed, 5 = aborted
                    if ($resCode -eq 2 -or $resCode -eq 3) {
                        $applySuccess = $true
                        $applyDetail = "Installed successfully (ResultCode $resCode)."
                    } else {
                        $applySuccess = $false
                        $applyDetail = "Installation failed with ResultCode $resCode."
                    }

                    if ($installResult.RebootRequired) {
                        $needsReboot = $true
                    }
                }
            } elseif ($item.id -eq 'sys_wu_pause') {
                $uxPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
                if (-not (Test-Path $uxPath)) {
                    $null = New-Item -Path $uxPath -Force -ErrorAction SilentlyContinue
                }

                $now = [DateTime]::UtcNow
                $startStr = Format-SRPauseTime $now
                $endStr = Format-SRPauseTime ($now.AddDays($pauseDays))

                Set-ItemProperty -Path $uxPath -Name 'PauseUpdatesStartTime' -Value $startStr -Force
                Set-ItemProperty -Path $uxPath -Name 'PauseUpdatesExpiryTime' -Value $endStr -Force
                Set-ItemProperty -Path $uxPath -Name 'PauseFeatureUpdatesStartTime' -Value $startStr -Force
                Set-ItemProperty -Path $uxPath -Name 'PauseFeatureUpdatesEndTime' -Value $endStr -Force
                Set-ItemProperty -Path $uxPath -Name 'PauseQualityUpdatesStartTime' -Value $startStr -Force
                Set-ItemProperty -Path $uxPath -Name 'PauseQualityUpdatesEndTime' -Value $endStr -Force

                $applyDetail = "Windows Update paused until $endStr ($pauseDays days)."
            }
        } catch {
            $applySuccess = $false
            $applyDetail = "Apply failed: $($_.Exception.Message)"
        }

        $appliedItems.Add((New-SRPrepItem `
            -Id $item.id `
            -Section $item.section `
            -Title $item.title `
            -Status $(if ($applySuccess) { 'DONE' } else { 'FAILED' }) `
            -Current $item.current `
            -Target $item.target `
            -Detail $applyDetail `
            -Risk $item.risk `
            -NeedsReboot $needsReboot `
            -NeedsAdmin $item.needs_admin `
            -DefaultApply $item.default_apply `
            -Commands $item.commands `
            -Undo $item.undo))
    }

    return ,$appliedItems.ToArray()
}

# -------------------------------------------------------------------------------------------------
# Undo-SRPrepSystem
# -------------------------------------------------------------------------------------------------
function Undo-SRPrepSystem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [scriptblock]$Log
    )

    $undoneItems = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrEmpty($BackupDir)) { return ,$undoneItems.ToArray() }

    # Check if backup contains sys_edition.json
    $editionBackupFile = Join-Path $BackupDir 'sys_edition.json'
    if (Test-Path $editionBackupFile) {
        $undoneItems.Add((New-SRPrepItem `
            -Id 'sys_edition' `
            -Section 'language' `
            -Title 'Windows edition' `
            -Status 'MANUAL' `
            -Current 'Windows Home/Pro (unactivated)' `
            -Target 'Windows Home Single Language (activated)' `
            -Detail "The Windows edition switch cannot be undone automatically. To get activated Windows back: buy Windows Home (or Pro) in Settings > System > Activation, or reinstall Windows 11 Home Single Language from the PC maker's recovery." `
            -Risk 'low' `
            -NeedsReboot $false `
            -NeedsAdmin $false `
            -DefaultApply $false `
            -Commands @() `
            -Undo $null))
    }

    $undoFile = Join-Path $BackupDir 'system-undo.json'
    if (-not (Test-Path $undoFile)) {
        if ($Log) { & $Log "No system-undo.json found in $BackupDir" }
        return ,$undoneItems.ToArray()
    }

    $rawEntries = @()
    try {
        $content = Get-Content -Path $undoFile -Raw -Encoding ASCII -ErrorAction SilentlyContinue
        if ($content) {
            $parsed = ConvertFrom-Json $content -ErrorAction SilentlyContinue
            if ($parsed -is [System.Collections.IEnumerable]) {
                foreach ($p in $parsed) { $rawEntries += $p }
            } elseif ($null -ne $parsed) {
                $rawEntries += $parsed
            }
        }
    } catch {
        if ($Log) { & $Log "Failed to parse $undoFile - $($_.Exception.Message)" }
        return ,$undoneItems.ToArray()
    }

    if ($rawEntries.Count -eq 0) { return ,$undoneItems.ToArray() }

    # Restore in reverse order
    $reversed = [System.Collections.Generic.List[object]]::new()
    for ($i = $rawEntries.Count - 1; $i -ge 0; $i--) {
        $reversed.Add($rawEntries[$i])
    }

    foreach ($entry in $reversed) {
        $id = [string]$entry.id
        $section = [string]$entry.section
        $undoData = $entry.undo
        $commands = [System.Collections.Generic.List[string]]::new()

        if ($id -eq 'sys_edition') {
            $alreadyHas = $false
            foreach ($u in $undoneItems) {
                if ($u.id -eq 'sys_edition') { $alreadyHas = $true; break }
            }
            if (-not $alreadyHas) {
                $undoneItems.Add((New-SRPrepItem `
                    -Id 'sys_edition' `
                    -Section 'language' `
                    -Title 'Windows edition' `
                    -Status 'MANUAL' `
                    -Current 'Windows Home/Pro (unactivated)' `
                    -Target 'Windows Home Single Language (activated)' `
                    -Detail "The Windows edition switch cannot be undone automatically. To get activated Windows back: buy Windows Home (or Pro) in Settings > System > Activation, or reinstall Windows 11 Home Single Language from the PC maker's recovery." `
                    -Risk 'low' `
                    -NeedsReboot $false `
                    -NeedsAdmin $false `
                    -DefaultApply $false `
                    -Commands @() `
                    -Undo $null))
            }
            continue
        }

        # Build human-readable restore commands
        if ($id -eq 'sys_wu_pause') {
            $props = @(
                'PauseUpdatesStartTime',
                'PauseUpdatesExpiryTime',
                'PauseFeatureUpdatesStartTime',
                'PauseFeatureUpdatesEndTime',
                'PauseQualityUpdatesStartTime',
                'PauseQualityUpdatesEndTime'
            )
            foreach ($pr in $props) {
                $val = if ($undoData.PSObject.Properties.Match($pr).Count -gt 0) { [string]$undoData.$pr } else { 'absent' }
                if ($val -eq 'absent') {
                    $commands.Add("Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name '$pr'")
                } else {
                    $commands.Add("Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name '$pr' -Value '$val'")
                }
            }
        } elseif ($id -eq 'sys_language') {
            $prevOverride = [string]$undoData.win_ui_language_override
            $prevPreferred = [string]$undoData.system_preferred_ui_language
            $prevTags = @($undoData.user_language_list_tags)

            if ($prevOverride -ne '') {
                $commands.Add("Set-WinUILanguageOverride -Language $prevOverride")
            } else {
                $commands.Add("Set-WinUILanguageOverride (reset to default)")
            }
            if ($prevTags.Count -gt 0) {
                $commands.Add("Set-WinUserLanguageList ($($prevTags -join ', ')) -Force")
            }
            if ($prevPreferred -ne '' -and $null -ne (Get-Command Set-SystemPreferredUILanguage -ErrorAction SilentlyContinue)) {
                $commands.Add("Set-SystemPreferredUILanguage -Language $prevPreferred")
            }
        } else {
            $commands.Add("Restore previous state for $id")
        }

        # -----------------------------------------------------------------------------------------
        # DRYRUN Path: Log every command with 'DRYRUN: ' and return SKIPPED
        # -----------------------------------------------------------------------------------------
        if ($DryRun) {
            foreach ($cmd in $commands) {
                if ($Log) { & $Log "DRYRUN: $cmd" }
            }

            $undoneItems.Add((New-SRPrepItem `
                -Id $id `
                -Section $section `
                -Title "Undo $id" `
                -Status 'SKIPPED' `
                -Current 'current' `
                -Target 'restored previous state' `
                -Detail 'dry run' `
                -Risk 'low' `
                -NeedsReboot ($id -eq 'sys_language') `
                -NeedsAdmin $true `
                -DefaultApply $false `
                -Commands $commands.ToArray() `
                -Undo $null))
            continue
        }

        # -----------------------------------------------------------------------------------------
        # REAL UNDO PATH: (Guarded: only runs on actual show PCs)
        # -----------------------------------------------------------------------------------------
        $undoSuccess = $true
        $undoDetail = 'Restored previous state successfully.'

        try {
            if ($id -eq 'sys_wu_pause') {
                $uxPath = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
                $props = @(
                    'PauseUpdatesStartTime',
                    'PauseUpdatesExpiryTime',
                    'PauseFeatureUpdatesStartTime',
                    'PauseFeatureUpdatesEndTime',
                    'PauseQualityUpdatesStartTime',
                    'PauseQualityUpdatesEndTime'
                )
                foreach ($pr in $props) {
                    $val = if ($undoData.PSObject.Properties.Match($pr).Count -gt 0) { [string]$undoData.$pr } else { 'absent' }
                    if ($val -eq 'absent') {
                        Remove-ItemProperty -Path $uxPath -Name $pr -ErrorAction SilentlyContinue
                    } else {
                        Set-ItemProperty -Path $uxPath -Name $pr -Value $val -Force -ErrorAction SilentlyContinue
                    }
                }
                $undoDetail = 'Restored previous Windows Update UX Settings pause state.'
            } elseif ($id -eq 'sys_language') {
                $prevOverride = [string]$undoData.win_ui_language_override
                $prevPreferred = [string]$undoData.system_preferred_ui_language
                $prevTags = @($undoData.user_language_list_tags)

                if ($prevTags.Count -gt 0 -and $null -ne (Get-Command Set-WinUserLanguageList -ErrorAction SilentlyContinue)) {
                    $restoreList = New-WinUserLanguageList $prevTags[0]
                    for ($k = 1; $k -lt $prevTags.Count; $k++) {
                        $restoreList.Add($prevTags[$k])
                    }
                    Set-WinUserLanguageList -LanguageList $restoreList -Force -ErrorAction SilentlyContinue
                }

                if ($prevOverride -ne '' -and $null -ne (Get-Command Set-WinUILanguageOverride -ErrorAction SilentlyContinue)) {
                    Set-WinUILanguageOverride -Language $prevOverride -ErrorAction SilentlyContinue
                }

                if ($prevPreferred -ne '' -and $null -ne (Get-Command Set-SystemPreferredUILanguage -ErrorAction SilentlyContinue)) {
                    Set-SystemPreferredUILanguage -Language $prevPreferred -ErrorAction SilentlyContinue
                }

                if ($null -ne (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue)) {
                    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true -ErrorAction SilentlyContinue
                }

                $undoDetail = 'Restored previous Windows display language and language list.'
            }
        } catch {
            $undoSuccess = $false
            $undoDetail = "Undo failed: $($_.Exception.Message)"
        }

        $undoneItems.Add((New-SRPrepItem `
            -Id $id `
            -Section $section `
            -Title "Undo $id" `
            -Status $(if ($undoSuccess) { 'DONE' } else { 'FAILED' }) `
            -Current 'modified' `
            -Target 'restored' `
            -Detail $undoDetail `
            -Risk 'low' `
            -NeedsReboot ($id -eq 'sys_language') `
            -NeedsAdmin $true `
            -DefaultApply $false `
            -Commands $commands.ToArray() `
            -Undo $null))
    }

    return ,$undoneItems.ToArray()
}
