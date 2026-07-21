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
$process = Start-Process -FilePath $installer -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ("/DIR={0}" -f $innoRoot)) -Wait -PassThru
if ($process.ExitCode -ne 0) {
    throw "Inno Setup tool installation failed with exit code $($process.ExitCode)"
}
$compiler = Join-Path $innoRoot 'ISCC.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw "Inno Setup compiler not found: $compiler"
}
Write-Output $compiler
