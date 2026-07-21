[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\product.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$appRoot = Join-Path $env:LOCALAPPDATA ([string]$config.product.install_dir_relative)
$logRoot = Join-Path $env:LOCALAPPDATA ([string]$config.product.log_dir_relative)
$temporaryRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$setupLog = Join-Path $temporaryRoot 'python-runtime-installer-e2e.setup.log'
$registryPath = "HKCU:\$($config.product.registry_path)"
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Python Runtime Installer'

function Invoke-Setup([string[]]$Arguments) {
    $process = Start-Process -FilePath $InstallerPath -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Installer exited with $($process.ExitCode). See $setupLog"
    }
}

Invoke-Setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/FORCEBUNDLED', ("/LOG={0}" -f $setupLog))
$manifestPath = Join-Path $appRoot 'manifest.json'
$pythonPath = Join-Path $appRoot 'venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) { throw "Managed Python missing: $pythonPath" }
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Manifest missing: $manifestPath" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.verification_status -ne 'passed' -or $manifest.runtime_ownership -ne 'private') {
    throw 'Installed manifest does not record a verified private runtime.'
}
if (-not (Test-Path -LiteralPath $registryPath)) { throw 'Discovery registry key is missing.' }
if (-not (Test-Path -LiteralPath $startMenu)) { throw 'Start menu group is missing.' }
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Python Runtime Installer.lnk'
if (Test-Path -LiteralPath $desktopShortcut) { throw 'Unexpected desktop shortcut was created.' }
if ([Environment]::GetEnvironmentVariable('PYTHON_RUNTIME_INSTALLER_HOME', 'User')) {
    throw 'Unexpected global environment variable was created.'
}

$healthyManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
Invoke-Setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ("/LOG={0}" -f $setupLog))
if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $healthyManifestHash) {
    throw 'A healthy same-version rerun unexpectedly rebuilt the environment.'
}

$sitePackages = (& $pythonPath -I -c 'import site; print(site.getsitepackages()[0])').Trim()
$driftMetadata = Join-Path $sitePackages 'custom_drift-1.0.dist-info'
New-Item -ItemType Directory -Path $driftMetadata -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $driftMetadata 'METADATA'), "Metadata-Version: 2.1`nName: custom-drift`nVersion: 1.0`n")
Invoke-Setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ("/LOG={0}" -f $setupLog))
if (Test-Path -LiteralPath $driftMetadata) {
    throw 'Same-version repair preserved an undeclared custom package.'
}
$uninstaller = Join-Path $appRoot 'unins000.exe'
if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'Uninstaller is missing.' }
$uninstall = Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
if ($uninstall.ExitCode -ne 0) { throw "Uninstaller exited with $($uninstall.ExitCode)" }
if (Test-Path -LiteralPath (Join-Path $appRoot 'venv')) { throw 'Managed virtual environment survived uninstall.' }
if (Test-Path -LiteralPath $registryPath) { throw 'Discovery registry key survived uninstall.' }
if (-not (Test-Path -LiteralPath $logRoot) -or @(Get-ChildItem -LiteralPath $logRoot -Filter 'installer-*.log').Count -eq 0) {
    throw 'Retained installer logs were not preserved.'
}

# Exercise the real reusable-interpreter branch using the exact setup-python
# interpreter. Preserve any runner registration and restore it in all cases.
$externalPython = (Get-Command python.exe -ErrorAction Stop).Source
$externalHash = (Get-FileHash -LiteralPath $externalPython -Algorithm SHA256).Hash
$pythonRegistry = 'HKCU:\Software\Python\PythonCore\3.13.14\InstallPath'
$registryExisted = Test-Path -LiteralPath $pythonRegistry
$savedDefault = $null
$savedValues = @{}
if ($registryExisted) {
    $savedDefault = (Get-Item -LiteralPath $pythonRegistry).GetValue('')
    $savedItem = Get-ItemProperty -LiteralPath $pythonRegistry
    foreach ($property in $savedItem.PSObject.Properties) {
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
    Invoke-Setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ("/LOG={0}" -f $setupLog))
    $reuseManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($reuseManifest.runtime_ownership -ne 'reused' -or $reuseManifest.base_python -ne $externalPython) {
        throw 'The controlled external CPython was not recorded as reused.'
    }
    $reuseUninstaller = Join-Path $appRoot 'unins000.exe'
    $reuseUninstall = Start-Process -FilePath $reuseUninstaller -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
    if ($reuseUninstall.ExitCode -ne 0) { throw "Reuse uninstall exited with $($reuseUninstall.ExitCode)" }
    if (-not (Test-Path -LiteralPath $externalPython -PathType Leaf)) {
        throw 'Reused CPython was removed by uninstall.'
    }
    if ((Get-FileHash -LiteralPath $externalPython -Algorithm SHA256).Hash -ne $externalHash) {
        throw 'Reused CPython was modified by uninstall.'
    }
} finally {
    if (Test-Path -LiteralPath $pythonRegistry) {
        Remove-Item -LiteralPath $pythonRegistry -Recurse -Force
    }
    if ($registryExisted) {
        New-Item -Path $pythonRegistry -Force | Out-Null
        if ($null -ne $savedDefault) {
            (Get-Item -LiteralPath $pythonRegistry).SetValue('', $savedDefault)
        }
        foreach ($name in $savedValues.Keys) {
            New-ItemProperty -Path $pythonRegistry -Name $name -Value $savedValues[$name] -Force | Out-Null
        }
    }
}
Write-Output 'End-to-end installer test passed.'
