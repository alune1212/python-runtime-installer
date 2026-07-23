[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AppRoot,
    [Parameter(Mandatory = $true)][string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RuntimeInstaller.psm1') -Force

$logRoot = Join-Path $env:LOCALAPPDATA 'PythonRuntimeInstaller\Logs'
Initialize-InstallerLog -LogDirectory $logRoot -Operation 'uninstall' | Out-Null

try {
    $config = Get-ProductConfig -ConfigPath $ConfigPath
    $manifestPath = Join-Path $AppRoot 'manifest.json'
    $manifest = $null
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    foreach ($relative in @('venv', '.staging')) {
        $ownedPath = Join-Path $AppRoot $relative
        if (Test-Path -LiteralPath $ownedPath) {
            Remove-OwnedDirectory -AppRoot $AppRoot -Path $ownedPath
        }
    }
    Get-ChildItem -LiteralPath $AppRoot -Directory -Filter '.previous-*' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-OwnedDirectory -AppRoot $AppRoot -Path $_.FullName }
    if ($manifest -and $manifest.runtime_ownership -eq 'private') {
        Uninstall-PrivatePython -AppRoot $AppRoot -InstallerFilename ([string]$config.target.python.filename)
        $runtimeRoot = Join-Path $AppRoot 'runtime'
        if (Test-Path -LiteralPath $runtimeRoot) {
            Remove-OwnedDirectory -AppRoot $AppRoot -Path $runtimeRoot
        }
    }
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $manifestPath -Force
    }
    Remove-DiscoveryRegistration -RegistryPath ([string]$config.product.registry_path)
    Write-InstallerLog -Stage 'complete' -Message 'Managed runtime uninstall completed; retained logs were preserved.'
    exit 0
} catch {
    Write-InstallerLog -Stage 'failure' -Level 'ERROR' -Message (
        Format-InstallerErrorRecord -ErrorRecord $_
    )
    exit 30
}
