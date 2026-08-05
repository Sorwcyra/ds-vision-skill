# check-update.ps1 - Check whether ds-vision-skill has a newer upstream version.
# Read-only except for a small per-user notification cache when -Notify is used.
# ASCII-only source.

param(
    [string]$Repo = 'Sorwcyra/ds-vision-skill',
    [string]$Ref = 'main',
    [switch]$Json,
    [switch]$Notify,
    [int]$NotifyHours = 24,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Read-LocalVersion([string]$Root) {
    $versionFile = Join-Path $Root 'VERSION'
    if (Test-Path -LiteralPath $versionFile) {
        return ((Get-Content -Raw -LiteralPath $versionFile).Trim())
    }
    $manifest = Join-Path $Root 'version.json'
    if (Test-Path -LiteralPath $manifest) {
        try { return ((Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json).version) } catch { }
    }
    return '0.0.0'
}

function Compare-SemVer([string]$A, [string]$B) {
    try {
        $va = [version]($A -replace '^[vV]', '')
        $vb = [version]($B -replace '^[vV]', '')
        return $va.CompareTo($vb)
    } catch {
        return [string]::Compare($A, $B, $true)
    }
}

function Get-CachePath {
    $dir = Join-Path $HOME '.ds-vision'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return (Join-Path $dir 'update-check.json')
}

function Should-Notify([string]$LatestVersion, [int]$Hours, [switch]$ForceNotify) {
    if ($ForceNotify) { return $true }
    $path = Get-CachePath
    if (-not (Test-Path -LiteralPath $path)) { return $true }
    try {
        $cache = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        if ($cache.latest_version -ne $LatestVersion) { return $true }
        $last = [datetime]$cache.notified_at
        return ((Get-Date) - $last).TotalHours -ge $Hours
    } catch {
        return $true
    }
}

function Save-NotifyCache([string]$LatestVersion) {
    $path = Get-CachePath
    [ordered]@{
        latest_version = $LatestVersion
        notified_at    = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $path -Encoding UTF8
}

$root = Split-Path -Parent $PSScriptRoot
$localVersion = Read-LocalVersion $root
try {
    $rawUrl = "https://github.com/$Repo/raw/refs/heads/$Ref/version.json"
    $remote = Invoke-RestMethod -Uri $rawUrl -Headers @{ 'Cache-Control' = 'no-cache' } -UseBasicParsing -TimeoutSec 8
} catch {
    try {
        $rawUrl = "https://raw.githubusercontent.com/$Repo/$Ref/version.json"
        $remote = Invoke-RestMethod -Uri $rawUrl -Headers @{ 'Cache-Control' = 'no-cache' } -UseBasicParsing -TimeoutSec 8
    } catch {
        $result = [ordered]@{
            update_available = $false
            local_version    = $localVersion
            latest_version   = $null
            repository       = "https://github.com/$Repo"
            error            = $_.Exception.Message
        }
        if ($Json) { $result | ConvertTo-Json -Depth 5 | Write-Output } else { Write-Output ("Update check unavailable: {0}" -f $_.Exception.Message) }
        exit 2
    }
}

$latestVersion = [string]$remote.version
$isNewer = (Compare-SemVer $latestVersion $localVersion) -gt 0
$result = [ordered]@{
    update_available = $isNewer
    local_version    = $localVersion
    latest_version   = $latestVersion
    repository       = "https://github.com/$Repo"
    updated          = $remote.updated
    release_notes    = $remote.release_notes
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6 | Write-Output
    exit 0
}

if ($isNewer) {
    if ((-not $Notify) -or (Should-Notify $latestVersion $NotifyHours $Force)) {
        Write-Output ("ds-vision-skill update available: {0} -> {1}" -f $localVersion, $latestVersion)
        Write-Output ("Repository: https://github.com/{0}" -f $Repo)
        Write-Output 'Run scripts/update-skill.ps1 to update if this installation is a git clone.'
        if ($remote.release_notes) {
            Write-Output 'Notes:'
            foreach ($note in @($remote.release_notes)) { Write-Output ("- {0}" -f $note) }
        }
        if ($Notify) { Save-NotifyCache $latestVersion }
    }
} else {
    Write-Output ("ds-vision-skill is up to date ({0})." -f $localVersion)
}
