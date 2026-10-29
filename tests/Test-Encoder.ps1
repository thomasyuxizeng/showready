# ShowReady - tests\Test-Encoder.ps1
# Plain PowerShell assertions (no Pester) for the encoder-probe parsing and the sender-test helpers in
# lib\LoadTest.ps1 (SRLT_ProbeErrorLines, SRLT_DriverRequired, SRLT_CleanLine, SRLT_ParseProgress, SRLT_Pct).
# -Live also runs a short real Invoke-SRSenderTest with bin\ffmpeg.exe (about 40 s).
# Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-Encoder.ps1 [-Live]
# Exit code 0 = all assertions passed, 1 = at least one failed. Pure ASCII, works on Windows PowerShell 5.1 and pwsh.
param([switch]$Live)

$ErrorActionPreference = 'Continue'
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kit = Split-Path -Parent $testsDir
$ltPath = Join-Path $kit 'lib\LoadTest.ps1'
$script:nPass = 0
$script:nFail = 0

function Assert-That {
    param([string]$Name, $Condition, [string]$Detail = '')
    if ($Condition -eq $true) {
        $script:nPass++
        Write-Host ('  PASS  ' + $Name) -ForegroundColor Green
    }
    else {
        $script:nFail++
        $d = ''
        if ($Detail -ne '') { $d = '  -> ' + $Detail }
        Write-Host ('  FAIL  ' + $Name + $d) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host 'ShowReady encoder tests' -ForegroundColor Cyan
Write-Host ('  PowerShell ' + $PSVersionTable.PSVersion.ToString()) -ForegroundColor DarkGray

# =============================================================================================
Write-Host 'a: dot-sourcing' -ForegroundColor Cyan
$dotOut = @(. $ltPath)
Assert-That 'a: dot-sourcing LoadTest.ps1 prints nothing' ($dotOut.Count -eq 0) ('output count ' + $dotOut.Count)
foreach ($fn in 'Invoke-SRLoadTest', 'Invoke-SRSenderTest', 'SRLT_ProbeErrorLines', 'SRLT_DriverRequired', 'SRLT_ParseProgress') {
    Assert-That ('a: ' + $fn + ' is defined') ($null -ne (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue))
}
$srcText = [System.IO.File]::ReadAllText($ltPath)
Assert-That 'a: LoadTest.ps1 is pure ASCII' (-not ($srcText -match '[^\x00-\x7F]'))

# =============================================================================================
Write-Host 'b: NVIDIA driver too old (sample lines from the contract)' -ForegroundColor Cyan
$nvOld = @(
    '[h264_nvenc @ 0000021c8f2e1a40] Driver does not support the required nvenc API version. Required: 13.0 Found: 12.2',
    '[h264_nvenc @ 0000021c8f2e1a40] The minimum required Nvidia driver for nvenc is 570.0 or newer',
    '[vost#0:0/h264_nvenc @ 0000016636fbfe40] [enc:h264_nvenc @ 000001663518a840] Error while opening encoder - maybe incorrect parameters such as bit_rate, rate, width or height.',
    '[vf#0:0 @ 0000016636fc1c00] Error sending frames to consumers: Function not implemented',
    '[vf#0:0 @ 0000016636fc1c00] Task finished with error code: -38 (Function not implemented)',
    '[vf#0:0 @ 0000016636fc1c00] Terminating thread with return code -38 (Function not implemented)',
    '[vost#0:0/h264_nvenc @ 0000016636fbfe40] Could not open encoder before EOF',
    '[out#0/null @ 0000016636fbf3c0] Nothing was written into output file, because at least one of its streams received no packets.',
    'Conversion failed!'
) -join "`r`n"
$lines = SRLT_ProbeErrorLines $nvOld
Assert-That 'b: result is a flat string array' ($lines -is [array] -and $lines.Count -eq 2 -and $lines[0] -is [string]) ('count ' + $lines.Count)
Assert-That 'b: first line, pointer removed' ($lines[0] -ceq '[h264_nvenc] Driver does not support the required nvenc API version. Required: 13.0 Found: 12.2') $lines[0]
Assert-That 'b: second line, pointer removed' ($lines[1] -ceq '[h264_nvenc] The minimum required Nvidia driver for nvenc is 570.0 or newer') $lines[1]
Assert-That 'b: generic aftermath lines left out' (-not (($lines -join '|') -match 'Error while opening|Conversion failed|Terminating'))
$dr = SRLT_DriverRequired $nvOld
Assert-That 'b: driver_required = 570.0 (number)' ($dr -is [double] -and $dr -eq 570.0) ([string]$dr)
Assert-That 'b: driver_required null when absent' ($null -eq (SRLT_DriverRequired 'Cannot load nvcuda.dll'))
Assert-That 'b: driver_required null for empty input' ($null -eq (SRLT_DriverRequired $null))

# =============================================================================================
Write-Host 'c: real n8.1 stderr from the dev laptop (no NVIDIA / AMD GPU)' -ForegroundColor Cyan
$nvNone = @(
    '[h264_nvenc @ 0000016636fc0840] Cannot load nvcuda.dll',
    '[vost#0:0/h264_nvenc @ 0000016636fbfe40] [enc:h264_nvenc @ 000001663518a840] Error while opening encoder - maybe incorrect parameters such as bit_rate, rate, width or height.',
    '[vf#0:0 @ 0000016636fc1c00] Error sending frames to consumers: Operation not permitted',
    '[vf#0:0 @ 0000016636fc1c00] Task finished with error code: -1 (Operation not permitted)',
    '[vf#0:0 @ 0000016636fc1c00] Terminating thread with return code -1 (Operation not permitted)',
    '[vost#0:0/h264_nvenc @ 0000016636fbfe40] Could not open encoder before EOF',
    '[out#0/null @ 0000016636fbf3c0] Nothing was written into output file, because at least one of its streams received no packets.',
    'Conversion failed!'
) -join "`n"
$l2 = SRLT_ProbeErrorLines $nvNone
Assert-That 'c: nvenc -> only "Cannot load nvcuda.dll"' ($l2.Count -eq 1 -and $l2[0] -ceq '[h264_nvenc] Cannot load nvcuda.dll') ($l2 -join ' | ')
$amf = @(
    '[AMF @ 00000130b398c5c0] DLL amfrt64.dll failed to open',
    '[h264_amf @ 00000130b38d9200] Failed to create  hardware device context (AMF) : Unknown error occurred',
    '[vost#0:0/h264_amf @ 00000130b38d8f00] [enc:h264_amf @ 00000130b38d9100] Error while opening encoder - maybe incorrect parameters such as bit_rate, rate, width or height.',
    'Conversion failed!'
) -join "`r`n"
$l3 = SRLT_ProbeErrorLines $amf
Assert-That 'c: amf -> AMF + h264_amf lines in order' ($l3.Count -eq 2 -and $l3[0] -ceq '[AMF] DLL amfrt64.dll failed to open' -and $l3[1] -ceq '[h264_amf] Failed to create  hardware device context (AMF) : Unknown error occurred') ($l3 -join ' | ')

# =============================================================================================
Write-Host 'd: preference passes, cap, duplicates' -ForegroundColor Cyan
$generic = @(
    '[vost#0:0/h264_qsv @ 0x1] [enc:h264_qsv @ 0x2] Error while opening encoder - maybe incorrect parameters such as bit_rate, rate, width or height.',
    '[in#0 @ 0000aa] Some other failure: Invalid argument',
    'Conversion failed!'
) -join "`n"
$l4 = SRLT_ProbeErrorLines $generic
Assert-That 'd: pass 2 takes a generic error line, not the aftermath' ($l4.Count -eq 1 -and $l4[0] -ceq '[in#0] Some other failure: Invalid argument') ($l4 -join ' | ')
$onlyOpen = @(
    '[vost#0:0/h264_qsv @ 0x1] [enc:h264_qsv @ 0x2] Error while opening encoder - maybe incorrect parameters such as bit_rate, rate, width or height.',
    'Conversion failed!'
) -join "`n"
$l5 = SRLT_ProbeErrorLines $onlyOpen
Assert-That 'd: pass 3 falls back to "Error while opening encoder", nested pointers removed' ($l5.Count -eq 1 -and $l5[0] -ceq '[vost#0:0/h264_qsv] [enc:h264_qsv] Error while opening encoder - maybe incorrect parameters such as bit_rate, rate, width or height.') ($l5 -join ' | ')
$many = @(
    '[h264_nvenc @ 01] line one',
    '[h264_nvenc @ 02] line one',
    '[h264_nvenc @ 03] line two',
    '[h264_nvenc @ 04] line three',
    '[h264_nvenc @ 05] line four'
) -join "`n"
$l6 = SRLT_ProbeErrorLines $many
Assert-That 'd: duplicates removed after cleaning, capped at 3' ($l6.Count -eq 3 -and $l6[0] -ceq '[h264_nvenc] line one' -and $l6[2] -ceq '[h264_nvenc] line three') ($l6 -join ' | ')
$l7 = SRLT_ProbeErrorLines ''
Assert-That 'd: empty stderr -> empty array' ($l7 -is [array] -and $l7.Count -eq 0)
$l8 = SRLT_ProbeErrorLines $null
Assert-That 'd: null stderr -> empty array' ($l8 -is [array] -and $l8.Count -eq 0)
$l9 = SRLT_ProbeErrorLines 'frame=  60 fps=0.0 q=-0.0 size=N/A time=00:00:01.00'
Assert-That 'd: harmless stderr -> empty array' ($l9.Count -eq 0)
Assert-That 'd: SRLT_CleanLine keeps lines without pointers' ((SRLT_CleanLine '  Conversion failed!  ') -ceq 'Conversion failed!')
Assert-That 'd: SRLT_CleanLine handles 0x pointers' ((SRLT_CleanLine '[h264_qsv @ 0x7ffd1234] X') -ceq '[h264_qsv] X')

# =============================================================================================
Write-Host 'e: progress parsing and percentiles' -ForegroundColor Cyan
$tmp = Join-Path $env:TEMP ('sr_test_prog_' + [guid]::NewGuid().ToString('N') + '.txt')
$blocks = New-Object System.Collections.ArrayList
$i = 0
foreach ($sp in '0.50', '0.98', '1.00', '1.01', '1.02', '0.99', '1.00') {
    $i++
    [void]$blocks.Add('frame=' + ($i * 60))
    [void]$blocks.Add('fps=' + (59 + ($i % 2)) + '.00')
    [void]$blocks.Add('out_time_us=' + ($i * 1500000))
    [void]$blocks.Add('speed=' + $sp + 'x')
    if ($i -eq 7) { [void]$blocks.Add('progress=end') } else { [void]$blocks.Add('progress=continue') }
}
[System.IO.File]::WriteAllLines($tmp, [string[]]$blocks.ToArray())
$pp = SRLT_ParseProgress -Path $tmp -SkipSeconds 5
Assert-That 'e: only blocks at >= 5 s counted (4 of 7)' ($pp.speeds.Count -eq 4 -and $pp.fps.Count -eq 4) ('speeds ' + ($pp.speeds -join ','))
Assert-That 'e: last_speed is the final block' ($pp.last_speed -eq 1.0)
Assert-That 'e: min of counted speeds = 0.99' ((SRLT_Min $pp.speeds) -eq 0.99)
$pp0 = SRLT_ParseProgress -Path $tmp -SkipSeconds 0
Assert-That 'e: SkipSeconds 0 counts all 7' ($pp0.speeds.Count -eq 7)
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
$ppm = SRLT_ParseProgress -Path (Join-Path $env:TEMP 'sr_no_such_file.txt')
Assert-That 'e: missing file -> empty, no throw' ($pp.speeds -is [array] -and $ppm.speeds.Count -eq 0 -and $null -eq $ppm.last_speed)
Assert-That 'e: SRLT_Pct p50 of 1..5 = 3' ((SRLT_Pct @(5, 1, 3, 2, 4) 0.5) -eq 3)
Assert-That 'e: SRLT_Pct p95 interpolates' ((SRLT_Pct @(10, 20, 30, 40, 50) 0.95) -eq 48)
Assert-That 'e: SRLT_Pct ignores nulls, null when empty' ((SRLT_Pct @($null, 7) 0.5) -eq 7 -and $null -eq (SRLT_Pct @($null) 0.5))

# =============================================================================================
Write-Host 'f: sender test without ffmpeg' -ForegroundColor Cyan
$cfg = [pscustomobject]@{ thresholds = [pscustomobject]@{ load_speed_min = 0.97 }; observer = [pscustomobject]@{ sender_seconds = [pscustomobject]@{ quick = 45; full = 120 } } }
$noBin = Join-Path $env:TEMP ('sr_nobin_' + [guid]::NewGuid().ToString('N'))
$st = Invoke-SRSenderTest -Config $cfg -BinDir $noBin
Assert-That 'f: no ffmpeg -> found false, stream not ok, no throw' ($st.ffmpeg.found -eq $false -and $st.stream.ok -eq $false -and $st.errors.Count -ge 1) ($st | ConvertTo-Json -Depth 4 -Compress)
Assert-That 'f: seconds default from config (45)' ($st.seconds -eq 45)
Assert-That 'f: contract fields present' ($st.codec -ceq 'speedhq' -and $st.pix_fmt -ceq 'yuv422p' -and $st.width -eq 1920 -and $st.height -eq 1080 -and $st.fps -eq 60 -and $st.note -match 'VMX')
$st2 = Invoke-SRSenderTest -Config $null -BinDir $noBin -Seconds 12
Assert-That 'f: null config and explicit seconds work' ($st2.seconds -eq 12 -and $st2.ffmpeg.found -eq $false)

# =============================================================================================
if ($Live) {
    Write-Host 'g: live sender test (bin\ffmpeg.exe, 15 s paced)' -ForegroundColor Cyan
    $lt = Invoke-SRSenderTest -Config $cfg -BinDir (Join-Path $kit 'bin') -Seconds 15 -Log { param($m) Write-Host ('    ' + $m) -ForegroundColor DarkGray }
    Assert-That 'g: ffmpeg found' ($lt.ffmpeg.found -eq $true) ([string]$lt.ffmpeg.version)
    Assert-That 'g: source clip generated' ($null -ne $lt.source -and $lt.source.file_mb -gt 0)
    Assert-That 'g: max_speed measured' ($null -ne $lt.max_speed -and $lt.max_speed -gt 0) ([string]$lt.max_speed)
    Assert-That 'g: paced speeds recorded' ($null -ne $lt.stream.speed_min) ($lt.stream | ConvertTo-Json -Compress)
    Assert-That 'g: CPU sampled' ($null -ne $lt.system -and $lt.system.samples.Count -ge 6 -and $null -ne $lt.system.cpu_p95) ('samples ' + $lt.system.samples.Count)
    Assert-That 'g: no errors' ($lt.errors.Count -eq 0) ($lt.errors -join ' | ')
    $left = @(Get-ChildItem -Path $env:TEMP -Filter 'sr_s*_*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-2) })
    Assert-That 'g: temp files cleaned up' ($left.Count -eq 0) (($left | ForEach-Object { $_.Name }) -join ',')
    Write-Host ('    max_speed ' + $lt.max_speed + ' x, speed_min ' + $lt.stream.speed_min + ', cpu_p95 ' + $lt.system.cpu_p95) -ForegroundColor DarkGray
}

# =============================================================================================
# h: output encodes get 4:2:0. Kit 1.3.1 sent the 4:2:2 source straight to h264_nvenc, which
#    only RTX 50 cards accept: an RTX 4070 Ti SUPER failed all three outputs ("Conversion failed!").
Write-Host 'h: output encodes and the probe are 4:2:0' -ForegroundColor Cyan
$ltSrc = [System.IO.File]::ReadAllText($ltPath)
$outLines = @($ltSrc -split "`n" | Where-Object { $_ -match 'role = "out-' })
Assert-That 'h: three output stream definitions' ($outLines.Count -eq 3) ('found ' + $outLines.Count)
Assert-That 'h: every output uses $outFmt' (@($outLines | Where-Object { $_ -notmatch 'args = "\$outFmt -c:v' }).Count -eq 0)
Assert-That 'h: $outFmt is yuv420p' ($ltSrc -match '\$outFmt = "-pix_fmt yuv420p"')
Assert-That 'h: encoder probe also forces yuv420p' ($ltSrc -match 'testsrc2=s=1920x1080:r=60 -t 1 -pix_fmt yuv420p -c:v')
$ffx = Join-Path $kit 'bin\ffmpeg.exe'
if ($Live -and (Test-Path $ffx)) {
    $src = Join-Path $env:TEMP ('sr_pf_' + [guid]::NewGuid().ToString('N') + '.mkv')
    try {
        $null = & $ffx -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=s=1920x1080:r=60' -t 1 -c:v speedhq -pix_fmt yuv422p $src 2>&1
        $log = @(& $ffx -hide_banner -i $src -t 1 -pix_fmt yuv420p -c:v libx264 -preset veryfast -f null - 2>&1 | ForEach-Object { [string]$_ })
        Assert-That 'h: live: 4:2:2 SpeedHQ source encodes as 4:2:0' (@($log | Where-Object { $_ -match 'libx264 @.*4:2:0' }).Count -eq 1) (@($log | Where-Object { $_ -match 'profile' }) -join ' ')
    }
    finally { Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue }
}

# =============================================================================================
Write-Host ''
$col = 'Green'
if ($script:nFail -gt 0) { $col = 'Red' }
Write-Host ('Encoder tests: ' + $script:nPass + ' passed, ' + $script:nFail + ' failed') -ForegroundColor $col
if ($script:nFail -gt 0) { exit 1 }
exit 0
