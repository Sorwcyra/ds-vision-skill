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
Write-Output '### cmd.exe launchers'
foreach ($launcher in @('setup.cmd', 'vision-router.cmd')) {
    $path = Join-Path $PSScriptRoot $launcher
    if (Test-Path -LiteralPath $path) {
        Write-Output ("- {0}: OK" -f $launcher)
    } else {
        $failed = $true
        Write-Output ("- {0}: FAIL (missing)" -f $launcher)
    }
}
$cmdSmoke = & cmd.exe /d /c "`"$PSScriptRoot\setup.cmd`" -Status" 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Output '- setup.cmd -Status: OK'
} else {
    $failed = $true
    Write-Output ("- setup.cmd -Status: FAIL ({0})" -f ($cmdSmoke | Out-String).Trim())
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
foreach ($doc in @(
    'SKILL.md',
    'README.md',
    'VERSION',
    'version.json',
    'references\channels.md',
    'references\benchmarks.md',
    'benchmarks\cross-version-mock-2026-08-11.json',
    'benchmarks\cross-version-live-2026-08-11.json',
    'agents\openai.yaml'
)) {
    $path = Join-Path $root $doc
    if (Test-Path -LiteralPath $path) {
        Write-Output ("- {0}: OK" -f $doc)
    } else {
        $failed = $true
        Write-Output ("- {0}: FAIL (missing)" -f $doc)
    }
}

Write-Output ''
Write-Output '### Benchmark data'
foreach ($resultFile in @(
    'benchmarks\cross-version-mock-2026-08-11.json',
    'benchmarks\cross-version-live-2026-08-11.json'
)) {
    try {
        $resultPath = Join-Path $root $resultFile
        $result = Get-Content -Raw -Encoding UTF8 -LiteralPath $resultPath | ConvertFrom-Json
        $versions = @($result.summary | ForEach-Object { $_.version } | Sort-Object)
        $expected = @('0.4.1', '0.4.2', '0.5.0')
        if ($result.benchmark_valid -and (($versions -join '|') -eq ($expected -join '|')) -and @($result.samples).Count -gt 0) {
            Write-Output ("- {0}: OK" -f $resultFile)
        } else {
            $failed = $true
            Write-Output ("- {0}: FAIL (invalid result contract)" -f $resultFile)
        }
    } catch {
        $failed = $true
        Write-Output ("- {0}: FAIL ({1})" -f $resultFile, $_.Exception.Message)
    }
}

Write-Output ''
Write-Output '### Version manifest'
try {
    $versionText = (Get-Content -Raw -LiteralPath (Join-Path $root 'VERSION')).Trim()
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $root 'version.json') | ConvertFrom-Json
    if ($versionText -and $manifest.version -eq $versionText) {
        Write-Output ("- VERSION matches version.json ({0}): OK" -f $versionText)
    } else {
        $failed = $true
        Write-Output ("- VERSION matches version.json: FAIL (VERSION={0}, manifest={1})" -f $versionText, $manifest.version)
    }
} catch {
    $failed = $true
    Write-Output ("- version manifest: FAIL ({0})" -f $_.Exception.Message)
}

Write-Output ''
if ($failed) {
    Write-Output 'RESULT: FAIL'
    exit 1
}

Write-Output 'RESULT: OK'
exit 0
