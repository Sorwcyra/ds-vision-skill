# mineru-extract.ps1 - Wrap the MinerU CLI into the standard vision envelope.
# ASCII-only source.

param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [ValidateSet('flash','extract')][string]$Mode = 'flash',
    [switch]$Json,
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $FilePath)) {
    Write-Error "File not found: $FilePath"
    exit 1
}
$cmd = Get-Command mineru-open-api -ErrorAction SilentlyContinue
if (-not $cmd) {
    Write-Error 'ERROR: mineru-open-api CLI not found. Install via: npm install -g mineru-open-api'
    exit 1
}

if (-not $OutDir) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $FilePath).Hash.Substring(0, 12)
    $OutDir = Join-Path $env:TEMP ("ds-vision-mineru-" + $hash)
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$existingMd = Get-ChildItem -Path $OutDir -Recurse -Filter *.md -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existingMd) {
    $content = [System.IO.File]::ReadAllText($existingMd.FullName, [System.Text.Encoding]::UTF8)
    if ($Json) {
        $envelope = [ordered]@{
            task_type  = 'document_parsing'
            tool_used  = "mineru-$Mode"
            confidence = 'high'
            result     = $content
            metadata   = [ordered]@{
                input  = $FilePath
                output = $existingMd.FullName
                chars  = $content.Length
                cached = $true
            }
        }
        Write-Output ($envelope | ConvertTo-Json -Depth 5 -Compress)
    } else {
        Write-Output $content
    }
    exit 0
}

# The npm PowerShell shim turns node's stderr (progress lines) into error
# records; capture everything with Continue so progress cannot abort us.
$ErrorActionPreference = 'Continue'
if ($Mode -eq 'flash') {
    $mineruOut = & mineru-open-api flash-extract $FilePath -o $OutDir 2>&1
} else {
    $mineruOut = & mineru-open-api extract $FilePath -o $OutDir -f md 2>&1
}
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -ne 0) {
    Write-Error "ERROR: mineru $Mode failed (exit $code)."
    exit 1
}

$md = Get-ChildItem -Path $OutDir -Recurse -Filter *.md -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $md) {
    Write-Error 'ERROR: mineru produced no markdown. Try a content-rich input, or -Mode extract with MINERU_TOKEN set.'
    exit 1
}
# Use .NET read: Get-Content attaches provider properties (PSPath etc.) to the
# string, which makes ConvertTo-Json serialize it as an object instead of text.
$content = [System.IO.File]::ReadAllText($md.FullName, [System.Text.Encoding]::UTF8)

if ($Json) {
    $envelope = [ordered]@{
        task_type  = 'document_parsing'
        tool_used  = "mineru-$Mode"
        confidence = 'high'
        result     = $content
        metadata   = [ordered]@{
            input  = $FilePath
            output = $md.FullName
            chars  = $content.Length
            cached = $false
        }
    }
    Write-Output ($envelope | ConvertTo-Json -Depth 5 -Compress)
} else {
    Write-Output $content
}
exit 0
