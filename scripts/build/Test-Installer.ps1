[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [string]$ReusablePythonPath = '',
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$EvidencePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ReusablePythonPath)) {
    throw 'ReusablePythonPath is required; implicit Python discovery is not allowed.'
}

$config = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\product.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).Path
$appRoot = Join-Path $env:LOCALAPPDATA ([string]$config.product.install_dir_relative)
$logRoot = Join-Path $env:LOCALAPPDATA ([string]$config.product.log_dir_relative)
$temporaryRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$setupLog = Join-Path $temporaryRoot 'python-runtime-installer-e2e.setup.log'
$registryPath = "HKCU:\$($config.product.registry_path)"
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Python Runtime Installer'
$manifestPath = Join-Path $appRoot 'manifest.json'
$pythonPath = Join-Path $appRoot 'venv\Scripts\python.exe'
$expectedPythonVersion = [string]$config.target.python.version
$privatePythonPath = Join-Path $appRoot ("runtime\{0}\python.exe" -f $expectedPythonVersion)
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $RepositoryRoot 'build\release\installer-e2e-evidence.json'
}
if ($env:GITHUB_SHA) {
    $expectedBuildCommit = $env:GITHUB_SHA
} else {
    $expectedBuildCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not resolve the expected build commit from Git.'
    }
}

$userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$machinePathBefore = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$secretSentinel = "installer-e2e-secret-{0}" -f [Guid]::NewGuid().ToString('N')
$env:PYTHON_RUNTIME_INSTALLER_E2E_SECRET = $secretSentinel
$installerSignature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
$nativeArchitecture = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
    $env:PROCESSOR_ARCHITEW6432.ToUpperInvariant()
} elseif (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITECTURE)) {
    $env:PROCESSOR_ARCHITECTURE.ToUpperInvariant()
} else {
    [string](Get-ItemProperty `
        -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' `
        -Name 'PROCESSOR_ARCHITECTURE' `
        -ErrorAction Stop).PROCESSOR_ARCHITECTURE
}
$windowsProductName = [string](Get-ItemProperty `
    -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
    -Name ProductName `
    -ErrorAction Stop).ProductName
$isWindowsServer = $windowsProductName -match 'Server'
$isGitHubHostedRunner = (
    [StringComparer]::OrdinalIgnoreCase.Equals([string]$env:GITHUB_ACTIONS, 'true') -and
    [StringComparer]::OrdinalIgnoreCase.Equals([string]$env:RUNNER_ENVIRONMENT, 'github-hosted')
)
$allowWindowsServerForE2E = $isWindowsServer -and $isGitHubHostedRunner
$script:e2eMayOwnInstallation = $false
$evidence = [ordered]@{
    schema_version = 1
    collected_at = [DateTime]::UtcNow.ToString('o')
    status = 'running'
    current_phase = $null
    host = [ordered]@{
        windows_version = [Environment]::OSVersion.VersionString
        architecture = $nativeArchitecture
        powershell_version = $PSVersionTable.PSVersion.ToString()
        powershell_edition = [string]$PSVersionTable.PSEdition
        product_name = $windowsProductName
        windows_server_e2e_override = $allowWindowsServerForE2E
    }
    installer = [ordered]@{
        path = $InstallerPath
        filename = [System.IO.Path]::GetFileName($InstallerPath)
        version = [string]$config.product.version
        sha256 = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        signature_status = [string]$installerSignature.Status
        build_commit = $expectedBuildCommit
    }
    commands = [ordered]@{}
    exit_codes = [ordered]@{}
    log_paths = [ordered]@{}
    durations_seconds = [ordered]@{}
    terminations = [ordered]@{}
    diagnostics = [ordered]@{}
}

function Test-E2ECondition([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

function Write-E2EEvidence([string]$Path) {
    $targetPath = [IO.Path]::GetFullPath($Path)
    $evidenceDirectory = [IO.Path]::GetDirectoryName($targetPath)
    [System.IO.Directory]::CreateDirectory($evidenceDirectory) | Out-Null
    $temporaryPath = Join-Path $evidenceDirectory (
        ".{0}.{1}.tmp" -f [IO.Path]::GetFileName($targetPath), [Guid]::NewGuid().ToString('N')
    )
    $backupPath = Join-Path $evidenceDirectory (
        ".{0}.{1}.bak" -f [IO.Path]::GetFileName($targetPath), [Guid]::NewGuid().ToString('N')
    )
    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            ($script:evidence | ConvertTo-Json -Depth 10),
            (New-Object System.Text.UTF8Encoding($false))
        )
        if ([System.IO.File]::Exists($targetPath)) {
            [System.IO.File]::Replace($temporaryPath, $targetPath, $backupPath)
            [System.IO.File]::Delete($backupPath)
        } else {
            [System.IO.File]::Move($temporaryPath, $targetPath)
        }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
        if ([System.IO.File]::Exists($backupPath)) {
            [System.IO.File]::Delete($backupPath)
        }
    }
}

function Get-E2EProcessTree([int]$RootProcessId) {
    $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $processIds = New-Object 'System.Collections.Generic.HashSet[int]'
    [void]$processIds.Add($RootProcessId)
    do {
        $added = $false
        foreach ($candidate in $allProcesses) {
            if (
                $processIds.Contains([int]$candidate.ParentProcessId) -and
                -not $processIds.Contains([int]$candidate.ProcessId)
            ) {
                [void]$processIds.Add([int]$candidate.ProcessId)
                $added = $true
            }
        }
    } while ($added)
    return @($processIds | Sort-Object)
}

function Stop-E2EProcessTree(
    [System.Diagnostics.Process]$Process,
    [string]$Phase
) {
    $processIds = @(Get-E2EProcessTree -RootProcessId $Process.Id)
    $result = [ordered]@{
        phase = $Phase
        root_process_id = $Process.Id
        process_ids = $processIds
        taskkill_exit_code = $null
        taskkill_timed_out = $false
        remaining_process_ids = @()
        terminated = $false
    }
    $taskkillPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    try {
        $terminator = Start-Process -FilePath $taskkillPath -ArgumentList @(
            '/PID',
            [string]$Process.Id,
            '/T',
            '/F'
        ) -WindowStyle Hidden -PassThru
        if ($terminator.WaitForExit(15000)) {
            $result.taskkill_exit_code = $terminator.ExitCode
        } else {
            $result.taskkill_timed_out = $true
            $terminator.Kill()
            [void]$terminator.WaitForExit(5000)
        }
    } catch {
        $result['taskkill_error'] = $_.Exception.Message
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $remaining = @($processIds | Where-Object {
                Get-Process -Id $_ -ErrorAction SilentlyContinue
            })
        if ($remaining.Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    foreach ($remainingProcessId in $remaining) {
        Stop-Process -Id $remainingProcessId -Force -ErrorAction SilentlyContinue
    }
    $result.remaining_process_ids = @($processIds | Where-Object {
            Get-Process -Id $_ -ErrorAction SilentlyContinue
        })
    $result.terminated = $result.remaining_process_ids.Count -eq 0
    return [pscustomobject]$result
}

function Get-ReusablePythonSnapshot(
    [string]$Path,
    [string]$ExpectedVersion,
    [string]$InstallerOwnedRoot
) {
    $resolvedPath = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    Test-E2ECondition ($resolvedPath.Provider.Name -eq 'FileSystem') 'Reusable Python must use the FileSystem provider.'
    $canonicalPath = [IO.Path]::GetFullPath($resolvedPath.Path)
    Test-E2ECondition (Test-Path -LiteralPath $canonicalPath -PathType Leaf) "Reusable Python is missing: $canonicalPath"
    Test-E2ECondition (
        [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFileName($canonicalPath), 'python.exe')
    ) "Reusable Python must be a python.exe file: $canonicalPath"

    $ownedRoot = [IO.Path]::GetFullPath($InstallerOwnedRoot).TrimEnd('\')
    $ownedPrefix = $ownedRoot + '\'
    $insideOwnedRoot = (
        [StringComparer]::OrdinalIgnoreCase.Equals($canonicalPath, $ownedRoot) -or
        $canonicalPath.StartsWith($ownedPrefix, [StringComparison]::OrdinalIgnoreCase)
    )
    Test-E2ECondition (-not $insideOwnedRoot) "Reusable Python is inside the installer-owned root: $canonicalPath"
    $blockedPath = $canonicalPath -match '(?i)[\\/](windowsapps|anaconda|miniconda|conda|embedded)(?:[\\/]|$)'
    Test-E2ECondition (-not $blockedPath) "Reusable Python uses a blocked distribution path: $canonicalPath"

    $probeText = @(
        & $canonicalPath -I -B -c 'import json,os,platform,struct,sys; print(json.dumps(dict(version=platform.python_version(), implementation=sys.implementation.name, bits=struct.calcsize(''P'') * 8, machine=platform.machine(), executable=os.path.realpath(sys.executable), prefix=os.path.realpath(sys.prefix), base_prefix=os.path.realpath(sys.base_prefix), is_virtual_environment=sys.prefix != sys.base_prefix)))'
    ) -join ''
    $probeExitCode = $LASTEXITCODE
    Test-E2ECondition ($probeExitCode -eq 0) "Reusable Python identity probe failed: $canonicalPath"
    $identity = $probeText | ConvertFrom-Json
    $reportedExecutable = [IO.Path]::GetFullPath([string]$identity.executable)

    Test-E2ECondition ($identity.version -eq $ExpectedVersion) "Reusable Python version is not $ExpectedVersion."
    Test-E2ECondition ($identity.implementation -eq 'cpython') 'Reusable Python implementation is not CPython.'
    Test-E2ECondition ([int]$identity.bits -eq 64) 'Reusable Python is not 64-bit.'
    Test-E2ECondition ($identity.machine -eq 'AMD64') 'Reusable Python machine is not AMD64.'
    Test-E2ECondition (
        [StringComparer]::OrdinalIgnoreCase.Equals($reportedExecutable, $canonicalPath)
    ) 'Reusable Python reported a different executable path.'
    Test-E2ECondition (
        -not [bool]$identity.is_virtual_environment -and
        [StringComparer]::OrdinalIgnoreCase.Equals([string]$identity.prefix, [string]$identity.base_prefix)
    ) 'Reusable Python must be a base interpreter, not a virtual environment.'

    $pythonFile = Get-Item -LiteralPath $canonicalPath
    return [pscustomobject][ordered]@{
        path = $canonicalPath
        version = [string]$identity.version
        architecture = ('{0}bit' -f [int]$identity.bits)
        bits = [int]$identity.bits
        machine = [string]$identity.machine
        implementation = [string]$identity.implementation
        executable = $reportedExecutable
        prefix = [string]$identity.prefix
        base_prefix = [string]$identity.base_prefix
        is_virtual_environment = [bool]$identity.is_virtual_environment
        sha256 = (Get-FileHash -LiteralPath $canonicalPath -Algorithm SHA256).Hash.ToLowerInvariant()
        length = [Int64]$pythonFile.Length
    }
}

function Test-ReusablePythonUnchanged(
    [string]$Path,
    $Baseline,
    [string]$ExpectedVersion,
    [string]$InstallerOwnedRoot,
    [string]$Phase
) {
    try {
        $current = Get-ReusablePythonSnapshot `
            -Path $Path `
            -ExpectedVersion $ExpectedVersion `
            -InstallerOwnedRoot $InstallerOwnedRoot
    } catch {
        throw "Reusable Python validation failed after $($Phase): $($_.Exception.Message)"
    }

    Test-E2ECondition (
        [StringComparer]::OrdinalIgnoreCase.Equals([string]$current.path, [string]$Baseline.path)
    ) "Reusable Python path changed after $Phase."
    Test-E2ECondition ([Int64]$current.length -eq [Int64]$Baseline.length) "Reusable Python size changed after $Phase."
    Test-E2ECondition ($current.sha256 -eq $Baseline.sha256) "Reusable Python content changed after $Phase."
    Test-E2ECondition (
        $current.version -eq $Baseline.version -and
        $current.bits -eq $Baseline.bits -and
        $current.machine -eq $Baseline.machine -and
        $current.implementation -eq $Baseline.implementation -and
        [StringComparer]::OrdinalIgnoreCase.Equals([string]$current.executable, [string]$Baseline.executable) -and
        [StringComparer]::OrdinalIgnoreCase.Equals([string]$current.prefix, [string]$Baseline.prefix) -and
        [StringComparer]::OrdinalIgnoreCase.Equals([string]$current.base_prefix, [string]$Baseline.base_prefix) -and
        $current.is_virtual_environment -eq $Baseline.is_virtual_environment
    ) "Reusable Python identity changed after $Phase."
    return $current
}

function Get-InstallerLogSnapshot {
    return @(Get-ChildItem -LiteralPath $logRoot -Filter 'installer-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending)
}

function Get-NewInstallerLogPath([string[]]$BeforePaths, [string]$Pattern, [string]$Phase) {
    $newLogs = @(Get-ChildItem -LiteralPath $logRoot -Filter $Pattern -File -ErrorAction SilentlyContinue |
            Where-Object { $BeforePaths -notcontains $_.FullName } |
            Sort-Object LastWriteTimeUtc -Descending)
    Test-E2ECondition ($newLogs.Count -gt 0) "Installer phase $Phase did not create the expected technical log."
    return $newLogs[0].FullName
}

function Get-SanitizedSetupLogTail([int]$LineCount = 80) {
    if (-not (Test-Path -LiteralPath $setupLog -PathType Leaf)) {
        return '<Inno Setup log is missing>'
    }

    try {
        $tail = (Get-Content -LiteralPath $setupLog -Tail $LineCount -ErrorAction Stop) -join [Environment]::NewLine
    } catch {
        return ("<could not read Inno Setup log: {0}>" -f $_.Exception.Message)
    }
    if (-not [string]::IsNullOrWhiteSpace($secretSentinel)) {
        $tail = $tail.Replace($secretSentinel, '<redacted-sentinel>')
    }
    $tail = $tail -replace 'gh[pousr]_[A-Za-z0-9]{30,}', '<redacted-github-token>'
    $tail = $tail -replace 'github_pat_[A-Za-z0-9_]{30,}', '<redacted-github-token>'
    $tail = $tail -replace 'AKIA[0-9A-Z]{16}', '<redacted-access-key>'
    return $tail
}

function Test-PathsUnchanged([string]$ExpectedUserPath, [string]$ExpectedMachinePath) {
    Test-E2ECondition `
        ([Environment]::GetEnvironmentVariable('Path', 'User') -eq $ExpectedUserPath) `
        'The user PATH changed during installer end-to-end testing.'
    Test-E2ECondition `
        ([Environment]::GetEnvironmentVariable('Path', 'Machine') -eq $ExpectedMachinePath) `
        'The machine PATH changed during installer end-to-end testing.'
}

function Get-LockedVersionMap([string]$Path) {
    $versions = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^([A-Za-z0-9_.-]+)==([^\s\\]+)') {
            $name = $Matches[1].ToLowerInvariant() -replace '[-_.]+', '-'
            $versions[$name] = $Matches[2]
        }
    }
    return $versions
}

function Compare-VersionMap($Actual, [hashtable]$Expected, [string]$Label) {
    $actualProperties = @($Actual.PSObject.Properties)
    Test-E2ECondition ($actualProperties.Count -eq $Expected.Count) "$Label count mismatch."
    foreach ($name in $Expected.Keys) {
        $property = $Actual.PSObject.Properties[$name]
        $actualVersion = if ($property) { [string]$property.Value } else { '<missing>' }
        Test-E2ECondition `
            ($actualVersion -eq [string]$Expected[$name]) `
            "$Label mismatch: $name expected=$($Expected[$name]) actual=$actualVersion"
    }
}

function Test-RegistryValueSet([hashtable]$Expected) {
    Test-E2ECondition (Test-Path -LiteralPath $registryPath) 'Discovery registry key is missing.'
    $actual = Get-ItemProperty -LiteralPath $registryPath
    foreach ($name in $Expected.Keys) {
        Test-E2ECondition `
            ([StringComparer]::OrdinalIgnoreCase.Equals([string]$actual.$name, [string]$Expected[$name])) `
            "Discovery registry mismatch: $name expected=$($Expected[$name]) actual=$($actual.$name)"
    }
}

function Invoke-Setup(
    [string]$Path,
    [string[]]$Arguments,
    [string]$Phase,
    [int[]]$AllowedExitCodes = @(0)
) {
    $logsBefore = @(Get-InstallerLogSnapshot | Select-Object -ExpandProperty FullName)
    $script:evidence.commands[$Phase] = "$([System.IO.Path]::GetFileName($Path)) $($Arguments -join ' ')"
    $script:evidence.current_phase = $Phase
    Write-E2EEvidence -Path $EvidencePath
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $nextProgressSeconds = 30
    while (-not $process.WaitForExit(1000)) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $nextProgressSeconds) {
            $sample = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
            $responding = if ($sample) { [string]$sample.Responding } else { 'exited' }
            $progressMessage = "E2E_PROGRESS phase={0} elapsed={1}s responding={2}" -f @(
                $Phase
                [int]$stopwatch.Elapsed.TotalSeconds
                $responding
            )
            [Console]::Out.WriteLine($progressMessage)
            $nextProgressSeconds += 30
        }
        if ($stopwatch.Elapsed.TotalMinutes -ge 12) {
            $stopwatch.Stop()
            $termination = Stop-E2EProcessTree -Process $process -Phase $Phase
            $script:evidence.durations_seconds[$Phase] = [Math]::Round(
                $stopwatch.Elapsed.TotalSeconds,
                2
            )
            $script:evidence.terminations[$Phase] = $termination
            Write-E2EEvidence -Path $EvidencePath
            throw "Installer phase $Phase exceeded the 12-minute test limit; process-tree termination success=$($termination.terminated)."
        }
    }
    $process.WaitForExit()
    $stopwatch.Stop()
    $script:evidence.durations_seconds[$Phase] = [Math]::Round(
        $stopwatch.Elapsed.TotalSeconds,
        2
    )
    $script:evidence.exit_codes[$Phase] = $process.ExitCode
    $completionMessage = "E2E_PHASE_COMPLETE phase={0} elapsed={1}s exit_code={2}" -f @(
        $Phase
        $script:evidence.durations_seconds[$Phase]
        $process.ExitCode
    )
    [Console]::Out.WriteLine($completionMessage)
    $logDiscoveryError = $null
    try {
        $script:evidence.log_paths[$Phase] = Get-NewInstallerLogPath -BeforePaths $logsBefore -Pattern 'installer-install-*.log' -Phase $Phase
    } catch {
        $logDiscoveryError = $_.Exception.Message
        $script:evidence.diagnostics["${Phase}_log_discovery"] = $logDiscoveryError
    }
    Write-E2EEvidence -Path $EvidencePath
    if ($AllowedExitCodes -notcontains $process.ExitCode) {
        $setupLogTail = Get-SanitizedSetupLogTail
        throw "Installer phase $Phase exited with $($process.ExitCode). Log discovery: $logDiscoveryError`nInno Setup log tail:`n$setupLogTail"
    }
    if ($logDiscoveryError) {
        $setupLogTail = Get-SanitizedSetupLogTail
        throw "$logDiscoveryError`nInno Setup log tail:`n$setupLogTail"
    }
    $script:evidence.current_phase = $null
    Write-E2EEvidence -Path $EvidencePath
    return $process.ExitCode
}

function Invoke-MonitoredUninstall(
    [string]$Path,
    [string]$Phase,
    [int]$TimeoutSeconds = 180,
    [switch]$AllowMissingLog
) {
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    $logsBefore = @(Get-InstallerLogSnapshot | Select-Object -ExpandProperty FullName)
    $script:evidence.commands[$Phase] = "$([System.IO.Path]::GetFileName($Path)) $($arguments -join ' ')"
    $script:evidence.current_phase = $Phase
    Write-E2EEvidence -Path $EvidencePath
    $process = Start-Process -FilePath $Path -ArgumentList $arguments -PassThru
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $nextProgressSeconds = 30
    while (-not $process.WaitForExit(1000)) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $nextProgressSeconds) {
            $sample = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
            $responding = if ($sample) { [string]$sample.Responding } else { 'exited' }
            $progressMessage = "E2E_PROGRESS phase={0} elapsed={1}s responding={2}" -f @(
                $Phase
                [int]$stopwatch.Elapsed.TotalSeconds
                $responding
            )
            [Console]::Out.WriteLine($progressMessage)
            $nextProgressSeconds += 30
        }
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $stopwatch.Stop()
            $termination = Stop-E2EProcessTree -Process $process -Phase $Phase
            $script:evidence.durations_seconds[$Phase] = [Math]::Round(
                $stopwatch.Elapsed.TotalSeconds,
                2
            )
            $script:evidence.terminations[$Phase] = $termination
            Write-E2EEvidence -Path $EvidencePath
            throw "Uninstaller phase $Phase exceeded the $TimeoutSeconds-second test limit; process-tree termination success=$($termination.terminated)."
        }
    }
    $process.WaitForExit()
    $postExitCleanupTimedOut = $false
    if ($process.ExitCode -eq 0) {
        $postExitCleanupDeadline = [DateTime]::UtcNow.AddSeconds(30)
        while (
            (Test-Path -LiteralPath $appRoot) -and
            [DateTime]::UtcNow -lt $postExitCleanupDeadline
        ) {
            if ($stopwatch.Elapsed.TotalSeconds -ge $nextProgressSeconds) {
                $progressMessage = "E2E_PROGRESS phase={0} elapsed={1}s responding=post-exit-cleanup" -f @(
                    $Phase
                    [int]$stopwatch.Elapsed.TotalSeconds
                )
                [Console]::Out.WriteLine($progressMessage)
                $nextProgressSeconds += 30
            }
            Start-Sleep -Milliseconds 250
        }
        $postExitCleanupTimedOut = Test-Path -LiteralPath $appRoot
        if ($postExitCleanupTimedOut) {
            $script:evidence.diagnostics["${Phase}_post_exit_cleanup"] = (
                "Application root still exists 30 seconds after the uninstaller process exited: {0}" -f
                $appRoot
            )
        }
    }
    $stopwatch.Stop()
    $script:evidence.durations_seconds[$Phase] = [Math]::Round(
        $stopwatch.Elapsed.TotalSeconds,
        2
    )
    $script:evidence.exit_codes[$Phase] = $process.ExitCode
    $completionMessage = "E2E_PHASE_COMPLETE phase={0} elapsed={1}s exit_code={2}" -f @(
        $Phase
        $script:evidence.durations_seconds[$Phase]
        $process.ExitCode
    )
    [Console]::Out.WriteLine($completionMessage)
    $logDiscoveryError = $null
    try {
        $script:evidence.log_paths[$Phase] = Get-NewInstallerLogPath `
            -BeforePaths $logsBefore `
            -Pattern 'installer-uninstall-*.log' `
            -Phase $Phase
    } catch {
        $logDiscoveryError = $_.Exception.Message
        $script:evidence.diagnostics["${Phase}_log_discovery"] = $logDiscoveryError
    }
    Write-E2EEvidence -Path $EvidencePath
    if ($process.ExitCode -ne 0) {
        throw "Uninstaller phase $Phase exited with $($process.ExitCode). Log discovery: $logDiscoveryError"
    }
    if ($postExitCleanupTimedOut) {
        throw $script:evidence.diagnostics["${Phase}_post_exit_cleanup"]
    }
    if ($logDiscoveryError -and -not $AllowMissingLog) {
        throw $logDiscoveryError
    }
    $script:evidence.current_phase = $null
    Write-E2EEvidence -Path $EvidencePath
    return $process.ExitCode
}

function Invoke-ManagedVerification([string]$Path, [string]$ResultPath, [string]$Phase) {
    $verifier = Join-Path $RepositoryRoot 'scripts\verify_environment.py'
    $arguments = @(
        $verifier,
        '--requirements', (Join-Path $RepositoryRoot 'requirements.txt'),
        '--bootstrap-requirements', (Join-Path $RepositoryRoot 'bootstrap-requirements.txt'),
        '--expected-python', $expectedPythonVersion,
        '--expected-executable', $Path,
        '--manifest', $manifestPath,
        '--output', $ResultPath
    )
    & $Path @arguments | Out-Null
    $script:evidence.exit_codes[$Phase] = $LASTEXITCODE
    Test-E2ECondition ($LASTEXITCODE -eq 0) "Managed verification phase $Phase failed."
    return Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Invoke-E2EFailureCleanup {
    $externalHashBefore = if (Test-Path -LiteralPath $ReusablePythonPath -PathType Leaf) {
        (Get-FileHash -LiteralPath $ReusablePythonPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } else {
        $null
    }
    $logsBefore = @(Get-InstallerLogSnapshot).Count
    $result = [ordered]@{
        attempted = $false
        reason = ''
        exit_code = $null
        app_root_removed = -not (Test-Path -LiteralPath $appRoot)
        registry_removed = -not (Test-Path -LiteralPath $registryPath)
        start_menu_removed = -not (Test-Path -LiteralPath $startMenu)
        logs_before = $logsBefore
        logs_after = $logsBefore
        external_python_sha256_before = $externalHashBefore
        external_python_sha256_after = $externalHashBefore
        external_python_preserved = $true
    }
    if (-not $script:e2eMayOwnInstallation) {
        $result.reason = 'The E2E run did not begin an installer mutation.'
        return [pscustomobject]$result
    }

    $recoveryUninstaller = Join-Path $appRoot 'unins000.exe'
    if (-not (Test-Path -LiteralPath $recoveryUninstaller -PathType Leaf)) {
        $result.reason = 'The product uninstaller is unavailable; no fallback deletion was attempted.'
        return [pscustomobject]$result
    }

    $result.attempted = $true
    try {
        $result.exit_code = Invoke-MonitoredUninstall `
            -Path $recoveryUninstaller `
            -Phase 'failure_cleanup' `
            -AllowMissingLog
        $result.reason = 'The product uninstaller completed.'
    } catch {
        $result.reason = "The product uninstaller failed: $($_.Exception.Message)"
    }
    $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while (
        (Test-Path -LiteralPath $appRoot) -and
        [DateTime]::UtcNow -lt $cleanupDeadline
    ) {
        Start-Sleep -Milliseconds 250
    }
    $result.app_root_removed = -not (Test-Path -LiteralPath $appRoot)
    $result.registry_removed = -not (Test-Path -LiteralPath $registryPath)
    $result.start_menu_removed = -not (Test-Path -LiteralPath $startMenu)
    $result.logs_after = @(Get-InstallerLogSnapshot).Count
    if (Test-Path -LiteralPath $ReusablePythonPath -PathType Leaf) {
        $result.external_python_sha256_after = (
            Get-FileHash -LiteralPath $ReusablePythonPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
    } else {
        $result.external_python_sha256_after = $null
    }
    $result.external_python_preserved = (
        $externalHashBefore -and
        $externalHashBefore -eq $result.external_python_sha256_after
    )
    return [pscustomobject]$result
}

try {
Write-E2EEvidence -Path $EvidencePath
Test-E2ECondition (-not (Test-Path -LiteralPath $appRoot)) "E2E test requires a clean application path: $appRoot"
Test-E2ECondition (-not (Test-Path -LiteralPath $registryPath)) "E2E test requires clean discovery metadata: $registryPath"
if ($InstallerPath.EndsWith('-unsigned.exe', [StringComparison]::OrdinalIgnoreCase)) {
    Test-E2ECondition ($installerSignature.Status -eq 'NotSigned') 'Unsigned-named installer unexpectedly has a non-NotSigned status.'
} else {
    Test-E2ECondition ($installerSignature.Status -eq 'Valid') 'Signed-named installer does not have a valid Authenticode signature.'
}

$reusablePythonBaseline = Get-ReusablePythonSnapshot `
    -Path $ReusablePythonPath `
    -ExpectedVersion $expectedPythonVersion `
    -InstallerOwnedRoot $appRoot
$ReusablePythonPath = [string]$reusablePythonBaseline.path
$evidence['reusable_python_baseline'] = [ordered]@{
    path = $ReusablePythonPath
    version = [string]$reusablePythonBaseline.version
    architecture = [string]$reusablePythonBaseline.architecture
    bits = [int]$reusablePythonBaseline.bits
    machine = [string]$reusablePythonBaseline.machine
    implementation = [string]$reusablePythonBaseline.implementation
    executable = [string]$reusablePythonBaseline.executable
    prefix = [string]$reusablePythonBaseline.prefix
    base_prefix = [string]$reusablePythonBaseline.base_prefix
    is_virtual_environment = [bool]$reusablePythonBaseline.is_virtual_environment
    sha256 = [string]$reusablePythonBaseline.sha256
    length = [Int64]$reusablePythonBaseline.length
    captured_before_install = $true
}

$setupArguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG="{0}"' -f $setupLog))
if ($allowWindowsServerForE2E) {
    $setupArguments += '/E2EALLOWWINDOWSSERVER'
}
$script:e2eMayOwnInstallation = $true
Invoke-Setup -Path $InstallerPath -Phase 'forced_private_install' -Arguments ($setupArguments + '/FORCEBUNDLED') | Out-Null

Test-E2ECondition (Test-Path -LiteralPath $pythonPath -PathType Leaf) "Managed Python missing: $pythonPath"
Test-E2ECondition (Test-Path -LiteralPath $privatePythonPath -PathType Leaf) "Private CPython missing: $privatePythonPath"
Test-E2ECondition (Test-Path -LiteralPath $manifestPath -PathType Leaf) "Manifest missing: $manifestPath"
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
Test-E2ECondition ($manifest.verification_status -eq 'passed') 'Installed manifest is not verified.'
Test-E2ECondition ($manifest.runtime_ownership -eq 'private') 'Forced bundled install did not record private ownership.'
Test-E2ECondition ($manifest.installer_version -eq $config.product.version) 'Installed product version is incorrect.'
Test-E2ECondition ($manifest.python_version -eq $expectedPythonVersion) 'Installed Python version is incorrect.'
Test-E2ECondition ($manifest.build_commit -eq $expectedBuildCommit) 'Installed build commit is incorrect.'
Test-E2ECondition `
    ([StringComparer]::OrdinalIgnoreCase.Equals([string]$manifest.python_executable, $pythonPath)) `
    'Manifest Python executable is not the fixed managed path.'
Test-E2ECondition `
    ([StringComparer]::OrdinalIgnoreCase.Equals([string]$manifest.base_python, $privatePythonPath)) `
    'Manifest base Python is not the fixed private path.'

$runtimeProbe = & $pythonPath -I -c 'import json,platform,sys;print(json.dumps(dict(version=platform.python_version(),bits=platform.architecture()[0],implementation=sys.implementation.name)))'
Test-E2ECondition ($LASTEXITCODE -eq 0) 'Managed runtime identity probe failed.'
$runtimeIdentity = $runtimeProbe | ConvertFrom-Json
Test-E2ECondition `
    ($runtimeIdentity.version -eq $expectedPythonVersion -and $runtimeIdentity.bits -eq '64bit' -and $runtimeIdentity.implementation -eq 'cpython') `
    "Managed runtime identity mismatch: $runtimeProbe"

$expectedPackages = Get-LockedVersionMap -Path (Join-Path $RepositoryRoot 'requirements.txt')
$expectedBootstrap = Get-LockedVersionMap -Path (Join-Path $RepositoryRoot 'bootstrap-requirements.txt')
Compare-VersionMap -Actual $manifest.packages -Expected $expectedPackages -Label 'Runtime package'
Compare-VersionMap -Actual $manifest.bootstrap_tooling -Expected $expectedBootstrap -Label 'Bootstrap package'
$requiredChecks = @(
    'runtime',
    'locked-package-versions',
    'immutable-distribution-set',
    'entrypoint-launchers',
    'imports',
    'pip-check',
    'scientific-and-files',
    'services-and-utilities',
    'selenium-import-only'
)
Test-E2ECondition (@($manifest.verification_checks).Count -eq $requiredChecks.Count) 'Manifest verification evidence is incomplete.'
foreach ($check in $requiredChecks) {
    Test-E2ECondition (@($manifest.verification_checks) -contains $check) "Manifest is missing verification check: $check"
}

$releasePayloadPath = Join-Path $RepositoryRoot 'build\release\payload-manifest.json'
Test-E2ECondition (Test-Path -LiteralPath $releasePayloadPath -PathType Leaf) 'Build payload manifest is missing.'
$releasePayload = Get-Content -LiteralPath $releasePayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json
Test-E2ECondition ($releasePayload.installer_version -eq $config.product.version) 'Payload product version is incorrect.'
Test-E2ECondition ($releasePayload.build_commit -eq $expectedBuildCommit) 'Payload build commit is incorrect.'
Test-E2ECondition ($manifest.payload_target -eq $releasePayload.target) 'Installed payload target is incorrect.'
$installedPayloadFiles = @{}
foreach ($entry in @($manifest.payload_files)) {
    $installedPayloadFiles[[string]$entry.path] = $entry
}
Test-E2ECondition ($installedPayloadFiles.Count -eq @($releasePayload.files).Count) 'Installed payload file count is incorrect.'
foreach ($expectedEntry in @($releasePayload.files)) {
    $actualEntry = $installedPayloadFiles[[string]$expectedEntry.path]
    Test-E2ECondition `
        ($actualEntry -and [Int64]$actualEntry.size -eq [Int64]$expectedEntry.size -and [string]$actualEntry.sha256 -eq [string]$expectedEntry.sha256) `
        "Installed payload checksum evidence mismatch: $($expectedEntry.path)"
}

$expectedDiscovery = @{
    InstallPath = $appRoot
    PythonExecutable = $pythonPath
    PythonVersion = $expectedPythonVersion
    InstallerVersion = [string]$config.product.version
    ManifestPath = $manifestPath
}
Test-RegistryValueSet -Expected $expectedDiscovery
$shortcutNames = @(
    'Open Python Environment Terminal.lnk',
    'Open Installation Logs.lnk',
    'Uninstall Python Runtime Installer.lnk'
)
Test-E2ECondition (Test-Path -LiteralPath $startMenu) 'Start menu group is missing.'
foreach ($shortcutName in $shortcutNames) {
    Test-E2ECondition (Test-Path -LiteralPath (Join-Path $startMenu $shortcutName) -PathType Leaf) "Start menu shortcut missing: $shortcutName"
}
$shortcutShell = New-Object -ComObject WScript.Shell
try {
    $terminalShortcut = $shortcutShell.CreateShortcut((Join-Path $startMenu $shortcutNames[0]))
    $expectedLauncher = Join-Path $appRoot 'Open-Environment.cmd'
    Test-E2ECondition `
        ([StringComparer]::OrdinalIgnoreCase.Equals($terminalShortcut.TargetPath, $expectedLauncher)) `
        "Environment shortcut target mismatch: $($terminalShortcut.TargetPath)"
} finally {
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcutShell)
}
$launcherSource = Get-Content -LiteralPath $expectedLauncher -Raw -Encoding UTF8
Test-E2ECondition `
    ($launcherSource -match 'call "%RUNTIME_ROOT%\\venv\\Scripts\\activate\.bat"' -and $launcherSource -match 'cmd /k') `
    'Environment shortcut launcher does not activate the managed environment.'
$launcherProbePath = Join-Path $temporaryRoot ("python-runtime-launcher-{0}.cmd" -f [Guid]::NewGuid().ToString('N'))
$launcherProbeLines = @(
    '@echo off',
    ('call "{0}"' -f (Join-Path $appRoot 'venv\Scripts\activate.bat')),
    ('if /I not "%VIRTUAL_ENV%"=="{0}" exit /b 91' -f (Join-Path $appRoot 'venv')),
    ('python -I -c "import os,sys;raise SystemExit(0 if os.path.normcase(sys.executable)==os.path.normcase(r''{0}'') else 92)"' -f $pythonPath)
)
[System.IO.File]::WriteAllText($launcherProbePath, ($launcherProbeLines -join [Environment]::NewLine), [Text.Encoding]::ASCII)
try {
    $launcherProbeArguments = '/d /s /c ""{0}""' -f $launcherProbePath
    $evidence.current_phase = 'start_menu_activation_probe'
    Write-E2EEvidence -Path $EvidencePath
    $launcherProbe = Start-Process `
        -FilePath $env:ComSpec `
        -ArgumentList $launcherProbeArguments `
        -WindowStyle Hidden `
        -PassThru
    $launcherProbeStopwatch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $launcherProbe.WaitForExit(1000)) {
        if ($launcherProbeStopwatch.Elapsed.TotalSeconds -ge 30) {
            $launcherProbeStopwatch.Stop()
            $termination = Stop-E2EProcessTree `
                -Process $launcherProbe `
                -Phase 'start_menu_activation_probe'
            $evidence.durations_seconds['start_menu_activation_probe'] = [Math]::Round(
                $launcherProbeStopwatch.Elapsed.TotalSeconds,
                2
            )
            $evidence.terminations['start_menu_activation_probe'] = $termination
            Write-E2EEvidence -Path $EvidencePath
            throw "Start menu activation probe exceeded 30 seconds; process-tree termination success=$($termination.terminated)."
        }
    }
    $launcherProbe.WaitForExit()
    $launcherProbeStopwatch.Stop()
    $evidence.durations_seconds['start_menu_activation_probe'] = [Math]::Round(
        $launcherProbeStopwatch.Elapsed.TotalSeconds,
        2
    )
    $evidence.exit_codes['start_menu_activation_probe'] = $launcherProbe.ExitCode
    Write-E2EEvidence -Path $EvidencePath
    Test-E2ECondition ($launcherProbe.ExitCode -eq 0) 'Start menu activation probe failed.'
    $evidence.current_phase = $null
    Write-E2EEvidence -Path $EvidencePath
} finally {
    [System.IO.File]::Delete($launcherProbePath)
}
$desktopShortcuts = @(Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Desktop')) -Filter '*Python Runtime Installer*.lnk' -File -ErrorAction SilentlyContinue)
Test-E2ECondition ($desktopShortcuts.Count -eq 0) 'Unexpected desktop shortcut was created.'
Test-E2ECondition (-not [Environment]::GetEnvironmentVariable('PYTHON_RUNTIME_INSTALLER_HOME', 'User')) 'Unexpected global environment variable was created.'
Test-PathsUnchanged -ExpectedUserPath $userPathBefore -ExpectedMachinePath $machinePathBefore

$postInstallResultPath = Join-Path $temporaryRoot ("python-runtime-verification-{0}.json" -f [Guid]::NewGuid().ToString('N'))
try {
    $postInstallVerification = Invoke-ManagedVerification -Path $pythonPath -ResultPath $postInstallResultPath -Phase 'post_install_verification'
} finally {
    [System.IO.File]::Delete($postInstallResultPath)
}
$evidence['manifest_summary'] = [ordered]@{
    installer_version = [string]$manifest.installer_version
    build_commit = [string]$manifest.build_commit
    python_version = [string]$manifest.python_version
    python_executable = [string]$manifest.python_executable
    base_python = [string]$manifest.base_python
    runtime_ownership = [string]$manifest.runtime_ownership
    package_count = @($manifest.packages.PSObject.Properties).Count
    payload_file_count = @($manifest.payload_files).Count
    verification_status = [string]$manifest.verification_status
    verification_checks = @($postInstallVerification.checks)
}
$evidence['registry'] = $expectedDiscovery

$healthyManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$healthyPythonHash = (Get-FileHash -LiteralPath $pythonPath -Algorithm SHA256).Hash
Invoke-Setup -Path $InstallerPath -Phase 'healthy_rerun' -Arguments $setupArguments | Out-Null
Test-E2ECondition ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $healthyManifestHash) 'Healthy rerun rebuilt the manifest.'
Test-E2ECondition ((Get-FileHash -LiteralPath $pythonPath -Algorithm SHA256).Hash -eq $healthyPythonHash) 'Healthy rerun changed managed Python.'
Test-PathsUnchanged -ExpectedUserPath $userPathBefore -ExpectedMachinePath $machinePathBefore
$evidence['idempotency'] = [ordered]@{
    manifest_sha256_before = $healthyManifestHash.ToLowerInvariant()
    manifest_sha256_after = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    rebuilt = $false
}

$sitePackages = (& $pythonPath -I -c 'import site;print(site.getsitepackages()[0])').Trim()
Test-E2ECondition ($LASTEXITCODE -eq 0) 'Could not resolve managed site-packages.'
$driftMetadata = Join-Path $sitePackages 'custom_drift-1.0.dist-info'
[System.IO.Directory]::CreateDirectory($driftMetadata) | Out-Null
$driftMetadataLines = @('Metadata-Version: 2.1', 'Name: custom-drift', 'Version: 1.0', '')
[System.IO.File]::WriteAllText((Join-Path $driftMetadata 'METADATA'), ($driftMetadataLines -join [Environment]::NewLine))
Invoke-Setup -Path $InstallerPath -Phase 'drift_repair' -Arguments $setupArguments | Out-Null
Test-E2ECondition (-not (Test-Path -LiteralPath $driftMetadata)) 'Drift repair retained an undeclared package.'
$repairedManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
Test-E2ECondition ($repairedManifestHash -ne $healthyManifestHash) 'Drift repair did not publish a rebuilt manifest.'
$repairResultPath = Join-Path $temporaryRoot ("python-runtime-repair-{0}.json" -f [Guid]::NewGuid().ToString('N'))
try {
    $repairVerification = Invoke-ManagedVerification -Path $pythonPath -ResultPath $repairResultPath -Phase 'post_repair_verification'
} finally {
    [System.IO.File]::Delete($repairResultPath)
}
$evidence['drift_repair'] = [ordered]@{
    injected_distribution = 'custom-drift==1.0'
    drift_removed = $true
    manifest_sha256_before = $healthyManifestHash.ToLowerInvariant()
    manifest_sha256_after = $repairedManifestHash.ToLowerInvariant()
    verification_checks = @($repairVerification.checks)
}

$healthyManifestHashBeforeFailure = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$healthyPythonHash = (Get-FileHash -LiteralPath $pythonPath -Algorithm SHA256).Hash
$stagingParent = Join-Path $appRoot '.staging'
$failedExitCode = Invoke-Setup -Path $InstallerPath -Phase 'failed_staging' -AllowedExitCodes @(20) -Arguments ($setupArguments + '/E2EFAILAFTERSTAGING')
Test-E2ECondition ($failedExitCode -eq 20) 'The staging failure returned an unexpected exit code.'
$activePythonHashAfterFailure = (Get-FileHash -LiteralPath $pythonPath -Algorithm SHA256).Hash
$activeManifestHashAfterFailure = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
Test-E2ECondition ($activePythonHashAfterFailure -eq $healthyPythonHash) 'Failed staging replaced active Python.'
Test-E2ECondition ($activeManifestHashAfterFailure -eq $healthyManifestHashBeforeFailure) 'Failed staging replaced the healthy manifest.'
$stagingEntries = @(Get-ChildItem -LiteralPath $stagingParent -Force -ErrorAction SilentlyContinue)
$stagingCleaned = $stagingEntries.Count -eq 0
Test-E2ECondition $stagingCleaned 'Failed staging content was not cleaned.'
$previousEntries = @(Get-ChildItem -LiteralPath $appRoot -Directory -Filter '.previous-*' -ErrorAction SilentlyContinue)
$previousEnvironmentAbsent = $previousEntries.Count -eq 0
Test-E2ECondition $previousEnvironmentAbsent 'Failed staging created a previous active environment.'
Test-RegistryValueSet -Expected $expectedDiscovery
$failedStagingLog = Get-Item -LiteralPath ([string]$evidence.log_paths['failed_staging'])
$failedStagingLogText = Get-Content -LiteralPath $failedStagingLog.FullName -Raw -Encoding UTF8
Test-E2ECondition ($failedStagingLogText -match '\[verification\] Exit code: 0') 'Failure injection occurred before staging verification passed.'
Test-E2ECondition ($failedStagingLogText.Contains('Test-only failure after successful staging verification.')) 'Expected staging failure evidence is missing from the log.'
$recoveryResultPath = Join-Path $temporaryRoot ("python-runtime-recovery-{0}.json" -f [Guid]::NewGuid().ToString('N'))
try {
    $recoveryVerification = Invoke-ManagedVerification -Path $pythonPath -ResultPath $recoveryResultPath -Phase 'failed_staging_preserved_environment_verification'
} finally {
    [System.IO.File]::Delete($recoveryResultPath)
}
$evidence['failed_staging'] = [ordered]@{
    exit_code = $failedExitCode
    active_python_sha256_before = $healthyPythonHash.ToLowerInvariant()
    active_python_sha256_after = $activePythonHashAfterFailure.ToLowerInvariant()
    manifest_sha256_before = $healthyManifestHashBeforeFailure.ToLowerInvariant()
    manifest_sha256_after = $activeManifestHashAfterFailure.ToLowerInvariant()
    manifest_preserved = ($activeManifestHashAfterFailure -eq $healthyManifestHashBeforeFailure)
    discovery_preserved = $true
    staging_verified = $true
    staging_cleaned = $stagingCleaned
    previous_environment_absent = $previousEnvironmentAbsent
    log_path = $failedStagingLog.FullName
    verification_checks = @($recoveryVerification.checks)
}

$logsBeforePrivateUninstall = @(Get-InstallerLogSnapshot)
Test-E2ECondition ($logsBeforePrivateUninstall.Count -gt 0) 'No installer logs exist before uninstall.'
$privateLogsGuaranteedRetained = @($logsBeforePrivateUninstall | Select-Object -First 19 -ExpandProperty FullName)
$uninstaller = Join-Path $appRoot 'unins000.exe'
Test-E2ECondition (Test-Path -LiteralPath $uninstaller -PathType Leaf) 'Uninstaller is missing.'
$privateUninstallExitCode = Invoke-MonitoredUninstall -Path $uninstaller -Phase 'private_uninstall'
$privateUninstallLog = [string]$evidence.log_paths['private_uninstall']
$evidence.log_paths['private_uninstall'] = $privateUninstallLog
Test-E2ECondition ($privateUninstallExitCode -eq 0) 'Private-runtime uninstall failed.'
$reusablePythonAfterPrivateUninstall = Test-ReusablePythonUnchanged `
    -Path $ReusablePythonPath `
    -Baseline $reusablePythonBaseline `
    -ExpectedVersion $expectedPythonVersion `
    -InstallerOwnedRoot $appRoot `
    -Phase 'private_uninstall'
Test-E2ECondition (-not (Test-Path -LiteralPath (Join-Path $appRoot 'venv'))) 'Managed environment survived uninstall.'
Test-E2ECondition (-not (Test-Path -LiteralPath $privatePythonPath -PathType Leaf)) 'Private CPython survived uninstall.'
Test-E2ECondition (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) 'Installed manifest survived uninstall.'
Test-E2ECondition (-not (Test-Path -LiteralPath $registryPath)) 'Discovery metadata survived uninstall.'
Test-E2ECondition (-not (Test-Path -LiteralPath $startMenu)) 'Start menu shortcuts survived uninstall.'
Test-E2ECondition (-not (Test-Path -LiteralPath $appRoot)) 'Application root survived uninstall.'
foreach ($retainedLog in $privateLogsGuaranteedRetained) {
    Test-E2ECondition (Test-Path -LiteralPath $retainedLog -PathType Leaf) "Uninstall removed retained log: $retainedLog"
}
Test-PathsUnchanged -ExpectedUserPath $userPathBefore -ExpectedMachinePath $machinePathBefore
$logsAfterPrivateUninstall = @(Get-InstallerLogSnapshot)
Test-E2ECondition ($logsAfterPrivateUninstall.Count -le 20) 'Private-runtime uninstall exceeded the newest-20 log retention bound.'
$evidence['private_uninstall'] = [ordered]@{
    managed_environment_removed = $true
    private_python_removed = $true
    manifest_removed = $true
    application_root_removed = $true
    registry_removed = $true
    start_menu_removed = $true
    log_path = $privateUninstallLog
    retained_log_count = $logsAfterPrivateUninstall.Count
    retained_prior_log_count = $privateLogsGuaranteedRetained.Count
    reusable_python_sha256_after = [string]$reusablePythonAfterPrivateUninstall.sha256
    reusable_python_length_after = [Int64]$reusablePythonAfterPrivateUninstall.length
    reusable_python_preserved = $true
}

$pythonRegistryRoot = 'HKCU:\Software\Python'
$pythonCoreRegistry = Join-Path $pythonRegistryRoot 'PythonCore'
$pythonRegistryRootExisted = Test-Path -LiteralPath $pythonRegistryRoot
$pythonCoreRegistryExisted = Test-Path -LiteralPath $pythonCoreRegistry
$pythonRegistryTag = Join-Path $pythonCoreRegistry ("3.13-e2e-{0}" -f [Guid]::NewGuid().ToString('N'))
$pythonRegistry = Join-Path $pythonRegistryTag 'InstallPath'
Test-E2ECondition (-not (Test-Path -LiteralPath $pythonRegistryTag)) 'The isolated PEP 514 test tag already exists.'
try {
    New-Item -Path $pythonRegistry -Force | Out-Null
    New-ItemProperty -Path $pythonRegistryTag -Name DisplayName -Value 'Python Runtime Installer E2E CPython' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $pythonRegistryTag -Name Version -Value $expectedPythonVersion -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $pythonRegistryTag -Name SysVersion -Value $expectedPythonVersion -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $pythonRegistryTag -Name SysArchitecture -Value '64bit' -PropertyType String -Force | Out-Null
    Set-Item -LiteralPath $pythonRegistry -Value (Split-Path -Parent $ReusablePythonPath)
    New-ItemProperty -Path $pythonRegistry -Name ExecutablePath -Value $ReusablePythonPath -PropertyType String -Force | Out-Null
    Invoke-Setup -Path $InstallerPath -Phase 'reuse_install' -Arguments $setupArguments | Out-Null
    $reuseManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-E2ECondition ($reuseManifest.runtime_ownership -eq 'reused') 'External CPython was not recorded as reused.'
    Test-E2ECondition ([StringComparer]::OrdinalIgnoreCase.Equals([string]$reuseManifest.base_python, $ReusablePythonPath)) 'Reused base Python path is incorrect.'
    $reuseResultPath = Join-Path $temporaryRoot ("python-runtime-reuse-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    try {
        $reuseVerification = Invoke-ManagedVerification -Path $pythonPath -ResultPath $reuseResultPath -Phase 'reuse_environment_verification'
    } finally {
        [System.IO.File]::Delete($reuseResultPath)
    }
    $logsBeforeReuseUninstall = @(Get-InstallerLogSnapshot)
    $reuseLogsGuaranteedRetained = @($logsBeforeReuseUninstall | Select-Object -First 19 -ExpandProperty FullName)
    $reuseUninstaller = Join-Path $appRoot 'unins000.exe'
    $reuseUninstallExitCode = Invoke-MonitoredUninstall -Path $reuseUninstaller -Phase 'reuse_uninstall'
    Test-E2ECondition ($reuseUninstallExitCode -eq 0) 'Reused-runtime uninstall failed.'
    $reusablePythonAfterReuseUninstall = Test-ReusablePythonUnchanged `
        -Path $ReusablePythonPath `
        -Baseline $reusablePythonBaseline `
        -ExpectedVersion $expectedPythonVersion `
        -InstallerOwnedRoot $appRoot `
        -Phase 'reuse_uninstall'
    Test-E2ECondition (Test-Path -LiteralPath $ReusablePythonPath -PathType Leaf) 'Reused CPython was removed by uninstall.'
    $reuseUninstallLog = [string]$evidence.log_paths['reuse_uninstall']
    $evidence.log_paths['reuse_uninstall'] = $reuseUninstallLog
    Test-E2ECondition (-not (Test-Path -LiteralPath (Join-Path $appRoot 'venv'))) 'Managed environment survived reused-runtime uninstall.'
    Test-E2ECondition (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) 'Installed manifest survived reused-runtime uninstall.'
    Test-E2ECondition (-not (Test-Path -LiteralPath $registryPath)) 'Discovery metadata survived reused-runtime uninstall.'
    Test-E2ECondition (-not (Test-Path -LiteralPath $startMenu)) 'Start menu shortcuts survived reused-runtime uninstall.'
    Test-E2ECondition (-not (Test-Path -LiteralPath $appRoot)) 'Application root survived reused-runtime uninstall.'
    foreach ($retainedLog in $reuseLogsGuaranteedRetained) {
        Test-E2ECondition (Test-Path -LiteralPath $retainedLog -PathType Leaf) "Reuse uninstall removed retained log: $retainedLog"
    }
    $logsAfterReuseUninstall = @(Get-InstallerLogSnapshot)
    Test-E2ECondition ($logsAfterReuseUninstall.Count -le 20) 'Reused-runtime uninstall exceeded the newest-20 log retention bound.'
    Test-PathsUnchanged -ExpectedUserPath $userPathBefore -ExpectedMachinePath $machinePathBefore
    $evidence['reused_runtime'] = [ordered]@{
        path = $ReusablePythonPath
        version = [string]$reusablePythonBaseline.version
        architecture = [string]$reusablePythonBaseline.architecture
        implementation = [string]$reusablePythonBaseline.implementation
        is_virtual_environment = [bool]$reusablePythonBaseline.is_virtual_environment
        sha256_before = [string]$reusablePythonBaseline.sha256
        sha256_after_private_uninstall = [string]$reusablePythonAfterPrivateUninstall.sha256
        sha256_after_reuse_uninstall = [string]$reusablePythonAfterReuseUninstall.sha256
        sha256_after = [string]$reusablePythonAfterReuseUninstall.sha256
        length_before = [Int64]$reusablePythonBaseline.length
        length_after_private_uninstall = [Int64]$reusablePythonAfterPrivateUninstall.length
        length_after_reuse_uninstall = [Int64]$reusablePythonAfterReuseUninstall.length
        private_uninstall_preserved = $true
        reuse_uninstall_preserved = $true
        preserved = $true
        managed_environment_removed = $true
        application_root_removed = $true
        registry_removed = $true
        start_menu_removed = $true
        registry_tag = $pythonRegistryTag
        uninstall_log_path = $reuseUninstallLog
        retained_log_count = $logsAfterReuseUninstall.Count
        retained_prior_log_count = $reuseLogsGuaranteedRetained.Count
        verification_checks = @($reuseVerification.checks)
    }
} finally {
    if (Test-Path -LiteralPath $pythonRegistryTag) {
        Remove-Item -LiteralPath $pythonRegistryTag -Recurse -Force
    }
    if (-not $pythonCoreRegistryExisted -and (Test-Path -LiteralPath $pythonCoreRegistry) -and @(Get-ChildItem -LiteralPath $pythonCoreRegistry).Count -eq 0) {
        Remove-Item -LiteralPath $pythonCoreRegistry -Force
    }
    if (-not $pythonRegistryRootExisted -and (Test-Path -LiteralPath $pythonRegistryRoot) -and @(Get-ChildItem -LiteralPath $pythonRegistryRoot).Count -eq 0) {
        Remove-Item -LiteralPath $pythonRegistryRoot -Force
    }
}

Test-E2ECondition (-not (Test-Path -LiteralPath $pythonRegistryTag)) 'Temporary PEP 514 test tag was not removed.'
if (-not $pythonCoreRegistryExisted) {
    Test-E2ECondition (-not (Test-Path -LiteralPath $pythonCoreRegistry)) 'Temporary PythonCore parent key was not restored.'
}
if (-not $pythonRegistryRootExisted) {
    Test-E2ECondition (-not (Test-Path -LiteralPath $pythonRegistryRoot)) 'Temporary Python registry root was not restored.'
}
$evidence['reused_runtime']['registry_restored'] = $true

$technicalLogs = @(Get-ChildItem -LiteralPath $logRoot -Filter 'installer-*.log' -File | Sort-Object LastWriteTimeUtc)
Test-E2ECondition ($technicalLogs.Count -gt 0) 'Retained installer logs are missing.'
Test-E2ECondition ($technicalLogs.Count -le 20) 'Technical log retention exceeded the newest-20 policy.'
Test-E2ECondition (Test-Path -LiteralPath $setupLog -PathType Leaf) 'Inno Setup log is missing.'
$currentRunTechnicalLogs = @($evidence.log_paths.Values |
        Sort-Object -Unique |
        ForEach-Object { Get-Item -LiteralPath ([string]$_) })
Test-E2ECondition ($currentRunTechnicalLogs.Count -eq $evidence.log_paths.Count) 'One or more phase logs are missing.'
$verificationBeforeCompletion = $false
foreach ($technicalLog in $currentRunTechnicalLogs) {
    $logText = Get-Content -LiteralPath $technicalLog.FullName -Raw -Encoding UTF8
    Test-E2ECondition (-not $logText.Contains($secretSentinel)) "Sensitive sentinel leaked to log: $($technicalLog.FullName)"
    Test-E2ECondition ($logText -notmatch 'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----') "Credential pattern found in log: $($technicalLog.FullName)"
    Test-E2ECondition ($logText -notmatch '[\u4e00-\u9fff]') "Technical log is not English-only: $($technicalLog.FullName)"
    $verificationIndex = $logText.LastIndexOf('[verification-final]', [StringComparison]::Ordinal)
    $completionIndex = $logText.LastIndexOf('[complete]', [StringComparison]::Ordinal)
    if ($verificationIndex -ge 0 -and $completionIndex -gt $verificationIndex) {
        $verificationBeforeCompletion = $true
    }
}
$setupLogText = Get-Content -LiteralPath $setupLog -Raw -Encoding UTF8
Test-E2ECondition (-not $setupLogText.Contains($secretSentinel)) 'Sensitive sentinel leaked to setup log.'
Test-E2ECondition ($setupLogText -notmatch 'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----') 'Credential pattern found in setup log.'
Test-E2ECondition $verificationBeforeCompletion 'No log proves final verification completed before installation activation.'
$evidence['logs'] = [ordered]@{
    setup_log = $setupLog
    technical_logs = @($technicalLogs | Select-Object -ExpandProperty FullName)
    scanned_phase_logs = @($currentRunTechnicalLogs | Select-Object -ExpandProperty FullName)
    phase_paths = $evidence.log_paths
    retained_count = $technicalLogs.Count
    retention_bound = 20
    english_only = $true
    sensitive_value_scan = 'passed'
    verification_before_completion = $verificationBeforeCompletion
}
$evidence.status = 'passed'
$evidence.current_phase = $null
$evidence['completed_at'] = [DateTime]::UtcNow.ToString('o')
Write-E2EEvidence -Path $EvidencePath
Write-Output "End-to-end installer test passed. Evidence: $EvidencePath"
} catch {
    $failureRecord = $_
    $failedPhase = if ($evidence.current_phase) {
        [string]$evidence.current_phase
    } else {
        'preflight-or-assertion'
    }
    $failureMessage = [string]$failureRecord.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($secretSentinel)) {
        $failureMessage = $failureMessage.Replace($secretSentinel, '<redacted>')
    }
    $evidence.status = 'failed'
    $evidence['failure'] = [ordered]@{
        phase = $failedPhase
        exception_type = $failureRecord.Exception.GetType().FullName
        message = $failureMessage
    }
    $evidence['completed_at'] = [DateTime]::UtcNow.ToString('o')
    try {
        Write-E2EEvidence -Path $EvidencePath
    } catch {
        [Console]::Error.WriteLine("Could not persist initial failure evidence: {0}" -f $_.Exception.Message)
    }

    $evidence['failure_cleanup'] = Invoke-E2EFailureCleanup
    $evidence.current_phase = $null
    $evidence['completed_at'] = [DateTime]::UtcNow.ToString('o')
    try {
        Write-E2EEvidence -Path $EvidencePath
    } catch {
        [Console]::Error.WriteLine("Could not persist final failure evidence: {0}" -f $_.Exception.Message)
    }
    throw $failureRecord
} finally {
    [Environment]::SetEnvironmentVariable('PYTHON_RUNTIME_INSTALLER_E2E_SECRET', $null, 'Process')
}
