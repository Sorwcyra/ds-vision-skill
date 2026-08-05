# update-skill.ps1 - Explicit updater for ds-vision-skill git-clone installs.
# This script never overwrites a non-git skill installation.
# ASCII-only source.

param(
    [string]$Remote = 'github',
    [string]$Branch = 'main',
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent $PSScriptRoot
$gitDir = Join-Path $root '.git'
$check = Join-Path $PSScriptRoot 'check-update.ps1'

if ($CheckOnly) {
    & $check
    exit $LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $gitDir)) {
    Write-Output 'This ds-vision-skill installation is not a git clone.'
    Write-Output 'To update safely, reinstall the skill from GitHub or install it as a git clone.'
    Write-Output 'Repository: https://github.com/Sorwcyra/ds-vision-skill'
    exit 1
}

Push-Location $root
try {
    $dirty = git status --porcelain
    if ($dirty) {
        Write-Output 'Local changes detected. Commit, stash, or back them up before updating.'
        Write-Output $dirty
        exit 2
    }

    Write-Output ("Fetching {0}/{1}..." -f $Remote, $Branch)
    git fetch $Remote $Branch
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $before = git rev-parse --short HEAD
    git pull --ff-only $Remote $Branch
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $after = git rev-parse --short HEAD

    Write-Output ("Updated ds-vision-skill: {0} -> {1}" -f $before, $after)

    $smoke = Join-Path $PSScriptRoot 'smoke-test.ps1'
    if (Test-Path -LiteralPath $smoke) {
        & $smoke
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}
