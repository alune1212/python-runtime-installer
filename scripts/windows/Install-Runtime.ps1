[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AppRoot,
    [Parameter(Mandatory = $true)][string]$PayloadRoot,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$RequirementsPath,
    [string]$BuildCommit = 'local',
    [string]$StatusPath = '',
    [switch]$ForceBundled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RuntimeInstaller.psm1') -Force

$logRoot = Join-Path $env:LOCALAPPDATA 'PythonRuntimeInstaller\Logs'
Initialize-InstallerLog -LogDirectory $logRoot -Operation 'install' | Out-Null
$stageRoot = $null
$previousRoot = $null
$privateRuntimeNew = $false
$activationAttempted = $false
$activationCommitted = $false
$previousManifestPath = $null
$operation = 'install'
$discoverySnapshot = $null

function Write-InstallStatus([string]$Value, [string]$Path) {
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        try {
            [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            [Console]::Error.WriteLine("Could not write UI status: {0}" -f $_.Exception.Message)
        }
    }
}

try {
    $config = Get-ProductConfig -ConfigPath $ConfigPath
    $incomingVersion = [string]$config.product.version
    $pythonVersion = [string]$config.target.python.version
    $activeRoot = Join-Path $AppRoot 'venv'
    $activePython = Join-Path $activeRoot 'Scripts\python.exe'
    $manifestPath = Join-Path $AppRoot 'manifest.json'
    $payloadManifestPath = Join-Path $PayloadRoot 'payload-manifest.json'
    $verifierPath = Join-Path $PayloadRoot 'scripts\verify_environment.py'
    $bootstrapRequirementsPath = Join-Path $PayloadRoot 'bootstrap-requirements.txt'
    $pythonInstallerPath = Join-Path $PayloadRoot ([string]$config.target.python.filename)
    $discoverySnapshot = Get-DiscoveryMetadataSnapshot -RegistryPath ([string]$config.product.registry_path)

    Assert-WindowsPreflight -AppRoot $AppRoot -MinimumFreeBytes ([Int64]$config.target.minimum_free_bytes)
    $payloadManifest = Test-PayloadManifest -PayloadRoot $PayloadRoot -ManifestPath $payloadManifestPath

    $installedManifest = $null
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $installedManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $versionComparison = Compare-InstallerVersion -InstalledVersion ([string]$installedManifest.installer_version) -IncomingVersion $incomingVersion
        if ($versionComparison -gt 0) {
            Write-InstallerLog -Stage 'lifecycle' -Level 'ERROR' -Message ("Downgrade blocked: installed={0} incoming={1}. Uninstall first." -f $installedManifest.installer_version, $incomingVersion)
            Write-InstallStatus -Value 'downgrade-blocked' -Path $StatusPath
            exit 21
        }
        if ($versionComparison -eq 0 -and (Test-Path -LiteralPath $activePython -PathType Leaf)) {
            try {
                Invoke-LoggedProcess -FilePath $activePython -Arguments @(
                    $verifierPath,
                    '--requirements', $RequirementsPath,
                    '--bootstrap-requirements', $bootstrapRequirementsPath,
                    '--expected-python', $pythonVersion,
                    '--expected-executable', $activePython,
                    '--manifest', $manifestPath
                ) -Stage 'repair-check' | Out-Null
                Publish-DiscoveryMetadata -RegistryPath ([string]$config.product.registry_path) -AppRoot $AppRoot -PythonExecutable $activePython -PythonVersion $pythonVersion -InstallerVersion $incomingVersion -ManifestPath $manifestPath
                Write-InstallerLog -Stage 'complete' -Message 'Existing environment is healthy; no rebuild required.'
                Write-InstallStatus -Value 'healthy' -Path $StatusPath
                exit 0
            } catch {
                $operation = 'repair'
                Write-InstallerLog -Stage 'repair-check' -Level 'WARN' -Message ("Environment drift detected; rebuilding. {0}" -f $_.Exception.Message)
            }
        } elseif ($versionComparison -lt 0) {
            $operation = 'upgrade'
        }
    }

    [System.IO.Directory]::CreateDirectory($AppRoot) | Out-Null
    $basePython = $null
    $runtimeOwnership = 'reused'
    if ($installedManifest -and $installedManifest.runtime_ownership -eq 'private' -and $installedManifest.base_python) {
        if (Test-CompatiblePython -PythonPath ([string]$installedManifest.base_python) -ExpectedVersion $pythonVersion) {
            $basePython = [string]$installedManifest.base_python
            $runtimeOwnership = 'private'
        } else {
            $private = Install-PrivatePython -InstallerPath $pythonInstallerPath -AppRoot $AppRoot -ExpectedVersion $pythonVersion
            $basePython = [string]$private.PythonPath
            $privateRuntimeNew = [bool]$private.NewlyInstalled
            $runtimeOwnership = 'private'
        }
    }
    if (-not $basePython) {
        $basePython = Find-CompatiblePython -ExpectedVersion $pythonVersion -ManagedRoot $AppRoot -ForceBundled:$ForceBundled
    }
    if (-not $basePython) {
        $private = Install-PrivatePython -InstallerPath $pythonInstallerPath -AppRoot $AppRoot -ExpectedVersion $pythonVersion
        $basePython = [string]$private.PythonPath
        $privateRuntimeNew = [bool]$private.NewlyInstalled
        $runtimeOwnership = 'private'
    }

    $transactionId = [Guid]::NewGuid().ToString('N')
    $stageRoot = Join-Path $AppRoot ('.staging\' + $transactionId)
    $stageVenv = Join-Path $stageRoot 'venv'
    [System.IO.Directory]::CreateDirectory($stageRoot) | Out-Null
    Invoke-LoggedProcess -FilePath $basePython -Arguments @('-I', '-m', 'venv', $stageVenv) -Stage 'venv-create' | Out-Null
    $stagePython = Join-Path $stageVenv 'Scripts\python.exe'
    $wheelhouse = Join-Path $PayloadRoot 'wheelhouse'
    Invoke-LoggedProcess -FilePath $stagePython -Arguments @(
        '-I', '-m', 'pip', 'install',
        '--no-index',
        '--find-links', $wheelhouse,
        '--require-hashes',
        '--no-deps',
        '--requirement', $bootstrapRequirementsPath,
        '--disable-pip-version-check'
    ) -Stage 'bootstrap-install' | Out-Null
    Invoke-LoggedProcess -FilePath $stagePython -Arguments @(
        '-I', '-m', 'pip', 'install',
        '--no-index',
        '--find-links', $wheelhouse,
        '--require-hashes',
        '--no-deps',
        '--requirement', $RequirementsPath,
        '--disable-pip-version-check'
    ) -Stage 'dependency-install' | Out-Null

    $stageResult = Join-Path $stageRoot 'verification.json'
    Invoke-LoggedProcess -FilePath $stagePython -Arguments @(
        $verifierPath,
        '--requirements', $RequirementsPath,
        '--bootstrap-requirements', $bootstrapRequirementsPath,
        '--expected-python', $pythonVersion,
        '--expected-executable', $stagePython,
        '--output', $stageResult
    ) -Stage 'verification' | Out-Null

    if (Test-Path -LiteralPath $activeRoot) {
        $previousRoot = Join-Path $AppRoot ('.previous-' + $transactionId)
        Move-Item -LiteralPath $activeRoot -Destination $previousRoot
    }
    Move-Item -LiteralPath $stageVenv -Destination $activeRoot
    $activationAttempted = $true
    Update-VenvActivationPath -VenvRoot $activeRoot -OldRoot $stageVenv

    # Python's distlib console launchers embed their interpreter path. Reinstall
    # from the same verified offline locks after the same-volume rename, while
    # the previous environment is still available and discovery is unpublished.
    foreach ($lockPath in @($bootstrapRequirementsPath, $RequirementsPath)) {
        Invoke-LoggedProcess -FilePath $activePython -Arguments @(
            '-I', '-m', 'pip', 'install',
            '--no-index',
            '--find-links', $wheelhouse,
            '--require-hashes',
            '--no-deps',
            '--force-reinstall',
            '--requirement', $lockPath,
            '--disable-pip-version-check'
        ) -Stage 'post-promotion-relink' | Out-Null
    }

    $finalResult = Join-Path $stageRoot 'verification-final.json'
    Invoke-LoggedProcess -FilePath $activePython -Arguments @(
        $verifierPath,
        '--requirements', $RequirementsPath,
        '--bootstrap-requirements', $bootstrapRequirementsPath,
        '--expected-python', $pythonVersion,
        '--expected-executable', $activePython,
        '--output', $finalResult
    ) -Stage 'verification-final' | Out-Null
    $verification = Get-Content -LiteralPath $finalResult -Raw -Encoding UTF8 | ConvertFrom-Json

    $installed = [ordered]@{
        schema_version = 1
        installer_version = $incomingVersion
        python_version = $pythonVersion
        python_executable = $activePython
        base_python = $basePython
        runtime_ownership = $runtimeOwnership
        build_commit = $BuildCommit
        payload_target = [string]$payloadManifest.target
        payload_files = $payloadManifest.files
        packages = $verification.packages
        bootstrap_tooling = $verification.bootstrap_tooling
        verification_checks = $verification.checks
        verified_at = $verification.verified_at
        verification_status = 'passed'
    }
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $previousManifestPath = Join-Path $AppRoot ('.previous-manifest-' + $transactionId + '.json')
        Copy-Item -LiteralPath $manifestPath -Destination $previousManifestPath
    }
    $temporaryManifestPath = Join-Path $AppRoot ('.manifest-' + $transactionId + '.json')
    [System.IO.File]::WriteAllText($temporaryManifestPath, ($installed | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporaryManifestPath -Destination $manifestPath -Force
    Publish-DiscoveryMetadata -RegistryPath ([string]$config.product.registry_path) -AppRoot $AppRoot -PythonExecutable $activePython -PythonVersion $pythonVersion -InstallerVersion $incomingVersion -ManifestPath $manifestPath
    $activationCommitted = $true

    if ($previousRoot -and (Test-Path -LiteralPath $previousRoot)) {
        try {
            Remove-OwnedDirectory -AppRoot $AppRoot -Path $previousRoot
        } catch {
            Write-InstallerLog -Stage 'cleanup' -Level 'WARN' -Message ("Previous environment cleanup deferred: {0}" -f $_.Exception.Message)
        }
        $previousRoot = $null
    }
    if ($stageRoot -and (Test-Path -LiteralPath $stageRoot)) {
        try {
            Remove-OwnedDirectory -AppRoot $AppRoot -Path $stageRoot
        } catch {
            Write-InstallerLog -Stage 'cleanup' -Level 'WARN' -Message ("Staging cleanup deferred: {0}" -f $_.Exception.Message)
        }
        $stageRoot = $null
    }
    if ($previousManifestPath -and (Test-Path -LiteralPath $previousManifestPath)) {
        Remove-Item -LiteralPath $previousManifestPath -Force
        $previousManifestPath = $null
    }
    Write-InstallerLog -Stage 'complete' -Message ("Installation completed: {0}" -f $activePython)
    Write-InstallStatus -Value $operation -Path $StatusPath
    exit 0
} catch {
    if ($activationCommitted) {
        [Console]::Error.WriteLine("Post-commit housekeeping warning: {0}" -f $_.Exception.Message)
        Write-InstallStatus -Value $operation -Path $StatusPath
        exit 0
    }
    Write-InstallerLog -Stage 'failure' -Level 'ERROR' -Message $_.Exception.ToString()
    Write-InstallStatus -Value 'failed' -Path $StatusPath
    try {
        if ($activationAttempted -and (Test-Path -LiteralPath (Join-Path $AppRoot 'venv'))) {
            Remove-OwnedDirectory -AppRoot $AppRoot -Path (Join-Path $AppRoot 'venv')
        }
        if ($previousRoot -and (Test-Path -LiteralPath $previousRoot)) {
            Move-Item -LiteralPath $previousRoot -Destination (Join-Path $AppRoot 'venv')
        }
        if ($previousManifestPath -and (Test-Path -LiteralPath $previousManifestPath)) {
            Move-Item -LiteralPath $previousManifestPath -Destination (Join-Path $AppRoot 'manifest.json') -Force
        } elseif ($activationAttempted -and (Test-Path -LiteralPath (Join-Path $AppRoot 'manifest.json'))) {
            Remove-Item -LiteralPath (Join-Path $AppRoot 'manifest.json') -Force
        }
        if ($discoverySnapshot) {
            Restore-DiscoveryMetadata -RegistryPath ([string]$config.product.registry_path) -Snapshot $discoverySnapshot
        }
        if ($stageRoot -and (Test-Path -LiteralPath $stageRoot)) {
            Remove-OwnedDirectory -AppRoot $AppRoot -Path $stageRoot
        }
        if ($privateRuntimeNew) {
            Uninstall-PrivatePython -AppRoot $AppRoot -InstallerFilename ([string]$config.target.python.filename)
        }
    } catch {
        Write-InstallerLog -Stage 'rollback' -Level 'ERROR' -Message $_.Exception.ToString()
    }
    exit 20
}
