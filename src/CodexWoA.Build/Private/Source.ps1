function Resolve-PackageVersionOverride {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return ""
    }

    $trimmed = $Version.Trim()
    if ($trimmed -notmatch "^\d+\.\d+\.\d+\.\d+$") {
        throw "-PackageVersionOverride must be a four-part MSIX version, for example 26.527.3686.1."
    }

    $parts = @($trimmed.Split(".") | ForEach-Object { [int]$_ })
    foreach ($part in $parts) {
        if ($part -lt 0 -or $part -gt 65535) {
            throw "-PackageVersionOverride parts must be between 0 and 65535: $trimmed"
        }
    }

    return ([version]$trimmed).ToString()
}

function Get-InstalledCodexPackageOrNull {
    $package = Get-AppxPackage -Name "OpenAI.Codex" |
        Where-Object { $_.Architecture -eq "X64" } |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($null -eq $package) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $package.InstallLocation)) {
        throw "Installed package path does not exist: $($package.InstallLocation)"
    }

    return $package
}

function Get-InstalledCodexPackage {
    $package = Get-InstalledCodexPackageOrNull
    if ($null -eq $package) {
        throw "Installed OpenAI.Codex x64 package was not found. Install Codex from Microsoft Store first or use -SourceMode StoreMsix."
    }

    return $package
}

function ConvertFrom-CodexStoreHtml {
    param([string]$Html)

    $rowPattern = '<tr[^>]*>.*?<a\s+[^>]*href="(?<href>[^"]+)"[^>]*>(?<file>OpenAI\.Codex_(?<version>\d+\.\d+\.\d+\.\d+)_x64__[^<]+\.msix)</a>.*?<td[^>]*>(?<expire>[^<]*)</td>.*?<td[^>]*>(?<sha1>[a-fA-F0-9]{40})</td>.*?<td[^>]*>(?<size>[^<]*)</td>.*?</tr>'
    $storeMatches = [regex]::Matches($Html, $rowPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($storeMatches.Count -eq 0) {
        throw "Could not find OpenAI.Codex x64 MSIX in Microsoft Store response."
    }

    return $storeMatches |
        ForEach-Object {
            $file = [System.Net.WebUtility]::HtmlDecode($_.Groups["file"].Value)
            $url = [System.Net.WebUtility]::HtmlDecode($_.Groups["href"].Value)
            $expire = [System.Net.WebUtility]::HtmlDecode($_.Groups["expire"].Value)
            $size = [System.Net.WebUtility]::HtmlDecode($_.Groups["size"].Value)

            Assert-SafeScalarValue "Store MSIX file" $file
            Assert-SafeScalarValue "Store MSIX URL" $url
            Assert-SafeScalarValue "Store MSIX expiry" $expire
            Assert-SafeScalarValue "Store MSIX size" $size
            Assert-AllowedStoreMsixUrl $url

            [pscustomobject]@{
                Version = [version]$_.Groups["version"].Value
                File = $file
                Url = $url
                Sha1 = $_.Groups["sha1"].Value.ToUpperInvariant()
                Expire = $expire
                Size = $size
            }
        } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Assert-AllowedStoreMsixUrl {
    param([string]$Url)

    $policy = (Get-SupplyChainPolicy).StoreSource
    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        throw "Store MSIX URL is not absolute: $Url"
    }

    if ($uri.Scheme -notin @("http", "https")) {
        throw "Store MSIX URL must use HTTP(S): $Url"
    }

    $host = $uri.Host.ToLowerInvariant()
    $allowed = @($policy.AllowedUrlHosts) | ForEach-Object { $_.ToLowerInvariant() }
    if ($allowed -notcontains $host) {
        throw "Store MSIX URL host is not allowlisted: $host"
    }
}

function Assert-CodexSourceMsixSignature {
    param([string]$MsixPath)

    $policy = (Get-SupplyChainPolicy).StoreSource
    $signature = Get-AuthenticodeSignature -LiteralPath $MsixPath
    if ($null -eq $signature.SignerCertificate) {
        throw "Source MSIX does not contain an Authenticode signer: $MsixPath"
    }

    $subject = $signature.SignerCertificate.Subject
    $issuer = $signature.SignerCertificate.Issuer
    if ($subject -ne $policy.ExpectedPublisher) {
        throw "Source MSIX signer subject '$subject' does not match expected publisher '$($policy.ExpectedPublisher)'."
    }

    if ($issuer -notlike "*$($policy.RequiredSignerIssuerContains)*") {
        throw "Source MSIX signer issuer '$issuer' does not match required issuer policy '$($policy.RequiredSignerIssuerContains)'."
    }
}

function Assert-CodexSourceManifestIdentity {
    param([xml]$Manifest)

    $policy = (Get-SupplyChainPolicy).StoreSource
    $identity = $Manifest.Package.Identity
    if ($identity.Name -ne $policy.ExpectedIdentityName) {
        throw "MSIX identity mismatch: $($identity.Name). Expected $($policy.ExpectedIdentityName)."
    }
    if ($identity.ProcessorArchitecture -ne $policy.ExpectedArchitecture) {
        throw "MSIX architecture mismatch: $($identity.ProcessorArchitecture). Expected $($policy.ExpectedArchitecture)."
    }
    if ($identity.Publisher -ne $policy.ExpectedPublisher) {
        throw "MSIX publisher mismatch: $($identity.Publisher). Expected $($policy.ExpectedPublisher)."
    }
}

function ConvertTo-FourPartVersion {
    param([string]$Value)

    $match = [regex]::Match($Value, "\d+\.\d+\.\d+(?:\.\d+)?")
    if (-not $match.Success) {
        return [version]"0.0.0.0"
    }

    $version = $match.Value
    if (($version.Split(".")).Count -eq 3) {
        $version = "$version.0"
    }
    return [version]$version
}

function Resolve-LatestStoreMsix {
    param(
        [string]$ProductId = "9PLM9XGG6VKS",
        [string]$Ring = "Retail",
        [string]$Lang = "en-US"
    )

    Write-Step "Resolving latest Codex x64 MSIX from Microsoft Store"
    $response = Invoke-WebRequest -UseBasicParsing `
        -Uri "https://store.rg-adguard.net/api/GetFiles" `
        -Method POST `
        -Headers @{
            Accept = "*/*"
            Origin = "https://store.rg-adguard.net"
            Referer = "https://store.rg-adguard.net/"
        } `
        -ContentType "application/x-www-form-urlencoded" `
        -Body "type=ProductId&url=$ProductId&ring=$Ring&lang=$Lang"

    return ConvertFrom-CodexStoreHtml ([string]$response.Content)
}

function Resolve-SourceMode {
    param([string]$RequestedMode)

    if ($RequestedMode -ne "Prompt") {
        return $RequestedMode
    }

    Write-Host ""
    Write-Host "Select Codex x64 source package:"
    Write-Host "  1. Download latest Microsoft Store MSIX"
    Write-Host "  2. Installed Microsoft Store package"
    Write-Host "  3. Open Microsoft Store, then use installed package"
    Write-Host "  4. Local Microsoft Store MSIX file"
    $choice = Read-Host "Choice [1/2/3/4]"
    switch ($choice) {
        "2" { return "Installed" }
        "3" { return "StoreLatest" }
        "4" { return "Msix" }
        default { return "StoreMsix" }
    }
}

function Copy-InstalledSource {
    param(
        [string]$Destination
    )

    $package = Get-InstalledCodexPackage
    Write-Step "Copying installed source package $($package.PackageFullName)"
    New-CleanDirectory $Destination | Out-Null
    Copy-DirectoryRobust $package.InstallLocation $Destination

    $script:Context.Report.source = [ordered]@{
        kind = "Installed"
        packageFullName = $package.PackageFullName
        version = $package.Version.ToString()
        installLocation = $package.InstallLocation
    }

    return $Destination
}

function Open-CodexStorePage {
    param([string]$ProductId = "9PLM9XGG6VKS")

    $storeUri = "ms-windows-store://pdp/?ProductId=$ProductId"
    $webUri = "https://apps.microsoft.com/detail/$ProductId"
    Write-Step "Opening Codex in Microsoft Store"

    try {
        Start-Process $storeUri | Out-Null
    }
    catch {
        Write-Warn "Could not open Microsoft Store URI: $($_.Exception.Message)"
        try {
            Start-Process $webUri | Out-Null
        }
        catch {
            Write-Warn "Could not open Store web page: $($_.Exception.Message)"
        }
    }
}

function Copy-StoreInstalledSource {
    param(
        [string]$Destination
    )

    Open-CodexStorePage

    $installed = Get-InstalledCodexPackageOrNull
    if ($null -ne $installed) {
        Write-Host "Installed x64 Codex was found: $($installed.PackageFullName)"
    }
    else {
        Write-Host "Install Codex from Microsoft Store, then return here."
    }

    Read-Host "Press Enter after Codex x64 is installed or updated from Microsoft Store"
    $copied = Copy-InstalledSource $Destination
    $script:Context.Report.source.kind = "StoreInstalled"
    $script:Context.Report.source.storePageOpened = $true
    return $copied
}

function Copy-StoreMsixSource {
    param(
        [string]$Destination,
        [string]$CacheDir
    )

    $storePackage = Resolve-LatestStoreMsix
    Write-Host "MSIX file:      $($storePackage.File)"
    Write-Host "MSIX version:   $($storePackage.Version)"
    Write-Host "MSIX SHA-1:     $($storePackage.Sha1)"
    Write-Host "MSIX expires:   $($storePackage.Expire)"

    $sourceDir = Join-Path $CacheDir "codex-source"
    New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
    $sourceMsix = Join-Path $sourceDir $storePackage.File

    $needsDownload = $true
    if (Test-Path -LiteralPath $sourceMsix) {
        $cachedSha1 = (Get-FileHash -Algorithm SHA1 -LiteralPath $sourceMsix).Hash.ToUpperInvariant()
        if ($cachedSha1 -eq $storePackage.Sha1) {
            Write-Step "Using cached Store MSIX $sourceMsix"
            $needsDownload = $false
        }
        else {
            Write-Warn "Cached Store MSIX SHA-1 mismatch. Redownloading $($storePackage.File)."
            Remove-IfExists $sourceMsix
        }
    }

    if ($needsDownload) {
        Download-File $storePackage.Url $sourceMsix
    }

    $actualSha1 = (Get-FileHash -Algorithm SHA1 -LiteralPath $sourceMsix).Hash.ToUpperInvariant()
    if ($actualSha1 -ne $storePackage.Sha1) {
        throw "SHA-1 mismatch. Expected $($storePackage.Sha1) but got $actualSha1."
    }

    $copied = Copy-MsixSource $sourceMsix $Destination
    $script:Context.Report.source.kind = "StoreMsix"
    $script:Context.Report.source["url"] = $storePackage.Url
    $script:Context.Report.source["sha1"] = $storePackage.Sha1
    $script:Context.Report.source["expire"] = $storePackage.Expire
    $script:Context.Report.source["size"] = $storePackage.Size
    return $copied
}

function Copy-MsixSource {
    param(
        [string]$MsixPath,
        [string]$Destination
    )

    if ([string]::IsNullOrWhiteSpace($MsixPath)) {
        $MsixPath = Read-Host "Path to OpenAI.Codex x64 MSIX"
    }

    if ([string]::IsNullOrWhiteSpace($MsixPath)) {
        throw "-SourceMsixPath is required when -SourceMode Msix is used."
    }

    $resolvedMsixPath = (Resolve-Path -LiteralPath $MsixPath).Path
    Assert-CodexSourceMsixSignature $resolvedMsixPath
    Write-Step "Extracting source MSIX $resolvedMsixPath"
    Expand-MsixClean $resolvedMsixPath $Destination

    $manifestPath = Join-Path $Destination "AppxManifest.xml"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "MSIX did not contain AppxManifest.xml: $resolvedMsixPath"
    }

    [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
    Assert-CodexSourceManifestIdentity $manifest
    $identity = $manifest.Package.Identity

    $script:Context.Report.source = [ordered]@{
        kind = "Msix"
        path = $resolvedMsixPath
        packageFullName = "OpenAI.Codex_$($identity.Version)_x64__2p2nqsd0c76g0"
        version = [string]$identity.Version
    }

    return $Destination
}

function Assert-SourceShape {
    param([string]$PackageRoot)

    $required = @(
        "AppxManifest.xml",
        "app\Codex.exe",
        "app\resources\app.asar",
        "app\resources\app.asar.unpacked"
    )

    foreach ($relative in $required) {
        $path = Join-Path $PackageRoot $relative
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Source package is missing required file: $relative"
        }
    }
}
