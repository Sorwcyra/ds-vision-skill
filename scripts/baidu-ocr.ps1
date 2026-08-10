# baidu-ocr.ps1 - Baidu Cloud OCR (general_basic / accurate_basic).
# ASCII-only source. Requires BAIDU_API_KEY and BAIDU_SECRET_KEY.

param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [switch]$Accurate,
    [switch]$Json,
    [int]$TimeoutSec = 60
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-EnvValue([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'User') }
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'Machine') }
    return $v
}

function Fail([int]$Code, [string]$Message) {
    [Console]::Error.WriteLine("ERROR: $Message")
    exit $Code
}

$ak = Get-EnvValue 'BAIDU_API_KEY'
$sk = Get-EnvValue 'BAIDU_SECRET_KEY'
if (-not $ak -or -not $sk) {
    Fail 2 'BAIDU_API_KEY and BAIDU_SECRET_KEY are required. Run setup.ps1 -SetKey -Channel baidu-ocr -Key <ak> -Secret <sk> -Verify'
}
if (-not (Test-Path -LiteralPath $ImagePath)) {
    Fail 1 "Image not found: $ImagePath"
}

# --- OAuth access token (cached until shortly before expiry) ---
$cacheDir = Join-Path $env:USERPROFILE '.ds-vision'
$tokenFile = Join-Path $cacheDir 'baidu-token.json'
$token = ''
$tokenCached = $false
$sha = [System.Security.Cryptography.SHA256]::Create()
$akHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ak)))).Replace('-', '')
$sha.Dispose()
if (Test-Path -LiteralPath $tokenFile) {
    try {
        $cachedToken = Get-Content -Raw -LiteralPath $tokenFile | ConvertFrom-Json
        $expiresAt = [DateTimeOffset]::Parse($cachedToken.expires_at)
        if ($cachedToken.ak_hash -eq $akHash -and $expiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(10)) {
            $token = $cachedToken.access_token
            $tokenCached = $true
        }
    } catch { }
}
if (-not $token) {
    try {
        $tokUrl = 'https://aip.baidubce.com/oauth/2.0/token?grant_type=client_credentials&client_id={0}&client_secret={1}' -f [uri]::EscapeDataString($ak), [uri]::EscapeDataString($sk)
        $tok = Invoke-RestMethod -Uri $tokUrl -Method Post -TimeoutSec 30
        $token = $tok.access_token
        $expiresIn = if ($tok.expires_in) { [int]$tok.expires_in } else { 2592000 }
        if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
        [ordered]@{
            access_token = $token
            ak_hash      = $akHash
            expires_at   = ([DateTimeOffset]::UtcNow.AddSeconds($expiresIn)).ToString('o')
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tokenFile -Encoding UTF8
    } catch {
        Fail 2 "baidu token fetch failed: $($_.Exception.Message)"
    }
}
if (-not $token) { Fail 2 'baidu token fetch returned empty.' }

# --- OCR request ---
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ImagePath))
$api = if ($Accurate) { 'accurate_basic' } else { 'general_basic' }
$url = "https://aip.baidubce.com/rest/2.0/ocr/v1/$api`?access_token=$token"
$body = "image=$([uri]::EscapeDataString($b64))&language_type=CHN_ENG&detect_direction=true"

try {
    $r = Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/x-www-form-urlencoded' -Body $body -TimeoutSec $TimeoutSec
} catch {
    $status = 0
    if ($_.Exception.Response) { try { $status = [int]$_.Exception.Response.StatusCode } catch { } }
    Fail 4 "baidu-ocr status=$status message=$($_.Exception.Message)"
}

if ($r.error_code) {
    $code = [int]$r.error_code
    if ($code -eq 17 -or $code -eq 18) {
        Fail 3 "baidu-ocr error=$code rate limited (daily/QPS limit)."
    }
    if ($code -eq 110 -or $code -eq 111) {
        Fail 2 "baidu-ocr error=$code token invalid/expired."
    }
    Fail 5 "baidu-ocr error=$code message=$($r.error_msg)"
}

$lines = @($r.words_result | ForEach-Object { $_.words })
$text = $lines -join "`n"

if ($Json) {
    $envelope = [ordered]@{
        task_type  = 'ocr'
        tool_used  = "baidu-ocr:$api"
        confidence = 'medium'
        result     = $text
        metadata   = [ordered]@{
            words_count = $lines.Count
            words_result_num = $r.words_result_num
            direction   = $r.direction
            token_cached = $tokenCached
        }
    }
    Write-Output ($envelope | ConvertTo-Json -Depth 5 -Compress)
} else {
    foreach ($l in $lines) { Write-Output $l }
}
exit 0
