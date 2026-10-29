<#
.SYNOPSIS
    Simulates show processing: 2 incoming 1080p60 feeds decoded + 3 simultaneous
    1080p60 H.264 encodes, real-time paced, while sampling CPU and GPU performance.
.DESCRIPTION
    Compliant with ShowReady CONTRACT.md. Windows PowerShell 5.1 and pwsh 7 compatible.
    Locale-independent (Korean Windows safe). Foreground execution with thorough cleanup.
    Also defines Invoke-SRSenderTest (observer PCs: one 1080p60 SpeedHQ encode) and SRLT_* helpers.
#>

# ---------------------------------------------------------------------------------------------
# Encoder probe stderr -> the few lines that explain the failure (see CONTRACT.md, encoders.tested)
# ---------------------------------------------------------------------------------------------
# "[h264_nvenc @ 0000021c8f2e1a40] X" -> "[h264_nvenc] X" (every bracket on the line).
function SRLT_CleanLine {
    param([string]$Line)
    return ([regex]::Replace([string]$Line, '\[([^\]\[@]+?) @ (0x)?[0-9A-Fa-f]+\]', '[$1]')).Trim()
}

function SRLT_ProbeErrorLines {
    param([string]$Stderr)
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrEmpty($Stderr)) { return , $out.ToArray() }
    $lines = @($Stderr -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $ctxRx = '^\[(h264_nvenc|hevc_nvenc|av1_nvenc|h264_amf|hevc_amf|av1_amf|AMF|h264_qsv|hevc_qsv|av1_qsv) @'
    $keyRx = '(?i)nvenc API version|minimum required Nvidia driver|runtime version|Cannot load|failed to open'
    $genRx = '(?i)cannot|could not|error|failed|invalid'
    # ffmpeg's generic aftermath of any encoder failure: only used when nothing better is there.
    $afterRx = '(?i)Error while opening encoder|Could not open encoder before EOF|Error sending frames|Task finished with error|Terminating thread|Nothing was written into output|Conversion failed|Error opening output'
    foreach ($pass in 1, 2, 3) {
        foreach ($l in $lines) {
            if ($out.Count -ge 3) { break }
            $take = $false
            if ($pass -eq 1) { $take = ($l -match $ctxRx -or $l -match $keyRx) }
            elseif ($pass -eq 2) { $take = ($l -match $genRx -and $l -notmatch $afterRx) }
            else { $take = ($l -match '(?i)Error while opening encoder') }
            if (-not $take) { continue }
            $c = SRLT_CleanLine $l
            if ($c -ne '' -and -not $out.Contains($c)) { [void]$out.Add($c) }
        }
        if ($out.Count -gt 0) { break }
    }
    return , $out.ToArray()
}

# "The minimum required Nvidia driver for nvenc is 570.0 or newer" -> 570.0 (number), else $null.
function SRLT_DriverRequired {
    param([string]$Stderr)
    $m = [regex]::Match([string]$Stderr, 'minimum required Nvidia driver for nvenc is (\S+)')
    if (-not $m.Success) { return $null }
    $v = 0.0
    if ([double]::TryParse($m.Groups[1].Value.TrimEnd('.', ','), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $v }
    return $null
}

function Invoke-SRLoadTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        $Config,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$BinDir,

        [Parameter(Mandatory = $false)]
        [int]$Seconds = 0,

        [Parameter(Mandatory = $false)]
        [scriptblock]$Log
    )

    $errors = @()
    $noteText = "SpeedHQ is the codec inside full-bandwidth NDI; OMT's VMX is the same class but not identical. vMix/OBS compositing load is NOT included $([char]0x2014) treat results as a lower bound."

    function Write-SRLog([string]$Message) {
        if ($Log) {
            try { & $Log $Message } catch {}
        }
    }

    function Get-SRPercentile($Values, [double]$Percentile) {
        $nonNull = @($Values | Where-Object { $null -ne $_ })
        if ($nonNull.Count -eq 0) { return $null }
        $sorted = @($nonNull | Sort-Object)
        $n = $sorted.Count
        if ($n -eq 1) { return [double]$sorted[0] }
        $index = ($n - 1) * $Percentile
        $lower = [int][math]::Floor($index)
        $upper = [int][math]::Ceiling($index)
        if ($lower -eq $upper) {
            return [math]::Round([double]$sorted[$lower], 2)
        }
        $fraction = $index - $lower
        $res = [double]$sorted[$lower] + $fraction * ([double]$sorted[$upper] - [double]$sorted[$lower])
        return [math]::Round($res, 2)
    }

    function Get-SRMin($Values) {
        $nonNull = @($Values | Where-Object { $null -ne $_ })
        if ($nonNull.Count -eq 0) { return $null }
        return [math]::Round([double]($nonNull | Measure-Object -Minimum).Minimum, 2)
    }

    function Get-SRMax($Values) {
        $nonNull = @($Values | Where-Object { $null -ne $_ })
        if ($nonNull.Count -eq 0) { return $null }
        return [math]::Round([double]($nonNull | Measure-Object -Maximum).Maximum, 2)
    }

    # Resolve run length
    if ($Seconds -le 0) {
        if ($Config -and $Config.loadtest -and $Config.loadtest.seconds -and $Config.loadtest.seconds.quick) {
            $Seconds = [int]$Config.loadtest.seconds.quick
        } else {
            $Seconds = 45
        }
    }

    # Tracking for cleanup in finally block
    $activeProcesses = @()
    $tempFiles = @()

    try {
        # 1. Locate ffmpeg
        Write-SRLog "Checking ffmpeg binary..."
        $ffmpegPath = $null
        if ($BinDir) {
            $candidate = Join-Path $BinDir "ffmpeg.exe"
            if (Test-Path $candidate) {
                $ffmpegPath = (Get-Item $candidate).FullName
            }
        }

        if (-not $ffmpegPath) {
            $errMsg = "ffmpeg.exe not found in BinDir: $BinDir"
            $errors += $errMsg
            Write-SRLog $errMsg
            return [pscustomobject]@{
                ffmpeg   = [pscustomobject]@{ found = $false; path = $null; version = $null }
                encoders = $null
                source   = $null
                seconds  = $Seconds
                streams  = @()
                system   = $null
                note     = $noteText
                errors   = $errors
            }
        }

        # Query ffmpeg version
        $ffVersion = $null
        try {
            $pinfo = New-Object System.Diagnostics.ProcessStartInfo
            $pinfo.FileName = $ffmpegPath
            $pinfo.Arguments = "-version"
            $pinfo.WorkingDirectory = $env:TEMP
            $pinfo.UseShellExecute = $false
            $pinfo.RedirectStandardOutput = $true
            $pinfo.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($pinfo)
            $stdout = $proc.StandardOutput.ReadToEnd()
            [void]$proc.WaitForExit(5000)
            if ($stdout -match '(?m)^ffmpeg version\s+([^\s]+)') {
                $ffVersion = $Matches[1]
            }
        } catch {
            $errors += "Failed to query ffmpeg version: $($_.Exception.Message)"
        }

        $ffmpegObj = [pscustomobject]@{
            found   = $true
            path    = $ffmpegPath
            version = $ffVersion
        }
        Write-SRLog "Found ffmpeg ($ffVersion) at $ffmpegPath"

        # 2. Encoders: list available and test candidates
        Write-SRLog "Querying available ffmpeg encoders..."
        $availableEncoders = @()
        try {
            $pinfo = New-Object System.Diagnostics.ProcessStartInfo
            $pinfo.FileName = $ffmpegPath
            $pinfo.Arguments = "-hide_banner -encoders"
            $pinfo.WorkingDirectory = $env:TEMP
            $pinfo.UseShellExecute = $false
            $pinfo.RedirectStandardOutput = $true
            $pinfo.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($pinfo)
            $stdout = $proc.StandardOutput.ReadToEnd()
            [void]$proc.WaitForExit(10000)
            foreach ($line in ($stdout -split "`r?`n")) {
                if ($line -match '^\s*V\S*\s+(\S+).*(?:codec h264|H\.264)') {
                    $availableEncoders += $Matches[1]
                }
            }
        } catch {
            $errors += "Failed to list encoders: $($_.Exception.Message)"
        }

        # Test candidate encoders in order: h264_nvenc, h264_amf, h264_qsv, libx264
        $candidateEncoders = @(
            [pscustomobject]@{ name = 'h264_nvenc'; preset = '-preset p4 -tune ll' },
            [pscustomobject]@{ name = 'h264_amf';   preset = '-quality speed' },
            [pscustomobject]@{ name = 'h264_qsv';   preset = '-preset veryfast' },
            [pscustomobject]@{ name = 'libx264';    preset = '-preset veryfast' }
        )

        $testedEncoders = @()
        $chosenEncoder = $null
        $chosenPreset = $null

        foreach ($cand in $candidateEncoders) {
            Write-SRLog "Testing encoder candidate '$($cand.name)' (1 s encode)..."
            $candOk = $false
            $candErr = $null
            $candLines = @()
            $candDriver = $null
            try {
                $pinfo = New-Object System.Diagnostics.ProcessStartInfo
                $pinfo.FileName = $ffmpegPath
                $pinfo.Arguments = "-hide_banner -y -f lavfi -i testsrc2=s=1920x1080:r=60 -t 1 -pix_fmt yuv420p -c:v $($cand.name) $($cand.preset) -f null -"
                $pinfo.WorkingDirectory = $env:TEMP
                $pinfo.UseShellExecute = $false
                $pinfo.RedirectStandardError = $true
                $pinfo.RedirectStandardOutput = $true
                $pinfo.CreateNoWindow = $true

                $proc = [System.Diagnostics.Process]::Start($pinfo)
                $stderr = $proc.StandardError.ReadToEnd()
                $exited = $proc.WaitForExit(20000)
                if (-not $exited) {
                    try { $proc.Kill() } catch {}
                    $candErr = "Timeout after 20s"
                } elseif ($proc.ExitCode -eq 0) {
                    $candOk = $true
                } else {
                    $candLines = SRLT_ProbeErrorLines $stderr
                    $candDriver = SRLT_DriverRequired $stderr
                    if ($candLines.Count -gt 0) {
                        $candErr = $candLines[0]
                    } else {
                        $candErr = "Exit code $($proc.ExitCode)"
                    }
                }
            } catch {
                $candErr = $_.Exception.Message
            }

            $testedEncoders += [pscustomobject]@{
                name            = $cand.name
                ok              = $candOk
                error           = $candErr
                error_lines     = @($candLines)
                driver_required = $candDriver
            }

            if ($candOk -and -not $chosenEncoder) {
                $chosenEncoder = $cand.name
                $chosenPreset = $cand.preset
                Write-SRLog "Encoder '$chosenEncoder' passed test and is chosen."
                break
            }
        }

        $encodersObj = [pscustomobject]@{
            available = $availableEncoders
            tested    = $testedEncoders
            chosen    = $chosenEncoder
        }

        if (-not $chosenEncoder) {
            $errMsg = "No working H.264 encoder passed testing."
            $errors += $errMsg
            Write-SRLog $errMsg
        }

        # 3. Generate 4 s SpeedHQ test source video
        $sourceObj = $null
        $srcFile = Join-Path $env:TEMP "sr_src_$([System.Guid]::NewGuid().ToString('N')).mkv"
        $tempFiles += $srcFile

        try {
            Write-SRLog "Generating 4 s SpeedHQ test source video..."
            $pinfo = New-Object System.Diagnostics.ProcessStartInfo
            $pinfo.FileName = $ffmpegPath
            $pinfo.Arguments = "-hide_banner -y -f lavfi -i ""testsrc2=s=1920x1080:r=60,noise=alls=12:allf=t"" -t 4 -c:v speedhq -pix_fmt yuv422p `"$srcFile`""
            $pinfo.WorkingDirectory = $env:TEMP
            $pinfo.UseShellExecute = $false
            $pinfo.RedirectStandardError = $true
            $pinfo.RedirectStandardOutput = $true
            $pinfo.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($pinfo)
            $stderr = $proc.StandardError.ReadToEnd()
            [void]$proc.WaitForExit(30000)

            if ($proc.ExitCode -eq 0 -and (Test-Path $srcFile)) {
                $srcLen = (Get-Item $srcFile).Length
                $sourceObj = [pscustomobject]@{
                    codec   = "speedhq"
                    pix_fmt = "yuv422p"
                    width   = 1920
                    height  = 1080
                    fps     = 60
                    seconds = 4
                    file_mb = [math]::Round([double]$srcLen / 1MB, 2)
                }
                Write-SRLog "Generated source video: $($sourceObj.file_mb) MB"
            } else {
                $errMsg = "Failed to generate SpeedHQ source video (exit code $($proc.ExitCode))"
                $errors += $errMsg
                Write-SRLog $errMsg
            }
        } catch {
            $errMsg = "Error generating source video: $($_.Exception.Message)"
            $errors += $errMsg
            Write-SRLog $errMsg
        }

        # 4. Configure the 5 streams
        $srtKbps = 10000
        $ytKbps  = 17000
        $twKbps  = 6000
        if ($Config -and $Config.show -and $Config.show.outputs) {
            foreach ($out in $Config.show.outputs) {
                if ($out.id -eq 'srt' -and $out.video_kbps) { $srtKbps = [int]$out.video_kbps }
                if ($out.id -eq 'youtube' -and $out.video_kbps) { $ytKbps = [int]$out.video_kbps }
                if ($out.id -eq 'twitch' -and $out.video_kbps) { $twKbps = [int]$out.video_kbps }
            }
        }

        $encToUse = if ($chosenEncoder) { $chosenEncoder } else { "libx264" }
        $presetToUse = if ($chosenPreset) { $chosenPreset } else { "-preset veryfast" }

        # The source is 4:2:2 SpeedHQ, like NDI. Without -pix_fmt, ffmpeg 8 hands 4:2:2 (nv16) to
        # h264_nvenc, which only RTX 50 cards can encode: every older NVIDIA GPU fails to open the
        # encoder. Streaming outputs are 4:2:0 anyway, as vMix/OBS send them.
        $outFmt = "-pix_fmt yuv420p"
        $streamsDef = @(
            [pscustomobject]@{ role = "in-1";        kind = "decode"; codec = "speedhq";  target_kbps = $null;   args = "-f null -" },
            [pscustomobject]@{ role = "in-2";        kind = "decode"; codec = "speedhq";  target_kbps = $null;   args = "-f null -" },
            [pscustomobject]@{ role = "out-srt";     kind = "encode"; codec = $encToUse;  target_kbps = $srtKbps; args = "$outFmt -c:v $encToUse $presetToUse -b:v $($srtKbps)k -maxrate $($srtKbps)k -bufsize $(2 * $srtKbps)k -g 120 -f null -" },
            [pscustomobject]@{ role = "out-youtube"; kind = "encode"; codec = $encToUse;  target_kbps = $ytKbps;  args = "$outFmt -c:v $encToUse $presetToUse -b:v $($ytKbps)k -maxrate $($ytKbps)k -bufsize $(2 * $ytKbps)k -g 120 -f null -" },
            [pscustomobject]@{ role = "out-twitch";  kind = "encode"; codec = $encToUse;  target_kbps = $twKbps;  args = "$outFmt -c:v $encToUse $presetToUse -b:v $($twKbps)k -maxrate $($twKbps)k -bufsize $(2 * $twKbps)k -g 120 -f null -" }
        )

        # 5. Launch all 5 streams concurrently
        Write-SRLog "Starting 5 concurrent streams for $Seconds seconds..."
        $runningStreams = @()
        foreach ($sd in $streamsDef) {
            $progFile = Join-Path $env:TEMP "sr_prog_$($sd.role)_$([System.Guid]::NewGuid().ToString('N')).txt"
            $errFile  = Join-Path $env:TEMP "sr_err_$($sd.role)_$([System.Guid]::NewGuid().ToString('N')).txt"
            $tempFiles += $progFile
            $tempFiles += $errFile

            $cmdArgs = "-hide_banner -nostats -re -stream_loop -1 -i `"$srcFile`" -t $Seconds $($sd.args) -progress `"$progFile`""

            $p = Start-Process -FilePath $ffmpegPath -ArgumentList $cmdArgs -WorkingDirectory $env:TEMP -RedirectStandardError $errFile -PassThru -NoNewWindow
            $null = $p.Handle # Preserve native handle in PS 5.1

            $activeProcesses += $p
            $runningStreams += [pscustomobject]@{
                Def      = $sd
                Process  = $p
                ProgFile = $progFile
                ErrFile  = $errFile
            }
        }

        # 6. Sample CIM performance counters once per second
        $samples = @()
        $loopWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $sampleIndex = 0

        while ($loopWatch.Elapsed.TotalSeconds -lt $Seconds) {
            $sampleStart = [System.Diagnostics.Stopwatch]::StartNew()
            $sampleTime = [int][math]::Floor($loopWatch.Elapsed.TotalSeconds)

            # CPU & Processor Performance
            $cpuVal = $null
            $perfVal = $null
            try {
                $procInfo = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Property PercentProcessorUtility, PercentProcessorTime, PercentProcessorPerformance, Name -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq '_Total' -or $_.Name -like '*_Total' } | Select-Object -First 1
                if ($procInfo) {
                    if ($null -ne $procInfo.PercentProcessorUtility) {
                        $cpuVal = [double]$procInfo.PercentProcessorUtility
                    } elseif ($null -ne $procInfo.PercentProcessorTime) {
                        $cpuVal = [double]$procInfo.PercentProcessorTime
                    }
                    if ($null -ne $procInfo.PercentProcessorPerformance) {
                        $perfVal = [double]$procInfo.PercentProcessorPerformance
                    }
                }
            } catch {}

            # Memory Committed Percentage
            $memVal = $null
            try {
                $memInfo = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -Property PercentCommittedBytesInUse -ErrorAction SilentlyContinue
                if ($memInfo -and $null -ne $memInfo.PercentCommittedBytesInUse) {
                    $memVal = [double]$memInfo.PercentCommittedBytesInUse
                }
            } catch {}

            # GPU Engine Counters
            $gpuEncVal = $null
            $gpuDecVal = $null
            $gpu3dVal  = $null
            try {
                $gpuInsts = Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -Property Name, UtilizationPercentage -ErrorAction SilentlyContinue
                if ($gpuInsts) {
                    $sumEnc = 0.0
                    $sumDec = 0.0
                    $sum3d  = 0.0
                    foreach ($inst in $gpuInsts) {
                        $n = $inst.Name
                        if ($n -like '*engtype_VideoEncode*') {
                            $sumEnc += [double]$inst.UtilizationPercentage
                        } elseif ($n -like '*engtype_VideoDecode*') {
                            $sumDec += [double]$inst.UtilizationPercentage
                        } elseif ($n -like '*engtype_3D*') {
                            $sum3d += [double]$inst.UtilizationPercentage
                        }
                    }
                    if ($sumEnc -gt 100.0) { $sumEnc = 100.0 }
                    if ($sumDec -gt 100.0) { $sumDec = 100.0 }
                    if ($sum3d  -gt 100.0) { $sum3d  = 100.0 }
                    $gpuEncVal = [math]::Round($sumEnc, 1)
                    $gpuDecVal = [math]::Round($sumDec, 1)
                    $gpu3dVal  = [math]::Round($sum3d, 1)
                }
            } catch {}

            $samples += [pscustomobject]@{
                t       = $sampleTime
                cpu     = if ($null -ne $cpuVal) { [math]::Round($cpuVal, 1) } else { $null }
                perf    = if ($null -ne $perfVal) { [math]::Round($perfVal, 1) } else { $null }
                gpu_enc = $gpuEncVal
                gpu_dec = $gpuDecVal
                gpu_3d  = $gpu3dVal
                mem     = if ($null -ne $memVal) { [math]::Round($memVal, 1) } else { $null }
            }
            $sampleIndex++

            if ($sampleIndex % 5 -eq 0 -or $sampleIndex -eq 1) {
                Write-SRLog "Load test running: $($sampleTime)s / ${Seconds}s (CPU: $cpuVal%, GPU Enc: $gpuEncVal%, Mem: $memVal%)"
            }

            $elapsedMs = $sampleStart.ElapsedMilliseconds
            $sleepMs = 1000 - $elapsedMs
            if ($sleepMs -gt 0 -and $loopWatch.Elapsed.TotalSeconds -lt $Seconds) {
                Start-Sleep -Milliseconds $sleepMs
            }
        }

        # 7. Wait for processes to exit (grace period up to 15s)
        Write-SRLog "Waiting for streams to finish..."
        foreach ($rs in $runningStreams) {
            if (-not $rs.Process.HasExited) {
                [void]$rs.Process.WaitForExit(15000)
            }
            if (-not $rs.Process.HasExited) {
                try { $rs.Process.Kill() } catch {}
            }
            $rs.Process.Refresh()
        }

        # 8. Parse progress files and determine results for each stream
        $speedMinThreshold = 0.97
        if ($Config -and $Config.thresholds -and $Config.thresholds.load_speed_min) {
            $speedMinThreshold = [double]$Config.thresholds.load_speed_min
        }

        $streamsResult = @()
        foreach ($rs in $runningStreams) {
            $def = $rs.Def
            $speeds = @()
            $fpsList = @()

            if (Test-Path $rs.ProgFile) {
                $progLines = Get-Content $rs.ProgFile
                $currentBlock = @{}
                foreach ($line in $progLines) {
                    if ($line -match '^(\w+)=(.*)$') {
                        $k = $Matches[1]
                        $v = $Matches[2].Trim()
                        $currentBlock[$k] = $v
                        if ($k -eq 'progress') {
                            $isPast5s = $false
                            $outUs = 0
                            if ($currentBlock.ContainsKey('out_time_us') -and [long]::TryParse($currentBlock['out_time_us'], [ref]$outUs)) {
                                if ($outUs -ge 5000000) { $isPast5s = $true }
                            } elseif ($currentBlock.ContainsKey('out_time')) {
                                $ts = [timespan]::Zero
                                if ([timespan]::TryParse($currentBlock['out_time'], [ref]$ts)) {
                                    if ($ts.TotalSeconds -ge 5.0) { $isPast5s = $true }
                                }
                            }

                            if ($isPast5s) {
                                if ($currentBlock.ContainsKey('speed') -and $currentBlock['speed'] -match '^([\d.]+)x$') {
                                    $speeds += [double]$Matches[1]
                                }
                                if ($currentBlock.ContainsKey('fps') -and $currentBlock['fps'] -match '^([\d.]+)$') {
                                    $fpsList += [double]$Matches[1]
                                }
                            }
                            $currentBlock = @{}
                        }
                    }
                }
            }

            $speedMin = Get-SRMin $speeds
            $speedP50 = Get-SRPercentile $speeds 0.50
            $fpsP50   = Get-SRPercentile $fpsList 0.50

            $exitCode = $rs.Process.ExitCode
            $streamOk = ($exitCode -eq 0) -and ($null -ne $speedMin) -and ($speedMin -ge $speedMinThreshold)
            $streamError = $null

            if (-not $streamOk) {
                if ($exitCode -ne 0) {
                    $errSnippet = $null
                    if (Test-Path $rs.ErrFile) {
                        $errLines = @(Get-Content $rs.ErrFile | Where-Object { $_ -match '(?i)(cannot|could not|error|failed|invalid|not supported)' })
                        # the first lines name the cause; the last is usually just "Conversion failed!"
                        $specific = @($errLines | Where-Object { $_ -notmatch '(?i)Conversion failed|Terminating thread|Task finished with error|Nothing was written' } | Select-Object -First 2)
                        if ($specific.Count -gt 0) { $errSnippet = (@($specific | ForEach-Object { $_.Trim() }) -join ' | ') }
                        elseif ($errLines.Count -gt 0) { $errSnippet = $errLines[-1].Trim() }
                    }
                    if ($errSnippet) {
                        $streamError = "Process failed (exit code $exitCode): $errSnippet"
                    } else {
                        $streamError = "Process failed with exit code $exitCode"
                    }
                } elseif ($null -eq $speedMin) {
                    $streamError = "No speed samples recorded after 5s"
                } elseif ($speedMin -lt $speedMinThreshold) {
                    $streamError = "speed_min $speedMin < threshold $speedMinThreshold"
                }
            }

            $streamsResult += [pscustomobject]@{
                role        = $def.role
                kind        = $def.kind
                codec       = $def.codec
                target_kbps = $def.target_kbps
                speed_min   = $speedMin
                speed_p50   = $speedP50
                fps_p50     = $fpsP50
                ok          = $streamOk
                error       = $streamError
            }
            Write-SRLog "Stream $($def.role) ($($def.kind)): speed_min=$speedMin, speed_p50=$speedP50, fps_p50=$fpsP50, ok=$streamOk"
        }

        # 9. Compute system aggregate statistics
        $cpuSamples    = @($samples | ForEach-Object { $_.cpu })
        $perfSamples   = @($samples | ForEach-Object { $_.perf })
        $gpuEncSamples = @($samples | ForEach-Object { $_.gpu_enc })
        $gpuDecSamples = @($samples | ForEach-Object { $_.gpu_dec })
        $gpu3dSamples  = @($samples | ForEach-Object { $_.gpu_3d })
        $memSamples    = @($samples | ForEach-Object { $_.mem })

        $perfStart = if ($samples.Count -gt 0 -and $null -ne $samples[0].perf) { [double]$samples[0].perf } else { $null }

        $systemObj = [pscustomobject]@{
            cpu_p50          = Get-SRPercentile $cpuSamples 0.50
            cpu_p95          = Get-SRPercentile $cpuSamples 0.95
            cpu_max          = Get-SRMax $cpuSamples
            perf_start       = $perfStart
            perf_min         = Get-SRMin $perfSamples
            perf_p50         = Get-SRPercentile $perfSamples 0.50
            gpu_enc_p95      = Get-SRPercentile $gpuEncSamples 0.95
            gpu_dec_p95      = Get-SRPercentile $gpuDecSamples 0.95
            gpu_3d_p95       = Get-SRPercentile $gpu3dSamples 0.95
            mem_used_pct_max = Get-SRMax $memSamples
            samples          = $samples
        }

        return [pscustomobject]@{
            ffmpeg   = $ffmpegObj
            encoders = $encodersObj
            source   = $sourceObj
            seconds  = $Seconds
            streams  = $streamsResult
            system   = $systemObj
            note     = $noteText
            errors   = $errors
        }
    }
    catch {
        $errors += "Unexpected error during load test: $($_.Exception.Message)"
        return [pscustomobject]@{
            ffmpeg   = $ffmpegObj
            encoders = $encodersObj
            source   = $sourceObj
            seconds  = $Seconds
            streams  = @()
            system   = $null
            note     = $noteText
            errors   = $errors
        }
    }
    finally {
        # Kill any processes that are still running
        if ($activeProcesses) {
            foreach ($p in $activeProcesses) {
                if ($p -and -not $p.HasExited) {
                    try { $p.Kill() } catch {}
                }
            }
        }
        # Clean up all created temp files
        if ($tempFiles) {
            foreach ($f in $tempFiles) {
                if ($f -and (Test-Path $f)) {
                    try { Remove-Item $f -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Observer PCs: one 1080p60 SpeedHQ encode (the job an NDI sender does). See CONTRACT.md.
# ---------------------------------------------------------------------------------------------
function SRLT_Log {
    param($Log, [string]$Message)
    if ($Log) { try { & $Log $Message } catch {} }
}

function SRLT_Pct {
    param($Values, [double]$Percentile)
    $nn = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($nn.Count -eq 0) { return $null }
    if ($nn.Count -eq 1) { return [math]::Round($nn[0], 2) }
    $idx = ($nn.Count - 1) * $Percentile
    $lo = [int][math]::Floor($idx)
    $hi = [int][math]::Ceiling($idx)
    return [math]::Round($nn[$lo] + ($idx - $lo) * ($nn[$hi] - $nn[$lo]), 2)
}

function SRLT_Min {
    param($Values)
    $nn = @($Values | Where-Object { $null -ne $_ })
    if ($nn.Count -eq 0) { return $null }
    return [math]::Round([double]($nn | Measure-Object -Minimum).Minimum, 2)
}

function SRLT_Max {
    param($Values)
    $nn = @($Values | Where-Object { $null -ne $_ })
    if ($nn.Count -eq 0) { return $null }
    return [math]::Round([double]($nn | Measure-Object -Maximum).Maximum, 2)
}

# One CIM sample: cpu, perf, gpu_3d, mem (each number or $null). Same counters as Invoke-SRLoadTest.
function SRLT_CimSample {
    param([int]$T)
    $cpu = $null; $perf = $null; $g3d = $null; $mem = $null
    try {
        $pinf = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -Property Name, PercentProcessorUtility, PercentProcessorTime, PercentProcessorPerformance -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($pinf) {
            if ($null -ne $pinf.PercentProcessorUtility) { $cpu = [double]$pinf.PercentProcessorUtility }
            elseif ($null -ne $pinf.PercentProcessorTime) { $cpu = [double]$pinf.PercentProcessorTime }
            if ($null -ne $pinf.PercentProcessorPerformance) { $perf = [double]$pinf.PercentProcessorPerformance }
        }
    } catch {}
    try {
        $minf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -Property PercentCommittedBytesInUse -ErrorAction SilentlyContinue
        if ($minf -and $null -ne $minf.PercentCommittedBytesInUse) { $mem = [double]$minf.PercentCommittedBytesInUse }
    } catch {}
    try {
        $ginf = Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -Filter "Name LIKE '%engtype_3D%'" -Property Name, UtilizationPercentage -ErrorAction SilentlyContinue
        if ($ginf) {
            $sum = 0.0
            foreach ($g in $ginf) { if ($g.Name -like '*engtype_3D*') { $sum += [double]$g.UtilizationPercentage } }
            if ($sum -gt 100.0) { $sum = 100.0 }
            $g3d = [math]::Round($sum, 1)
        }
    } catch {}
    $o = [ordered]@{ t = $T; cpu = $null; perf = $null; gpu_3d = $g3d; mem = $null }
    if ($null -ne $cpu) { $o.cpu = [math]::Round($cpu, 1) }
    if ($null -ne $perf) { $o.perf = [math]::Round($perf, 1) }
    if ($null -ne $mem) { $o.mem = [math]::Round($mem, 1) }
    return [pscustomobject]$o
}

# ffmpeg -progress file -> speeds/fps after $SkipSeconds of output, plus the speed of the last block.
function SRLT_ParseProgress {
    param([string]$Path, [double]$SkipSeconds = 5.0)
    $speeds = New-Object System.Collections.ArrayList
    $fpsL = New-Object System.Collections.ArrayList
    $last = $null
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        $blk = @{}
        foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
            if ($line -notmatch '^(\w+)=(.*)$') { continue }
            $k = $Matches[1]
            $blk[$k] = $Matches[2].Trim()
            if ($k -ne 'progress') { continue }
            $sp = $null
            $spm = [regex]::Match([string]$blk['speed'], '^([\d.]+)x$')
            if ($spm.Success) { $sp = [double]::Parse($spm.Groups[1].Value, $inv) }
            if ($null -ne $sp) { $last = $sp }
            $us = [long]0
            $past = $false
            if ($blk.ContainsKey('out_time_us') -and [long]::TryParse([string]$blk['out_time_us'], [ref]$us)) { $past = ($us -ge [long]($SkipSeconds * 1000000)) }
            if ($past) {
                if ($null -ne $sp) { [void]$speeds.Add($sp) }
                $fm = [regex]::Match([string]$blk['fps'], '^([\d.]+)$')
                if ($fm.Success) { [void]$fpsL.Add([double]::Parse($fm.Groups[1].Value, $inv)) }
            }
            $blk = @{}
        }
    }
    return [pscustomobject]@{ speeds = $speeds.ToArray(); fps = $fpsL.ToArray(); last_speed = $last }
}

function Invoke-SRSenderTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)] [AllowNull()] $Config,
        [Parameter(Mandatory = $true, Position = 1)] [string]$BinDir,
        [int]$Seconds = 0,
        [scriptblock]$Log
    )
    $errs = New-Object System.Collections.ArrayList
    $note = "SpeedHQ is the codec full NDI uses. OMT's VMX codec has no ffmpeg encoder, so SpeedHQ stands in for both. ffmpeg's SpeedHQ encoder is less optimised than the NDI SDK's, so this errs on the safe side."
    if ($Seconds -le 0) {
        $Seconds = 45
        try {
            $q = $Config.observer.sender_seconds.quick
            if ($null -ne $q -and [int]$q -gt 0) { $Seconds = [int]$q }
        } catch {}
    }
    $speedThr = 0.97
    try { if ($null -ne $Config.thresholds.load_speed_min) { $speedThr = [double]$Config.thresholds.load_speed_min } } catch {}

    $res = [ordered]@{
        ffmpeg    = [pscustomobject]@{ found = $false; path = $null; version = $null }
        codec     = 'speedhq'
        pix_fmt   = 'yuv422p'
        width     = 1920
        height    = 1080
        fps       = 60
        seconds   = $Seconds
        source    = $null
        max_speed = $null
        stream    = [pscustomobject]@{ speed_min = $null; speed_p50 = $null; fps_p50 = $null; ok = $false; error = 'Not run' }
        system    = $null
        note      = $note
        errors    = $null
    }
    $procs = New-Object System.Collections.ArrayList
    $temps = New-Object System.Collections.ArrayList
    try {
        $ff = $null
        if ($BinDir) {
            $cand = Join-Path $BinDir 'ffmpeg.exe'
            if (Test-Path -LiteralPath $cand) { $ff = (Get-Item -LiteralPath $cand).FullName }
        }
        if (-not $ff) {
            [void]$errs.Add("ffmpeg.exe not found in BinDir: $BinDir")
            $res.stream.error = 'ffmpeg.exe not found'
        } else {
            $ver = $null
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $ff
                $psi.Arguments = '-version'
                $psi.WorkingDirectory = $env:TEMP
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.CreateNoWindow = $true
                $vp = [System.Diagnostics.Process]::Start($psi)
                $vo = $vp.StandardOutput.ReadToEnd()
                [void]$vp.WaitForExit(5000)
                $vm = [regex]::Match($vo, '(?m)^ffmpeg version\s+(\S+)')
                if ($vm.Success) { $ver = $vm.Groups[1].Value }
            } catch { [void]$errs.Add("Failed to query ffmpeg version: $($_.Exception.Message)") }
            $res.ffmpeg = [pscustomobject]@{ found = $true; path = $ff; version = $ver }
            SRLT_Log $Log "Found ffmpeg ($ver)"

            # Source clip (same as the load test)
            $src = Join-Path $env:TEMP ("sr_src_" + [guid]::NewGuid().ToString('N') + ".mkv")
            [void]$temps.Add($src)
            SRLT_Log $Log 'Generating the 4 s SpeedHQ test clip...'
            $srcOk = $false
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $ff
                $psi.Arguments = "-hide_banner -y -f lavfi -i ""testsrc2=s=1920x1080:r=60,noise=alls=12:allf=t"" -t 4 -c:v speedhq -pix_fmt yuv422p ""$src"""
                $psi.WorkingDirectory = $env:TEMP
                $psi.UseShellExecute = $false
                $psi.RedirectStandardError = $true
                $psi.RedirectStandardOutput = $true
                $psi.CreateNoWindow = $true
                $gp = [System.Diagnostics.Process]::Start($psi)
                $gerr = $gp.StandardError.ReadToEnd()
                if (-not $gp.WaitForExit(60000)) { try { $gp.Kill() } catch {} }
                if ($gp.HasExited -and $gp.ExitCode -eq 0 -and (Test-Path -LiteralPath $src)) {
                    $srcOk = $true
                    $res.source = [pscustomobject]@{ codec = 'speedhq'; pix_fmt = 'yuv422p'; width = 1920; height = 1080; fps = 60; seconds = 4
                        file_mb = [math]::Round([double](Get-Item -LiteralPath $src).Length / 1MB, 2) }
                } else {
                    $gl = SRLT_ProbeErrorLines $gerr
                    $gmsg = 'Failed to generate the SpeedHQ test clip'
                    if ($gl.Count -gt 0) { $gmsg = $gmsg + ': ' + $gl[0] }
                    [void]$errs.Add($gmsg)
                    $res.stream.error = $gmsg
                }
            } catch {
                [void]$errs.Add("Error generating the test clip: $($_.Exception.Message)")
                $res.stream.error = 'Could not generate the test clip'
            }

            if ($srcOk) {
                # 1. Unpaced 10 s encode: how much faster than real time can this PC encode one feed?
                SRLT_Log $Log 'Measuring top SpeedHQ encode speed (10 s, unpaced)...'
                $mprog = Join-Path $env:TEMP ("sr_sprog_" + [guid]::NewGuid().ToString('N') + ".txt")
                $merr = Join-Path $env:TEMP ("sr_serr_" + [guid]::NewGuid().ToString('N') + ".txt")
                [void]$temps.Add($mprog)
                [void]$temps.Add($merr)
                try {
                    $margs = "-hide_banner -nostats -stream_loop -1 -i ""$src"" -t 10 -c:v speedhq -pix_fmt yuv422p -f null - -progress ""$mprog"""
                    $mp = Start-Process -FilePath $ff -ArgumentList $margs -WorkingDirectory $env:TEMP -RedirectStandardError $merr -PassThru -WindowStyle Hidden
                    $null = $mp.Handle
                    [void]$procs.Add($mp)
                    if (-not $mp.WaitForExit(60000)) {
                        try { $mp.Kill() } catch {}
                        [void]$errs.Add('Unpaced encode did not finish within 60 s')
                    }
                    $mp.Refresh()
                    $mpp = SRLT_ParseProgress -Path $mprog -SkipSeconds 0
                    if ($mp.HasExited -and $mp.ExitCode -eq 0 -and $null -ne $mpp.last_speed) {
                        $res.max_speed = [math]::Round([double]$mpp.last_speed, 2)
                    } elseif ($mp.HasExited -and $mp.ExitCode -ne 0) {
                        [void]$errs.Add("Unpaced encode failed (exit code $($mp.ExitCode))")
                    }
                } catch { [void]$errs.Add("Unpaced encode error: $($_.Exception.Message)") }
                if ($null -ne $res.max_speed) { SRLT_Log $Log "Top speed: $($res.max_speed) x real time" }

                # 2. Paced run, in real time like a live sender, while sampling the PC
                SRLT_Log $Log "Encoding one 1080p60 SpeedHQ feed in real time for $Seconds s..."
                $prog = Join-Path $env:TEMP ("sr_sprog_" + [guid]::NewGuid().ToString('N') + ".txt")
                $perr = Join-Path $env:TEMP ("sr_serr_" + [guid]::NewGuid().ToString('N') + ".txt")
                [void]$temps.Add($prog)
                [void]$temps.Add($perr)
                $pargs = "-hide_banner -nostats -re -stream_loop -1 -i ""$src"" -t $Seconds -c:v speedhq -pix_fmt yuv422p -f null - -progress ""$prog"""
                $pp = Start-Process -FilePath $ff -ArgumentList $pargs -WorkingDirectory $env:TEMP -RedirectStandardError $perr -PassThru -WindowStyle Hidden
                $null = $pp.Handle
                [void]$procs.Add($pp)

                $samples = New-Object System.Collections.ArrayList
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $nSamp = 0
                while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
                    $t0 = $sw.ElapsedMilliseconds
                    $smp = SRLT_CimSample -T ([int][math]::Floor($sw.Elapsed.TotalSeconds))
                    [void]$samples.Add($smp)
                    $nSamp++
                    if ($nSamp -eq 1 -or $nSamp % 10 -eq 0) { SRLT_Log $Log "Sender test: $($smp.t) s / $Seconds s (CPU $($smp.cpu) %)" }
                    if ($pp.HasExited) { break }
                    $waitMs = 1000 - ($sw.ElapsedMilliseconds - $t0)
                    if ($waitMs -gt 0 -and $sw.Elapsed.TotalSeconds -lt $Seconds) { Start-Sleep -Milliseconds $waitMs }
                }
                if (-not $pp.HasExited) { [void]$pp.WaitForExit(15000) }
                if (-not $pp.HasExited) {
                    try { $pp.Kill() } catch {}
                    [void]$errs.Add('The paced encode did not stop on time and was stopped')
                }
                $pp.Refresh()

                $pr = SRLT_ParseProgress -Path $prog -SkipSeconds 5
                $smin = SRLT_Min $pr.speeds
                $sp50 = SRLT_Pct $pr.speeds 0.5
                $fp50 = SRLT_Pct $pr.fps 0.5
                $code = $null
                if ($pp.HasExited) { $code = $pp.ExitCode }
                $ok = ($code -eq 0 -and $null -ne $smin -and $smin -ge $speedThr)
                $serr = $null
                if (-not $ok) {
                    if ($code -ne 0) {
                        $etext = ''
                        try { $etext = [string](Get-Content -LiteralPath $perr -Raw -ErrorAction SilentlyContinue) } catch {}
                        $el = SRLT_ProbeErrorLines $etext
                        if ($el.Count -gt 0) { $serr = "Process failed (exit code $code): $($el[0])" } else { $serr = "Process failed with exit code $code" }
                    } elseif ($null -eq $smin) {
                        $serr = 'No speed samples recorded after 5s'
                    } else {
                        $serr = "speed_min $smin < threshold $speedThr"
                    }
                }
                $res.stream = [pscustomobject]@{ speed_min = $smin; speed_p50 = $sp50; fps_p50 = $fp50; ok = $ok; error = $serr }
                SRLT_Log $Log "Sender encode: speed_min=$smin, speed_p50=$sp50, fps_p50=$fp50, ok=$ok"

                $sa = $samples.ToArray()
                $cpuV = @($sa | ForEach-Object { $_.cpu })
                $perfV = @($sa | ForEach-Object { $_.perf })
                $pstart = $null
                if ($sa.Count -gt 0 -and $null -ne $sa[0].perf) { $pstart = [double]$sa[0].perf }
                $res.system = [pscustomobject]@{
                    cpu_p50          = SRLT_Pct $cpuV 0.5
                    cpu_p95          = SRLT_Pct $cpuV 0.95
                    cpu_max          = SRLT_Max $cpuV
                    perf_start       = $pstart
                    perf_min         = SRLT_Min $perfV
                    perf_p50         = SRLT_Pct $perfV 0.5
                    gpu_3d_p95       = SRLT_Pct @($sa | ForEach-Object { $_.gpu_3d }) 0.95
                    mem_used_pct_max = SRLT_Max @($sa | ForEach-Object { $_.mem })
                    samples          = $sa
                }
            }
        }
    } catch {
        [void]$errs.Add("Unexpected error during sender test: $($_.Exception.Message)")
    } finally {
        foreach ($proc in $procs) { try { if ($proc -and -not $proc.HasExited) { $proc.Kill() } } catch {} }
        foreach ($tf in $temps) { try { if ($tf -and (Test-Path -LiteralPath $tf)) { Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue } } catch {} }
    }
    $res.errors = $errs.ToArray()
    return [pscustomobject]$res
}
