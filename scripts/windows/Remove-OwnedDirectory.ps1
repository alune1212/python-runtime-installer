[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AppRoot,
    [Parameter(Mandatory = $true)][string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RuntimeInstaller.psm1') -Force

Remove-OwnedDirectory -AppRoot $AppRoot -Path $Path
