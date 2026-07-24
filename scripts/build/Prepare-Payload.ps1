[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$PythonExecutable = 'python'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Push-Location $RepositoryRoot
try {
    $configPath = Join-Path $RepositoryRoot 'config\product.json'
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $payloadRoot = Join-Path $RepositoryRoot 'build\payload'
    $releaseRoot = Join-Path $RepositoryRoot 'build\release'

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [string]$ExpectedPublisher = ''
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
    $actual = Get-Sha256 -Path $Destination
    if ($actual -ne $ExpectedSha256) {
        throw "Download hash mismatch: $Destination expected=$ExpectedSha256 actual=$actual"
    }
    if ($ExpectedPublisher) {
        $signature = Get-AuthenticodeSignature -LiteralPath $Destination
        $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
        if ($signature.Status -ne 'Valid' -or -not $subject.Contains($ExpectedPublisher)) {
            throw "Authenticode verification failed: $Destination status=$($signature.Status) subject=$subject"
        }
    }
}

if (Test-Path -LiteralPath $payloadRoot) {
    Remove-Item -LiteralPath $payloadRoot -Recurse -Force
}
if (Test-Path -LiteralPath $releaseRoot) {
    Remove-Item -LiteralPath $releaseRoot -Recurse -Force
}
[System.IO.Directory]::CreateDirectory($payloadRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($releaseRoot) | Out-Null

$pythonInstaller = Join-Path $payloadRoot ([string]$config.target.python.filename)
Get-VerifiedDownload -Uri ([string]$config.target.python.url) -Destination $pythonInstaller -ExpectedSha256 ([string]$config.target.python.sha256) -ExpectedPublisher ([string]$config.target.python.expected_publisher)

$pythonLicense = Join-Path $releaseRoot 'PYTHON_LICENSE.txt'
Get-VerifiedDownload -Uri ([string]$config.target.python.license_url) -Destination $pythonLicense -ExpectedSha256 ([string]$config.target.python.license_sha256)
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'LICENSE') -Destination (Join-Path $releaseRoot 'PROJECT_LICENSE.txt')

& $PythonExecutable -m pip --version | Out-Null
& uv run python -m scripts.build.build_wheelhouse --python $PythonExecutable
if ($LASTEXITCODE -ne 0) { throw 'Wheelhouse creation failed.' }
& uv run python -m scripts.build.generate_notices
if ($LASTEXITCODE -ne 0) { throw 'Third-party notice generation failed.' }
& uv run python -m scripts.build.generate_sbom
if ($LASTEXITCODE -ne 0) { throw 'SBOM generation failed.' }
& uv run python -m scripts.build.download_source_evidence
if ($LASTEXITCODE -ne 0) { throw 'Source evidence generation failed.' }
$innoConfig = $config.build.inno_setup
$translationConfig = $innoConfig.chinese_translation
$innoLicenseDirectory = Join-Path $releaseRoot 'licenses\inno-setup'
$translationLicenseDirectory = Join-Path $releaseRoot 'licenses\inno-setup-chinese-translation'
$translationSourceDirectory = Join-Path $releaseRoot 'sources\inno-setup-chinese-translation'
foreach ($directory in @($innoLicenseDirectory, $translationLicenseDirectory, $translationSourceDirectory)) {
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
}
$innoLicensePath = Join-Path $innoLicenseDirectory 'LICENSE.txt'
Get-VerifiedDownload -Uri ([string]$innoConfig.license_url) -Destination $innoLicensePath -ExpectedSha256 ([string]$innoConfig.license_sha256)
$translationLicensePath = Join-Path $translationLicenseDirectory 'LICENSE.txt'
Get-VerifiedDownload -Uri ([string]$translationConfig.license_url) -Destination $translationLicensePath -ExpectedSha256 ([string]$translationConfig.license_sha256)
$translationSourcePath = Join-Path $translationSourceDirectory ([string]$translationConfig.filename)
Get-VerifiedDownload -Uri ([string]$translationConfig.url) -Destination $translationSourcePath -ExpectedSha256 ([string]$translationConfig.sha256)

$noticeLines = @(
    '',
    'Build and installer components',
    '',
    'Name: Inno Setup',
    ("Version: {0}" -f $innoConfig.version),
    'License: Inno Setup License',
    ("Source: {0}" -f $innoConfig.url),
    'License file: licenses/inno-setup/LICENSE.txt',
    '',
    'Name: Inno Setup Chinese Simplified Translation',
    ("Version: {0} (commit {1})" -f $translationConfig.version, $translationConfig.commit),
    'License: MIT',
    ("Source: {0}" -f $translationConfig.url),
    'License file: licenses/inno-setup-chinese-translation/LICENSE.txt',
    'Source file: sources/inno-setup-chinese-translation/ChineseSimplified.isl',
    ''
)
$noticePath = Join-Path $releaseRoot 'THIRD_PARTY_NOTICES.txt'
$noticeText = $noticeLines -join [Environment]::NewLine
[System.IO.File]::AppendAllText($noticePath, $noticeText, (New-Object System.Text.UTF8Encoding($false)))
& uv run python -m scripts.build.write_provenance
if ($LASTEXITCODE -ne 0) { throw 'Provenance generation failed.' }

Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'requirements.txt') -Destination $payloadRoot
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'bootstrap-requirements.txt') -Destination $payloadRoot
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'LICENSE') -Destination $payloadRoot
Copy-Item -LiteralPath $pythonLicense -Destination $payloadRoot
Copy-Item -LiteralPath (Join-Path $releaseRoot 'THIRD_PARTY_NOTICES.txt') -Destination $payloadRoot
Copy-Item -LiteralPath (Join-Path $releaseRoot 'python-runtime-installer.cdx.json') -Destination $payloadRoot
Copy-Item -LiteralPath (Join-Path $releaseRoot 'build-provenance.json') -Destination $payloadRoot
Copy-Item -LiteralPath (Join-Path $releaseRoot 'licenses') -Destination $payloadRoot -Recurse
Copy-Item -LiteralPath (Join-Path $releaseRoot 'sources') -Destination $payloadRoot -Recurse
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'config') -Destination $payloadRoot -Recurse
[System.IO.Directory]::CreateDirectory((Join-Path $payloadRoot 'scripts\build')) | Out-Null
[System.IO.Directory]::CreateDirectory((Join-Path $payloadRoot 'scripts\windows')) | Out-Null
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts\__init__.py') -Destination (Join-Path $payloadRoot 'scripts')
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts\select_entrypoint_requirements.py') -Destination (Join-Path $payloadRoot 'scripts')
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts\verify_environment.py') -Destination (Join-Path $payloadRoot 'scripts')
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts\build\__init__.py') -Destination (Join-Path $payloadRoot 'scripts\build')
Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts\build\requirements_lock.py') -Destination (Join-Path $payloadRoot 'scripts\build')
Copy-Item -Path (Join-Path $RepositoryRoot 'scripts\windows\*') -Destination (Join-Path $payloadRoot 'scripts\windows') -Recurse

& uv run python -m scripts.build.generate_payload_manifest
if ($LASTEXITCODE -ne 0) { throw 'Payload manifest generation failed.' }
& uv run python -m scripts.build.generate_payload_manifest --verify
if ($LASTEXITCODE -ne 0) { throw 'Payload manifest verification failed.' }
Copy-Item -LiteralPath (Join-Path $payloadRoot 'payload-manifest.json') -Destination $releaseRoot
Write-Output "Payload ready: $payloadRoot"
} finally {
    Pop-Location
}
