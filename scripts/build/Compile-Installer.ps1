[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$InnoCompiler = '',
    [string]$BuildCommit = 'local',
    [switch]$SignedName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Push-Location $RepositoryRoot
try {
    & uv run python -m scripts.build.generate_inno_config
    if ($LASTEXITCODE -ne 0) { throw 'Inno configuration generation failed.' }
    if (-not $InnoCompiler) {
        $InnoCompiler = Join-Path $RepositoryRoot 'build\tools\inno\ISCC.exe'
    }
    if (-not (Test-Path -LiteralPath $InnoCompiler -PathType Leaf)) {
        throw "Inno Setup compiler not found: $InnoCompiler"
    }
    $definitionCommit = "/DBuildCommit=$BuildCommit"
    $definitions = @($definitionCommit)
    if ($SignedName) { $definitions += '/DSignedName=1' }
    & $InnoCompiler @definitions (Join-Path $RepositoryRoot 'installer\python-runtime-installer.iss')
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed with exit code $LASTEXITCODE" }
    Write-Output 'Installer compilation completed.'
} finally {
    Pop-Location
}
