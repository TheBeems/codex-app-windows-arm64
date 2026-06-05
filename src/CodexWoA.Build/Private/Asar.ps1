function Read-ElectronVersion {
    param(
        [string]$AppDir,
        [string]$AsarExtractDir
    )

    $versionFile = Join-Path $AppDir "version"
    if (Test-Path -LiteralPath $versionFile) {
        $version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
        if ($version -match "^\d+\.\d+\.\d+") {
            return $version
        }
    }

    $packageJson = Join-Path $AsarExtractDir "package.json"
    if (Test-Path -LiteralPath $packageJson) {
        $package = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
        if ($package.devDependencies.electron) {
            return [string]$package.devDependencies.electron
        }
        if ($package.dependencies.electron) {
            return [string]$package.dependencies.electron
        }
    }

    throw "Could not determine Electron version"
}

function Read-NodeVersion {
    param([string]$NodeExe)

    if (Test-Path -LiteralPath $NodeExe) {
        $version = (Get-Item -LiteralPath $NodeExe).VersionInfo.ProductVersion
        if ($version -match "^\d+\.\d+\.\d+") {
            return $Matches[0]
        }
    }

    throw "Could not determine bundled Node.js version from $NodeExe"
}

function Use-Asar {
    param(
        [string[]]$Arguments
    )

    Require-CommandPath "pnpm" | Out-Null
    Invoke-Checked "pnpm" (@("dlx", "@electron/asar") + $Arguments)
}

function Extract-AsarTolerant {
    param(
        [string]$AsarPath,
        [string]$Destination
    )

    $node = Require-CommandPath "node"
    $extractScript = Get-Content -LiteralPath (Join-Path $script:ScriptRoot "src\CodexWoA.Build\Tools\extract-asar-tolerant.js") -Raw

    Invoke-Checked $node @("-e", $extractScript, $AsarPath, $Destination)
}

function Extract-AppAsar {
    param(
        [string]$ResourcesDir,
        [string]$Destination
    )

    $asarPath = Join-Path $ResourcesDir "app.asar"
    New-CleanDirectory $Destination | Out-Null
    Extract-AsarTolerant $asarPath $Destination

    $unpacked = Join-Path $ResourcesDir "app.asar.unpacked"
    if (Test-Path -LiteralPath $unpacked) {
        Copy-DirectoryRobust $unpacked $Destination -Mode Merge
    }
}

function Repack-AppAsar {
    param(
        [string]$ExtractedDir,
        [string]$ResourcesDir
    )

    $asarPath = Join-Path $ResourcesDir "app.asar"
    $unpackedPath = Join-Path $ResourcesDir "app.asar.unpacked"
    Remove-IfExists $asarPath
    Remove-IfExists $unpackedPath
    Use-Asar @("pack", $ExtractedDir, $asarPath, "--unpack", "{*.node,*.dll,*.exe,codex,bwrap}")
}
