#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProductId = "9PLM9XGG6VKS",
    [string]$Repo = $env:GITHUB_REPOSITORY,
    [string]$Ring = "Retail",
    [string]$Lang = "en-US",
    [string]$VersionOverride = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot "src\CodexWoA.Build\CodexWoA.Build.psd1") -Force
$result = Resolve-CodexStorePackage @PSBoundParameters

Write-Host "Store version:  $($result.storeVersion)"
Write-Host "Package version: $($result.packageVersion)"
Write-Host "Release tag:    $($result.releaseTag)"
Write-Host "Latest release: $($result.latestReleaseTag)"
Write-Host "MSIX file:      $($result.msixFile)"
Write-Host "MSIX SHA-1:     $($result.msixSha1)"
Write-Host "MSIX expires:   $($result.msixExpire)"
Write-Host "Should build:   $($result.shouldBuild)"

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    "should_build=$($result.shouldBuild.ToString().ToLowerInvariant())" >> $env:GITHUB_OUTPUT
    "store_version=$($result.packageVersion)" >> $env:GITHUB_OUTPUT
    "release_tag=$($result.releaseTag)" >> $env:GITHUB_OUTPUT
    "msix_url=$($result.msixUrl)" >> $env:GITHUB_OUTPUT
    "msix_file=$($result.msixFile)" >> $env:GITHUB_OUTPUT
    "msix_sha1=$($result.msixSha1)" >> $env:GITHUB_OUTPUT
}

$result | ConvertTo-Json -Depth 4
exit 0
