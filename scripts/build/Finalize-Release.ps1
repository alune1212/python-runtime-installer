[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$CertificateBase64 = $env:WINDOWS_SIGNING_CERTIFICATE_BASE64,
    [string]$CertificatePassword = $env:WINDOWS_SIGNING_CERTIFICATE_PASSWORD,
    [string]$TimestampUrl = $env:WINDOWS_SIGNING_TIMESTAMP_URL
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\product.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$releaseRoot = Join-Path $RepositoryRoot 'build\release'
$innoOutput = Join-Path $RepositoryRoot 'installer\output'
$baseName = "{0}-{1}-windows-x64" -f $config.product.output_basename, $config.product.version
$unsignedSource = Join-Path $innoOutput ($baseName + '-unsigned.exe')
$signedSource = Join-Path $innoOutput ($baseName + '.exe')
[System.IO.Directory]::CreateDirectory($releaseRoot) | Out-Null

$isSigningConfigured = -not [string]::IsNullOrWhiteSpace($CertificateBase64) -and -not [string]::IsNullOrWhiteSpace($CertificatePassword)
if ($isSigningConfigured) {
    if (-not (Test-Path -LiteralPath $signedSource -PathType Leaf)) {
        throw "Signed-name installer source not found: $signedSource"
    }
    if (-not $TimestampUrl) { $TimestampUrl = 'http://timestamp.digicert.com' }
    & (Join-Path $PSScriptRoot 'Sign-Installer.ps1') -InstallerPath $signedSource -CertificateBase64 $CertificateBase64 -CertificatePassword $CertificatePassword -TimestampUrl $TimestampUrl
    if ($LASTEXITCODE -ne 0) { throw 'Installer signing failed.' }
    $installer = Join-Path $releaseRoot ($baseName + '.exe')
    Copy-Item -LiteralPath $signedSource -Destination $installer -Force
} else {
    if (-not (Test-Path -LiteralPath $unsignedSource -PathType Leaf)) {
        throw "Unsigned installer source not found: $unsignedSource"
    }
    $installer = Join-Path $releaseRoot ($baseName + '-unsigned.exe')
    Copy-Item -LiteralPath $unsignedSource -Destination $installer -Force
    @"
# Unsigned build

This executable is not Authenticode-signed and may trigger Microsoft SmartScreen.
Production distribution should configure the repository code-signing secrets.
"@ | Set-Content -LiteralPath (Join-Path $releaseRoot 'UNSIGNED_BUILD.md') -Encoding UTF8
}

$hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
("{0}  {1}`n" -f $hash, [System.IO.Path]::GetFileName($installer)) | Set-Content -LiteralPath (Join-Path $releaseRoot 'SHA256SUMS.txt') -Encoding ASCII
$evidenceName = "{0}-{1}-evidence.zip" -f $config.product.output_basename, $config.product.version
$evidencePath = Join-Path $releaseRoot $evidenceName
$temporaryRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$evidenceStaging = Join-Path $temporaryRoot ("python-runtime-evidence-{0}" -f [Guid]::NewGuid().ToString('N'))
try {
    [System.IO.Directory]::CreateDirectory($evidenceStaging) | Out-Null
    foreach ($name in @('PYTHON_LICENSE.txt', 'PROJECT_LICENSE.txt', 'THIRD_PARTY_NOTICES.txt', 'python-runtime-installer.cdx.json', 'build-provenance.json', 'payload-manifest.json')) {
        Copy-Item -LiteralPath (Join-Path $releaseRoot $name) -Destination $evidenceStaging
    }
    Copy-Item -LiteralPath (Join-Path $releaseRoot 'licenses') -Destination $evidenceStaging -Recurse
    Copy-Item -LiteralPath (Join-Path $releaseRoot 'sources') -Destination $evidenceStaging -Recurse
    Compress-Archive -Path (Join-Path $evidenceStaging '*') -DestinationPath $evidencePath -CompressionLevel Optimal -Force
} finally {
    if (Test-Path -LiteralPath $evidenceStaging) {
        Remove-Item -LiteralPath $evidenceStaging -Recurse -Force
    }
}
& uv run python -m scripts.build.scan_release --installer $installer
if ($LASTEXITCODE -ne 0) { throw 'Release evidence validation failed.' }
Write-Output $installer
