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
    [switch]$NoCache,
    [ValidateRange(1, 8192)]
    [int]$MaxTokens = 1024,
    [ValidateRange(1, 300)]
    [int]$TimeoutSec = 90
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
    # Read once so cache hashing and base64 encoding do not traverse the file twice.
    $bytes = [IO.File]::ReadAllBytes($InputPath)
    $sizeMB = [Math]::Round($bytes.Length / 1MB, 2)
    if ($sizeMB -gt 15) {
        throw "image too large (${sizeMB} MB). Downscale it first or use MinerU for documents."
    }
    $shaObj = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($shaObj.ComputeHash($bytes))).Replace('-', '')
    } finally {
        $shaObj.Dispose()
    }
    $mime = Get-ImageMime $InputPath
    return [pscustomobject]@{
        data_url = ''
        hash = $hash
        mime = $mime
        size_mb = $sizeMB
        bytes = $bytes
    }
}

function Add-PreparedImageDataUrl([object]$PreparedImagePayload, [string]$InputPath) {
    if (-not $PreparedImagePayload.data_url) {
        $bytes = if ($PreparedImagePayload.bytes) { $PreparedImagePayload.bytes } else { [IO.File]::ReadAllBytes($InputPath) }
        $PreparedImagePayload.data_url = "data:$($PreparedImagePayload.mime);base64,$([Convert]::ToBase64String($bytes))"
        $PreparedImagePayload.bytes = $null
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
        $base = Get-EnvValue 'GLM_BASE_URL'
        if (-not $base) { $base = 'https://open.bigmodel.cn/api/paas/v4/chat/completions' }
        return [pscustomobject]@{
            name = $Name
            url = Get-ChatUrl $base
            model = 'glm-4v-flash'
            key = Get-EnvValue 'GLM_API_KEY'
        }
    }
    if ($Name -eq 'glm-thinking') {
        $base = Get-EnvValue 'GLM_BASE_URL'
        if (-not $base) { $base = 'https://open.bigmodel.cn/api/paas/v4/chat/completions' }
        return [pscustomobject]@{
            name = $Name
            url = Get-ChatUrl $base
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

function Get-VlmCacheFile([string]$ImageHash, [string]$UserPrompt, [string]$ChannelName, [string]$Model, [string]$Endpoint, [int]$OutputTokens) {
    $cacheDir = Join-Path $env:USERPROFILE '.ds-vision\cache'
    $shaObj = [System.Security.Cryptography.SHA256]::Create()
    try {
        $cacheInput = [Text.Encoding]::UTF8.GetBytes(('v2|' + $ImageHash + '|' + $UserPrompt + '|' + $ChannelName + '|' + $Model + '|' + $Endpoint + '|' + $OutputTokens))
        $cacheKey = ([BitConverter]::ToString($shaObj.ComputeHash($cacheInput))).Replace('-', '').ToLower()
    } finally {
        $shaObj.Dispose()
    }
    return Join-Path $cacheDir ($cacheKey + '.json')
}

function Write-RaceCache([string]$CacheFile, [object]$Envelope) {
    if (-not $CacheFile) { return }
    $cacheDir = Split-Path -Parent $CacheFile
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    $jsonText = $Envelope | ConvertTo-Json -Depth 6 -Compress
    [IO.File]::WriteAllText($CacheFile, $jsonText, (New-Object Text.UTF8Encoding($false)))
}

function New-RaceRequestBody([string]$Model, [string]$DataUrlJson, [string]$PromptJson, [int]$OutputTokens) {
    $body = '{"model":' + ($Model | ConvertTo-Json -Compress) + ',"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":' + $DataUrlJson + '}}'
    if ($PromptJson) { $body += ',{"type":"text","text":' + $PromptJson + '}' }
    $body += ']}]'
    if ($OutputTokens -gt 0) { $body += ',"max_tokens":' + $OutputTokens }
    $body += '}'
    return $body
}

function Get-HttpFailure([string]$ChannelName, [int]$Status, [string]$Message) {
    if ($Status -eq 401 -or $Status -eq 403) {
        return [pscustomobject]@{ name = $ChannelName; code = 2; text = "ERROR: channel=$ChannelName status=$Status auth failed." }
    }
    if ($Status -eq 429) {
        return [pscustomobject]@{ name = $ChannelName; code = 3; text = "ERROR: channel=$ChannelName status=429 rate limited." }
    }
    if ($Status -eq 0 -or $Status -ge 500) {
        return [pscustomobject]@{ name = $ChannelName; code = 4; text = "ERROR: channel=$ChannelName status=$Status network/server: $Message" }
    }
    return [pscustomobject]@{ name = $ChannelName; code = 5; text = "ERROR: channel=$ChannelName status=$Status request rejected: $Message" }
}

function Read-HttpResponseText([object]$Response) {
    $bytes = $Response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $encoding = [Text.Encoding]::UTF8
    $charset = $Response.Content.Headers.ContentType.CharSet
    if ($charset) {
        try { $encoding = [Text.Encoding]::GetEncoding($charset.Trim('"')) } catch { }
    }
    $stream = New-Object IO.MemoryStream(,$bytes)
    $reader = New-Object IO.StreamReader($stream, $encoding, $true)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Run-RacePrepared([array]$ChannelNames, [object]$PreparedImagePayload, [string]$InputPath, [string]$UserPrompt, [bool]$DisableCache, [int]$OutputTokens, [int]$RequestTimeoutSec) {
    $configs = @()
    foreach ($name in $ChannelNames) {
        $config = Get-RaceChannelConfig $name
        if (-not $config -or -not $config.key) { continue }
        $cacheFile = Get-VlmCacheFile $PreparedImagePayload.hash $UserPrompt $config.name $config.model $config.url $OutputTokens
        $config | Add-Member -NotePropertyName cache_file -NotePropertyValue $cacheFile -Force
        if (-not $DisableCache -and (Test-Path -LiteralPath $cacheFile)) {
            try {
                $cached = Get-Content -Raw -LiteralPath $cacheFile | ConvertFrom-Json
                if ($cached.result) {
                    $cached.metadata | Add-Member -NotePropertyName cached -NotePropertyValue $true -Force
                    $cached.metadata | Add-Member -NotePropertyName race_runtime -NotePropertyValue 'cache' -Force
                    return [pscustomobject]@{
                        success = $true
                        started_channels = @()
                        winner  = [pscustomobject]@{
                            name = $config.name
                            code = 0
                            text = ($cached | ConvertTo-Json -Depth 6 -Compress)
                            payload = $cached
                        }
                        attempts = @([pscustomobject]@{ name = $config.name; code = 0; text = 'cache hit' })
                    }
                }
            } catch { }
        }
        $configs += $config
    }

    if ($configs.Count -eq 0) {
        return [pscustomobject]@{ success = $false; started_channels = @(); winner = $null; attempts = @() }
    }

    $PreparedImagePayload = Add-PreparedImageDataUrl $PreparedImagePayload $InputPath
    $dataUrlJson = $PreparedImagePayload.data_url | ConvertTo-Json -Compress
    $promptJson = if ($UserPrompt) { $UserPrompt | ConvertTo-Json -Compress } else { '' }

    Add-Type -AssemblyName System.Net.Http
    if ([Net.ServicePointManager]::DefaultConnectionLimit -lt 16) {
        [Net.ServicePointManager]::DefaultConnectionLimit = 16
    }
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    if ($handler.PSObject.Properties.Name -contains 'MaxConnectionsPerServer') {
        $handler.MaxConnectionsPerServer = 8
    }
    $client = New-Object Net.Http.HttpClient($handler)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    $workers = @()
    $results = @()
    $raceCts = $null
    try {
        foreach ($config in $configs) {
            $request = $null
            try {
                $body = New-RaceRequestBody $config.model $dataUrlJson $promptJson $OutputTokens
                $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Post, $config.url)
                if (-not $request.Headers.TryAddWithoutValidation('Authorization', "Bearer $($config.key)")) {
                    throw 'authorization header was rejected.'
                }
                $request.Headers.ExpectContinue = $false
                $request.Content = New-Object Net.Http.StringContent($body, [Text.Encoding]::UTF8, 'application/json')
                $workers += [pscustomobject]@{
                    name = $config.name
                    config = $config
                    request = $request
                    stopwatch = New-Object Diagnostics.Stopwatch
                    task = $null
                }
            } catch {
                if ($request) { $request.Dispose() }
                $results += Get-HttpFailure $config.name 0 "request setup: $($_.Exception.Message)"
            }
        }

        if ($workers.Count -eq 0) {
            return [pscustomobject]@{ success = $false; started_channels = @(); winner = $null; attempts = $results }
        }

        # Build every request first, then start all four in one tight loop.
        $raceCts = New-Object Threading.CancellationTokenSource
        $raceCts.CancelAfter($RequestTimeoutSec * 1000)
        $startedWorkers = @()
        foreach ($worker in $workers) {
            try {
                $worker.stopwatch.Start()
                $worker.task = $client.SendAsync($worker.request, [Net.Http.HttpCompletionOption]::ResponseContentRead, $raceCts.Token)
                $startedWorkers += $worker
            } catch {
                $worker.stopwatch.Stop()
                $results += Get-HttpFailure $worker.name 0 "request start: $($_.Exception.Message)"
            }
        }

        if ($startedWorkers.Count -eq 0) {
            return [pscustomobject]@{ success = $false; started_channels = @(); winner = $null; attempts = $results }
        }

        $pending = @($startedWorkers)
        $raceClock = [Diagnostics.Stopwatch]::StartNew()
        while ($pending.Count -gt 0) {
            [Threading.Tasks.Task[]]$taskArray = @($pending | ForEach-Object { $_.task })
            $remainingMs = [Math]::Max(1, ($RequestTimeoutSec * 1000) - [int]$raceClock.ElapsedMilliseconds)
            $finishedIndex = [Threading.Tasks.Task]::WaitAny($taskArray, $remainingMs)
            if ($finishedIndex -lt 0) {
                try { $raceCts.Cancel() } catch { }
                foreach ($timedOut in $pending) {
                    $results += Get-HttpFailure $timedOut.name 0 'race timeout.'
                }
                break
            }
            $worker = $pending[$finishedIndex]
            $worker.stopwatch.Stop()
            $response = $null
            $result = $null
            try {
                $response = $worker.task.GetAwaiter().GetResult()
                $status = [int]$response.StatusCode
                if (-not $response.IsSuccessStatusCode) {
                    $result = Get-HttpFailure $worker.name $status $response.ReasonPhrase
                } else {
                    $responseText = Read-HttpResponseText $response
                    $parsed = $null
                    try {
                        $parsed = $responseText | ConvertFrom-Json
                    } catch {
                        $result = [pscustomobject]@{ name = $worker.name; code = 1; text = 'ERROR: invalid JSON response.' }
                    }
                    $content = if ($parsed -and $parsed.choices -and $parsed.choices[0].message.content) { $parsed.choices[0].message.content } else { $null }
                    if (-not $result -and $content) {
                        $envelope = [ordered]@{
                            task_type  = 'image_reasoning'
                            tool_used  = "$($worker.name):$($worker.config.model)"
                            confidence = 'high'
                            result     = $content
                            metadata   = [ordered]@{
                                channel    = $worker.name
                                model      = $worker.config.model
                                image_sha  = $PreparedImagePayload.hash.Substring(0, 12)
                                image_mb   = $PreparedImagePayload.size_mb
                                prepared_payload = $true
                                race_runtime = 'httpclient-task'
                                latency_ms = $worker.stopwatch.ElapsedMilliseconds
                                max_tokens = $OutputTokens
                                cached     = $false
                            }
                        }
                        # Stop loser traffic as soon as the response is known to be valid.
                        try { $raceCts.Cancel() } catch { }
                        if (-not $DisableCache) {
                            try { Write-RaceCache $worker.config.cache_file $envelope } catch { }
                        }
                        $result = [pscustomobject]@{
                            name = $worker.name
                            code = 0
                            text = 'ok'
                            payload = [pscustomobject]$envelope
                        }
                    } elseif (-not $result) {
                        $result = [pscustomobject]@{ name = $worker.name; code = 1; text = 'ERROR: empty response content.' }
                    }
                }
            } catch {
                $message = $_.Exception.Message
                if ($_.Exception.InnerException) { $message = $_.Exception.InnerException.Message }
                $result = Get-HttpFailure $worker.name 0 $message
            } finally {
                if ($response) { $response.Dispose() }
            }

            $results += $result
            if ($result.code -eq 0) {
                try { $raceCts.Cancel() } catch { }
                return [pscustomobject]@{
                    success = $true
                    started_channels = @($startedWorkers | ForEach-Object { $_.name })
                    winner  = $result
                    attempts = $results
                }
            }
            $pending = @($pending | Where-Object { $_.name -ne $worker.name })
        }

        return [pscustomobject]@{
            success = $false
            started_channels = @($startedWorkers | ForEach-Object { $_.name })
            winner  = $null
            attempts = $results
        }
    } finally {
        if ($raceCts) { try { $raceCts.Cancel() } catch { } }
        if ($client) { $client.Dispose() }
        foreach ($worker in $workers) {
            if ($worker.task -and $worker.task.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) {
                try {
                    $completedResponse = $worker.task.GetAwaiter().GetResult()
                    if ($completedResponse) { $completedResponse.Dispose() }
                } catch { }
            }
            if ($worker.request) { $worker.request.Dispose() }
        }
        if ($raceCts) { $raceCts.Dispose() }
        if ($handler) { $handler.Dispose() }
    }
}

function Emit-RaceWinner([object]$Race, [array]$StartedChannels) {
    if (-not $Json) {
        if ($Race.winner.payload -and $null -ne $Race.winner.payload.result) {
            Write-Output $Race.winner.payload.result
        } else {
            Write-Output $Race.winner.text
        }
        return
    }

    try {
        $payload = if ($Race.winner.payload) { $Race.winner.payload } else { $Race.winner.text | ConvertFrom-Json }
        if (-not $payload.metadata) {
            $payload | Add-Member -NotePropertyName metadata -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $raceMeta = [ordered]@{
            mode               = 'first-success'
            winner             = $Race.winner.name
            started_channels   = @($StartedChannels)
            completed_attempts = @($Race.attempts | ForEach-Object { [ordered]@{ name = $_.name; code = $_.code } })
        }
        if ($payload.metadata -is [Collections.IDictionary]) {
            $payload.metadata['race'] = $raceMeta
        } else {
            $payload.metadata | Add-Member -NotePropertyName race -NotePropertyValue $raceMeta -Force
        }
        Write-Output ($payload | ConvertTo-Json -Depth 10 -Compress)
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
        } | ConvertTo-Json -Depth 8 -Compress | Write-Output
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
            } | ConvertTo-Json -Depth 8 -Compress | Write-Output
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
    $effectiveMaxTokens = $MaxTokens
    if ($Complex -and -not $PSBoundParameters.ContainsKey('MaxTokens')) { $effectiveMaxTokens = 2048 }

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
            $race = Run-RacePrepared $raceChannels $preparedPayload $Path $Prompt ([bool]$NoCache) $effectiveMaxTokens $TimeoutSec
            $attempts += @($race.attempts)
            if ($race.success) {
                $actuallyStarted = @($race.started_channels)
                Emit-RaceWinner $race $actuallyStarted
                exit 0
            }
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
            $attempts += Run-Step $ch { & $vlm -ImagePath $Path -Prompt $Prompt -Json -NoCache -Channel $ch -MaxTokens $effectiveMaxTokens -TimeoutSec $TimeoutSec }
        } else {
            $attempts += Run-Step $ch { & $vlm -ImagePath $Path -Prompt $Prompt -Json -Channel $ch -MaxTokens $effectiveMaxTokens -TimeoutSec $TimeoutSec }
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
    } | ConvertTo-Json -Depth 8 -Compress | Write-Output
} else {
    Write-Output $last
}
exit 1
