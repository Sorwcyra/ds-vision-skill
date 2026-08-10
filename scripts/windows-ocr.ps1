# windows-ocr.ps1 - Offline OCR via Windows WinRT OcrEngine (no network).
# ASCII-only source.

param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $ImagePath)) {
    Write-Error "Image not found: $ImagePath"
    exit 1
}
# WinRT GetFileFromPathAsync requires an absolute backslash path;
# forward-slash input (common from shells/agents) throws otherwise.
$ImagePath = [IO.Path]::GetFullPath($ImagePath)

$ext = [IO.Path]::GetExtension($ImagePath).ToLower()
if ($ext -notin @('.png','.jpg','.jpeg','.bmp','.tif','.tiff','.gif','.webp')) {
    Write-Error "Unsupported image type '$ext' for Windows OCR."
    exit 1
}

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime]

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await([object]$WinRtTask, [Type]$ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    return $netTask.Result
}

try {
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($ImagePath)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language('zh-Hans')))
    if (-not $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
    if (-not $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language('en-US'))) }
    if (-not $engine) {
        Write-Error 'No OCR language engine available on this system.'
        exit 1
    }

    $result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
} catch {
    Write-Error "windows-ocr failed: $($_.Exception.Message)"
    exit 1
}

if (-not $result) { exit 0 }
$lines = @()
foreach ($line in $result.Lines) {
    $lines += $line.Text
}
$text = $lines -join "`n"
if ($Json) {
    $envelope = [ordered]@{
        task_type  = 'ocr'
        tool_used  = 'windows-ocr'
        confidence = 'medium'
        result     = $text
        metadata   = [ordered]@{
            lines            = $lines.Count
            engine_language  = $engine.RecognizerLanguage.LanguageTag
            offline          = $true
        }
    }
    Write-Output ($envelope | ConvertTo-Json -Depth 5 -Compress)
} else {
    foreach ($l in $lines) { Write-Output $l }
}
# Explicit exit 0: vision-router.ps1 reads $LASTEXITCODE to detect success;
# without it a stale value makes the router skip this channel.
exit 0
