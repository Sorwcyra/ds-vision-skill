# vlm-vision.ps1 - Generic OpenAI-compatible vision caller for ds-vision-skill.
# ASCII-only source. Pass Chinese text via -Prompt; never embed non-ASCII here.
# Exit codes: 0 success, 1 generic, 2 missing key/auth, 3 rate-limited, 4 network, 5 request rejected.

param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [string]$Prompt = 'Describe this image in detail.',
    [ValidateSet('glm','glm-thinking','agnes-2.5-flash','agnes-2.0-flash','custom','custom-1','custom-2','custom-3','local')]
    [string]$Channel = 'glm',
    [string]$Model = '',
    [string]$BaseUrl = '',
    [string]$ApiKey = '',
    [string]$PreparedImageJson = '',
    [string]$PreparedImageDataUrlFile = '',
    [string]$PreparedImageSha256 = '',
    [double]$PreparedImageSizeMB = 0,
    [switch]$Json,
    [switch]$NoCache,
    [ValidateRange(1, 300)]
    [int]$TimeoutSec = 90,
    [ValidateRange(1, 8192)]
    [int]$MaxTokens = 1024
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Get-EnvValue([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'User') }
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'Machine') }
    return $v
}

if (-not (Test-Path -LiteralPath $ImagePath)) {
    Write-Err "ERROR: image not found: $ImagePath"
    exit 1
}

$channelKeys = @{
    glm           = Get-EnvValue 'GLM_API_KEY'
    'glm-thinking' = Get-EnvValue 'GLM_API_KEY'
    'agnes-2.5-flash' = Get-EnvValue 'AGNES_API_KEY'
    'agnes-2.0-flash' = Get-EnvValue 'AGNES_API_KEY'
    custom        = Get-EnvValue 'VISION_CUSTOM_API_KEY'
    'custom-1'    = Get-EnvValue 'VISION_CUSTOM_1_API_KEY'
    'custom-2'    = Get-EnvValue 'VISION_CUSTOM_2_API_KEY'
    'custom-3'    = Get-EnvValue 'VISION_CUSTOM_3_API_KEY'
}

$channelDefaults = @{
    glm           = @{ url = if (Get-EnvValue 'GLM_BASE_URL') { Get-EnvValue 'GLM_BASE_URL' } else { 'https://open.bigmodel.cn/api/paas/v4/chat/completions' }; model = 'glm-4v-flash' }
    'glm-thinking' = @{ url = if (Get-EnvValue 'GLM_BASE_URL') { Get-EnvValue 'GLM_BASE_URL' } else { 'https://open.bigmodel.cn/api/paas/v4/chat/completions' }; model = 'glm-4.1v-thinking-flash' }
    'agnes-2.5-flash' = @{ url = if (Get-EnvValue 'AGNES_BASE_URL') { Get-EnvValue 'AGNES_BASE_URL' } else { 'https://api.agnes-ai.cn/v1/chat/completions' }; model = 'agnes-2.5-flash' }
    'agnes-2.0-flash' = @{ url = if (Get-EnvValue 'AGNES_BASE_URL') { Get-EnvValue 'AGNES_BASE_URL' } else { 'https://api.agnes-ai.cn/v1/chat/completions' }; model = 'agnes-2.0-flash' }
    custom        = @{ url = Get-EnvValue 'VISION_CUSTOM_BASE_URL'; model = Get-EnvValue 'VISION_CUSTOM_MODEL' }
    'custom-1'    = @{ url = Get-EnvValue 'VISION_CUSTOM_1_BASE_URL'; model = Get-EnvValue 'VISION_CUSTOM_1_MODEL' }
    'custom-2'    = @{ url = Get-EnvValue 'VISION_CUSTOM_2_BASE_URL'; model = Get-EnvValue 'VISION_CUSTOM_2_MODEL' }
    'custom-3'    = @{ url = Get-EnvValue 'VISION_CUSTOM_3_BASE_URL'; model = Get-EnvValue 'VISION_CUSTOM_3_MODEL' }
}

function Get-ChatUrl([string]$Url) {
    $Url = $Url.TrimEnd('/')
    if ($Url -notmatch '/chat/completions$') { $Url += '/chat/completions' }
    return $Url
}

function Test-PortOpen([string]$HostName, [int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(700) -and $client.Connected) { return $true }
    } catch { }
    finally { $client.Close() }
    return $false
}

# --- resolve endpoint and model ---
$chatUrl = ''
$resolvedModel = $Model

if ($Channel -eq 'local') {
    $probes = @(
        @{ name = 'ollama';   url = 'http://127.0.0.1:11434/v1/chat/completions' },
        @{ name = 'lmstudio'; url = 'http://127.0.0.1:1234/v1/chat/completions' },
        @{ name = 'llamacpp'; url = 'http://127.0.0.1:8080/v1/chat/completions' }
    )
    $found = $null
    foreach ($p in $probes) {
        $target = [uri]$p.url
        if (Test-PortOpen $target.Host $target.Port) { $found = $p; break }
    }
    if (-not $found) {
        Write-Err 'ERROR: no local vision runtime found on 11434 (ollama) / 1234 (lmstudio) / 8080 (llamacpp). Start one first.'
        exit 1
    }
    $chatUrl = $found.url
    if (-not $resolvedModel) {
        $resolvedModel = if (Get-EnvValue 'VISION_LOCAL_MODEL') { Get-EnvValue 'VISION_LOCAL_MODEL' } else { 'qwen2.5-vl:3b' }
    }
} else {
    $defaultUrl = $channelDefaults[$Channel].url
    $chatUrl = if ($BaseUrl) { $BaseUrl } else { $defaultUrl }
    if (-not $chatUrl) {
        Write-Err "ERROR: channel '$Channel' has no default base URL. Provide -BaseUrl or set the required env vars."
        exit 2
    }
    if (-not $resolvedModel) { $resolvedModel = $channelDefaults[$Channel].model }
}

$chatUrl = Get-ChatUrl $chatUrl

$preparedImage = $null
if ($PreparedImageDataUrlFile) {
    if (-not (Test-Path -LiteralPath $PreparedImageDataUrlFile)) {
        Write-Err "ERROR: prepared image data URL file not found: $PreparedImageDataUrlFile"
        exit 1
    }
    if (-not $PreparedImageSha256) {
        Write-Err 'ERROR: -PreparedImageSha256 is required with -PreparedImageDataUrlFile.'
        exit 1
    }
    $preparedImage = [pscustomobject]@{
        image_sha256 = $PreparedImageSha256
        size_mb      = $PreparedImageSizeMB
        data_url_file = $PreparedImageDataUrlFile
        data_url     = ''
    }
} elseif ($PreparedImageJson) {
    if (-not (Test-Path -LiteralPath $PreparedImageJson)) {
        Write-Err "ERROR: prepared image payload not found: $PreparedImageJson"
        exit 1
    }
    try {
        $preparedImage = Get-Content -Raw -LiteralPath $PreparedImageJson | ConvertFrom-Json
    } catch {
        Write-Err "ERROR: prepared image payload is invalid JSON: $($_.Exception.Message)"
        exit 1
    }
    if (-not $preparedImage.image_sha256 -or -not $preparedImage.data_url) {
        Write-Err 'ERROR: prepared image payload is missing image_sha256 or data_url.'
        exit 1
    }
}

# --- cache lookup (cost optimization: reuse identical requests) ---
$cacheDir = Join-Path $env:USERPROFILE '.ds-vision\cache'
$imgHash = if ($preparedImage) { [string]$preparedImage.image_sha256 } else { (Get-FileHash -Algorithm SHA256 -LiteralPath $ImagePath).Hash }
$shaObj = [System.Security.Cryptography.SHA256]::Create()
$cacheInput = [Text.Encoding]::UTF8.GetBytes(('v2|' + $imgHash + '|' + $Prompt + '|' + $Channel + '|' + $resolvedModel + '|' + $chatUrl + '|' + $MaxTokens))
$cacheKey = ([BitConverter]::ToString($shaObj.ComputeHash($cacheInput))).Replace('-', '').ToLower()
$shaObj.Dispose()
$cacheFile = Join-Path $cacheDir ($cacheKey + '.json')

if (-not $NoCache -and (Test-Path -LiteralPath $cacheFile)) {
    $cached = Get-Content -Raw -LiteralPath $cacheFile | ConvertFrom-Json
    if ($cached.result) {
        $cached.metadata | Add-Member -NotePropertyName cached -NotePropertyValue $true -Force
        if ($Json) {
            Write-Output ($cached | ConvertTo-Json -Depth 6 -Compress)
        } else {
            Write-Output $cached.result
        }
        exit 0
    }
}

# --- resolve key ---
$resolvedKey = $ApiKey
if (-not $resolvedKey -and $Channel -ne 'local') { $resolvedKey = $channelKeys[$Channel] }
if (-not $resolvedKey -and $Channel -ne 'local') {
    Write-Err "ERROR: API key missing for channel '$Channel'. Set the env var or pass -ApiKey."
    exit 2
}

# --- encode image (or reuse a router-prepared payload during channel races) ---
if ($preparedImage) {
    $sizeMB = [double]$preparedImage.size_mb
    if ($sizeMB -gt 15) {
        Write-Err "ERROR: image too large (${sizeMB} MB). Downscale it first or use MinerU for documents."
        exit 1
    }
    if ($preparedImage.data_url_file) {
        $dataUrl = [System.IO.File]::ReadAllText($preparedImage.data_url_file, [System.Text.Encoding]::UTF8)
    } else {
        $dataUrl = [string]$preparedImage.data_url
    }
} else {
    $bytes = [IO.File]::ReadAllBytes($ImagePath)
    $sizeMB = [Math]::Round($bytes.Length / 1MB, 2)
    if ($sizeMB -gt 15) {
        Write-Err "ERROR: image too large (${sizeMB} MB). Downscale it first or use MinerU for documents."
        exit 1
    }
    $b64 = [Convert]::ToBase64String($bytes)
    $mime = switch ([IO.Path]::GetExtension($ImagePath).ToLower()) {
        '.jpg'  { 'image/jpeg' }
        '.jpeg' { 'image/jpeg' }
        '.png'  { 'image/png' }
        '.webp' { 'image/webp' }
        '.gif'  { 'image/gif' }
        '.bmp'  { 'image/bmp' }
        default { 'image/png' }
    }
    $dataUrl = "data:$mime;base64,$b64"
}

$content = @(@{ type = 'image_url'; image_url = @{ url = $dataUrl } })
if ($Prompt) { $content += @{ type = 'text'; text = $Prompt } }
$requestPayload = @{ model = $resolvedModel; messages = @(@{ role = 'user'; content = $content }); max_tokens = $MaxTokens }
$body = $requestPayload | ConvertTo-Json -Depth 12 -Compress

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $headers = if ($resolvedKey) { @{ Authorization = "Bearer $resolvedKey" } } else { @{} }
    # PS 5.1 can decode UTF-8 JSON as the system codepage when servers omit a charset.
    # Read response bytes explicitly to keep CJK output intact.
    $resp = Invoke-WebRequest -Uri $chatUrl -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec $TimeoutSec -UseBasicParsing
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
        $content = $r.choices[0].message.content
        $envelope = [ordered]@{
            task_type  = 'image_reasoning'
            tool_used  = "$Channel`:$resolvedModel"
            confidence = 'high'
            result     = $content
            metadata   = [ordered]@{
                channel    = $Channel
                model      = $resolvedModel
                image_sha  = $imgHash.Substring(0, 12)
                image_mb   = $sizeMB
                prepared_payload = [bool]$preparedImage
                latency_ms = $sw.ElapsedMilliseconds
                max_tokens = $MaxTokens
                cached     = $false
            }
        }
        if (-not $NoCache) {
            if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
            $envelope | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $cacheFile -Encoding UTF8
        }
        if ($Json) {
            Write-Output ($envelope | ConvertTo-Json -Depth 6 -Compress)
        } else {
            Write-Output $content
        }
        exit 0
    }
    Write-Err 'ERROR: empty response content.'
    exit 1
} catch {
    $status = 0
    if ($_.Exception.Response) { try { $status = [int]$_.Exception.Response.StatusCode } catch { } }
    if ($status -eq 401 -or $status -eq 403) {
        Write-Err "ERROR: channel=$Channel status=$status auth failed."
        exit 2
    }
    if ($status -eq 429) {
        Write-Err "ERROR: channel=$Channel status=429 rate limited."
        exit 3
    }
    if ($status -eq 0 -or $status -ge 500) {
        Write-Err "ERROR: channel=$Channel status=$status network/server: $($_.Exception.Message)"
        exit 4
    }
    Write-Err "ERROR: channel=$Channel status=$status request rejected: $($_.Exception.Message)"
    exit 5
}
