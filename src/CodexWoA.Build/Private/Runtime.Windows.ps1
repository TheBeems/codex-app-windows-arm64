function Read-PngUInt32BigEndian {
    param(
        [byte[]]$Bytes,
        [int]$Offset
    )

    return (($Bytes[$Offset] -shl 24) -bor ($Bytes[$Offset + 1] -shl 16) -bor ($Bytes[$Offset + 2] -shl 8) -bor $Bytes[$Offset + 3])
}

function New-IcoFromPng {
    param(
        [string]$PngPath,
        [string]$IcoPath
    )

    $png = [System.IO.File]::ReadAllBytes($PngPath)
    if ($png.Length -lt 24 -or $png[0] -ne 0x89 -or $png[1] -ne 0x50 -or $png[2] -ne 0x4E -or $png[3] -ne 0x47) {
        throw "Icon source is not a PNG file: $PngPath"
    }

    $width = Read-PngUInt32BigEndian $png 16
    $height = Read-PngUInt32BigEndian $png 20
    $iconWidth = if ($width -ge 256) { 0 } else { [byte]$width }
    $iconHeight = if ($height -ge 256) { 0 } else { [byte]$height }

    New-Item -ItemType Directory -Path (Split-Path -Parent $IcoPath) -Force | Out-Null
    $stream = [System.IO.File]::Create($IcoPath)
    try {
        $writer = New-Object System.IO.BinaryWriter($stream)
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]1)
        $writer.Write([byte]$iconWidth)
        $writer.Write([byte]$iconHeight)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$png.Length)
        $writer.Write([uint32]22)
        $writer.Write($png)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-RceditPath {
    param([string]$CacheDir)

    $rceditVersion = "v2.0.0"
    $rceditName = "rcedit-x64.exe"
    $rceditPath = Join-Path $CacheDir $rceditName
    $expectedHash = "3E7801DB1A5EDBEC91B49A24A094AAD776CB4515488EA5A4CA2289C400EADE2A"
    if (-not (Test-Path -LiteralPath $rceditPath)) {
        Download-File "https://github.com/electron/rcedit/releases/download/$rceditVersion/$rceditName" $rceditPath
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $rceditPath).Hash
    if ($actualHash -ne $expectedHash) {
        throw "rcedit SHA256 mismatch: $actualHash"
    }

    return $rceditPath
}

function Set-CodexExecutableIcon {
    param(
        [string]$PackageRoot,
        [string]$CodexExe,
        [string]$CacheDir
    )

    $iconPng = Join-Path $PackageRoot "assets\icon.png"
    if (-not (Test-Path -LiteralPath $iconPng)) {
        Write-Warn "Could not patch Codex.exe icon because assets\icon.png was not found."
        return
    }

    $iconIco = Join-Path $CacheDir "CodexWoA.ico"
    New-IcoFromPng $iconPng $iconIco
    $rcedit = Get-RceditPath $CacheDir
    Invoke-Checked $rcedit @($CodexExe, "--set-icon", $iconIco)
    Add-Replacement "Codex.exe-icon" "patched" "assets\icon.png"
}

function Install-Arm64ElectronRuntime {
    param(
        [string]$AppDir,
        [string]$ElectronVersion,
        [string]$CacheDir
    )

    Write-Step "Replacing Electron runtime with win32-arm64 v$ElectronVersion"
    $zipName = "electron-v$ElectronVersion-win32-arm64.zip"
    $zipPath = Join-Path $CacheDir $zipName
    $url = "https://github.com/electron/electron/releases/download/v$ElectronVersion/$zipName"
    if (-not (Test-Path -LiteralPath $zipPath)) {
        Download-File $url $zipPath
    }

    $runtimeDir = Join-Path $CacheDir "electron-win32-arm64-$ElectronVersion"
    Expand-ZipClean $zipPath $runtimeDir

    $resourcesDir = Join-Path $AppDir "resources"
    $savedResources = Join-Path (Split-Path -Parent $AppDir) "resources.saved"
    Remove-IfExists $savedResources
    Move-Item -LiteralPath $resourcesDir -Destination $savedResources

    Get-ChildItem -LiteralPath $AppDir -Force | Remove-Item -Recurse -Force
    Copy-DirectoryRobust $runtimeDir $AppDir
    Remove-IfExists (Join-Path $AppDir "resources")
    Move-Item -LiteralPath $savedResources -Destination $resourcesDir

    $electronExe = Join-Path $AppDir "electron.exe"
    $codexExe = Join-Path $AppDir "Codex.exe"
    if (-not (Test-Path -LiteralPath $electronExe)) {
        throw "Electron runtime did not contain electron.exe"
    }
    Move-Item -LiteralPath $electronExe -Destination $codexExe -Force
    Set-CodexExecutableIcon (Split-Path -Parent $AppDir) $codexExe $CacheDir

    Add-Replacement "electron-runtime" "arm64" $zipName
}

function Install-Arm64Node {
    param(
        [string]$ResourcesDir,
        [string]$NodeVersion,
        [string]$CacheDir
    )

    Write-Step "Replacing Node.js with win-arm64 v$NodeVersion"
    $existingCandidates = @(Get-ChildItem -LiteralPath $ResourcesDir -Recurse -File -Filter "node.exe" -Depth 3 -ErrorAction Stop)
    if ($existingCandidates.Count -eq 0) {
        throw "Could not find existing node.exe under $($ResourcesDir) to replace"
    }
    if ($existingCandidates.Count -gt 1) {
        $paths = ($existingCandidates.FullName -join "`n")
        throw "Found multiple node.exe candidates under $($ResourcesDir):`n$paths"
    }

    $zipName = "node-v$NodeVersion-win-arm64.zip"
    $zipPath = Join-Path $CacheDir $zipName
    $url = "https://nodejs.org/dist/v$NodeVersion/$zipName"
    if (-not (Test-Path -LiteralPath $zipPath)) {
        Download-File $url $zipPath
    }

    $nodeDir = Join-Path $CacheDir "node-win-arm64-$NodeVersion"
    Expand-ZipClean $zipPath $nodeDir
    $armNodeExe = Get-ChildItem -LiteralPath $nodeDir -Recurse -File -Filter "node.exe" | Select-Object -First 1
    if ($null -eq $armNodeExe) {
        throw "Node archive did not contain node.exe"
    }

    Copy-Item -LiteralPath $armNodeExe.FullName -Destination $existingCandidates[0].FullName -Force
    Add-Replacement "node.exe" "arm64" $zipName
}

function Get-GitHubRelease {
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$Tag
    )

    $headers = @{ Accept = "application/vnd.github+json" }
    if ($Tag -eq "latest") {
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases/latest" -Headers $headers
    }

    return Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases/tags/$Tag" -Headers $headers
}

function Download-GitHubReleaseAsset {
    param(
        [object]$Release,
        [string]$AssetName,
        [string]$Destination
    )

    $asset = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if ($null -eq $asset) {
        throw "Release asset not found: $AssetName"
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        Download-File $asset.browser_download_url $Destination
    }

    return $Destination
}

function Install-Arm64CodexHelpers {
    param(
        [string]$ResourcesDir,
        [string]$CacheDir,
        [string]$ReleaseTag
    )

    Write-Step "Replacing Codex helper executables from openai/codex"
    $release = Get-GitHubRelease "openai" "codex" $ReleaseTag
    $script:Context.Report.versions.codexRelease = $release.tag_name

    $mapping = @(
        @{ asset = "codex-aarch64-pc-windows-msvc.exe"; target = "codex.exe"; required = $false },
        @{ asset = "codex-command-runner-aarch64-pc-windows-msvc.exe"; target = "codex-command-runner.exe"; required = $false },
        @{ asset = "codex-windows-sandbox-setup-aarch64-pc-windows-msvc.exe"; target = "codex-windows-sandbox-setup.exe"; required = $false },
        @{ asset = "codex-app-server-aarch64-pc-windows-msvc.exe"; target = "codex-app-server.exe"; required = $false },
        @{ asset = "codex-responses-api-proxy-aarch64-pc-windows-msvc.exe"; target = "codex-responses-api-proxy.exe"; required = $false }
    )

    foreach ($item in $mapping) {
        $targetPath = Join-Path $ResourcesDir $item.target
        if (-not (Test-Path -LiteralPath $targetPath) -and -not $item.required) {
            continue
        }

        try {
            $downloadPath = Join-Path $CacheDir $item.asset
            Download-GitHubReleaseAsset $release $item.asset $downloadPath | Out-Null
            Copy-Item -LiteralPath $downloadPath -Destination $targetPath -Force
            Add-Replacement $item.target "arm64" $item.asset
        }
        catch {
            if ($item.required) {
                throw
            }
            Write-Warn "Could not replace $($item.target); keeping original out-of-process fallback. $($_.Exception.Message)"
            Add-Replacement $item.target "fallback" $_.Exception.Message
        }
    }
}

function Install-Arm64Ripgrep {
    param(
        [string]$ResourcesDir,
        [string]$CacheDir
    )

    Write-Step "Replacing rg.exe with ripgrep arm64"
    $release = Get-GitHubRelease "BurntSushi" "ripgrep" "latest"
    $tag = $release.tag_name.TrimStart("v")
    $assetName = "ripgrep-$tag-aarch64-pc-windows-msvc.zip"
    $zipPath = Join-Path $CacheDir $assetName
    Download-GitHubReleaseAsset $release $assetName $zipPath | Out-Null

    $ripgrepDir = Join-Path $CacheDir "ripgrep-arm64-$tag"
    Expand-ZipClean $zipPath $ripgrepDir
    $rgExe = Get-ChildItem -LiteralPath $ripgrepDir -Recurse -File -Filter "rg.exe" | Select-Object -First 1
    if ($null -eq $rgExe) {
        throw "ripgrep archive did not contain rg.exe"
    }

    Copy-Item -LiteralPath $rgExe.FullName -Destination (Join-Path $ResourcesDir "rg.exe") -Force
    Add-Replacement "rg.exe" "arm64" $assetName
}

function Remove-WindowsUpdaterNative {
    param([string]$ResourcesDir)

    $updaterPath = Join-Path $ResourcesDir "native\windows-updater.node"
    if (Test-Path -LiteralPath $updaterPath) {
        Remove-Item -LiteralPath $updaterPath -Force
        Add-Replacement "windows-updater.node" "removed" "self-signed WoA package disables native updater"
    }
}
