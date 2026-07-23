[CmdletBinding()]
param([string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\product.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$toolRoot = Join-Path $RepositoryRoot 'build\tools'
$innoRoot = Join-Path $toolRoot 'inno'
$installer = Join-Path $toolRoot ([string]$config.build.inno_setup.filename)
[System.IO.Directory]::CreateDirectory($toolRoot) | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri ([string]$config.build.inno_setup.url) -OutFile $installer -UseBasicParsing
$actual = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne [string]$config.build.inno_setup.sha256) {
    throw "Inno Setup hash mismatch: expected=$($config.build.inno_setup.sha256) actual=$actual"
}
$signature = Get-AuthenticodeSignature -LiteralPath $installer
$subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
if ($signature.Status -ne 'Valid' -or -not $subject.Contains([string]$config.build.inno_setup.expected_publisher)) {
    throw "Inno Setup signature verification failed: status=$($signature.Status) subject=$subject"
}
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
Invoke-WebRequest -Uri ([string]$translation.url) -OutFile $translationPath -UseBasicParsing
$translationHash = (Get-FileHash -LiteralPath $translationPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($translationHash -ne [string]$translation.sha256) {
    throw "Inno Setup translation hash mismatch: expected=$($translation.sha256) actual=$translationHash"
}
Write-Output $compiler
