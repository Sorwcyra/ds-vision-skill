# vlm-vision.ps1 - Generic OpenAI-compatible vision caller for ds-vision-skill.
# ASCII-only source. Pass Chinese text via -Prompt; never embed non-ASCII here.
# Exit codes: 0 success, 1 generic, 2 missing key/auth, 3 rate-limited, 4 network, 5 request rejected.

param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [string]$Prompt = 'Describe this image in detail.',
    [ValidateSet('glm','glm-thinking','custom','local')]
    [string]$Channel = 'glm',
    [string]$Model = '',
    [string]$BaseUrl = '',
    [string]$ApiKey = '',
    [switch]$Json,
    [switch]$NoCache,
    [int]$TimeoutSec = 90
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
    custom        = Get-EnvValue 'VISION_CUSTOM_API_KEY'
}

$channelDefaults = @{
    glm           = @{ url = 'https://open.bigmodel.cn/api/paas/v4/chat/completions'; model = 'glm-4v-flash' }
    'glm-thinking' = @{ url = 'https://open.bigmodel.cn/api/paas/v4/chat/completions'; model = 'glm-4.1v-thinking-flash' }
    custom        = @{ url = Get-EnvValue 'VISION_CUSTOM_BASE_URL'; model = Get-EnvValue 'VISION_CUSTOM_MODEL' }
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

# --- cache lookup (cost optimization: reuse identical requests) ---
$cacheDir = Join-Path $env:USERPROFILE '.ds-vision\cache'
$imgHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ImagePath).Hash
$shaObj = [System.Security.Cryptography.SHA256]::Create()
$cacheInput = [Text.Encoding]::UTF8.GetBytes(($imgHash + '|' + $Prompt + '|' + $Channel + '|' + $resolvedModel))
$cacheKey = ([BitConverter]::ToString($shaObj.ComputeHash($cacheInput))).Replace('-', '').ToLower()
$shaObj.Dispose()
$cacheFile = Join-Path $cacheDir ($cacheKey + '.json')

if (-not $NoCache -and (Test-Path -LiteralPath $cacheFile)) {
    $cached = Get-Content -Raw -LiteralPath $cacheFile | ConvertFrom-Json
    if ($cached.result) {
        $cached.metadata | Add-Member -NotePropertyName cached -NotePropertyValue $true -Force
        if ($Json) {
            Write-Output ($cached | ConvertTo-Json -Depth 6)
        } else {
            Write-Output $cached.result
        }
        exit 0
    }
}

# --- resolve key ---
$resolvedKey = $ApiKey
if (-not $resolvedKey) { $resolvedKey = $channelKeys[$Channel] }
if (-not $resolvedKey) {
    Write-Err "ERROR: API key missing for channel '$Channel'. Set the env var or pass -ApiKey."
    exit 2
}

# --- encode image ---
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

$content = @(@{ type = 'image_url'; image_url = @{ url = "data:$mime;base64,$b64" } })
if ($Prompt) { $content += @{ type = 'text'; text = $Prompt } }
$body = @{ model = $resolvedModel; messages = @(@{ role = 'user'; content = $content }) } | ConvertTo-Json -Depth 12

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $r = Invoke-RestMethod -Uri $chatUrl -Method Post -Headers @{ Authorization = "Bearer $resolvedKey" } -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec $TimeoutSec
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
                latency_ms = $sw.ElapsedMilliseconds
                cached     = $false
            }
        }
        if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
        $envelope | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cacheFile -Encoding UTF8
        if ($Json) {
            Write-Output ($envelope | ConvertTo-Json -Depth 6)
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
