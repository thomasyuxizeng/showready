# ShowReady - tests\Test-AudioNames.ps1
# Plain PowerShell assertions (no Pester) for lib\AudioNames.ps1 and Rename-AudioDevices.ps1.
# Offline by default; -Live also lists this PC's audio devices (read only, renames nothing).
# Exit code 0 = all assertions passed, 1 = at least one failed. Pure ASCII, works on Windows PowerShell 5.1 and pwsh.

param([switch]$Live)

$ErrorActionPreference = 'Continue'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($testsDir)) { $testsDir = $PSScriptRoot }
$kit = Split-Path -Parent $testsDir

$script:nPass = 0
$script:nFail = 0

function Assert-That {
    param([string]$Name, $Condition, [string]$Detail = '')
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

# Korean from code points, so this file stays ASCII
function K { param([int[]]$Codes) return (-join [char[]]$Codes) }
$SPK = K 0xC2A4, 0xD53C, 0xCEE4                  # speakers
$HP  = K 0xD5E4, 0xB4DC, 0xD3F0                  # headphones
$HS  = K 0xD5E4, 0xB4DC, 0xC14B                  # headset
$MIC = K 0xB9C8, 0xC774, 0xD06C                  # microphone
$ARR = K 0xBC30, 0xC5F4                          # array
$DIG = K 0xB514, 0xC9C0, 0xD138                  # digital
$AUD = K 0xC624, 0xB514, 0xC624                  # audio
$STM = (K 0xC2A4, 0xD14C, 0xB808, 0xC624) + ' ' + (K 0xBBF9, 0xC2A4)   # stereo mix
$UNK = K 0xAC00, 0xB098, 0xB2E4                  # not a device word

Write-Host ''
Write-Host 'ShowReady audio name tests' -ForegroundColor Cyan
Write-Host ('  PowerShell ' + $PSVersionTable.PSVersion.ToString()) -ForegroundColor DarkGray

# =============================================================================================
Write-Host 'a: source files' -ForegroundColor Cyan
foreach ($f in 'lib\AudioNames.ps1', 'Rename-AudioDevices.ps1', 'Rename-AudioDevices.cmd', 'tests\Test-AudioNames.ps1') {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $kit $f))
    $non = @($bytes | Where-Object { $_ -gt 127 }).Count
    Assert-That ('a: ' + $f + ' is pure ASCII') ($non -eq 0) ($non.ToString() + ' non-ASCII bytes')
}
$dotOut = @(. (Join-Path $kit 'lib\AudioNames.ps1'))
Assert-That 'a: dot-sourcing AudioNames.ps1 prints nothing' ($dotOut.Count -eq 0) ('output count ' + $dotOut.Count)
$dotOut2 = @(. (Join-Path $kit 'lib\AudioNames.ps1'))
Assert-That 'a: dot-sourcing twice is fine (type added once)' ($dotOut2.Count -eq 0)
foreach ($fn in 'Get-SRAudioNameMap', 'ConvertTo-SREnglishAudioName', 'Test-SRHangul', 'Get-SRNewFullName', 'Get-SRAudioEndpoints', 'Set-SRAudioEndpointName') {
    Assert-That ('a: ' + $fn + ' defined') ($null -ne (Get-Command $fn -ErrorAction SilentlyContinue))
}
$errs = $null
[void][System.Management.Automation.PSParser]::Tokenize([System.IO.File]::ReadAllText((Join-Path $kit 'Rename-AudioDevices.ps1')), [ref]$errs)
Assert-That 'a: Rename-AudioDevices.ps1 parses' (@($errs).Count -eq 0) (@($errs | ForEach-Object { $_.Message }) -join '; ')

# =============================================================================================
Write-Host 'b: Korean -> English' -ForegroundColor Cyan
$map = Get-SRAudioNameMap
$cases = @(
    @($SPK, 'Speakers'),
    @($HP, 'Headphones'),
    @($MIC, 'Microphone'),
    @(($HS + ' ' + $MIC), 'Headset Microphone'),
    @(($MIC + ' ' + $ARR), 'Microphone Array'),
    @(($SPK + '/' + $HP), 'Speakers/Headphones'),
    @(($DIG + ' ' + $AUD + '(S/PDIF)'), 'Digital Audio(S/PDIF)'),
    @($STM, 'Stereo Mix'),
    @(('2- ' + $SPK), '2- Speakers'),
    @(($SPK + '  2'), 'Speakers 2')
)
foreach ($c in $cases) {
    $got = ConvertTo-SREnglishAudioName -Name $c[0] -Map $map
    Assert-That ('b: -> ' + $c[1]) ($got -eq $c[1]) ('got [' + $got + ']')
}
Assert-That 'b: English name -> empty (nothing to do)' ((ConvertTo-SREnglishAudioName -Name 'Speakers' -Map $map) -eq '')
Assert-That 'b: empty name -> empty' ((ConvertTo-SREnglishAudioName -Name '' -Map $map) -eq '')
Assert-That 'b: unknown Korean -> null' ($null -eq (ConvertTo-SREnglishAudioName -Name $UNK -Map $map))
Assert-That 'b: known + unknown Korean -> null (never half-translated)' ($null -eq (ConvertTo-SREnglishAudioName -Name ($SPK + ' ' + $UNK) -Map $map))
Assert-That 'b: map works without -Map' ((ConvertTo-SREnglishAudioName -Name $SPK) -eq 'Speakers')
$mapOk = $true
foreach ($m in $map) { if (-not (Test-SRHangul ([string]$m.ko)) -or (Test-SRHangul ([string]$m.en))) { $mapOk = $false } }
Assert-That 'b: every map entry is Korean -> non-Korean' $mapOk
$longestFirst = $true
for ($i = 1; $i -lt $map.Count; $i++) {
    for ($j = 0; $j -lt $i; $j++) { if (([string]$map[$i].ko).Contains([string]$map[$j].ko)) { $longestFirst = $false } }
}
Assert-That 'b: phrases come before the words inside them' $longestFirst
Assert-That 'b: Test-SRHangul on English is false' (-not (Test-SRHangul 'Speakers (Realtek(R) Audio)'))

# =============================================================================================
Write-Host 'c: full names' -ForegroundColor Cyan
$full = $SPK + ' (Blackmagic DeckLink Quad 2 (1) Audio)'
Assert-That 'c: bracket part kept' ((Get-SRNewFullName $full $SPK 'Speakers') -eq 'Speakers (Blackmagic DeckLink Quad 2 (1) Audio)')
Assert-That 'c: no full name -> new name' ((Get-SRNewFullName '' $SPK 'Speakers') -eq 'Speakers')
Assert-That 'c: full name not starting with the name -> unchanged' ((Get-SRNewFullName 'Other (X)' $SPK 'Speakers') -eq 'Other (X)')

# =============================================================================================
if ($Live) {
    Write-Host 'd: live (read only)' -ForegroundColor Cyan
    $all = $null
    try { $all = Get-SRAudioEndpoints } catch { }
    Assert-That 'd: lists audio devices' ($null -ne $all -and $all.Count -gt 0) 'none listed'
    $shapeOk = $true
    foreach ($e in @($all)) {
        if ([string]::IsNullOrEmpty([string]$e.Id) -or @('output', 'input') -notcontains [string]$e.Flow -or @(1, 2, 8) -notcontains [int]$e.State) { $shapeOk = $false }
    }
    Assert-That 'd: each has an id, a flow and state active/disabled/unplugged' $shapeOk
    $plan = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kit 'Rename-AudioDevices.ps1') -PlanOnly 2>&1
    Assert-That 'd: -PlanOnly runs and exits 0' ($LASTEXITCODE -eq 0) ('exit ' + $LASTEXITCODE)
    Assert-That 'd: -PlanOnly reports a device count' ((@($plan) -join "`n") -match 'Found \d+ audio devices')
}

Write-Host ''
$color = 'Green'
if ($script:nFail -gt 0) { $color = 'Red' }
Write-Host ('Audio name tests: ' + $script:nPass + ' passed, ' + $script:nFail + ' failed') -ForegroundColor $color
if ($script:nFail -gt 0) { exit 1 }
exit 0
