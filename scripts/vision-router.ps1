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
    $output = & $Command 2>&1
    $code = $LASTEXITCODE
    return [pscustomobject]@{
        name = $Name
        code = $code
        text = (($output | Out-String).Trim())
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
        if ($Prompt -match '(?i)\bocr\b|文字|识别|提取|票据|发票|扫描') { $Intent = 'ocr' }
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
    $baseArgs = @('-ImagePath', $Path, '-Prompt', $Prompt, '-Json')
    if ($NoCache) { $baseArgs += '-NoCache' }

    $channels = @()
    if ($Complex) { $channels += 'glm-thinking' } else { $channels += 'glm' }
    if ($channels -notcontains 'glm-thinking') { $channels += 'glm-thinking' }
    if ((Get-EnvValue 'VISION_CUSTOM_API_KEY') -and (Get-EnvValue 'VISION_CUSTOM_BASE_URL') -and (Get-EnvValue 'VISION_CUSTOM_MODEL')) { $channels += 'custom' }
    if ((Test-PortOpen 11434) -or (Test-PortOpen 1234) -or (Test-PortOpen 8080)) { $channels += 'local' }

    foreach ($ch in $channels) {
        if (($ch -eq 'glm' -or $ch -eq 'glm-thinking') -and -not (Get-EnvValue 'GLM_API_KEY')) { continue }
        $attempts += Run-Step $ch { & $vlm @baseArgs -Channel $ch }
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
