# vision-router.ps1 - Single entry point for ds-vision-skill.
# ASCII-only source. Pass non-ASCII user prompts through -Prompt.

param(
    [Parameter(Mandatory = $true)][string]$Path,
    [ValidateSet('auto','reason','ocr','document')]
    [string]$Intent = 'auto',
    [string]$Prompt = 'Analyze this visual input and return the useful content.',
    [switch]$Complex,
    [switch]$AccurateOcr,
    [switch]$Json,
    [switch]$NoCache
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Fail([int]$Code, [string]$Message) {
    [Console]::Error.WriteLine("ERROR: $Message")
    exit $Code
}

function Get-EnvValue([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'User') }
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'Machine') }
    return $v
}

function Test-PortOpen([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(500) -and $client.Connected) { return $true }
    } catch { }
    finally { $client.Close() }
    return $false
}

function Run-Step([string]$Name, [scriptblock]$Command) {
    # A terminating error in a child script must not abort the fallback chain.
    $output = @()
    $code = 1
    try {
        $output = & $Command 2>&1
        $code = $LASTEXITCODE
    } catch {
        $output = @("ERROR: $($_.Exception.Message)")
    }
    return [pscustomobject]@{
        name = $Name
        code = $code
        text = (($output | Out-String).Trim())
    }
}

function Quote-PowerShellSingle([string]$Value) {
    return "'" + ($Value -replace "'", "''") + "'"
}

function Run-Race([string]$ScriptPath, [array]$ChannelNames, [string]$InputPath, [string]$UserPrompt, [bool]$DisableCache) {
    $workers = @()
    foreach ($name in $ChannelNames) {
        $outFile = Join-Path $env:TEMP ("ds-vision-race-{0}-{1}.out" -f $PID, ([guid]::NewGuid().ToString('N')))
        $errFile = Join-Path $env:TEMP ("ds-vision-race-{0}-{1}.err" -f $PID, ([guid]::NewGuid().ToString('N')))
        $quotedScript = Quote-PowerShellSingle $ScriptPath
        $quotedPath = Quote-PowerShellSingle $InputPath
        $quotedPrompt = Quote-PowerShellSingle $UserPrompt
        $quotedChannel = Quote-PowerShellSingle $name
        $cacheSwitch = if ($DisableCache) { ' -NoCache' } else { '' }
        $cmd = @"
`$ErrorActionPreference = 'Continue'
& $quotedScript -ImagePath $quotedPath -Prompt $quotedPrompt -Json$cacheSwitch -Channel $quotedChannel
exit `$LASTEXITCODE
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru
        $workers += [pscustomobject]@{
            name = $name
            process = $proc
            stdout = $outFile
            stderr = $errFile
        }
    }

    $pending = @($workers)
    $results = @()
    try {
        while ($pending.Count -gt 0) {
            $finished = @($pending | Where-Object { $_.process.HasExited })
            if ($finished.Count -eq 0) {
                Start-Sleep -Milliseconds 100
                continue
            }
            foreach ($worker in @($finished)) {
                $worker.process.WaitForExit()
                $stdout = if (Test-Path -LiteralPath $worker.stdout) { (Get-Content -Raw -LiteralPath $worker.stdout) } else { '' }
                $stderr = if (Test-Path -LiteralPath $worker.stderr) { (Get-Content -Raw -LiteralPath $worker.stderr) } else { '' }
                $code = $worker.process.ExitCode
                $stdoutText = $stdout.Trim()
                $jsonSuccess = $false
                if ($stdoutText) {
                    try {
                        $parsed = $stdoutText | ConvertFrom-Json
                        $jsonSuccess = [bool]$parsed.result
                    } catch { }
                }
                if ($jsonSuccess -and $null -eq $code) { $code = 0 }
                $text = if ($jsonSuccess -or $code -eq 0) { $stdoutText } else { (($stdout + "`n" + $stderr).Trim()) }
                $result = [pscustomobject]@{
                    name = $worker.name
                    code = $code
                    text = $text
                }
                $results += $result
                if ($jsonSuccess -or $result.code -eq 0) {
                    foreach ($other in @($pending | Where-Object { $_.process.Id -ne $worker.process.Id })) {
                        if (-not $other.process.HasExited) {
                            Stop-Process -Id $other.process.Id -Force -ErrorAction SilentlyContinue
                        }
                    }
                    return [pscustomobject]@{
                        success = $true
                        winner  = $result
                        attempts = $results
                    }
                }
                $pending = @($pending | Where-Object { $_.process.Id -ne $worker.process.Id })
            }
        }
    } finally {
        foreach ($worker in $workers) {
            if ($worker.process -and -not $worker.process.HasExited) {
                Stop-Process -Id $worker.process.Id -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $worker.stdout -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $worker.stderr -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]@{
        success = $false
        winner  = $null
        attempts = $results
    }
}

function Emit-RaceWinner([object]$Race, [array]$StartedChannels) {
    if (-not $Json) {
        Write-Output $Race.winner.text
        return
    }

    try {
        $payload = $Race.winner.text | ConvertFrom-Json
        if (-not $payload.metadata) {
            $payload | Add-Member -NotePropertyName metadata -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $raceMeta = [ordered]@{
            mode               = 'first-success'
            winner             = $Race.winner.name
            started_channels   = @($StartedChannels)
            completed_attempts = @($Race.attempts | ForEach-Object { [ordered]@{ name = $_.name; code = $_.code } })
        }
        $payload.metadata | Add-Member -NotePropertyName race -NotePropertyValue $raceMeta -Force
        Write-Output ($payload | ConvertTo-Json -Depth 10)
    } catch {
        Write-Output $Race.winner.text
    }
}

function Emit-FallbackResult([string]$TaskType, [string]$Tool, [string]$Result, [array]$Attempts) {
    if ($Json) {
        [ordered]@{
            task_type  = $TaskType
            tool_used  = $Tool
            confidence = 'medium'
            result     = $Result
            metadata   = [ordered]@{
                routed_by = 'vision-router'
                attempts  = @($Attempts | ForEach-Object { [ordered]@{ name = $_.name; code = $_.code } })
            }
        } | ConvertTo-Json -Depth 8 | Write-Output
    } else {
        Write-Output $Result
    }
}

if (-not (Test-Path -LiteralPath $Path)) { Fail 1 "Input not found: $Path" }

$ext = [IO.Path]::GetExtension($Path).ToLower()
$documentExts = @('.pdf','.doc','.docx','.ppt','.pptx')
$imageExts = @('.png','.jpg','.jpeg','.webp','.gif','.bmp','.tif','.tiff')

if ($Intent -eq 'auto') {
    if ($ext -in $documentExts) { $Intent = 'document' }
    elseif ($ext -in $imageExts) {
        if ($Prompt -match '(?i)\bocr\b|\u6587\u5b57|\u8bc6\u522b|\u63d0\u53d6|\u7968\u636e|\u53d1\u7968|\u626b\u63cf') { $Intent = 'ocr' }
        else { $Intent = 'reason' }
    } else {
        $Intent = 'document'
    }
}

$attempts = @()
$scriptDir = $PSScriptRoot

if ($Intent -eq 'document') {
    $mineru = Join-Path $scriptDir 'mineru-extract.ps1'
    $attempts += Run-Step 'mineru flash' { & $mineru -FilePath $Path -Mode flash -Json }
    if ($attempts[-1].code -eq 0) { Write-Output $attempts[-1].text; exit 0 }
    if (Get-EnvValue 'MINERU_TOKEN') {
        $attempts += Run-Step 'mineru extract' { & $mineru -FilePath $Path -Mode extract -Json }
        if ($attempts[-1].code -eq 0) { Write-Output $attempts[-1].text; exit 0 }
    }
    if ($ext -notin $imageExts) {
        $last = if ($attempts.Count) { $attempts[-1].text } else { 'MinerU route unavailable.' }
        if ($Json) {
            [ordered]@{
                task_type  = 'document_parsing'
                tool_used  = 'vision-router'
                confidence = 'low'
                result     = ''
                metadata   = [ordered]@{
                    error    = $last
                    attempts = @($attempts | ForEach-Object { [ordered]@{ name = $_.name; code = $_.code; message = $_.text } })
                }
            } | ConvertTo-Json -Depth 8 | Write-Output
        } else {
            Write-Output $last
        }
        exit 1
    }
    $Intent = 'ocr'
}

if ($Intent -eq 'ocr') {
    $baidu = Join-Path $scriptDir 'baidu-ocr.ps1'
    if ((Get-EnvValue 'BAIDU_API_KEY') -and (Get-EnvValue 'BAIDU_SECRET_KEY')) {
        if ($AccurateOcr) {
            $attempts += Run-Step 'baidu-ocr accurate' { & $baidu -ImagePath $Path -Accurate -Json }
        } else {
            $attempts += Run-Step 'baidu-ocr general' { & $baidu -ImagePath $Path -Json }
        }
        if ($attempts[-1].code -eq 0) { Write-Output $attempts[-1].text; exit 0 }
    }
    $winOcr = Join-Path $scriptDir 'windows-ocr.ps1'
    if ($ext -in $imageExts) {
        $attempts += Run-Step 'windows-ocr' { & $winOcr -ImagePath $Path -Json }
        if ($attempts[-1].code -eq 0) { Write-Output $attempts[-1].text; exit 0 }
    }
    $Intent = 'reason'
}

if ($Intent -eq 'reason') {
    $vlm = Join-Path $scriptDir 'vlm-vision.ps1'

    $raceChannels = @()
    if (Get-EnvValue 'AGNES_API_KEY') {
        $raceChannels += 'agnes-2.0-flash'
        $raceChannels += 'agnes-2.5-flash'
    }
    if (Get-EnvValue 'GLM_API_KEY') {
        $raceChannels += 'glm-thinking'
        $raceChannels += 'glm'
    }

    if ($raceChannels.Count -gt 0) {
        $race = Run-Race $vlm $raceChannels $Path $Prompt ([bool]$NoCache)
        $attempts += @($race.attempts)
        if ($race.success) { Emit-RaceWinner $race $raceChannels; exit 0 }
    }

    $channels = @()
    foreach ($slot in 1..3) {
        if ((Get-EnvValue "VISION_CUSTOM_${slot}_API_KEY") -and (Get-EnvValue "VISION_CUSTOM_${slot}_BASE_URL") -and (Get-EnvValue "VISION_CUSTOM_${slot}_MODEL")) {
            $channels += "custom-$slot"
        }
    }
    if ((Get-EnvValue 'VISION_CUSTOM_API_KEY') -and (Get-EnvValue 'VISION_CUSTOM_BASE_URL') -and (Get-EnvValue 'VISION_CUSTOM_MODEL')) { $channels += 'custom' }
    if ((Test-PortOpen 11434) -or (Test-PortOpen 1234) -or (Test-PortOpen 8080)) { $channels += 'local' }

    foreach ($ch in $channels) {
        if ($NoCache) {
            $attempts += Run-Step $ch { & $vlm -ImagePath $Path -Prompt $Prompt -Json -NoCache -Channel $ch }
        } else {
            $attempts += Run-Step $ch { & $vlm -ImagePath $Path -Prompt $Prompt -Json -Channel $ch }
        }
        if ($attempts[-1].code -eq 0) { Write-Output $attempts[-1].text; exit 0 }
    }
}

$last = if ($attempts.Count) { $attempts[-1].text } else { 'No route was available.' }
if ($Json) {
    [ordered]@{
        task_type  = $Intent
        tool_used  = 'vision-router'
        confidence = 'low'
        result     = ''
        metadata   = [ordered]@{
            error    = $last
            attempts = @($attempts | ForEach-Object { [ordered]@{ name = $_.name; code = $_.code; message = $_.text } })
        }
    } | ConvertTo-Json -Depth 8 | Write-Output
} else {
    Write-Output $last
}
exit 1
