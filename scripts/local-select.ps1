# local-select.ps1 - Pick a local vision model for this machine.
# Uses llmfit when available (or uvx llmfit), falls back to a curated list by VRAM.
# ASCII-only source.

param(
    [switch]$Force,
    [int]$TopN = 5
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$profileDir = Join-Path $env:USERPROFILE '.ds-vision'
$profilePath = Join-Path $profileDir 'local-profile.json'

# --- VRAM detection: nvidia-smi first, CIM fallback ---
$vramGB = $null
$nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($nvidiaSmi) {
    $line = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
    if ($line) { $vramGB = [double](($line -split ' ')[0]) / 1024 }
}
if (-not $vramGB) {
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Sort-Object AdapterRAM -Descending | Select-Object -First 1
    if ($gpu -and $gpu.AdapterRAM) { $vramGB = [Math]::Round($gpu.AdapterRAM / 1GB, 1) }
}
$hasGpu = $vramGB -gt 0

# --- reuse cached profile if hardware unchanged ---
if (-not $Force -and (Test-Path $profilePath)) {
    try {
        $cached = Get-Content -Raw $profilePath | ConvertFrom-Json
        if ($cached.vram_gb -eq $vramGB) {
            Write-Output "CACHED model=$($cached.selected_model) runtime=$($cached.runtime) (profile: $profilePath)"
            exit 0
        }
    } catch { }
}

# --- llmfit acquisition ---
$llmfitCmd = $null
if (Get-Command llmfit -ErrorAction SilentlyContinue) { $llmfitCmd = 'llmfit' }
elseif (Get-Command uvx -ErrorAction SilentlyContinue) { $llmfitCmd = 'uvx llmfit' }

$visionCandidates = @()
$llmfitUsed = $false
if ($llmfitCmd) {
    try {
        $raw = & $llmfitCmd fit --json -n 50 2>$null | Out-String
        $fit = $raw | ConvertFrom-Json
        if ($fit.models) {
            $llmfitUsed = $true
            $visionCandidates = @($fit.models | Where-Object {
                (($_.name + ' ' + $_.use_case + ' ' + $_.category) -match '(?i)vl|vision|multimodal|llava|minicpm|moondream|omni|ocr|smolvlm|internvl|granite|pixtral|gemma3')
            } | Sort-Object score -Descending | Select-Object -First $TopN)
        }
    } catch {
        Write-Output "NOTE: llmfit failed ($($_.Exception.Message)); using fallback list."
    }
}

# --- curated fallback by VRAM ---
if (-not $visionCandidates) {
    if ($hasGpu) {
        if ($vramGB -ge 8) {
            $list = @('qwen2.5-vl:7b','llama3.2-vision:11b','qwen2.5-vl:3b','minicpm-v','moondream')
        } elseif ($vramGB -ge 4) {
            $list = @('qwen2.5-vl:3b','minicpm-v','moondream','smolvlm')
        } else {
            $list = @('moondream','smolvlm')
        }
    } else {
        $list = @('moondream','smolvlm')
    }
    $visionCandidates = @($list | ForEach-Object {
        [pscustomobject]@{ name = $_; provider = 'fallback'; score = 0; fit_level = 'n/a'; runtime = 'ollama' }
    })
}

if (-not $visionCandidates) {
    Write-Error 'No vision model candidates found. Install llmfit (uv tool install llmfit) and retry.'
    exit 1
}

# --- runtime probe ---
function Test-Port([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(500) -and $client.Connected) { return $true }
    } catch { }
    finally { $client.Close() }
    return $false
}
$runtime = 'ollama (not running)'
if (Test-Port 11434) { $runtime = 'ollama (running)' }
elseif (Test-Port 1234) { $runtime = 'lmstudio (running)' }
elseif (Test-Port 8080) { $runtime = 'llamacpp (running)' }

$selected = $visionCandidates[0].name

# --- ollama tag hint (llmfit names are HF-style; ollama uses short tags) ---
$ollamaTag = ''
if ($runtime -match 'ollama') {
    if ($vramGB -ge 8) { $ollamaTag = 'qwen2.5-vl:7b' }
    elseif ($vramGB -ge 4) { $ollamaTag = 'qwen2.5-vl:3b' }
    else { $ollamaTag = 'moondream' }
}

# --- persist profile ---
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir | Out-Null }
$profile = [ordered]@{
    selected_model = $selected
    runtime        = $runtime
    ollama_tag     = $ollamaTag
    llmfit_used    = $llmfitUsed
    vram_gb        = $vramGB
    has_gpu        = $hasGpu
    candidates     = @($visionCandidates | Select-Object name, provider, score, fit_level, runtime)
    generated_at   = (Get-Date).ToString('o')
}
$profile | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $profilePath -Encoding UTF8

Write-Output "SELECTED model=$selected runtime=$runtime vram=${vramGB}GB llmfit=$llmfitUsed"
if ($ollamaTag) { Write-Output "OLLAMA_TAG: $ollamaTag (run: ollama pull $ollamaTag)" }
Write-Output "CANDIDATES: $((@($visionCandidates | ForEach-Object { $_.name }) -join ', '))"
Write-Output "PROFILE: $profilePath"
