[CmdletBinding()]
param([string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_VerifiedDownload.ps1')
$config = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\product.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$toolRoot = Join-Path $RepositoryRoot 'build\tools'
$innoRoot = Join-Path $toolRoot 'inno'
$installer = Join-Path $toolRoot ([string]$config.build.inno_setup.filename)
[System.IO.Directory]::CreateDirectory($toolRoot) | Out-Null

Get-VerifiedDownload `
    -Uri ([string]$config.build.inno_setup.url) `
    -Destination $installer `
    -ExpectedSha256 ([string]$config.build.inno_setup.sha256) `
    -ExpectedPublisher ([string]$config.build.inno_setup.expected_publisher)
$process = Start-Process -FilePath $installer -ArgumentList @(
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
    '/SP-',
    '/CURRENTUSER',
    '/PORTABLE=1',
    '/NOICONS',
    ("/DIR={0}" -f $innoRoot)
) -Wait -PassThru
if ($process.ExitCode -ne 0) {
    throw "Inno Setup tool installation failed with exit code $($process.ExitCode)"
}
$compiler = Join-Path $innoRoot 'ISCC.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw "Inno Setup compiler not found: $compiler"
}
$translation = $config.build.inno_setup.chinese_translation
$translationDirectory = Join-Path $innoRoot 'Languages'
[System.IO.Directory]::CreateDirectory($translationDirectory) | Out-Null
$translationPath = Join-Path $translationDirectory ([string]$translation.filename)
Get-VerifiedDownload `
    -Uri ([string]$translation.url) `
    -Destination $translationPath `
    -ExpectedSha256 ([string]$translation.sha256)
Write-Output $compiler
