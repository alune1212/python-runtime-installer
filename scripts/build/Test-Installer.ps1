[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$EvidencePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
if ([string]::IsNullOrWhiteSpace($expectedBuildCommit)) {
    throw 'Could not resolve the expected build commit.'
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
$evidence = [ordered]@{
    schema_version = 1
    collected_at = [DateTime]::UtcNow.ToString('o')
    host = [ordered]@{
        windows_version = [Environment]::OSVersion.VersionString
        architecture = $nativeArchitecture
        powershell_version = $PSVersionTable.PSVersion.ToString()
        powershell_edition = [string]$PSVersionTable.PSEdition
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
}

function Test-E2ECondition([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
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
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
    $script:evidence.exit_codes[$Phase] = $process.ExitCode
    $script:evidence.log_paths[$Phase] = Get-NewInstallerLogPath -BeforePaths $logsBefore -Pattern 'installer-install-*.log' -Phase $Phase

    if ($AllowedExitCodes -notcontains $process.ExitCode) {
        throw "Installer phase $Phase exited with $($process.ExitCode). See $setupLog"
    }
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

Test-E2ECondition (-not (Test-Path -LiteralPath $appRoot)) "E2E test requires a clean application path: $appRoot"
Test-E2ECondition (-not (Test-Path -LiteralPath $registryPath)) "E2E test requires clean discovery metadata: $registryPath"
if ($InstallerPath.EndsWith('-unsigned.exe', [StringComparison]::OrdinalIgnoreCase)) {
    Test-E2ECondition ($installerSignature.Status -eq 'NotSigned') 'Unsigned-named installer unexpectedly has a non-NotSigned status.'
} else {
    Test-E2ECondition ($installerSignature.Status -eq 'Valid') 'Signed-named installer does not have a valid Authenticode signature.'
}

$setupArguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ("/LOG={0}" -f $setupLog))
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

$runtimeProbe = & $pythonPath -I -c 'import json,platform,sys;print(json.dumps({"version":platform.python_version(),"bits":platform.architecture()[0],"implementation":sys.implementation.name}))'
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
    $launcherProbe = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/s', '/c', ('"{0}"' -f $launcherProbePath)) -WindowStyle Hidden -Wait -PassThru
    $evidence.exit_codes['start_menu_activation_probe'] = $launcherProbe.ExitCode
    Test-E2ECondition ($launcherProbe.ExitCode -eq 0) 'Start menu activation probe failed.'
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
Test-E2ECondition ((Get-FileHash -LiteralPath $pythonPath -Algorithm SHA256).Hash -eq $healthyPythonHash) 'Failed staging replaced active Python.'
Test-E2ECondition ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $healthyManifestHashBeforeFailure) 'Failed staging replaced the healthy manifest.'
$stagingEntries = @(Get-ChildItem -LiteralPath $stagingParent -Force -ErrorAction SilentlyContinue)
Test-E2ECondition ($stagingEntries.Count -eq 0) 'Failed staging content was not cleaned.'
$previousEntries = @(Get-ChildItem -LiteralPath $appRoot -Directory -Filter '.previous-*' -ErrorAction SilentlyContinue)
Test-E2ECondition ($previousEntries.Count -eq 0) 'Failed staging created a previous active environment.'
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
    active_python_sha256_after = (Get-FileHash -LiteralPath $pythonPath -Algorithm SHA256).Hash.ToLowerInvariant()
    manifest_preserved = ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $healthyManifestHashBeforeFailure)
    discovery_preserved = $true
    staging_verified = $true
    log_path = $failedStagingLog.FullName
    verification_checks = @($recoveryVerification.checks)
}

$logsBeforePrivateUninstall = @(Get-InstallerLogSnapshot)
Test-E2ECondition ($logsBeforePrivateUninstall.Count -gt 0) 'No installer logs exist before uninstall.'
$privateLogPathsBefore = @($logsBeforePrivateUninstall | Select-Object -ExpandProperty FullName)
$privateLogsGuaranteedRetained = @($logsBeforePrivateUninstall | Select-Object -First 19 -ExpandProperty FullName)
$uninstaller = Join-Path $appRoot 'unins000.exe'
Test-E2ECondition (Test-Path -LiteralPath $uninstaller -PathType Leaf) 'Uninstaller is missing.'
$evidence.commands['private_uninstall'] = "$([System.IO.Path]::GetFileName($uninstaller)) /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
$privateUninstall = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
$evidence.exit_codes['private_uninstall'] = $privateUninstall.ExitCode
$privateUninstallLog = Get-NewInstallerLogPath -BeforePaths $privateLogPathsBefore -Pattern 'installer-uninstall-*.log' -Phase 'private_uninstall'
$evidence.log_paths['private_uninstall'] = $privateUninstallLog
Test-E2ECondition ($privateUninstall.ExitCode -eq 0) 'Private-runtime uninstall failed.'
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
}

$externalPython = (Get-Command python.exe -ErrorAction Stop).Source
$externalHash = (Get-FileHash -LiteralPath $externalPython -Algorithm SHA256).Hash
$externalLength = (Get-Item -LiteralPath $externalPython).Length
$externalProbeText = & $externalPython -I -c 'import json,platform,sys;print(json.dumps({"version":platform.python_version(),"bits":platform.architecture()[0],"implementation":sys.implementation.name}))'
Test-E2ECondition ($LASTEXITCODE -eq 0) 'Controlled external Python probe failed.'
$externalIdentity = $externalProbeText | ConvertFrom-Json
$blockedExternalPath = $externalPython.ToLowerInvariant() -match '\\(windowsapps|anaconda|miniconda|conda|embedded)\\'
Test-E2ECondition `
    ($externalIdentity.version -eq $expectedPythonVersion -and $externalIdentity.bits -eq '64bit' -and $externalIdentity.implementation -eq 'cpython' -and -not $blockedExternalPath) `
    "External Python is not reusable standard CPython $expectedPythonVersion x64: $externalPython"

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
    (Get-Item -LiteralPath $pythonRegistry).SetValue('', (Split-Path -Parent $externalPython), [Microsoft.Win32.RegistryValueKind]::String)
    New-ItemProperty -Path $pythonRegistry -Name ExecutablePath -Value $externalPython -PropertyType String -Force | Out-Null
    Invoke-Setup -Path $InstallerPath -Phase 'reuse_install' -Arguments $setupArguments | Out-Null
    $reuseManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-E2ECondition ($reuseManifest.runtime_ownership -eq 'reused') 'External CPython was not recorded as reused.'
    Test-E2ECondition ([StringComparer]::OrdinalIgnoreCase.Equals([string]$reuseManifest.base_python, $externalPython)) 'Reused base Python path is incorrect.'
    $reuseResultPath = Join-Path $temporaryRoot ("python-runtime-reuse-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    try {
        $reuseVerification = Invoke-ManagedVerification -Path $pythonPath -ResultPath $reuseResultPath -Phase 'reuse_environment_verification'
    } finally {
        [System.IO.File]::Delete($reuseResultPath)
    }
    $logsBeforeReuseUninstall = @(Get-InstallerLogSnapshot)
    $reuseLogPathsBefore = @($logsBeforeReuseUninstall | Select-Object -ExpandProperty FullName)
    $reuseLogsGuaranteedRetained = @($logsBeforeReuseUninstall | Select-Object -First 19 -ExpandProperty FullName)
    $reuseUninstaller = Join-Path $appRoot 'unins000.exe'
    $evidence.commands['reuse_uninstall'] = "$([System.IO.Path]::GetFileName($reuseUninstaller)) /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
    $reuseUninstall = Start-Process -FilePath $reuseUninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
    $evidence.exit_codes['reuse_uninstall'] = $reuseUninstall.ExitCode
    Test-E2ECondition ($reuseUninstall.ExitCode -eq 0) 'Reused-runtime uninstall failed.'
    Test-E2ECondition (Test-Path -LiteralPath $externalPython -PathType Leaf) 'Reused CPython was removed by uninstall.'
    $reuseUninstallLog = Get-NewInstallerLogPath -BeforePaths $reuseLogPathsBefore -Pattern 'installer-uninstall-*.log' -Phase 'reuse_uninstall'
    $evidence.log_paths['reuse_uninstall'] = $reuseUninstallLog
    Test-E2ECondition ((Get-FileHash -LiteralPath $externalPython -Algorithm SHA256).Hash -eq $externalHash) 'Reused CPython was modified by uninstall.'
    Test-E2ECondition ((Get-Item -LiteralPath $externalPython).Length -eq $externalLength) 'Reused CPython size changed during uninstall.'
    Test-E2ECondition (-not (Test-Path -LiteralPath (Join-Path $appRoot 'venv'))) 'Managed environment survived reused-runtime uninstall.'
    Test-E2ECondition (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) 'Installed manifest survived reused-runtime uninstall.'
    Test-E2ECondition (-not (Test-Path -LiteralPath $registryPath)) 'Discovery metadata survived reused-runtime uninstall.'
    Test-E2ECondition (-not (Test-Path -LiteralPath $appRoot)) 'Application root survived reused-runtime uninstall.'
    foreach ($retainedLog in $reuseLogsGuaranteedRetained) {
        Test-E2ECondition (Test-Path -LiteralPath $retainedLog -PathType Leaf) "Reuse uninstall removed retained log: $retainedLog"
    }
    $logsAfterReuseUninstall = @(Get-InstallerLogSnapshot)
    Test-E2ECondition ($logsAfterReuseUninstall.Count -le 20) 'Reused-runtime uninstall exceeded the newest-20 log retention bound.'
    Test-PathsUnchanged -ExpectedUserPath $userPathBefore -ExpectedMachinePath $machinePathBefore
    $evidence['reused_runtime'] = [ordered]@{
        path = $externalPython
        version = [string]$externalIdentity.version
        architecture = [string]$externalIdentity.bits
        sha256_before = $externalHash.ToLowerInvariant()
        sha256_after = (Get-FileHash -LiteralPath $externalPython -Algorithm SHA256).Hash.ToLowerInvariant()
        preserved = $true
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
$evidence['completed_at'] = [DateTime]::UtcNow.ToString('o')
$evidenceDirectory = Split-Path -Parent $EvidencePath
[System.IO.Directory]::CreateDirectory($evidenceDirectory) | Out-Null
[System.IO.File]::WriteAllText($EvidencePath, ($evidence | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
[Environment]::SetEnvironmentVariable('PYTHON_RUNTIME_INSTALLER_E2E_SECRET', $null, 'Process')
Write-Output "End-to-end installer test passed. Evidence: $EvidencePath"
