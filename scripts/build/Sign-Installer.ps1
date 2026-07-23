[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [Parameter(Mandatory = $true)][string]$CertificateBase64,
    [Parameter(Mandatory = $true)][string]$CertificatePassword,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw "Installer not found: $InstallerPath"
}
$temporaryRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$certificatePath = Join-Path $temporaryRoot ("python-runtime-signing-{0}.pfx" -f [Guid]::NewGuid().ToString('N'))
try {
    [System.IO.File]::WriteAllBytes($certificatePath, [Convert]::FromBase64String($CertificateBase64))
    $signTool = Get-ChildItem -Path 'C:\Program Files (x86)\Windows Kits\10\bin' -Filter 'signtool.exe' -Recurse -File |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $signTool) {
        throw 'signtool.exe was not found in the Windows SDK.'
    }
    & $signTool.FullName sign /fd SHA256 /td SHA256 /tr $TimestampUrl /f $certificatePath /p $CertificatePassword $InstallerPath
    if ($LASTEXITCODE -ne 0) { throw "signtool sign failed with exit code $LASTEXITCODE" }
    & $signTool.FullName verify /pa /all /v $InstallerPath
    if ($LASTEXITCODE -ne 0) { throw "signtool verify failed with exit code $LASTEXITCODE" }
    $signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
    if ($signature.Status -ne 'Valid') {
        throw "Authenticode status is not valid: $($signature.Status)"
    }
    Write-Output "Signed installer: $InstallerPath"
} finally {
    if (Test-Path -LiteralPath $certificatePath) {
        Remove-Item -LiteralPath $certificatePath -Force
    }
}
