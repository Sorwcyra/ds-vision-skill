# smoke-test.ps1 - Lightweight local checks for ds-vision-skill.
# ASCII-only source.

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$failed = $false

Write-Output '## DS Vision Skill - Smoke Test'
Write-Output ''

Write-Output '### PowerShell syntax'
foreach ($f in Get-ChildItem -Path $PSScriptRoot -Filter *.ps1) {
    $errs = $null
    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $f.FullName), [ref]$errs)
    if ($errs -and $errs.Count) {
        $failed = $true
        Write-Output ("- {0}: FAIL" -f $f.Name)
        foreach ($e in $errs) { Write-Output ("  {0}" -f $e.Message) }
    } else {
        Write-Output ("- {0}: OK" -f $f.Name)
    }
}

Write-Output ''
Write-Output '### Preflight JSON'
$preflight = Join-Path $PSScriptRoot 'preflight.ps1'
try {
    $json = & $preflight -Json | ConvertFrom-Json
    if ($json.routing.image_reasoning) {
        Write-Output '- preflight.ps1 -Json: OK'
    } else {
        $failed = $true
        Write-Output '- preflight.ps1 -Json: FAIL (missing routing)'
    }
} catch {
    $failed = $true
    Write-Output ("- preflight.ps1 -Json: FAIL ({0})" -f $_.Exception.Message)
}

Write-Output ''
Write-Output '### Docs'
foreach ($doc in @('SKILL.md','README.md','references\channels.md','agents\openai.yaml')) {
    $path = Join-Path $root $doc
    if (Test-Path -LiteralPath $path) {
        Write-Output ("- {0}: OK" -f $doc)
    } else {
        $failed = $true
        Write-Output ("- {0}: FAIL (missing)" -f $doc)
    }
}

Write-Output ''
if ($failed) {
    Write-Output 'RESULT: FAIL'
    exit 1
}

Write-Output 'RESULT: OK'
exit 0
