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
$ProgressPreference = 'SilentlyContinue'

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

function Get-ImageMime([string]$InputPath) {
    switch ([IO.Path]::GetExtension($InputPath).ToLower()) {
        '.jpg'  { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.png'  { return 'image/png' }
        '.webp' { return 'image/webp' }
        '.gif'  { return 'image/gif' }
        '.bmp'  { return 'image/bmp' }
        default { return 'image/png' }
    }
}

function New-PreparedImagePayload([string]$InputPath) {
    $file = Get-Item -LiteralPath $InputPath
    $sizeMB = [Math]::Round($file.Length / 1MB, 2)
    if ($sizeMB -gt 15) {
        throw "image too large (${sizeMB} MB). Downscale it first or use MinerU for documents."
    }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $InputPath).Hash
    $mime = Get-ImageMime $InputPath
    return [pscustomobject]@{
        data_url = ''
        hash = $hash
        mime = $mime
        size_mb = $sizeMB
    }
}

function Add-PreparedImageDataUrl([object]$PreparedImagePayload, [string]$InputPath) {
    if (-not $PreparedImagePayload.data_url) {
        $bytes = [IO.File]::ReadAllBytes($InputPath)
        $PreparedImagePayload.data_url = "data:$($PreparedImagePayload.mime);base64,$([Convert]::ToBase64String($bytes))"
    }
    return $PreparedImagePayload
}

function Get-ChatUrl([string]$Url) {
    $Url = $Url.TrimEnd('/')
    if ($Url -notmatch '/chat/completions$') { $Url += '/chat/completions' }
    return $Url
}

function Get-RaceChannelConfig([string]$Name) {
    if ($Name -eq 'glm') {
        return [pscustomobject]@{
            name = $Name
            url = Get-ChatUrl 'https://open.bigmodel.cn/api/paas/v4/chat/completions'
            model = 'glm-4v-flash'
            key = Get-EnvValue 'GLM_API_KEY'
        }
    }
    if ($Name -eq 'glm-thinking') {
        return [pscustomobject]@{
            name = $Name
            url = Get-ChatUrl 'https://open.bigmodel.cn/api/paas/v4/chat/completions'
            model = 'glm-4.1v-thinking-flash'
            key = Get-EnvValue 'GLM_API_KEY'
        }
    }
    if ($Name -eq 'agnes-2.5-flash') {
        $base = Get-EnvValue 'AGNES_BASE_URL'
        if (-not $base) { $base = 'https://api.agnes-ai.cn/v1/chat/completions' }
        return [pscustomobject]@{
            name = $Name
            url = Get-ChatUrl $base
            model = 'agnes-2.5-flash'
            key = Get-EnvValue 'AGNES_API_KEY'
        }
    }
    if ($Name -eq 'agnes-2.0-flash') {
        $base = Get-EnvValue 'AGNES_BASE_URL'
        if (-not $base) { $base = 'https://api.agnes-ai.cn/v1/chat/completions' }
        return [pscustomobject]@{
            name = $Name
            url = Get-ChatUrl $base
            model = 'agnes-2.0-flash'
            key = Get-EnvValue 'AGNES_API_KEY'
        }
    }
    return $null
}

function Get-VlmCacheFile([string]$ImageHash, [string]$UserPrompt, [string]$ChannelName, [string]$Model) {
    $cacheDir = Join-Path $env:USERPROFILE '.ds-vision\cache'
    $shaObj = [System.Security.Cryptography.SHA256]::Create()
    try {
        $cacheInput = [Text.Encoding]::UTF8.GetBytes(($ImageHash + '|' + $UserPrompt + '|' + $ChannelName + '|' + $Model))
        $cacheKey = ([BitConverter]::ToString($shaObj.ComputeHash($cacheInput))).Replace('-', '').ToLower()
    } finally {
        $shaObj.Dispose()
    }
    return Join-Path $cacheDir ($cacheKey + '.json')
}

function Run-RacePrepared([array]$ChannelNames, [object]$PreparedImagePayload, [string]$InputPath, [string]$UserPrompt, [bool]$DisableCache) {
    $scriptBlock = {
        param(
            [string]$ChannelName,
            [string]$ChatUrl,
            [string]$Model,
            [string]$ApiKey,
            [string]$DataUrl,
            [string]$Prompt,
            [string]$ImageHash,
            [double]$ImageSizeMB,
            [string]$CacheFile
        )

        $ProgressPreference = 'SilentlyContinue'
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

        $content = @(@{ type = 'image_url'; image_url = @{ url = $DataUrl } })
        if ($Prompt) { $content += @{ type = 'text'; text = $Prompt } }
        $body = @{ model = $Model; messages = @(@{ role = 'user'; content = $content }) } | ConvertTo-Json -Depth 12

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $headers = if ($ApiKey) { @{ Authorization = "Bearer $ApiKey" } } else { @{} }
            $resp = Invoke-WebRequest -Uri $ChatUrl -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 90 -UseBasicParsing
            if ($resp.RawContentStream) {
                if ($resp.RawContentStream.CanSeek) { $resp.RawContentStream.Position = 0 }
                $reader = New-Object System.IO.StreamReader($resp.RawContentStream, [System.Text.Encoding]::UTF8)
                $responseText = $reader.ReadToEnd()
            } else {
                $responseText = [string]$resp.Content
            }
            $r = $responseText | ConvertFrom-Json
            $sw.Stop()
            if ($r.choices -and $r.choices[0].message.content) {
                $envelope = [ordered]@{
                    task_type  = 'image_reasoning'
                    tool_used  = "$ChannelName`:$Model"
                    confidence = 'high'
                    result     = $r.choices[0].message.content
                    metadata   = [ordered]@{
                        channel    = $ChannelName
                        model      = $Model
                        image_sha  = $ImageHash.Substring(0, 12)
                        image_mb   = $ImageSizeMB
                        prepared_payload = $true
                        race_runtime = 'runspace'
                        latency_ms = $sw.ElapsedMilliseconds
                        cached     = $false
                    }
                }
                if ($CacheFile) {
                    $cacheDir = Split-Path -Parent $CacheFile
                    if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
                    $envelope | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $CacheFile -Encoding UTF8
                }
                return [pscustomobject]@{
                    name = $ChannelName
                    code = 0
                    text = ($envelope | ConvertTo-Json -Depth 6)
                }
            }
            return [pscustomobject]@{ name = $ChannelName; code = 1; text = 'ERROR: empty response content.' }
        } catch {
            $status = 0
            if ($_.Exception.Response) { try { $status = [int]$_.Exception.Response.StatusCode } catch { } }
            if ($status -eq 401 -or $status -eq 403) {
                return [pscustomobject]@{ name = $ChannelName; code = 2; text = "ERROR: channel=$ChannelName status=$status auth failed." }
            }
            if ($status -eq 429) {
                return [pscustomobject]@{ name = $ChannelName; code = 3; text = "ERROR: channel=$ChannelName status=429 rate limited." }
            }
            if ($status -eq 0 -or $status -ge 500) {
                return [pscustomobject]@{ name = $ChannelName; code = 4; text = "ERROR: channel=$ChannelName status=$status network/server: $($_.Exception.Message)" }
            }
            return [pscustomobject]@{ name = $ChannelName; code = 5; text = "ERROR: channel=$ChannelName status=$status request rejected: $($_.Exception.Message)" }
        }
    }

    $configs = @()
    foreach ($name in $ChannelNames) {
        $config = Get-RaceChannelConfig $name
        if (-not $config -or -not $config.key) { continue }
        $cacheFile = Get-VlmCacheFile $PreparedImagePayload.hash $UserPrompt $config.name $config.model
        $config | Add-Member -NotePropertyName cache_file -NotePropertyValue $cacheFile -Force
        if (-not $DisableCache -and (Test-Path -LiteralPath $cacheFile)) {
            try {
                $cached = Get-Content -Raw -LiteralPath $cacheFile | ConvertFrom-Json
                if ($cached.result) {
                    $cached.metadata | Add-Member -NotePropertyName cached -NotePropertyValue $true -Force
                    $cached.metadata | Add-Member -NotePropertyName race_runtime -NotePropertyValue 'runspace-cache' -Force
                    return [pscustomobject]@{
                        success = $true
                        winner  = [pscustomobject]@{
                            name = $config.name
                            code = 0
                            text = ($cached | ConvertTo-Json -Depth 6)
                        }
                        attempts = @([pscustomobject]@{ name = $config.name; code = 0; text = 'cache hit' })
                    }
                }
            } catch { }
        }
        $configs += $config
    }

    $PreparedImagePayload = Add-PreparedImageDataUrl $PreparedImagePayload $InputPath

    $workers = @()
    foreach ($config in $configs) {
        $ps = [powershell]::Create()
        [void]$ps.AddScript($scriptBlock).AddArgument($config.name).AddArgument($config.url).AddArgument($config.model).AddArgument($config.key).AddArgument($PreparedImagePayload.data_url).AddArgument($UserPrompt).AddArgument($PreparedImagePayload.hash).AddArgument($PreparedImagePayload.size_mb).AddArgument($config.cache_file)
        $workers += [pscustomobject]@{
            name = $config.name
            shell = $ps
            handle = $ps.BeginInvoke()
        }
    }

    $pending = @($workers)
    $results = @()
    try {
        while ($pending.Count -gt 0) {
            $finished = @($pending | Where-Object { $_.handle.IsCompleted })
            if ($finished.Count -eq 0) {
                Start-Sleep -Milliseconds 50
                continue
            }
            foreach ($worker in @($finished)) {
                $output = $worker.shell.EndInvoke($worker.handle)
                $result = if ($output.Count -gt 0) { $output[0] } else { [pscustomobject]@{ name = $worker.name; code = 1; text = 'ERROR: channel returned no output.' } }
                $results += $result
                if ($result.code -eq 0) {
                    foreach ($other in @($pending | Where-Object { $_.name -ne $worker.name })) {
                        try { $other.shell.Stop() } catch { }
                    }
                    return [pscustomobject]@{
                        success = $true
                        winner  = $result
                        attempts = $results
                    }
                }
                $pending = @($pending | Where-Object { $_.name -ne $worker.name })
            }
        }
    } finally {
        foreach ($worker in $workers) {
            if ($worker.shell) { $worker.shell.Dispose() }
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
        if ($AccurateOcr -or $Prompt -match '(?i)\bocr\b') { $Intent = 'ocr' }
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
        $raceChannels += 'agnes-2.5-flash'
        $raceChannels += 'agnes-2.0-flash'
    }
    if (Get-EnvValue 'GLM_API_KEY') {
        $raceChannels += 'glm'
        $raceChannels += 'glm-thinking'
    }

    if ($raceChannels.Count -gt 0) {
        $preparedPayload = $null
        try {
            $preparedPayload = New-PreparedImagePayload $Path
            $race = Run-RacePrepared $raceChannels $preparedPayload $Path $Prompt ([bool]$NoCache)
            $attempts += @($race.attempts)
            if ($race.success) { Emit-RaceWinner $race $raceChannels; exit 0 }
        } catch {
            $attempts += [pscustomobject]@{
                name = 'prepare-image-payload'
                code = 1
                text = "ERROR: $($_.Exception.Message)"
            }
        }
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
