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
$result = Resolve-CodexStorePackage `
    -ProductId $ProductId `
    -Repo $Repo `
    -Ring $Ring `
    -Lang $Lang `
    -VersionOverride $VersionOverride

Write-Host "Store version:  $($result.storeVersion)"
Write-Host "Package version: $($result.packageVersion)"
Write-Host "Release tag:    $($result.releaseTag)"
Write-Host "Latest release: $($result.latestReleaseTag)"
Write-Host "MSIX file:      $($result.msixFile)"
Write-Host "MSIX SHA-1:     $($result.msixSha1)"
Write-Host "MSIX expires:   $($result.msixExpire)"
Write-Host "Should build:   $($result.shouldBuild)"

function Write-GitHubScalarOutput {
    param(
        [string]$Name,
        [string]$Value
    )

    if ($Name -notmatch "^[A-Za-z_][A-Za-z0-9_]*$") {
        throw "Invalid GitHub output name: $Name"
    }
    if ($null -ne $Value -and $Value -match "[\x00-\x1F\x7F]") {
        throw "GitHub output '$Name' contains a control character."
    }

    "$Name=$Value" >> $env:GITHUB_OUTPUT
}

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    Write-GitHubScalarOutput "should_build" $result.shouldBuild.ToString().ToLowerInvariant()
    Write-GitHubScalarOutput "store_version" $result.packageVersion
    Write-GitHubScalarOutput "release_tag" $result.releaseTag
    Write-GitHubScalarOutput "msix_url" $result.msixUrl
    Write-GitHubScalarOutput "msix_file" $result.msixFile
    Write-GitHubScalarOutput "msix_sha1" $result.msixSha1
}

$result | ConvertTo-Json -Depth 4
exit 0
