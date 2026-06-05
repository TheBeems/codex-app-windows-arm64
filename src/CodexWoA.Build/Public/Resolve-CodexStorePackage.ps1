function Resolve-CodexStorePackage {
    [CmdletBinding()]
    param(
        [string]$ProductId = "9PLM9XGG6VKS",
        [string]$Repo = "",
        [string]$Ring = "Retail",
        [string]$Lang = "en-US",
        [string]$VersionOverride = "",
        [string]$Html = ""
    )

    $storePackage = if ([string]::IsNullOrWhiteSpace($Html)) {
        Resolve-LatestStoreMsix -ProductId $ProductId -Ring $Ring -Lang $Lang
    }
    else {
        ConvertFrom-CodexStoreHtml $Html
    }

    $latestTag = "0.0.0"
    if (-not [string]::IsNullOrWhiteSpace($Repo)) {
        try {
            $resolvedLatestTag = gh release view --repo $Repo --json tagName --jq ".tagName" 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolvedLatestTag)) {
                $latestTag = $resolvedLatestTag
            }
        }
        catch {
            $latestTag = "0.0.0"
        }
    }

    $latestReleaseVersion = ConvertTo-FourPartVersion $latestTag
    $resolvedOverride = Resolve-PackageVersionOverride $VersionOverride
    $effectivePackageVersion = $storePackage.Version
    $releaseTag = $storePackage.Version.ToString(3)
    $shouldBuild = $storePackage.Version -gt $latestReleaseVersion
    if (-not [string]::IsNullOrWhiteSpace($resolvedOverride)) {
        $effectivePackageVersion = [version]$resolvedOverride
        $releaseTag = $resolvedOverride
        $shouldBuild = $true
    }

    return [pscustomobject][ordered]@{
        shouldBuild = $shouldBuild
        storeVersion = $storePackage.Version.ToString()
        packageVersion = $effectivePackageVersion.ToString()
        releaseTag = $releaseTag
        msixUrl = $storePackage.Url
        msixFile = $storePackage.File
        msixSha1 = $storePackage.Sha1
        msixExpire = $storePackage.Expire
        latestReleaseTag = $latestTag
    }
}
