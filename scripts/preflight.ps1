# preflight.ps1 - ds-vision-skill channel availability matrix.
# Read-only: no external network calls (only local port probes).
# ASCII-only source.

param(
    [switch]$Json
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'

function Test-Port([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(500) -and $client.Connected) { return 'open' }
    } catch { }
    finally { $client.Close() }
    return 'closed'
}

function Get-EnvValue([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'User') }
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'Machine') }
    return $v
}

$gpu = Get-CimInstance Win32_VideoController | Sort-Object AdapterRAM -Descending | Select-Object -First 1
if ($gpu) {
    $vramGB = [Math]::Round($gpu.AdapterRAM / 1GB, 1)
} else {
    $vramGB = $null
}
$ramGB = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 0)
$toolNames = @('mineru-open-api','llmfit','uvx','ollama','docker')
$tools = [ordered]@{}
foreach ($tool in $toolNames) { $tools[$tool] = [bool](Get-Command $tool -ErrorAction SilentlyContinue) }
$ports = [ordered]@{
    ollama   = Test-Port 11434
    lmstudio = Test-Port 1234
    llamacpp = Test-Port 8080
}

$channels = [ordered]@{
    'glm (4V-Flash simple)'                  = 'GLM_API_KEY'
    'glm-thinking (4.1V-Thinking complex)'   = 'GLM_API_KEY'
    'agnes-2.5-flash'                        = 'AGNES_API_KEY'
    'agnes-2.0-flash'                        = 'AGNES_API_KEY'
    'baidu-ocr (general/accurate)'           = 'BAIDU_API_KEY'
    'custom-1 relay'                         = 'VISION_CUSTOM_1_API_KEY'
    'custom-2 relay'                         = 'VISION_CUSTOM_2_API_KEY'
    'custom-3 relay'                         = 'VISION_CUSTOM_3_API_KEY'
    'legacy custom relay'                    = 'VISION_CUSTOM_API_KEY'
}

$cloud = [ordered]@{}
foreach ($name in $channels.Keys) {
    $keyName = $channels[$name]
    $cloud[$name] = [bool](Get-EnvValue $keyName)
}

$data = [ordered]@{
    system = [ordered]@{
        gpu       = $(if ($gpu) { $gpu.Name } else { '' })
        vram_gb   = $vramGB
        cpu_cores = $env:NUMBER_OF_PROCESSORS
        ram_gb    = $ramGB
    }
    tools = $tools
    local_runtimes = $ports
    cloud_channels = $cloud
    notes = [ordered]@{
        baidu_secret_missing = [bool]((Get-EnvValue 'BAIDU_API_KEY') -and -not (Get-EnvValue 'BAIDU_SECRET_KEY'))
        agnes_base_override   = [bool](Get-EnvValue 'AGNES_BASE_URL')
        custom_1_configured   = [bool]((Get-EnvValue 'VISION_CUSTOM_1_API_KEY') -and (Get-EnvValue 'VISION_CUSTOM_1_BASE_URL') -and (Get-EnvValue 'VISION_CUSTOM_1_MODEL'))
        custom_2_configured   = [bool]((Get-EnvValue 'VISION_CUSTOM_2_API_KEY') -and (Get-EnvValue 'VISION_CUSTOM_2_BASE_URL') -and (Get-EnvValue 'VISION_CUSTOM_2_MODEL'))
        custom_3_configured   = [bool]((Get-EnvValue 'VISION_CUSTOM_3_API_KEY') -and (Get-EnvValue 'VISION_CUSTOM_3_BASE_URL') -and (Get-EnvValue 'VISION_CUSTOM_3_MODEL'))
        legacy_custom_configured = [bool]((Get-EnvValue 'VISION_CUSTOM_API_KEY') -and (Get-EnvValue 'VISION_CUSTOM_BASE_URL') -and (Get-EnvValue 'VISION_CUSTOM_MODEL'))
    }
    routing = [ordered]@{
        image_reasoning  = @('race: glm/glm-thinking/agnes-2.5-flash/agnes-2.0-flash','custom-1','custom-2','custom-3','local')
        document_parsing = @('mineru flash','mineru extract')
        ocr              = @('baidu-ocr','windows-ocr','mineru')
    }
}

if ($Json) {
    Write-Output ($data | ConvertTo-Json -Depth 6)
    exit 0
}

Write-Output '## DS Vision Skill - Preflight'
Write-Output ''
Write-Output '### System'
if ($gpu) { Write-Output ("- GPU: {0}; VRAM: {1} GB" -f $gpu.Name, $vramGB) }
Write-Output ("- CPU cores: {0}; RAM: {1} GB" -f $env:NUMBER_OF_PROCESSORS, $ramGB)
Write-Output ''
Write-Output '### Tools'
foreach ($tool in $toolNames) {
    Write-Output ("- {0}: {1}" -f $tool, $(if ($tools[$tool]) { 'OK' } else { 'not found' }))
}
Write-Output ''
Write-Output '### Local runtimes (port probe)'
Write-Output ("- ollama 11434: {0}" -f $ports.ollama)
Write-Output ("- lmstudio 1234: {0}" -f $ports.lmstudio)
Write-Output ("- llamacpp 8080: {0}" -f $ports.llamacpp)
Write-Output ''
Write-Output '### Cloud channels (env keys)'
foreach ($name in $channels.Keys) {
    Write-Output ("- {0}: {1}" -f $name, $(if ($cloud[$name]) { 'OK (key set)' } else { 'dormant (no key)' }))
}
if ($data.notes.baidu_secret_missing) { Write-Output '- baidu-ocr note: BAIDU_API_KEY set but BAIDU_SECRET_KEY missing.' }
if ($data.notes.agnes_base_override) { Write-Output ("- agnes endpoint override: {0}" -f (Get-EnvValue 'AGNES_BASE_URL')) }
foreach ($slot in 1..3) {
    if ($data.notes["custom_${slot}_configured"]) {
        Write-Output ("- custom-{0} endpoint: {1} model={2}" -f $slot, (Get-EnvValue "VISION_CUSTOM_${slot}_BASE_URL"), (Get-EnvValue "VISION_CUSTOM_${slot}_MODEL"))
    }
}
if ($data.notes.legacy_custom_configured) { Write-Output ("- legacy custom endpoint: {0} model={1}" -f (Get-EnvValue 'VISION_CUSTOM_BASE_URL'), (Get-EnvValue 'VISION_CUSTOM_MODEL')) }
Write-Output ''
Write-Output '### Category routing (first available)'
Write-Output '- image_reasoning: race(glm, glm-thinking, agnes-2.5-flash, agnes-2.0-flash) -> custom-1 -> custom-2 -> custom-3 -> local'
Write-Output '- document_parsing: mineru flash -> mineru extract'
Write-Output '- ocr: baidu-ocr -> windows-ocr (local) -> mineru'
