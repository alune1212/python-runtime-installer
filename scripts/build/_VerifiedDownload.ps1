# Shared helpers for verified downloads and SHA-256 hashing across the build pipeline.
# Dot-source this file from any script that needs to fetch a binary artifact with
# a pinned hash and (optionally) Authenticode publisher verification.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
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
