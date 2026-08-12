# setup.ps1 - Channel configuration guide for ds-vision-skill.
# ASCII-only source. Non-interactive: the agent drives the conversation with the
# user, and calls this script to inspect, persist, verify, or remove settings.
#
# Usage:
#   scripts\setup.cmd -Status                         # cmd.exe-safe launcher
#   scripts\setup.cmd -SetKey -Channel glm -Key "YOUR_GLM_API_KEY" -Verify
#   setup.ps1 -Status
#   setup.ps1 -Help
#   setup.ps1 -SetKey -Channel CHANNEL -Key "YOUR_KEY" [-Secret "YOUR_SECRET"] [-BaseUrl "URL"] [-Verify] [-Force]
#   setup.ps1 -RemoveKey -Channel CHANNEL
#   setup.ps1 -SetCustom [-Slot 1|2|3] -BaseUrl "URL" -Key "YOUR_KEY" -Model "MODEL" [-Verify] [-Force]
#   setup.ps1 -Verify -Channel CHANNEL [-ImagePath "PATH"]

param(
    [switch]$Status,
    [switch]$Help,
    [switch]$SetKey,
    [switch]$RemoveKey,
    [switch]$SetCustom,
    [switch]$Verify,
    [switch]$Force,
    [ValidateSet('glm','glm-thinking','agnes-2.5-flash','agnes-2.0-flash','baidu-ocr','custom','custom-1','custom-2','custom-3')]
    [string]$Channel = '',
    [string]$Key = '',
    [string]$Secret = '',
    [string]$BaseUrl = '',
    [string]$Model = '',
    [string]$ImagePath = '',
    [ValidateSet(1,2,3)]
    [int]$Slot = 1
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-EnvValue([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'User') }
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'Machine') }
    return $v
}

function Mask([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if ($Value.Length -le 8) { return '****' }
    return $Value.Substring(0, 4) + '****' + $Value.Substring($Value.Length - 4)
}

function Set-EnvUser([string]$Name, [string]$Value) {
    # Registry-only write: [Environment]::SetEnvironmentVariable(...,'User')
    # broadcasts WM_SETTINGCHANGE and can hang when a window is busy.
    Set-Item -Path "Env:$Name" -Value $Value
    New-ItemProperty -Path 'HKCU:\Environment' -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Remove-EnvUser([string]$Name) {
    Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKCU:\Environment' -Name $Name -ErrorAction SilentlyContinue
}

function Test-Port([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(500) -and $client.Connected) { return 'open' }
    } catch { }
    finally { $client.Close() }
    return 'closed'
}

$channels = @{
    glm           = @{ envs = @('GLM_API_KEY'); name = 'Zhipu GLM-4V-Flash (simple, free)'; signup = 'https://open.bigmodel.cn/' }
    'glm-thinking' = @{ envs = @('GLM_API_KEY'); name = 'Zhipu GLM-4.1V-Thinking-Flash (complex)'; signup = 'https://open.bigmodel.cn/' }
    'agnes-2.5-flash' = @{ envs = @('AGNES_API_KEY'); name = 'Agnes 2.5 Flash (OpenAI-compatible vision)'; signup = 'https://api.agnes-ai.cn/v1/chat/completions' }
    'agnes-2.0-flash' = @{ envs = @('AGNES_API_KEY'); name = 'Agnes 2.0 Flash (OpenAI-compatible vision)'; signup = 'https://api.agnes-ai.cn/v1/chat/completions' }
    'baidu-ocr'   = @{ envs = @('BAIDU_API_KEY','BAIDU_SECRET_KEY'); name = 'Baidu OCR (general/accurate)'; signup = 'https://console.bce.baidu.com/ai/#/ai/ocr/app/list' }
}

function Test-Channel([string]$Ch) {
    $img = $ImagePath
    if (-not $img) {
        Add-Type -AssemblyName System.Drawing
        $img = Join-Path $env:TEMP 'ds-vision-setup-test.png'
        $bmp = New-Object System.Drawing.Bitmap 640, 200
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)
        $g.DrawString('DS vision test 123', (New-Object System.Drawing.Font('Arial', 40)), [System.Drawing.Brushes]::Black, 20, 60)
        $g.Dispose()
        $bmp.Save($img, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }
    if ($Ch -eq 'baidu-ocr') {
        $script = Join-Path $PSScriptRoot 'baidu-ocr.ps1'
        $output = & $script -ImagePath $img 2>&1
    } else {
        $script = Join-Path $PSScriptRoot 'vlm-vision.ps1'
        $output = & $script -ImagePath $img -Prompt 'Reply with OK if you can see this image.' -Channel $Ch 2>&1
    }
    $code = $LASTEXITCODE
    $out = $output | Out-String
    Write-Output ("  verify channel=$Ch exit=$code")
    $trimmed = $out.Trim()
    if ($trimmed) {
        $len = [Math]::Min(300, $trimmed.Length)
        Write-Output ("  response: {0}" -f $trimmed.Substring(0, $len))
    }
    $script:lastVerifyExit = $code
}

function Show-Status {
    Write-Output '## DS Vision Skill - Setup Status'
    Write-Output ''
    Write-Output '### Cloud channels'
    foreach ($c in ($channels.Keys | Sort-Object)) {
        $info = $channels[$c]
        $need = @($info.envs)
        $missing = @($need | Where-Object { -not (Get-EnvValue $_) })
        $status = if ($missing.Count -eq 0) { 'configured' } else { 'dormant (missing: ' + ($missing -join ', ') + ')' }
        Write-Output ("- {0} [{1}]: {2}" -f $c, $info.name, $status)
    }
    foreach ($slotId in 1..3) {
        $customOk = (Get-EnvValue "VISION_CUSTOM_${slotId}_API_KEY") -and (Get-EnvValue "VISION_CUSTOM_${slotId}_BASE_URL") -and (Get-EnvValue "VISION_CUSTOM_${slotId}_MODEL")
        Write-Output ("- custom-{0} [third-party slot]: {1}" -f $slotId, $(if ($customOk) { 'configured' } else { 'dormant' }))
    }
    Write-Output ("- agnes base url: {0}" -f $(if (Get-EnvValue 'AGNES_BASE_URL') { Get-EnvValue 'AGNES_BASE_URL' } else { 'https://api.agnes-ai.cn/v1/chat/completions (default)' }))
    Write-Output ''
    Write-Output '### Local'
    Write-Output ("- llmfit: {0}" -f $(if (Get-Command llmfit -ErrorAction SilentlyContinue) { 'OK' } else { 'not found (uv tool install llmfit)' }))
    Write-Output ("- ollama 11434: {0} | lmstudio 1234: {1} | llamacpp 8080: {2}" -f (Test-Port 11434), (Test-Port 1234), (Test-Port 8080))
    Write-Output ''
    Write-Output '### Next steps'
    Write-Output '- Run "scripts\setup.cmd -Help" for registration links and cmd.exe-safe commands.'
    Write-Output '- First configure free race channels: glm and agnes-2.5-flash.'
    Write-Output '- Optional third-party slots: scripts\setup.cmd -SetCustom -Slot 1 -BaseUrl "URL" -Key "YOUR_KEY" -Model "MODEL"'
}

function Show-Help {
    Write-Output '## DS Vision Skill - Registration Guide'
    Write-Output ''
    Write-Output '### Shell safety'
    Write-Output '- If a harness defaults to cmd.exe (Zcode, some Codex/Hermes wrappers), use scripts\setup.cmd.'
    Write-Output '- Do not paste PowerShell-only syntax or <KEY> placeholders into cmd.exe; quote real values instead.'
    Write-Output '- Equivalent explicit launcher: powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\setup.ps1 ...'
    Write-Output ''
    foreach ($c in ($channels.Keys | Sort-Object)) {
        $info = $channels[$c]
        $secret = if ($info.envs.Count -gt 1) { ' -Secret "YOUR_' + $info.envs[1] + '"' } else { '' }
        Write-Output ("### {0} ({1})" -f $c, $info.name)
        Write-Output ("- Sign up: {0}" -f $info.signup)
        Write-Output ("- Env vars: {0}" -f ($info.envs -join ' + '))
        $base = if ($c -like 'agnes-*') { ' -BaseUrl "https://api.agnes-ai.cn/v1/chat/completions"' } else { '' }
        Write-Output ("- Enable: scripts\setup.cmd -SetKey -Channel {0} -Key ""YOUR_{1}""{2}{3} -Verify" -f $c, $info.envs[0], $secret, $base)
        Write-Output ''
    }
    Write-Output '### custom-1 / custom-2 / custom-3 (third-party OpenAI-compatible slots)'
    Write-Output '- Env vars: VISION_CUSTOM_<slot>_BASE_URL + VISION_CUSTOM_<slot>_API_KEY + VISION_CUSTOM_<slot>_MODEL'
    Write-Output '- Enable: scripts\setup.cmd -SetCustom -Slot 1 -BaseUrl "https://example.com/v1/chat/completions" -Key "YOUR_API_KEY" -Model "YOUR_MODEL" -Verify'
    Write-Output ''
    Write-Output '### local (offline / privacy)'
    Write-Output '- Install Ollama: winget install Ollama.Ollama, then: ollama pull qwen2.5-vl:3b'
    Write-Output '- Or run LM Studio / llama.cpp on their default ports; then: scripts\setup.cmd -Status'
    Write-Output '- Model selection: scripts/local-select.ps1 -Force'
}

function Do-SetKey {
    if (-not $Channel -or $Channel -eq 'custom') {
        Write-Error 'SetKey requires -Channel glm|glm-thinking|agnes-2.5-flash|agnes-2.0-flash|baidu-ocr (use -SetCustom for the custom relay).'
        exit 1
    }
    $info = $channels[$Channel]
    if (-not $Key) { Write-Error '-Key is required.'; exit 1 }
    if ($Channel -like 'agnes-*' -and $BaseUrl) { Set-Item -Path 'Env:AGNES_BASE_URL' -Value $BaseUrl }
    if ($info.envs.Count -gt 1 -and -not $Secret) {
        Write-Error ("{0} also requires -Secret ({1})." -f $Channel, $info.envs[1])
        exit 1
    }
    for ($i = 0; $i -lt $info.envs.Count; $i++) {
        $value = if ($i -eq 0) { $Key } else { $Secret }
        Set-Item -Path "Env:$($info.envs[$i])" -Value $value
    }
    if ($Verify) {
        Test-Channel $Channel
        if ($LASTEXITCODE -ne 0 -and -not $Force) {
            Write-Output "Verification failed for '$Channel'; key NOT saved. Use -Force to save anyway."
            exit 1
        }
    }
    for ($i = 0; $i -lt $info.envs.Count; $i++) {
        $value = if ($i -eq 0) { $Key } else { $Secret }
        Set-EnvUser $info.envs[$i] $value
        Write-Output ("Saved {0}={1} (User scope)" -f $info.envs[$i], (Mask $value))
    }
    if ($Channel -like 'agnes-*' -and $BaseUrl) {
        Set-EnvUser 'AGNES_BASE_URL' $BaseUrl
        Write-Output ("Saved AGNES_BASE_URL={0} (User scope)" -f $BaseUrl)
    }
    if ($Verify) { Write-Output 'Verification: OK' }
}

function Do-SetCustom {
    if (-not $BaseUrl -or -not $Key -or -not $Model) {
        Write-Error 'SetCustom requires -BaseUrl, -Key and -Model.'
        exit 1
    }
    $prefix = "VISION_CUSTOM_${Slot}"
    Set-Item -Path "Env:${prefix}_BASE_URL" -Value $BaseUrl
    Set-Item -Path "Env:${prefix}_API_KEY" -Value $Key
    Set-Item -Path "Env:${prefix}_MODEL" -Value $Model
    if ($Verify) {
        Test-Channel "custom-$Slot"
        if ($LASTEXITCODE -ne 0 -and -not $Force) {
            Write-Output "Verification failed for custom-$Slot; settings NOT saved. Use -Force to save anyway."
            exit 1
        }
    }
    Set-EnvUser "${prefix}_BASE_URL" $BaseUrl
    Set-EnvUser "${prefix}_API_KEY" $Key
    Set-EnvUser "${prefix}_MODEL" $Model
    Write-Output ("Saved {0}_BASE_URL={1} {0}_API_KEY={2} {0}_MODEL={3} (User scope)" -f $prefix, $BaseUrl, (Mask $Key), $Model)
    if ($Verify) { Write-Output 'Verification: OK' }
}

function Do-RemoveKey {
    if (-not $Channel) {
        Write-Error 'RemoveKey requires -Channel <name|custom|custom-1|custom-2|custom-3>.'
        exit 1
    }
    if ($Channel -eq 'custom') {
        foreach ($n in @('VISION_CUSTOM_BASE_URL','VISION_CUSTOM_API_KEY','VISION_CUSTOM_MODEL','VISION_CUSTOM_1_BASE_URL','VISION_CUSTOM_1_API_KEY','VISION_CUSTOM_1_MODEL','VISION_CUSTOM_2_BASE_URL','VISION_CUSTOM_2_API_KEY','VISION_CUSTOM_2_MODEL','VISION_CUSTOM_3_BASE_URL','VISION_CUSTOM_3_API_KEY','VISION_CUSTOM_3_MODEL')) {
            Remove-EnvUser $n
        }
        Write-Output 'Removed custom relay settings, including custom-1/custom-2/custom-3 (User scope).'
        exit 0
    }
    if ($Channel -like 'custom-*') {
        $slotId = $Channel.Replace('custom-', '')
        foreach ($n in @("VISION_CUSTOM_${slotId}_BASE_URL","VISION_CUSTOM_${slotId}_API_KEY","VISION_CUSTOM_${slotId}_MODEL")) {
            Remove-EnvUser $n
        }
        Write-Output ("Removed {0} settings (User scope)." -f $Channel)
        exit 0
    }
    $info = $channels[$Channel]
    foreach ($n in $info.envs) {
        Remove-EnvUser $n
    }
    Write-Output ("Removed {0} (User scope)." -f ($info.envs -join ', '))
}

$primary = @([bool]$Status, [bool]$Help, [bool]$SetKey, [bool]$RemoveKey, [bool]$SetCustom)
$primaryCount = ($primary | Where-Object { $_ }).Count
if ($primaryCount -ne 1 -and -not ($primaryCount -eq 0 -and $Verify)) {
    Write-Output 'Usage:'
    Write-Output '  scripts\setup.cmd -Status'
    Write-Output '  scripts\setup.cmd -Help'
    Write-Output '  scripts\setup.cmd -SetKey -Channel glm -Key "YOUR_GLM_API_KEY" [-Verify]'
    Write-Output '  scripts\setup.cmd -RemoveKey -Channel glm'
    Write-Output '  scripts\setup.cmd -SetCustom -Slot 1 -BaseUrl "URL" -Key "YOUR_KEY" -Model "MODEL" [-Verify]'
    Write-Output '  powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\setup.ps1 -Verify -Channel glm'
    exit 1
}

if ($Verify -and -not ($SetKey -or $SetCustom)) {
    if (-not $Channel) { Write-Error 'Verify requires -Channel <name|custom|custom-1|custom-2|custom-3>.'; exit 1 }
    Test-Channel $Channel
    exit $LASTEXITCODE
}

if ($Status) { Show-Status; exit 0 }
if ($Help) { Show-Help; exit 0 }
if ($SetKey) { Do-SetKey; exit 0 }
if ($RemoveKey) { Do-RemoveKey; exit 0 }
if ($SetCustom) { Do-SetCustom; exit 0 }
