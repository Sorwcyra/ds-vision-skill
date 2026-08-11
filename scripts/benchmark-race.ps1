# benchmark-race.ps1 - Reproducible cross-version race benchmark.
# ASCII-only source. Results and temporary snapshots never contain API keys.

[CmdletBinding()]
param(
    [ValidateSet('Mock', 'Live')]
    [string]$Mode = 'Mock',

    [ValidateRange(1, 1000)]
    [int]$RunsPerVersion = 24,

    [ValidateRange(0, 100)]
    [int]$WarmupRuns = 2,

    [string]$ImagePath = '',
    [string]$OutputPath = '',
    [string]$PythonPath = '',

    [ValidateRange(10, 600)]
    [int]$ProcessTimeoutSec = 180
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:SecretsToRedact = @()
$script:ExpectedModels = @(
    'agnes-2.5-flash',
    'agnes-2.0-flash',
    'glm-4v-flash',
    'glm-4.1v-thinking-flash'
)
$script:Versions = @(
    [pscustomobject]@{
        version = '0.4.1'
        commit = 'ba795e63f16e6d8f2d2e107661c62a9e8775f6af'
        tree = 'a52ee6f019968dc186d82a3f87031c58552848a9'
        patch_files = @('scripts/vlm-vision.ps1')
        patch_count = 2
    },
    [pscustomobject]@{
        version = '0.4.2'
        commit = '096ce662b3114d37e3eb11c2f2714e230f4f5cc6'
        tree = '8ede21f56af339c083e9b7b28555b4fffeafa14b'
        patch_files = @('scripts/vision-router.ps1', 'scripts/vlm-vision.ps1')
        patch_count = 4
    },
    [pscustomobject]@{
        version = '0.5.0'
        commit = 'd48ab934026aa3da6a1be085008b61880df7b48c'
        tree = '065cb1900c6359d72f0e9b42b715cbd38fa27867'
        patch_files = @()
        patch_count = 0
    }
)

function Invoke-Git([string[]]$Arguments, [switch]$AllowFailure) {
    $output = @(& git @Arguments 2>&1)
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) {
        throw "git $($Arguments -join ' ') failed (exit $code): $($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{ code = $code; output = @($output) }
}

function Get-FileSha256([string]$LiteralPath) {
    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StringSha256([string]$Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Quote-PowerShellSingle([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Quote-ProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-ScopedEnvironmentValue([string]$Name) {
    foreach ($scope in @('Process', 'User', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable($Name, $scope)
        if ($value) { return $value }
    }
    return $null
}

function Get-CacheStats([string]$ProfilePath) {
    $cachePath = [IO.Path]::GetFullPath((Join-Path $ProfilePath '.ds-vision\cache'))
    $profileFull = [IO.Path]::GetFullPath($ProfilePath).TrimEnd('\') + '\'
    if (-not $cachePath.StartsWith($profileFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Resolved cache path escaped the isolated benchmark profile.'
    }
    if (-not (Test-Path -LiteralPath $cachePath)) {
        return [pscustomobject]@{ files = 0; bytes = 0 }
    }
    $files = @(Get-ChildItem -LiteralPath $cachePath -Recurse -File -ErrorAction Stop)
    $bytes = 0L
    foreach ($file in $files) { $bytes += [long]$file.Length }
    return [pscustomobject]@{ files = $files.Count; bytes = $bytes }
}

function Get-PercentileNearestRank([double[]]$Values, [double]$Percentile) {
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $rank = [Math]::Ceiling(($Percentile / 100.0) * $sorted.Count)
    if ($rank -lt 1) { $rank = 1 }
    return [double]$sorted[$rank - 1]
}

function Get-MetricStats([object[]]$Values) {
    $numbers = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($numbers.Count -eq 0) { return $null }
    $mean = [double](($numbers | Measure-Object -Average).Average)
    $variance = 0.0
    foreach ($number in $numbers) { $variance += [Math]::Pow(($number - $mean), 2) }
    $variance = $variance / $numbers.Count
    return [ordered]@{
        n = $numbers.Count
        min = [Math]::Round([double](($numbers | Measure-Object -Minimum).Minimum), 3)
        p50 = [Math]::Round((Get-PercentileNearestRank $numbers 50), 3)
        p90 = [Math]::Round((Get-PercentileNearestRank $numbers 90), 3)
        p95 = [Math]::Round((Get-PercentileNearestRank $numbers 95), 3)
        mean = [Math]::Round($mean, 3)
        stddev_population = [Math]::Round([Math]::Sqrt($variance), 3)
        max = [Math]::Round([double](($numbers | Measure-Object -Maximum).Maximum), 3)
    }
}

function Protect-Diagnostic([string]$Value, [string]$TempRoot) {
    if (-not $Value) { return '' }
    $protected = $Value
    foreach ($path in @($TempRoot, $script:RepoRoot, $env:USERPROFILE)) {
        if ($path) { $protected = $protected.Replace($path, '<redacted-path>') }
    }
    foreach ($secret in $script:SecretsToRedact) {
        if ($secret) {
            $protected = $protected.Replace(('Bearer ' + $secret), 'Bearer <redacted-secret>')
            $protected = $protected.Replace($secret, '<redacted-secret>')
        }
    }
    if ($protected.Length -gt 1000) { $protected = $protected.Substring(0, 1000) }
    return $protected
}

function Assert-ReleaseIdentity([object]$VersionInfo) {
    $exists = Invoke-Git @('cat-file', '-e', ($VersionInfo.commit + '^{commit}')) -AllowFailure
    if ($exists.code -ne 0) {
        throw "Required release commit is missing (possibly a shallow clone): $($VersionInfo.commit)"
    }
    $tree = ((Invoke-Git @('rev-parse', ($VersionInfo.commit + '^{tree}'))).output -join '').Trim()
    if ($tree -ne $VersionInfo.tree) {
        throw "Tree mismatch for $($VersionInfo.version): expected $($VersionInfo.tree), got $tree"
    }
    $versionText = ((Invoke-Git @('show', ($VersionInfo.commit + ':VERSION'))).output -join "`n").Trim()
    $versionJsonText = ((Invoke-Git @('show', ($VersionInfo.commit + ':version.json'))).output -join "`n")
    $versionJson = $versionJsonText | ConvertFrom-Json
    if ($versionText -ne $VersionInfo.version -or [string]$versionJson.version -ne $VersionInfo.version) {
        throw "Release metadata mismatch for commit $($VersionInfo.commit)."
    }
}

function Get-TreeManifest([string]$Commit) {
    $lines = (Invoke-Git @('ls-tree', '-r', '--full-tree', $Commit)).output
    $entries = @()
    foreach ($lineObject in $lines) {
        $line = [string]$lineObject
        if ($line -notmatch '^(\d+) blob ([0-9a-f]{40})\t(.+)$') {
            throw "Unexpected git ls-tree entry: $line"
        }
        $entries += [pscustomobject]@{ mode = $Matches[1]; oid = $Matches[2]; path = $Matches[3] }
    }
    return @($entries)
}

function Assert-Snapshot([string]$SnapshotRoot, [object[]]$Manifest) {
    $actualFiles = @(Get-ChildItem -LiteralPath $SnapshotRoot -Recurse -File | ForEach-Object {
        $_.FullName.Substring($SnapshotRoot.Length).TrimStart('\').Replace('\', '/')
    } | Sort-Object)
    $expectedFiles = @($Manifest | ForEach-Object { $_.path } | Sort-Object)
    if (($actualFiles -join "`n") -ne ($expectedFiles -join "`n")) {
        throw 'Extracted snapshot path set does not match the release tree.'
    }
    foreach ($entry in $Manifest) {
        $filePath = Join-Path $SnapshotRoot ($entry.path.Replace('/', '\'))
        # git archive materializes the platform working-tree EOL convention.
        # Reapply the repository path filters before comparing the logical blob.
        $oid = ((Invoke-Git @('hash-object', ('--path=' + $entry.path), '--', $filePath)).output -join '').Trim()
        if ($oid -ne $entry.oid) {
            throw "Snapshot blob mismatch: $($entry.path)"
        }
    }
}

function Export-ReleaseSnapshot([object]$VersionInfo, [string]$TempRoot) {
    Assert-ReleaseIdentity $VersionInfo
    $archivePath = Join-Path $TempRoot ("release-{0}.zip" -f $VersionInfo.version)
    $snapshotRoot = Join-Path $TempRoot ("release-{0}" -f $VersionInfo.version)
    [void](New-Item -ItemType Directory -Path $snapshotRoot -Force)
    [void](Invoke-Git @('archive', '--format=zip', ('--output=' + $archivePath), $VersionInfo.commit))
    Expand-Archive -LiteralPath $archivePath -DestinationPath $snapshotRoot -Force
    $manifest = @(Get-TreeManifest $VersionInfo.commit)
    Assert-Snapshot $snapshotRoot $manifest
    $manifestText = (($manifest | Sort-Object path | ForEach-Object { "$($_.mode) $($_.oid) $($_.path)" }) -join "`n") + "`n"
    return [pscustomobject]@{
        root = $snapshotRoot
        archive_sha256 = Get-FileSha256 $archivePath
        manifest_sha256 = Get-StringSha256 $manifestText
        manifest_file_count = $manifest.Count
        manifest = @($manifest)
        patches = @()
    }
}

function Assert-PatchedSnapshot([object]$Snapshot, [string[]]$AllowedPaths) {
    $allowed = @{}
    foreach ($path in $AllowedPaths) { $allowed[$path.Replace('\', '/')] = $true }
    $actualFiles = @(Get-ChildItem -LiteralPath $Snapshot.root -Recurse -File | ForEach-Object {
        $_.FullName.Substring($Snapshot.root.Length).TrimStart('\').Replace('\', '/')
    } | Sort-Object)
    $expectedFiles = @($Snapshot.manifest | ForEach-Object { $_.path } | Sort-Object)
    if (($actualFiles -join "`n") -ne ($expectedFiles -join "`n")) {
        throw 'Endpoint injection changed the snapshot path set.'
    }
    foreach ($entry in $Snapshot.manifest) {
        if ($allowed.ContainsKey($entry.path)) { continue }
        $filePath = Join-Path $Snapshot.root ($entry.path.Replace('/', '\'))
        $oid = ((Invoke-Git @('hash-object', ('--path=' + $entry.path), '--', $filePath)).output -join '').Trim()
        if ($oid -ne $entry.oid) { throw "Endpoint injection changed a non-whitelisted file: $($entry.path)" }
    }
}

function Set-MockEndpointInSnapshot([object]$VersionInfo, [object]$Snapshot, [string]$MockEndpoint) {
    if ($VersionInfo.patch_count -eq 0) { return @() }
    $officialEndpoint = 'https://open.bigmodel.cn/api/paas/v4/chat/completions'
    $patches = @()
    $total = 0
    foreach ($relativePath in $VersionInfo.patch_files) {
        $filePath = Join-Path $Snapshot.root ($relativePath.Replace('/', '\'))
        $beforeHash = Get-FileSha256 $filePath
        $content = [IO.File]::ReadAllText($filePath, [Text.UTF8Encoding]::new($false))
        $count = ([regex]::Matches($content, [regex]::Escape($officialEndpoint))).Count
        if ($count -lt 1) { throw "Expected fixed GLM endpoint was not found in $relativePath" }
        $updated = $content.Replace($officialEndpoint, $MockEndpoint)
        [IO.File]::WriteAllText($filePath, $updated, [Text.UTF8Encoding]::new($false))
        $afterHash = Get-FileSha256 $filePath
        $total += $count
        $patches += [pscustomobject]@{
            file = $relativePath
            replacements = $count
            before_sha256 = $beforeHash
            after_sha256 = $afterHash
        }
    }
    if ($total -ne $VersionInfo.patch_count) {
        throw "Mock endpoint injection count mismatch for $($VersionInfo.version): expected $($VersionInfo.patch_count), got $total"
    }
    $remaining = @(Get-ChildItem -LiteralPath (Join-Path $Snapshot.root 'scripts') -Filter '*.ps1' -File | Select-String -SimpleMatch $officialEndpoint)
    if ($remaining.Count -gt 0) {
        throw "A production GLM endpoint remains reachable in the $($VersionInfo.version) mock snapshot."
    }
    Assert-PatchedSnapshot $Snapshot @($VersionInfo.patch_files)
    return @($patches)
}

function Resolve-PythonExecutable([string]$RequestedPath) {
    if ($RequestedPath) {
        $resolved = (Resolve-Path -LiteralPath $RequestedPath).Path
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Python executable not found: $RequestedPath" }
        return $resolved
    }
    foreach ($name in @('python.exe', 'python', 'py.exe')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    throw 'Python 3 is required for Mock mode. Pass -PythonPath if it is not on PATH.'
}

function Start-BenchmarkMock([string]$PythonExecutable, [string]$TempRoot) {
    $mockScript = Join-Path $PSScriptRoot 'benchmark-mock.py'
    if (-not (Test-Path -LiteralPath $mockScript -PathType Leaf)) { throw "Mock server script not found: $mockScript" }
    $readyPath = Join-Path $TempRoot 'mock-ready.json'
    $stdoutPath = Join-Path $TempRoot 'mock-stdout.log'
    $stderrPath = Join-Path $TempRoot 'mock-stderr.log'
    $argumentLine = (Quote-ProcessArgument $mockScript) + ' --host 127.0.0.1 --port 0 --ready-file ' + (Quote-ProcessArgument $readyPath)
    $process = Start-Process -FilePath $PythonExecutable -ArgumentList $argumentLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $readyPath)) {
            if ($process.HasExited) {
                $errorText = if (Test-Path -LiteralPath $stderrPath) { [IO.File]::ReadAllText($stderrPath) } else { '' }
                throw "Mock server exited before becoming ready: $errorText"
            }
            Start-Sleep -Milliseconds 50
        }
        if (-not (Test-Path -LiteralPath $readyPath)) { throw 'Mock server readiness timed out.' }
        $ready = ([IO.File]::ReadAllText($readyPath, [Text.Encoding]::ASCII) | ConvertFrom-Json)
        if ([int]$ready.pid -ne $process.Id) { throw 'Mock ready file PID does not match the started process.' }
        $baseUri = "http://127.0.0.1:$($ready.port)"
        $health = Invoke-RestMethod -UseBasicParsing -Uri ($baseUri + '/health') -Method Get -TimeoutSec 5
        if ($health.status -ne 'ok') { throw 'Mock server health check failed.' }
        return [pscustomobject]@{
            process = $process
            base_uri = $baseUri
            endpoint = $baseUri + '/v1/chat/completions'
            ready = $ready
            stdout_path = $stdoutPath
            stderr_path = $stderrPath
        }
    } catch {
        if (-not $process.HasExited) {
            [void](& taskkill.exe /PID $process.Id /T /F 2>$null)
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
        throw
    }
}

function Stop-BenchmarkMock([object]$Mock) {
    if (-not $Mock -or -not $Mock.process) { return }
    if (-not $Mock.process.HasExited) {
        try {
            [void](Invoke-RestMethod -UseBasicParsing -Uri ($Mock.base_uri + '/shutdown') -Method Post -Body '' -TimeoutSec 5)
        } catch { }
        if (-not $Mock.process.WaitForExit(5000)) {
            [void](& taskkill.exe /PID $Mock.process.Id /T /F 2>$null)
            [void]$Mock.process.WaitForExit(5000)
        }
    }
    $Mock.process.Dispose()
}

function Get-MockRunStats([object]$Mock, [string]$RunId) {
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $stats = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $encodedRunId = [Uri]::EscapeDataString($RunId)
            $stats = Invoke-RestMethod -UseBasicParsing -Uri ($Mock.base_uri + '/stats?run_id=' + $encodedRunId) -Method Get -TimeoutSec 5
            if ([int]$stats.request_count -ge 4 -and $null -ne $stats.race_latency_ms) { break }
        } catch { }
        Start-Sleep -Milliseconds 25
    }
    return $stats
}

function Invoke-VersionRun(
    [object]$VersionInfo,
    [object]$Snapshot,
    [string]$FixturePath,
    [string]$FixtureSha256,
    [string]$RunId,
    [string]$Phase,
    [int]$Iteration,
    [int]$OrderPosition,
    [string]$BenchmarkMode,
    [object]$Mock,
    [string]$TempRoot
) {
    if ((Get-FileSha256 $FixturePath) -ne $FixtureSha256) { throw 'Benchmark fixture changed during the run.' }
    $runProfile = Join-Path $TempRoot ("profile-{0}" -f $RunId)
    $cachePath = Join-Path $runProfile '.ds-vision\cache'
    [void](New-Item -ItemType Directory -Path $cachePath -Force)
    $beforeCache = Get-CacheStats $runProfile
    $prompt = "Describe the image briefly. BENCH_RUN_ID=$RunId"
    $routerPath = Join-Path $Snapshot.root 'scripts\vision-router.ps1'
    $command = @(
        '$ErrorActionPreference = ''Stop''',
        '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)',
        ('& {0} -Path {1} -Intent reason -Prompt {2} -Json -NoCache' -f (Quote-PowerShellSingle $routerPath), (Quote-PowerShellSingle $FixturePath), (Quote-PowerShellSingle $prompt)),
        'exit $LASTEXITCODE'
    ) -join '; '
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $PSHOME 'powershell.exe'
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['USERPROFILE'] = $runProfile
    $psi.EnvironmentVariables['HOME'] = $runProfile
    if ($BenchmarkMode -eq 'Mock') {
        $psi.EnvironmentVariables['GLM_API_KEY'] = 'benchmark-dummy-key'
        $psi.EnvironmentVariables['AGNES_API_KEY'] = 'benchmark-dummy-key'
        $psi.EnvironmentVariables['GLM_BASE_URL'] = $Mock.endpoint
        $psi.EnvironmentVariables['AGNES_BASE_URL'] = $Mock.endpoint
        foreach ($slot in 1..3) {
            $psi.EnvironmentVariables["VISION_CUSTOM_${slot}_API_KEY"] = 'benchmark-dummy-key'
            $psi.EnvironmentVariables["VISION_CUSTOM_${slot}_BASE_URL"] = $Mock.endpoint
            $psi.EnvironmentVariables["VISION_CUSTOM_${slot}_MODEL"] = "benchmark-custom-$slot"
        }
        $psi.EnvironmentVariables['VISION_CUSTOM_API_KEY'] = 'benchmark-dummy-key'
        $psi.EnvironmentVariables['VISION_CUSTOM_BASE_URL'] = $Mock.endpoint
        $psi.EnvironmentVariables['VISION_CUSTOM_MODEL'] = 'benchmark-custom'
    } else {
        $psi.EnvironmentVariables['GLM_BASE_URL'] = 'https://open.bigmodel.cn/api/paas/v4/chat/completions'
        $psi.EnvironmentVariables['AGNES_BASE_URL'] = 'https://api.agnes-ai.cn/v1/chat/completions'
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $started = $process.Start()
    if (-not $started) { throw "Failed to start PowerShell for $($VersionInfo.version)." }
    $timedOut = -not $process.WaitForExit($ProcessTimeoutSec * 1000)
    if ($timedOut) {
        [void](& taskkill.exe /PID $process.Id /T /F 2>$null)
        [void]$process.WaitForExit(10000)
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $stopwatch.Stop()
    $exitCode = if ($timedOut) { -1 } else { $process.ExitCode }
    $process.Dispose()
    $afterCache = Get-CacheStats $runProfile

    $parsed = $null
    $parseError = ''
    try {
        if ($stdout.Trim()) { $parsed = $stdout.Trim() | ConvertFrom-Json }
        else { $parseError = 'stdout was empty' }
    } catch {
        $parseError = $_.Exception.Message
    }
    $resultText = if ($parsed -and $null -ne $parsed.result) { [string]$parsed.result } else { '' }
    $winner = ''
    $reportedLatency = $null
    $reportedStarted = 0
    if ($parsed -and $parsed.metadata) {
        if ($parsed.metadata.latency_ms -ne $null) { $reportedLatency = [double]$parsed.metadata.latency_ms }
        if ($parsed.metadata.race) {
            $winner = [string]$parsed.metadata.race.winner
            $reportedStarted = @($parsed.metadata.race.started_channels).Count
        }
        if (-not $winner -and $parsed.metadata.channel) { $winner = [string]$parsed.metadata.channel }
    }
    $processSuccess = (-not $timedOut -and $exitCode -eq 0 -and $parsed -and $resultText)
    $stats = $null
    $requestCount = $null
    $uniqueModels = @()
    $fullFanout = $false
    $authOk = $null
    $loopbackOk = $null
    $serverRaceMs = $null
    $fanoutSpreadMs = $null
    $firstReadyModel = ''
    if ($BenchmarkMode -eq 'Mock') {
        $stats = Get-MockRunStats $Mock $RunId
        if ($stats) {
            $requestCount = [int]$stats.request_count
            $uniqueModels = @($stats.unique_models)
            $serverRaceMs = if ($null -ne $stats.race_latency_ms) { [double]$stats.race_latency_ms } else { $null }
            $fanoutSpreadMs = if ($null -ne $stats.fanout_spread_ms) { [double]$stats.fanout_spread_ms } else { $null }
            $firstReadyModel = [string]$stats.first_ready_model
            $authOk = (@($stats.events | Where-Object { -not $_.authorization_ok }).Count -eq 0)
            $loopbackOk = (@($stats.events | Where-Object { -not $_.client_is_loopback }).Count -eq 0)
            $fullFanout = ($requestCount -eq 4 -and (($uniqueModels | Sort-Object) -join '|') -eq (($script:ExpectedModels | Sort-Object) -join '|'))
        }
    } else {
        $requestCount = $reportedStarted
        $fullFanout = ($reportedStarted -eq 4)
    }
    $outputMatches = $true
    $selectedFastest = $null
    $winnerMatchesFirstReady = $null
    $mockResultModel = ''
    if ($BenchmarkMode -eq 'Mock') {
        $matchPattern = '^BENCH_OK:([^:]+):' + [regex]::Escape($RunId) + '$'
        if ($resultText -match $matchPattern) { $mockResultModel = $Matches[1] }
        $outputMatches = [bool]($mockResultModel -and $script:ExpectedModels -contains $mockResultModel)
        $selectedFastest = [bool]($mockResultModel -eq 'glm-4v-flash')
        $winnerMatchesFirstReady = [bool]($mockResultModel -and $mockResultModel -eq $firstReadyModel)
    }
    $strictSuccess = [bool]($processSuccess -and $fullFanout -and $outputMatches)
    if ($BenchmarkMode -eq 'Mock') {
        $strictSuccess = [bool]($strictSuccess -and $authOk -and $loopbackOk)
    }
    $diagnostic = ''
    if (-not $strictSuccess) {
        $diagnostic = Protect-Diagnostic ((@($parseError, $stderr.Trim(), $stdout.Trim()) | Where-Object { $_ }) -join ' | ') $TempRoot
    }
    return [pscustomobject][ordered]@{
        version = $VersionInfo.version
        commit = $VersionInfo.commit
        phase = $Phase
        iteration = $Iteration
        order_position = $OrderPosition
        run_id = $RunId
        timestamp_utc = [DateTime]::UtcNow.ToString('o')
        wall_ms = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 3)
        reported_winner_latency_ms = $reportedLatency
        server_race_ms = $serverRaceMs
        fanout_spread_ms = $fanoutSpreadMs
        winner = $winner
        first_ready_model = $firstReadyModel
        request_count = $requestCount
        unique_models = @($uniqueModels)
        full_fanout = [bool]$fullFanout
        authorization_ok = $authOk
        loopback_only = $loopbackOk
        process_success = [bool]$processSuccess
        measurement_valid = [bool]$strictSuccess
        strict_success = [bool]$strictSuccess
        exit_code = $exitCode
        timed_out = [bool]$timedOut
        output_matches_mock_contract = [bool]$outputMatches
        selected_fastest_model = $selectedFastest
        winner_matches_first_ready = $winnerMatchesFirstReady
        cache_files_before = $beforeCache.files
        cache_files_after = $afterCache.files
        cache_bytes_after = $afterCache.bytes
        diagnostic = $diagnostic
    }
}

function Get-VersionSummary([object[]]$Samples, [string]$Version) {
    $measured = @($Samples | Where-Object { $_.version -eq $Version -and $_.phase -eq 'measured' })
    $valid = @($measured | Where-Object { $_.strict_success })
    $winnerCounts = [ordered]@{}
    foreach ($group in @($valid | Group-Object winner | Sort-Object Name)) { $winnerCounts[$group.Name] = $group.Count }
    $successRate = if ($measured.Count) { 100.0 * $valid.Count / $measured.Count } else { 0.0 }
    $fanoutCount = @($measured | Where-Object { $_.full_fanout }).Count
    $fanoutRate = if ($measured.Count) { 100.0 * $fanoutCount / $measured.Count } else { 0.0 }
    $fastestSelections = @($valid | Where-Object { $_.selected_fastest_model -eq $true }).Count
    $fastestSelectionRate = if (@($valid | Where-Object { $null -ne $_.selected_fastest_model }).Count) {
        100.0 * $fastestSelections / @($valid | Where-Object { $null -ne $_.selected_fastest_model }).Count
    } else { $null }
    $firstReadyMatches = @($valid | Where-Object { $_.winner_matches_first_ready -eq $true }).Count
    $firstReadyMatchRate = if (@($valid | Where-Object { $null -ne $_.winner_matches_first_ready }).Count) {
        100.0 * $firstReadyMatches / @($valid | Where-Object { $null -ne $_.winner_matches_first_ready }).Count
    } else { $null }
    return [ordered]@{
        version = $Version
        measured_n = $measured.Count
        valid_n = $valid.Count
        strict_success_rate_pct = [Math]::Round($successRate, 2)
        full_fanout_rate_pct = [Math]::Round($fanoutRate, 2)
        fastest_model_selected_rate_pct = if ($null -ne $fastestSelectionRate) { [Math]::Round($fastestSelectionRate, 2) } else { $null }
        first_ready_response_selected_rate_pct = if ($null -ne $firstReadyMatchRate) { [Math]::Round($firstReadyMatchRate, 2) } else { $null }
        winner_counts = $winnerCounts
        wall_ms = Get-MetricStats @($valid | ForEach-Object { $_.wall_ms })
        server_race_ms = Get-MetricStats @($valid | ForEach-Object { $_.server_race_ms })
        fanout_spread_ms = Get-MetricStats @($valid | ForEach-Object { $_.fanout_spread_ms })
        reported_winner_latency_ms = Get-MetricStats @($valid | ForEach-Object { $_.reported_winner_latency_ms })
        cache_files_after = Get-MetricStats @($measured | ForEach-Object { $_.cache_files_after })
    }
}

function Get-ReductionPercent([object]$OldValue, [object]$NewValue) {
    if ($null -eq $OldValue -or $null -eq $NewValue -or [double]$OldValue -eq 0) { return $null }
    return [Math]::Round((([double]$OldValue - [double]$NewValue) / [double]$OldValue) * 100.0, 2)
}

function Get-Comparison([object]$OldSummary, [object]$NewSummary) {
    return [ordered]@{
        from = $OldSummary.version
        to = $NewSummary.version
        wall_p50_reduction_pct = Get-ReductionPercent $OldSummary.wall_ms.p50 $NewSummary.wall_ms.p50
        wall_p95_reduction_pct = Get-ReductionPercent $OldSummary.wall_ms.p95 $NewSummary.wall_ms.p95
        server_race_p50_reduction_pct = Get-ReductionPercent $OldSummary.server_race_ms.p50 $NewSummary.server_race_ms.p50
        fanout_spread_p50_reduction_pct = Get-ReductionPercent $OldSummary.fanout_spread_ms.p50 $NewSummary.fanout_spread_ms.p50
    }
}

$tempRoot = $null
$mock = $null
try {
    Push-Location $script:RepoRoot
    try {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is required.' }
        $customFixture = [bool]$ImagePath
        if ($customFixture) { $ImagePath = (Resolve-Path -LiteralPath $ImagePath).Path }
        if (-not $OutputPath) {
            $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
            $OutputPath = Join-Path $script:RepoRoot ("benchmarks\cross-version-{0}-{1}.json" -f $Mode.ToLowerInvariant(), $stamp)
        }
        if (-not [IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path $script:RepoRoot $OutputPath }
        $OutputPath = [IO.Path]::GetFullPath($OutputPath)
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force)

        if ($Mode -eq 'Live') {
            $glmSecret = Get-ScopedEnvironmentValue 'GLM_API_KEY'
            $agnesSecret = Get-ScopedEnvironmentValue 'AGNES_API_KEY'
            if (-not $glmSecret -or -not $agnesSecret) {
                throw 'Live mode requires both GLM_API_KEY and AGNES_API_KEY. Values are never printed or recorded.'
            }
            $script:SecretsToRedact = @($glmSecret, $agnesSecret)
        }

        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $tempRoot = Join-Path $tempBase ('ds-vision-benchmark-' + [Guid]::NewGuid().ToString('N'))
        $tempRoot = [IO.Path]::GetFullPath($tempRoot)
        if (-not $tempRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe benchmark temp root.' }
        [void](New-Item -ItemType Directory -Path $tempRoot)
        [IO.File]::WriteAllText((Join-Path $tempRoot '.ds-vision-benchmark-root'), 'owned', [Text.Encoding]::ASCII)

        $python = $null
        if ($Mode -eq 'Mock') {
            $python = Resolve-PythonExecutable $PythonPath
            $mock = Start-BenchmarkMock $python $tempRoot
        }

        $snapshots = [ordered]@{}
        $releaseMetadata = @()
        foreach ($versionInfo in $script:Versions) {
            Write-Host ("Preparing release {0} ({1})..." -f $versionInfo.version, $versionInfo.commit.Substring(0, 12))
            $snapshot = Export-ReleaseSnapshot $versionInfo $tempRoot
            $patches = @()
            if ($Mode -eq 'Mock') { $patches = @(Set-MockEndpointInSnapshot $versionInfo $snapshot $mock.endpoint) }
            $snapshots[$versionInfo.version] = $snapshot
            $patchText = (($patches | ForEach-Object { "$($_.file)|$($_.replacements)|$($_.before_sha256)|$($_.after_sha256)" }) -join "`n")
            $releaseMetadata += [ordered]@{
                version = $versionInfo.version
                commit = $versionInfo.commit
                tree = $versionInfo.tree
                archive_sha256 = $snapshot.archive_sha256
                manifest_sha256 = $snapshot.manifest_sha256
                manifest_file_count = $snapshot.manifest_file_count
                endpoint_injection = @($patches)
                endpoint_injection_manifest_sha256 = if ($patchText) { Get-StringSha256 $patchText } else { $null }
            }
        }

        $fixtureSource = 'custom path supplied by operator'
        if (-not $customFixture) {
            $ImagePath = Join-Path $snapshots['0.5.0'].root 'assets\star-history.png'
            $fixtureSource = 'immutable asset from the v0.5.0 release snapshot'
            $expectedFixtureSha = '1556668875623ec5d7aa6faef537f8c85311eaa42d79c9d677a44fa9f51449c6'
            if ((Get-FileSha256 $ImagePath) -ne $expectedFixtureSha) {
                throw 'The canonical v0.5.0 benchmark fixture does not match its pinned SHA-256.'
            }
        }
        $fixtureSha = Get-FileSha256 $ImagePath
        $fixtureInfo = Get-Item -LiteralPath $ImagePath
        $fixtureWidth = $null
        $fixtureHeight = $null
        try {
            Add-Type -AssemblyName System.Drawing
            $bitmap = New-Object Drawing.Bitmap($ImagePath)
            try { $fixtureWidth = $bitmap.Width; $fixtureHeight = $bitmap.Height } finally { $bitmap.Dispose() }
        } catch { }

        $permutations = @(
            [pscustomobject]@{ order = @('0.4.1', '0.4.2', '0.5.0') },
            [pscustomobject]@{ order = @('0.4.1', '0.5.0', '0.4.2') },
            [pscustomobject]@{ order = @('0.4.2', '0.4.1', '0.5.0') },
            [pscustomobject]@{ order = @('0.4.2', '0.5.0', '0.4.1') },
            [pscustomobject]@{ order = @('0.5.0', '0.4.1', '0.4.2') },
            [pscustomobject]@{ order = @('0.5.0', '0.4.2', '0.4.1') }
        )
        $samples = @()
        foreach ($phaseInfo in @(
            [pscustomobject]@{ name = 'warmup'; count = $WarmupRuns },
            [pscustomobject]@{ name = 'measured'; count = $RunsPerVersion }
        )) {
            for ($iteration = 1; $iteration -le $phaseInfo.count; $iteration++) {
                $permutation = $permutations[($iteration - 1) % $permutations.Count].order
                for ($position = 0; $position -lt $permutation.Count; $position++) {
                    $versionName = $permutation[$position]
                    $versionInfo = @($script:Versions | Where-Object { $_.version -eq $versionName })[0]
                    $nonce = [Guid]::NewGuid().ToString('N').Substring(0, 10)
                    $runId = ("{0}-{1}-{2}-{3}" -f $Mode.ToLowerInvariant(), $versionName.Replace('.', ''), $phaseInfo.name.Substring(0, 1), $nonce)
                    $sample = Invoke-VersionRun $versionInfo $snapshots[$versionName] $ImagePath $fixtureSha $runId $phaseInfo.name $iteration ($position + 1) $Mode $mock $tempRoot
                    $samples += $sample
                    Write-Host ("[{0} {1}/{2}] v{3} wall={4:N1}ms winner={5} strict={6}" -f $phaseInfo.name, $iteration, $phaseInfo.count, $versionName, $sample.wall_ms, $sample.winner, $sample.strict_success)
                }
            }
        }

        $summaries = @()
        foreach ($versionInfo in $script:Versions) { $summaries += Get-VersionSummary $samples $versionInfo.version }
        $summary041 = @($summaries | Where-Object { $_.version -eq '0.4.1' })[0]
        $summary042 = @($summaries | Where-Object { $_.version -eq '0.4.2' })[0]
        $summary050 = @($summaries | Where-Object { $_.version -eq '0.5.0' })[0]
        $comparisons = @(
            Get-Comparison $summary041 $summary042
            Get-Comparison $summary042 $summary050
            Get-Comparison $summary041 $summary050
        )
        $benchmarkValid = (@($summaries | Where-Object { $_.measured_n -ne $RunsPerVersion -or $_.valid_n -ne $RunsPerVersion }).Count -eq 0)

        $gitVersion = ((Invoke-Git @('--version')).output -join ' ').Trim()
        $pythonVersion = $null
        if ($python) { $pythonVersion = (& $python --version 2>&1 | Out-String).Trim() }
        $os = Get-CimInstance Win32_OperatingSystem
        $computer = Get-CimInstance Win32_ComputerSystem
        $head = ((Invoke-Git @('rev-parse', 'HEAD')).output -join '').Trim()
        $dirty = ((Invoke-Git @('status', '--porcelain')).output.Count -gt 0)
        $promptTemplate = 'Describe the image briefly. BENCH_RUN_ID={unique-run-id}'
        $result = [ordered]@{
            schema_version = 2
            benchmark = 'ds-vision-skill cross-version race'
            mode = $Mode.ToLowerInvariant()
            benchmark_valid = [bool]$benchmarkValid
            generated_at_utc = [DateTime]::UtcNow.ToString('o')
            method = [ordered]@{
                release_behavior = 'as-shipped; endpoint-only injection in isolated old-version Mock snapshots'
                percentile = 'nearest-rank'
                warmup_runs_per_version = $WarmupRuns
                measured_runs_per_version = $RunsPerVersion
                process_boundary = 'fresh powershell.exe per sample'
                cache = 'unique USERPROFILE per sample with -NoCache; released behavior preserved'
                order = 'six fixed balanced permutations cycled by iteration'
                prompt_template = $promptTemplate
                prompt_template_sha256 = Get-StringSha256 $promptTemplate
                process_timeout_sec = $ProcessTimeoutSec
            }
            environment = [ordered]@{
                os_caption = [string]$os.Caption
                os_version = [string]$os.Version
                os_build = [string]$os.BuildNumber
                cpu = [string]$env:PROCESSOR_IDENTIFIER
                logical_processors = [int]$computer.NumberOfLogicalProcessors
                memory_bytes = [long]$computer.TotalPhysicalMemory
                powershell = $PSVersionTable.PSVersion.ToString()
                git = $gitVersion
                python = $pythonVersion
                timezone = [TimeZoneInfo]::Local.Id
            }
            fixture = [ordered]@{
                source = $fixtureSource
                file = $fixtureInfo.Name
                bytes = [long]$fixtureInfo.Length
                sha256 = $fixtureSha
                width = $fixtureWidth
                height = $fixtureHeight
            }
            mock = if ($mock) {
                [ordered]@{
                    transport = 'IPv4 loopback HTTP/1.1'
                    delays_ms = $mock.ready.delays_ms
                    expected_models = $script:ExpectedModels
                    expected_fastest_model = 'glm-4v-flash'
                    authorization_recorded_as_boolean_only = $true
                    script_sha256 = Get-FileSha256 (Join-Path $PSScriptRoot 'benchmark-mock.py')
                }
            } else { $null }
            live = if ($Mode -eq 'Live') {
                [ordered]@{
                    glm_key_present = [bool](Get-ScopedEnvironmentValue 'GLM_API_KEY')
                    agnes_key_present = [bool](Get-ScopedEnvironmentValue 'AGNES_API_KEY')
                    keys_recorded = $false
                    endpoint_class = 'official provider endpoints'
                }
            } else { $null }
            releases = $releaseMetadata
            source = [ordered]@{
                benchmark_worktree_head = $head
                benchmark_worktree_dirty_when_run = [bool]$dirty
                driver_sha256 = Get-FileSha256 $PSCommandPath
            }
            samples = @($samples)
            summary = @($summaries)
            comparisons = @($comparisons)
            limitations = @(
                'Mock isolates local orchestration and serialization; it does not predict provider latency.',
                'Live includes network, provider load, queueing, and model generation variance.',
                'Reported winner latency is diagnostic only because its timing boundary differs by release.',
                '0.4.1 and 0.4.2 may write a winner cache even with -NoCache; 0.5.0 does not.'
            )
        }
        $json = $result | ConvertTo-Json -Depth 30
        foreach ($secret in $script:SecretsToRedact) {
            if ($secret -and $json.Contains($secret)) {
                throw 'Secret-leak assertion failed; the benchmark result was not written.'
            }
        }
        [IO.File]::WriteAllText($OutputPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Write-Host "Benchmark result: $OutputPath"
        $failed = @($samples | Where-Object { $_.phase -eq 'measured' -and -not $_.strict_success })
        if ($failed.Count -gt 0) {
            Write-Warning "$($failed.Count) measured sample(s) failed the strict contract. They remain in the raw data and are excluded from latency statistics."
        }
        if (-not $benchmarkValid) {
            throw 'Benchmark data was written, but one or more releases did not meet the required valid sample count.'
        }
    } finally {
        Pop-Location
    }
} finally {
    Stop-BenchmarkMock $mock
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        $marker = Join-Path $resolvedTemp '.ds-vision-benchmark-root'
        if ($resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $marker)) {
            [IO.Directory]::Delete($resolvedTemp, $true)
        } else {
            Write-Warning "Refused to remove unverified temp path: $resolvedTemp"
        }
    }
}
