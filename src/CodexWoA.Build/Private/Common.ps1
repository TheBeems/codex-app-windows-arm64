function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    $script:Context.Report.warnings.Add($Message)
    Write-Warning $Message
}

function Add-Replacement {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = ""
    )

    $script:Context.Report.replacements.Add([ordered]@{
        name = $Name
        status = $Status
        detail = $Detail
    })
}

function Remove-IfExists {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function New-CleanDirectory {
    param([string]$Path)
    Remove-IfExists $Path
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return (Resolve-Path -LiteralPath $Path).Path
}

function Set-TextUtf8NoBom {
    param(
        [string]$Path,
        [string]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Require-CommandPath {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required command not found: $Name"
    }
    return $command.Source
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int[]]$SuccessExitCodes = @(0)
    )

    Write-Verbose ("Running: {0} {1}" -f $FilePath, ($Arguments -join " "))
    & $FilePath @Arguments | Out-Host
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($SuccessExitCodes -notcontains $exitCode) {
        throw "Command failed with exit code $exitCode`: $FilePath $($Arguments -join ' ')"
    }
    return $exitCode
}

function Copy-DirectoryRobust {
    param(
        [string]$Source,
        [string]$Destination,
        [ValidateSet("Mirror", "Merge")]
        [string]$Mode = "Mirror"
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $copyMode = if ($Mode -eq "Mirror") { "/MIR" } else { "/E" }
    & robocopy $Source $Destination $copyMode /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Host
    $exitCode = $LASTEXITCODE
    if ($exitCode -gt 7) {
        throw "robocopy failed with exit code $exitCode"
    }
}

function Normalize-PercentEncodedScopedPackageDirs {
    param(
        [string]$Root,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }

    $normalized = New-Object "System.Collections.Generic.List[string]"
    $encodedDirs = @(Get-ChildItem -LiteralPath $Root -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "(?i)%40" } |
        Sort-Object { $_.FullName.Length } -Descending)

    foreach ($dir in $encodedDirs) {
        if (-not (Test-Path -LiteralPath $dir.FullName)) {
            continue
        }

        $decodedName = $dir.Name -replace "(?i)%40", "@"
        if ($decodedName -eq $dir.Name) {
            continue
        }

        $target = Join-Path $dir.Parent.FullName $decodedName
        if (Test-Path -LiteralPath $target) {
            Copy-DirectoryRobust $dir.FullName $target -Mode Merge
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force
        }
        else {
            Rename-Item -LiteralPath $dir.FullName -NewName $decodedName
        }

        $normalized.Add((Get-RelativePath $Root $target)) | Out-Null
    }

    if ($normalized.Count -gt 0) {
        Add-Replacement $Label "normalized" ($normalized -join ", ")
    }
}



function Find-WindowsKitTool {
    param([string]$ToolName)

    $preferredArches = @("arm64", "x64", "x86")
    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne "Arm64") {
        $preferredArches = @("x64", "arm64", "x86")
    }

    $kitRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (Test-Path -LiteralPath $kitRoot) {
        $versions = Get-ChildItem -LiteralPath $kitRoot -Directory |
            Where-Object { $_.Name -match "^\d+\.\d+\.\d+\.\d+$" } |
            Sort-Object { [version]$_.Name } -Descending

        foreach ($version in $versions) {
            foreach ($arch in $preferredArches) {
                $candidate = Join-Path $version.FullName (Join-Path $arch $ToolName)
                if (Test-Path -LiteralPath $candidate) {
                    return $candidate
                }
            }
        }
    }

    $command = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    throw "Could not find Windows SDK tool: $ToolName"
}

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Write-Host "Downloading $Url"
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination
    if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -eq 0) {
        throw "Downloaded file is empty: $Destination"
    }
}

function Get-SupplyChainPolicy {
    $contextVariable = Get-Variable -Name Context -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $contextVariable -and
        $null -ne $contextVariable.Value -and
        $null -ne $contextVariable.Value.SupplyChainPolicy) {
        return $contextVariable.Value.SupplyChainPolicy
    }

    return Import-PowerShellDataFile -LiteralPath (Join-Path $script:ModuleRoot "Data\SupplyChainPolicy.psd1")
}

function Assert-SafeScalarValue {
    param(
        [string]$Name,
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return
    }

    if ($Value -match "[\x00-\x1F\x7F]") {
        throw "$Name contains a control character and cannot cross a trust boundary."
    }
}

function Assert-FileSha256 {
    param(
        [string]$Path,
        [string]$ExpectedHash,
        [string]$Label = $Path
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedHash) -or $ExpectedHash -notmatch "^[a-fA-F0-9]{64}$") {
        throw "Missing SHA-256 policy for $Label."
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
    if ($actualHash -ne $ExpectedHash.ToUpperInvariant()) {
        throw "$Label SHA-256 mismatch. Expected $($ExpectedHash.ToUpperInvariant()) but got $actualHash."
    }
}

function Get-SupplyChainAssetHash {
    param([string]$AssetName)

    $hash = (Get-SupplyChainPolicy).AssetHashes[$AssetName]
    if ([string]::IsNullOrWhiteSpace($hash)) {
        throw "No supply-chain hash is pinned for asset: $AssetName"
    }

    return $hash
}

function Download-VerifiedFile {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$AssetName = (Split-Path -Leaf $Destination)
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        Download-File $Url $Destination
    }

    Assert-FileSha256 $Destination (Get-SupplyChainAssetHash $AssetName) $AssetName
    return $Destination
}

function Resolve-PinnedReleaseTag {
    param(
        [string]$RequestedTag,
        [string]$PinnedTag,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($RequestedTag) -or $RequestedTag -eq "latest") {
        return $PinnedTag
    }

    if ($RequestedTag -ne $PinnedTag) {
        throw "$Label release tag '$RequestedTag' is not pinned in SupplyChainPolicy.psd1. Expected '$PinnedTag'."
    }

    return $RequestedTag
}

function Expand-ZipClean {
    param(
        [string]$ZipPath,
        [string]$Destination
    )

    New-CleanDirectory $Destination | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
}

function Expand-MsixClean {
    param(
        [string]$MsixPath,
        [string]$Destination
    )

    New-CleanDirectory $Destination | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($MsixPath, $Destination)
}

function Get-TarCommandPath {
    $command = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if ($null -ne $command -and $command.CommandType -eq "Application") {
        return $command.Source
    }

    $command = Get-Command "tar" -ErrorAction SilentlyContinue
    if ($null -ne $command -and $command.CommandType -eq "Application") {
        return $command.Source
    }

    throw "Required command not found: tar.exe"
}

function Expand-TarGzClean {
    param(
        [string]$TarGzPath,
        [string]$Destination
    )

    New-CleanDirectory $Destination | Out-Null
    $tar = Get-TarCommandPath
    Invoke-Checked $tar @("-xzf", $TarGzPath, "-C", $Destination)
}





function Get-RelativePath {
    param(
        [string]$Root,
        [string]$Path
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    return $pathFull.Substring($rootFull.Length + 1).Replace("/", "\")
}















































































































































