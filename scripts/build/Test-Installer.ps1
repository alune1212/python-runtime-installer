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
$evidence = [ordered]@{
    schema_version = 1
    collected_at = [DateTime]::UtcNow.ToString('o')
    host = [ordered]@{
        windows_version = [Environment]::OSVersion.VersionString
        architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
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
}

function Test-E2ECondition([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
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
    $script:evidence.commands[$Phase] = "$([System.IO.Path]::GetFileName($Path)) $($Arguments -join ' ')"
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
    $script:evidence.exit_codes[$Phase] = $process.ExitCode
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

$healthyManifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
$healthyPythonHash = (Get-FileHash -LiteralPath $pythonPath -Algorithm SHA256).Hash
$failureManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$failureManifest.verification_status = 'failed'
[System.IO.File]::WriteAllText($manifestPath, ($failureManifest | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
$stagingParent = Join-Path $appRoot '.staging'
$stagingParentExisted = Test-Path -LiteralPath $stagingParent -PathType Container
if ($stagingParentExisted) {
    Test-E2ECondition (@(Get-ChildItem -LiteralPath $stagingParent -Force).Count -eq 0) 'The staging root is not empty before the failure fixture.'
    [System.IO.Directory]::Delete($stagingParent, $false)
}
[System.IO.File]::WriteAllText($stagingParent, 'recoverable e2e staging blocker', [Text.Encoding]::ASCII)
try {
    $failedExitCode = Invoke-Setup -Path $InstallerPath -Phase 'failed_staging' -AllowedExitCodes @(20) -Arguments $setupArguments
    Test-E2ECondition ($failedExitCode -eq 20) 'The staging failure returned an unexpected exit code.'
    Test-E2ECondition ((Get-FileHash -LiteralPath $pythonPath -Algorithm SHA256).Hash -eq $healthyPythonHash) 'Failed staging replaced active Python.'
    Test-RegistryValueSet -Expected $expectedDiscovery
} finally {
    [System.IO.File]::Delete($stagingParent)
    if ($stagingParentExisted) {
        [System.IO.Directory]::CreateDirectory($stagingParent) | Out-Null
    }
    [System.IO.File]::WriteAllBytes($manifestPath, $healthyManifestBytes)
}
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
    manifest_restored = ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $repairedManifestHash)
    discovery_preserved = $true
    verification_checks = @($recoveryVerification.checks)
}

$logsBeforePrivateUninstall = @(Get-ChildItem -LiteralPath $logRoot -Filter 'installer-*.log' -File | Select-Object -ExpandProperty FullName)
Test-E2ECondition ($logsBeforePrivateUninstall.Count -gt 0) 'No installer logs exist before uninstall.'
$uninstaller = Join-Path $appRoot 'unins000.exe'
Test-E2ECondition (Test-Path -LiteralPath $uninstaller -PathType Leaf) 'Uninstaller is missing.'
$evidence.commands['private_uninstall'] = "$([System.IO.Path]::GetFileName($uninstaller)) /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
$privateUninstall = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
$evidence.exit_codes['private_uninstall'] = $privateUninstall.ExitCode
Test-E2ECondition ($privateUninstall.ExitCode -eq 0) 'Private-runtime uninstall failed.'
Test-E2ECondition (-not (Test-Path -LiteralPath (Join-Path $appRoot 'venv'))) 'Managed environment survived uninstall.'
Test-E2ECondition (-not (Test-Path -LiteralPath $privatePythonPath -PathType Leaf)) 'Private CPython survived uninstall.'
Test-E2ECondition (-not (Test-Path -LiteralPath $registryPath)) 'Discovery metadata survived uninstall.'
Test-E2ECondition (-not (Test-Path -LiteralPath $startMenu)) 'Start menu shortcuts survived uninstall.'
foreach ($retainedLog in $logsBeforePrivateUninstall) {
    Test-E2ECondition (Test-Path -LiteralPath $retainedLog -PathType Leaf) "Uninstall removed retained log: $retainedLog"
}
Test-PathsUnchanged -ExpectedUserPath $userPathBefore -ExpectedMachinePath $machinePathBefore
$evidence['private_uninstall'] = [ordered]@{
    managed_environment_removed = $true
    private_python_removed = $true
    registry_removed = $true
    start_menu_removed = $true
    retained_log_count = $logsBeforePrivateUninstall.Count
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

$pythonRegistry = "HKCU:\Software\Python\PythonCore\$expectedPythonVersion\InstallPath"
$pythonRegistryExisted = Test-Path -LiteralPath $pythonRegistry
$savedDefault = $null
$savedValues = @{}
if ($pythonRegistryExisted) {
    $savedDefault = (Get-Item -LiteralPath $pythonRegistry).GetValue('')
    foreach ($property in (Get-ItemProperty -LiteralPath $pythonRegistry).PSObject.Properties) {
        if (-not $property.Name.StartsWith('PS')) {
            $savedValues[$property.Name] = $property.Value
        }
    }
}
try {
    if (Test-Path -LiteralPath $pythonRegistry) {
        Remove-Item -LiteralPath $pythonRegistry -Recurse -Force
    }
    New-Item -Path $pythonRegistry -Force | Out-Null
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
    $logsBeforeReuseUninstall = @(Get-ChildItem -LiteralPath $logRoot -Filter 'installer-*.log' -File | Select-Object -ExpandProperty FullName)
    $reuseUninstaller = Join-Path $appRoot 'unins000.exe'
    $evidence.commands['reuse_uninstall'] = "$([System.IO.Path]::GetFileName($reuseUninstaller)) /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
    $reuseUninstall = Start-Process -FilePath $reuseUninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
    $evidence.exit_codes['reuse_uninstall'] = $reuseUninstall.ExitCode
    Test-E2ECondition ($reuseUninstall.ExitCode -eq 0) 'Reused-runtime uninstall failed.'
    Test-E2ECondition (Test-Path -LiteralPath $externalPython -PathType Leaf) 'Reused CPython was removed by uninstall.'
    Test-E2ECondition ((Get-FileHash -LiteralPath $externalPython -Algorithm SHA256).Hash -eq $externalHash) 'Reused CPython was modified by uninstall.'
    Test-E2ECondition ((Get-Item -LiteralPath $externalPython).Length -eq $externalLength) 'Reused CPython size changed during uninstall.'
    Test-E2ECondition (-not (Test-Path -LiteralPath (Join-Path $appRoot 'venv'))) 'Managed environment survived reused-runtime uninstall.'
    Test-E2ECondition (-not (Test-Path -LiteralPath $registryPath)) 'Discovery metadata survived reused-runtime uninstall.'
    foreach ($retainedLog in $logsBeforeReuseUninstall) {
        Test-E2ECondition (Test-Path -LiteralPath $retainedLog -PathType Leaf) "Reuse uninstall removed retained log: $retainedLog"
    }
    Test-PathsUnchanged -ExpectedUserPath $userPathBefore -ExpectedMachinePath $machinePathBefore
    $evidence['reused_runtime'] = [ordered]@{
        path = $externalPython
        version = [string]$externalIdentity.version
        architecture = [string]$externalIdentity.bits
        sha256_before = $externalHash.ToLowerInvariant()
        sha256_after = (Get-FileHash -LiteralPath $externalPython -Algorithm SHA256).Hash.ToLowerInvariant()
        preserved = $true
        verification_checks = @($reuseVerification.checks)
    }
} finally {
    if (Test-Path -LiteralPath $pythonRegistry) {
        Remove-Item -LiteralPath $pythonRegistry -Recurse -Force
    }
    if ($pythonRegistryExisted) {
        New-Item -Path $pythonRegistry -Force | Out-Null
        if ($null -ne $savedDefault) {
            (Get-Item -LiteralPath $pythonRegistry).SetValue('', $savedDefault)
        }
        foreach ($name in $savedValues.Keys) {
            New-ItemProperty -Path $pythonRegistry -Name $name -Value $savedValues[$name] -Force | Out-Null
        }
    }
}

$technicalLogs = @(Get-ChildItem -LiteralPath $logRoot -Filter 'installer-*.log' -File | Sort-Object LastWriteTimeUtc)
Test-E2ECondition ($technicalLogs.Count -gt 0) 'Retained installer logs are missing.'
Test-E2ECondition (Test-Path -LiteralPath $setupLog -PathType Leaf) 'Inno Setup log is missing.'
$verificationBeforeCompletion = $false
foreach ($technicalLog in $technicalLogs) {
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
    retained_count = $technicalLogs.Count
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
