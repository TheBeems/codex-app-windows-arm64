function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    $script:Report.warnings.Add($Message)
    Write-Warning $Message
}

function Add-Replacement {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = ""
    )

    $script:Report.replacements.Add([ordered]@{
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

function Get-PeMachine {
    param([string]$Path)

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) {
            return "NotPE"
        }

        $stream.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
        $peOffset = $reader.ReadUInt32()
        $stream.Seek($peOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        if ($reader.ReadUInt32() -ne 0x00004550) {
            return "NotPE"
        }

        $machine = $reader.ReadUInt16()
        switch ($machine) {
            0x014c { return "x86" }
            0x8664 { return "x64" }
            0xaa64 { return "arm64" }
            0x01c4 { return "arm" }
            default { return ("0x{0:X4}" -f $machine) }
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-ElfMachine {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.Length -lt 20) {
        return "NotELF"
    }

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        $magic = $reader.ReadBytes(4)
        if ($magic.Length -ne 4 -or $magic[0] -ne 0x7F -or $magic[1] -ne 0x45 -or $magic[2] -ne 0x4C -or $magic[3] -ne 0x46) {
            return "NotELF"
        }

        $class = $reader.ReadByte()
        if ($class -ne 2) {
            return "ELF32"
        }

        $data = $reader.ReadByte()
        $stream.Seek(18, [System.IO.SeekOrigin]::Begin) | Out-Null
        $machineBytes = $reader.ReadBytes(2)
        if ($machineBytes.Length -ne 2) {
            return "NotELF"
        }

        if ($data -eq 2) {
            $machine = ($machineBytes[0] -shl 8) -bor $machineBytes[1]
        }
        else {
            $machine = $machineBytes[0] -bor ($machineBytes[1] -shl 8)
        }

        switch ($machine) {
            0x003E { return "x64" }
            0x00B7 { return "arm64" }
            0x0028 { return "arm" }
            default { return ("0x{0:X4}" -f $machine) }
        }
    }
    finally {
        $stream.Dispose()
    }
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







































































function Get-NpmPackageVersion {
    param(
        [string]$AsarDir,
        [string]$PackageName
    )

    $packageJson = Join-Path $AsarDir (Join-Path "node_modules\$PackageName" "package.json")
    if (-not (Test-Path -LiteralPath $packageJson)) {
        $rootPackageJson = Join-Path $AsarDir "package.json"
        $rootPackage = Get-Content -LiteralPath $rootPackageJson -Raw | ConvertFrom-Json
        $property = $rootPackage.dependencies.PSObject.Properties[$PackageName]
        $range = if ($null -ne $property) { [string]$property.Value } else { "" }
        if ([string]::IsNullOrWhiteSpace($range)) {
            throw "Could not find dependency version for $PackageName"
        }
        return $range
    }

    $package = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
    return [string]$package.version
}

function Patch-BetterSqlite3ForElectron42 {
    param(
        [string]$PackageDir,
        [string]$ElectronVersion
    )

    $electronMajor = [int]($ElectronVersion.Split(".")[0])
    if ($electronMajor -lt 42) {
        return
    }

    $sourceDir = Join-Path $PackageDir "src"
    if (-not (Test-Path -LiteralPath $sourceDir)) {
        throw "better-sqlite3 source directory was not found: $sourceDir"
    }

    $mainSource = Join-Path $sourceDir "better_sqlite3.cpp"
    $macrosSource = Join-Path $sourceDir "util\macros.cpp"
    $helpersSource = Join-Path $sourceDir "util\helpers.cpp"

    $main = Get-Content -LiteralPath $mainSource -Raw
    $macros = Get-Content -LiteralPath $macrosSource -Raw
    $helpers = Get-Content -LiteralPath $helpersSource -Raw

    $needsFrameAddressShim = $main -notmatch "__builtin_frame_address"
    $needsExternalNewPatch = $main.Contains("v8::Local<v8::External> data = v8::External::New(isolate, addon);")
    $needsExternalValuePatch = $macros.Contains("static_cast<Addon*>(info.Data().As<v8::External>()->Value())")
    $needsNativeDataPropertyPatch = $helpers -match "func,\r?\n\s*0,\r?\n\s*data"

    if (-not ($needsFrameAddressShim -or $needsExternalNewPatch -or $needsExternalValuePatch -or $needsNativeDataPropertyPatch)) {
        return
    }

    if ($needsFrameAddressShim) {
        $main = $main -replace "#include <climits>", @"
#if defined(_MSC_VER) && !defined(__clang__) && !defined(__builtin_frame_address)
#include <intrin.h>
#define __builtin_frame_address(level) _AddressOfReturnAddress()
#endif

#include <climits>
"@
    }
    if ($needsExternalNewPatch) {
        $main = $main.Replace(
            "v8::Local<v8::External> data = v8::External::New(isolate, addon);",
            "v8::Local<v8::External> data = V8_EXTERNAL_NEW(isolate, addon);")
    }
    Set-TextUtf8NoBom $mainSource $main

    if (($needsExternalNewPatch -or $needsExternalValuePatch) -and $macros -notmatch "V8_EXTERNAL_POINTER_TAG") {
        $macros = $macros.Replace(
            "#define EasyIsolate v8::Isolate* isolate = v8::Isolate::GetCurrent()",
            @"
#if defined(V8_MAJOR_VERSION) && V8_MAJOR_VERSION >= 14
#define V8_EXTERNAL_POINTER_TAG v8::kExternalPointerTypeTagDefault
#define V8_EXTERNAL_NEW(isolate, value) v8::External::New((isolate), (value), V8_EXTERNAL_POINTER_TAG)
#define V8_EXTERNAL_VALUE(external) (external)->Value(V8_EXTERNAL_POINTER_TAG)
#else
#define V8_EXTERNAL_NEW(isolate, value) v8::External::New((isolate), (value))
#define V8_EXTERNAL_VALUE(external) (external)->Value()
#endif

#define EasyIsolate v8::Isolate* isolate = v8::Isolate::GetCurrent()
"@)
    }
    if ($needsExternalValuePatch) {
        $macros = $macros.Replace(
            "static_cast<Addon*>(info.Data().As<v8::External>()->Value())",
            "static_cast<Addon*>(V8_EXTERNAL_VALUE(info.Data().As<v8::External>()))")
    }
    Set-TextUtf8NoBom $macrosSource $macros

    if ($needsNativeDataPropertyPatch) {
        $helpers = $helpers -replace "(func,\r?\n\s*)0(,\r?\n\s*data)", '${1}nullptr${2}'
        Set-TextUtf8NoBom $helpersSource $helpers
    }

    Add-Replacement "better-sqlite3-source" "patched" "Electron 42 V8 API compatibility"
}

function Get-VsWherePath {
    $candidate = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    $command = Get-Command "vswhere.exe" -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    return $null
}

function Get-VisualStudioInstances {
    $vswhere = Get-VsWherePath
    if ($null -eq $vswhere) {
        return @()
    }

    $json = & $vswhere -all -products * -format json
    if ([string]::IsNullOrWhiteSpace(($json -join ""))) {
        return @()
    }

    $instances = $json | ConvertFrom-Json
    if ($null -eq $instances) {
        return @()
    }

    return @($instances | Where-Object { $_.isComplete -eq $true -and $_.installationPath })
}

function Get-InstalledVsComponentIds {
    param([string]$InstallationPath)

    $instanceId = Split-Path -Leaf $InstallationPath
    $instanceDir = Join-Path "C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances" $instanceId
    $stateJson = Join-Path $instanceDir "state.json"
    if (Test-Path -LiteralPath $stateJson) {
        try {
            $state = Get-Content -LiteralPath $stateJson -Raw | ConvertFrom-Json
            if ($state.selectedPackages) {
                return @($state.selectedPackages.PSObject.Properties.Name)
            }
        }
        catch {
            Write-Verbose "Could not read Visual Studio state.json: $($_.Exception.Message)"
        }
    }

    return @()
}

function Test-VsComponentInstalled {
    param(
        [string]$ComponentId,
        [string]$InstallationPath
    )

    $vswhere = Get-VsWherePath
    if ($null -eq $vswhere) {
        return $false
    }

    $output = & $vswhere -all -products * -requires $ComponentId -property installationPath
    return @($output) -contains $InstallationPath
}

function Get-VsPlanComponentIds {
    param(
        [string]$InstallationPath,
        [string]$Pattern
    )

    $instancesRoot = "C:\ProgramData\Microsoft\VisualStudio\Packages\_Instances"
    if (-not (Test-Path -LiteralPath $instancesRoot)) {
        return @()
    }

    $plans = Get-ChildItem -LiteralPath $instancesRoot -Recurse -File -Filter "plan.xml" -ErrorAction SilentlyContinue
    foreach ($plan in $plans) {
        try {
            [xml]$xml = Get-Content -LiteralPath $plan.FullName -Raw
            $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
            $ns.AddNamespace("s", "http://schemas.datacontract.org/2004/07/Microsoft.VisualStudio.Setup")
            $ids = $xml.SelectNodes("//s:PackagePlan/s:Id", $ns) | ForEach-Object { $_.InnerText }
            $matchedIds = @($ids |
                ForEach-Object { ($_ -split ",")[0] } |
                Where-Object { $_ -match $Pattern } |
                Sort-Object -Unique)
            if ($matchedIds.Count -gt 0) {
                return @($matchedIds)
            }
        }
        catch {
            Write-Verbose "Could not inspect Visual Studio plan $($plan.FullName): $($_.Exception.Message)"
        }
    }

    return @()
}

function Get-Arm64CppComponentIds {
    param(
        [string]$InstallationPath,
        [string]$ToolsetVersion
    )

    $toolsetPrefix = ($ToolsetVersion -split "\.")[0..1] -join "."
    $escapedPrefix = [regex]::Escape($toolsetPrefix)
    $arm64ToolComponents = @(Get-VsPlanComponentIds $InstallationPath "^Microsoft\.VisualStudio\.Component\.VC\.$escapedPrefix\.\d+\.\d+\.ARM64$")
    if ($arm64ToolComponents.Count -gt 0) {
        return @(($arm64ToolComponents | Sort-Object -Descending | Select-Object -First 1))
    }

    return @("Microsoft.VisualStudio.Component.VC.Tools.ARM64")
}

function Find-VisualStudioCppInstance {
    $instances = Get-VisualStudioInstances
    foreach ($instance in ($instances | Sort-Object installationVersion -Descending)) {
        $toolsRoot = Join-Path $instance.installationPath "VC\Tools\MSVC"
        if (-not (Test-Path -LiteralPath $toolsRoot)) {
            continue
        }

        $toolset = Get-ChildItem -LiteralPath $toolsRoot -Directory |
            Sort-Object { [version]$_.Name } -Descending |
            Select-Object -First 1
        if ($null -eq $toolset) {
            continue
        }

        return [pscustomobject][ordered]@{
            installationPath = [string]$instance.installationPath
            displayName = [string]$instance.displayName
            installationVersion = [string]$instance.installationVersion
            toolsetVersion = [string]$toolset.Name
            toolsetPath = [string]$toolset.FullName
        }
    }

    return $null
}

function Test-Arm64CppToolchainFiles {
    param([string]$ToolsetPath)

    $compilerCandidates = @(
        (Join-Path $ToolsetPath "bin\Hostarm64\arm64\cl.exe"),
        (Join-Path $ToolsetPath "bin\Hostx64\arm64\cl.exe"),
        (Join-Path $ToolsetPath "bin\Hostx86\arm64\cl.exe")
    )
    $hasCompiler = $false
    foreach ($candidate in $compilerCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            $hasCompiler = $true
            break
        }
    }

    $arm64LibDir = Join-Path $ToolsetPath "lib\arm64"
    $hasArm64Libs = $false
    if (Test-Path -LiteralPath $arm64LibDir) {
        $hasArm64Libs = $null -ne (Get-ChildItem -LiteralPath $arm64LibDir -File -Filter "*.lib" -ErrorAction SilentlyContinue | Select-Object -First 1)
    }

    return ($hasCompiler -and $hasArm64Libs)
}

function Get-VisualStudioDependencyGuidance {
    param(
        [object]$VsInfo,
        [string[]]$ComponentIds
    )

    $componentList = ($ComponentIds | ForEach-Object { "  - $_" }) -join "`n"
    $installCommand = if ($null -ne $VsInfo) {
        $setup = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\setup.exe"
        $addArgs = ($ComponentIds | ForEach-Object { "--add `"$($_)`"" }) -join " "
        "`"$setup`" modify --installPath `"$($VsInfo.installationPath)`" $addArgs --quiet --norestart --wait"
    }
    else {
        "Install Visual Studio 2026/2022 C++ desktop build tools, then add ARM64 C++ tools."
    }

    return @"
Visual Studio ARM64 C++ tools are required before rebuilding native modules.

Install these Visual Studio components:
$componentList

You can either:
  1. Re-run this script with -InstallVsDependencies, or
  2. Open Visual Studio Installer > Modify > Individual components and install ARM64 C++ tools, or
  3. Run this command:
     $installCommand
"@
}

function Install-VisualStudioComponents {
    param(
        [object]$VsInfo,
        [string[]]$ComponentIds
    )

    $setup = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\setup.exe"
    if (-not (Test-Path -LiteralPath $setup)) {
        throw "Visual Studio setup.exe was not found. $([Environment]::NewLine)$(Get-VisualStudioDependencyGuidance $VsInfo $ComponentIds)"
    }

    Write-Step "Installing Visual Studio ARM64 C++ dependencies"
    $arguments = New-Object "System.Collections.Generic.List[string]"
    $arguments.Add("modify") | Out-Null
    $arguments.Add("--installPath") | Out-Null
    $arguments.Add($VsInfo.installationPath) | Out-Null
    foreach ($componentId in $ComponentIds) {
        $arguments.Add("--add") | Out-Null
        $arguments.Add($componentId) | Out-Null
    }
    $arguments.Add("--quiet") | Out-Null
    $arguments.Add("--norestart") | Out-Null
    $arguments.Add("--wait") | Out-Null

    $exitCode = Invoke-Checked $setup ([string[]]$arguments) @(0, 3010)
    if ($exitCode -eq 3010) {
        Write-Warn "Visual Studio Installer requested a restart. If native module rebuild still fails, reboot Windows and rerun this script."
    }
}

function Ensure-VisualStudioArm64Tools {
    if ($SkipVsDependencyCheck) {
        Write-Warn "Skipping Visual Studio dependency preflight because -SkipVsDependencyCheck was provided."
        return
    }

    Write-Step "Checking Visual Studio ARM64 C++ toolchain"
    $vsInfo = Find-VisualStudioCppInstance
    if ($null -eq $vsInfo) {
        throw "Visual Studio C++ toolchain was not found. Install Visual Studio C++ desktop build tools with ARM64 support."
    }

    $arm64ToolComponents = @(Get-Arm64CppComponentIds $vsInfo.installationPath $vsInfo.toolsetVersion)
    $toolchainFilesPresent = Test-Arm64CppToolchainFiles $vsInfo.toolsetPath
    $detectedMissingComponents = @($arm64ToolComponents | Where-Object { -not (Test-VsComponentInstalled $_ $vsInfo.installationPath) })
    $missingComponents = if ($toolchainFilesPresent) { @() } else { @($detectedMissingComponents) }

    $script:Report.visualStudio = [ordered]@{
        displayName = $vsInfo.displayName
        installationPath = $vsInfo.installationPath
        installationVersion = $vsInfo.installationVersion
        toolsetVersion = $vsInfo.toolsetVersion
        requiredComponents = @($arm64ToolComponents)
        missingComponents = @($missingComponents)
        arm64ToolchainFilesPresent = $toolchainFilesPresent
        nodePtySpectreMitigation = "disabled in node-pty gyp before ARM64 rebuild"
    }

    if ($toolchainFilesPresent) {
        return
    }

    if ($InstallVsDependencies) {
        Install-VisualStudioComponents $vsInfo $arm64ToolComponents
        $toolchainFilesPresent = Test-Arm64CppToolchainFiles $vsInfo.toolsetPath
        $detectedMissingComponents = @($arm64ToolComponents | Where-Object { -not (Test-VsComponentInstalled $_ $vsInfo.installationPath) })
        $missingComponents = if ($toolchainFilesPresent) { @() } else { @($detectedMissingComponents) }
        $script:Report.visualStudio.missingComponents = @($missingComponents)
        $script:Report.visualStudio.arm64ToolchainFilesPresent = $toolchainFilesPresent
        if ($toolchainFilesPresent) {
            return
        }
    }

    throw @"
Visual Studio ARM64 C++ tools are required before rebuilding native modules.

Install this Visual Studio component:
  - $($arm64ToolComponents -join "`n  - ")

You can re-run this script with -InstallVsDependencies, or install ARM64 C++ tools from Visual Studio Installer > Modify > Individual components.
"@
}

function Disable-NodePtySpectreMitigation {
    param([string]$NodePtyDir)

    if (-not (Test-Path -LiteralPath $NodePtyDir)) {
        throw "node-pty directory was not found: $NodePtyDir"
    }

    $patchedFiles = New-Object "System.Collections.Generic.List[string]"
    $targets = @(
        (Join-Path $NodePtyDir "binding.gyp"),
        (Join-Path $NodePtyDir "deps\winpty\src\winpty.gyp")
    )

    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) {
            continue
        }

        $before = Get-Content -LiteralPath $target -Raw
        $after = $before -replace "(?m)^\s*'SpectreMitigation'\s*:\s*'Spectre'\s*,?\r?\n", ""
        if ($after -ne $before) {
            Set-TextUtf8NoBom $target $after
            $patchedFiles.Add((Get-RelativePath $NodePtyDir $target)) | Out-Null
        }
    }

    if ($patchedFiles.Count -gt 0) {
        Add-Replacement "node-pty-spectre-mitigation" "disabled" ($patchedFiles -join ", ")
    }
}

function Prune-NodePtyNonArm64Payloads {
    param([string]$NodePtyDir)

    if (-not (Test-Path -LiteralPath $NodePtyDir)) {
        throw "node-pty directory was not found: $NodePtyDir"
    }

    $removed = New-Object "System.Collections.Generic.List[string]"

    $prebuildsRoot = Join-Path $NodePtyDir "prebuilds"
    if (Test-Path -LiteralPath $prebuildsRoot) {
        $prebuildDirs = @(Get-ChildItem -LiteralPath $prebuildsRoot -Directory -ErrorAction SilentlyContinue)
        foreach ($prebuildDir in $prebuildDirs) {
            if ($prebuildDir.Name -eq "win32-arm64") {
                continue
            }

            $removed.Add((Get-RelativePath $NodePtyDir $prebuildDir.FullName)) | Out-Null
            Remove-Item -LiteralPath $prebuildDir.FullName -Recurse -Force
        }
    }

    $conptyRoot = Join-Path $NodePtyDir "third_party\conpty"
    if (Test-Path -LiteralPath $conptyRoot) {
        $versionDirs = @(Get-ChildItem -LiteralPath $conptyRoot -Directory -ErrorAction SilentlyContinue)
        foreach ($versionDir in $versionDirs) {
            $platformDirs = @(Get-ChildItem -LiteralPath $versionDir.FullName -Directory -ErrorAction SilentlyContinue)
            foreach ($platformDir in $platformDirs) {
                if ($platformDir.Name -eq "win10-arm64") {
                    continue
                }

                $removed.Add((Get-RelativePath $NodePtyDir $platformDir.FullName)) | Out-Null
                Remove-Item -LiteralPath $platformDir.FullName -Recurse -Force
            }
        }
    }

    if ($removed.Count -gt 0) {
        Add-Replacement "node-pty-non-arm64-payloads" "pruned" ($removed -join ", ")
    }
}











function Invoke-WithTemporaryEnv {
    param(
        [hashtable]$Environment,
        [scriptblock]$ScriptBlock
    )

    $old = @{}
    foreach ($key in $Environment.Keys) {
        $old[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], "Process")
    }

    try {
        & $ScriptBlock
    }
    finally {
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $old[$key], "Process")
        }
    }
}

function Add-MsvcFrameAddressShim {
    param([string]$Path)

    $content = Get-Content -LiteralPath $Path -Raw
    if ($content.Contains("__builtin_frame_address(level)")) {
        return $false
    }

    $shim = @"
#ifndef NODE_ADDON_API_DISABLE_DEPRECATED
#define NODE_ADDON_API_DISABLE_DEPRECATED
#endif

#if defined(_MSC_VER) && !defined(__clang__) && !defined(__builtin_frame_address)
#include <intrin.h>
#define __builtin_frame_address(level) _AddressOfReturnAddress()
#endif

"@

    Set-TextUtf8NoBom $Path ($shim + $content)
    return $true
}

function Get-NpmPackageVersionFromDirectory {
    param([string]$PackageDir)

    $packageJson = Join-Path $PackageDir "package.json"
    if (-not (Test-Path -LiteralPath $packageJson)) {
        throw "Package metadata was not found: $packageJson"
    }

    $package = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
    return [string]$package.version
}

function Invoke-NodeGypArm64ElectronRebuild {
    param(
        [string]$PackageDir,
        [string]$ElectronVersion
    )

    $resolvedPackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
    $shortRoot = Join-Path $script:ScriptRoot "build\node-gyp"
    $shortRoot = New-Item -ItemType Directory -Path $shortRoot -Force
    $shortRoot = (Resolve-Path -LiteralPath $shortRoot.FullName).Path

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($resolvedPackageDir))
    }
    finally {
        $sha256.Dispose()
    }
    $hash = [System.BitConverter]::ToString($hashBytes).Replace("-", "").Substring(0, 12).ToLowerInvariant()
    $shortPackageDir = Join-Path $shortRoot $hash

    if (Test-Path -LiteralPath $shortPackageDir) {
        $resolvedShortPackageDir = (Resolve-Path -LiteralPath $shortPackageDir).Path
        if (-not $resolvedShortPackageDir.StartsWith($shortRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean node-gyp build path outside short root: $resolvedShortPackageDir"
        }
    }

    Write-Host "Staging native rebuild in short path: $shortPackageDir"
    Copy-DirectoryRobust $resolvedPackageDir $shortPackageDir
    Remove-IfExists (Join-Path $shortPackageDir "build")

    Push-Location $shortPackageDir
    try {
        Invoke-Checked "pnpm" @(
            "dlx",
            "node-gyp",
            "rebuild",
            "--arch=arm64",
            "--target=$ElectronVersion",
            "--dist-url=https://electronjs.org/headers"
        )
    }
    finally {
        Pop-Location
    }

    Copy-DirectoryRobust (Join-Path $shortPackageDir "build") (Join-Path $resolvedPackageDir "build")
}

function Get-WlDeviceKitNodeModulesDirs {
    param([string]$AsarDir)

    $candidates = @(
        (Join-Path $AsarDir "node_modules\@worklouder\device-kit-oai\node_modules\@worklouder\wl-device-kit\node_modules"),
        (Join-Path $AsarDir "node_modules\%40worklouder\device-kit-oai\node_modules\%40worklouder\wl-device-kit\node_modules")
    )

    return @($candidates | Where-Object { Test-Path -LiteralPath $_ })
}

function Get-RequiredWlDeviceKitNodeModulesDir {
    param([string]$AsarDir)

    foreach ($nodeModulesDir in Get-WlDeviceKitNodeModulesDirs $AsarDir) {
        if ((Test-Path -LiteralPath (Join-Path $nodeModulesDir "node-hid\package.json")) -and
            (Test-Path -LiteralPath (Join-Path $nodeModulesDir "serialport\node_modules\@serialport\bindings-cpp\package.json"))) {
            return $nodeModulesDir
        }
    }

    throw "Could not find Work Louder device kit native module sources."
}

function Sync-WlDeviceKitNativeModuleBuilds {
    param(
        [string]$AsarDir,
        [string]$BuiltHidNode,
        [string]$BuiltSerialPortNode
    )

    if ((Get-PeMachine $BuiltHidNode) -ne "arm64") {
        throw "node-hid build did not produce an ARM64 binary: $BuiltHidNode"
    }
    if ((Get-PeMachine $BuiltSerialPortNode) -ne "arm64") {
        throw "serialport build did not produce an ARM64 binary: $BuiltSerialPortNode"
    }

    $hidBytes = [System.IO.File]::ReadAllBytes($BuiltHidNode)
    $serialPortBytes = [System.IO.File]::ReadAllBytes($BuiltSerialPortNode)

    foreach ($nodeModulesDir in Get-WlDeviceKitNodeModulesDirs $AsarDir) {
        $hidReleaseDir = Join-Path $nodeModulesDir "node-hid\build\Release"
        New-Item -ItemType Directory -Path $hidReleaseDir -Force | Out-Null
        Get-ChildItem -LiteralPath $hidReleaseDir -Filter "*.node" -File -ErrorAction SilentlyContinue |
            Remove-Item -Force
        [System.IO.File]::WriteAllBytes((Join-Path $hidReleaseDir "HID.node"), $hidBytes)

        $serialPortReleaseDirs = @(
            (Join-Path $nodeModulesDir "serialport\node_modules\@serialport\bindings-cpp\build\Release"),
            (Join-Path $nodeModulesDir "serialport\node_modules\%40serialport\bindings-cpp\build\Release")
        )
        foreach ($serialPortReleaseDir in $serialPortReleaseDirs) {
            if (-not (Test-Path -LiteralPath (Split-Path -Parent $serialPortReleaseDir))) {
                continue
            }

            New-Item -ItemType Directory -Path $serialPortReleaseDir -Force | Out-Null
            Get-ChildItem -LiteralPath $serialPortReleaseDir -Filter "*.node" -File -ErrorAction SilentlyContinue |
                Remove-Item -Force
            [System.IO.File]::WriteAllBytes((Join-Path $serialPortReleaseDir "bindings.node"), $serialPortBytes)
        }
    }
}

function Install-Arm64WlDeviceKitNativeModules {
    param(
        [string]$AsarDir,
        [string]$ElectronVersion
    )

    $nodeModulesDir = Get-RequiredWlDeviceKitNodeModulesDir $AsarDir
    $nodeHidDir = Join-Path $nodeModulesDir "node-hid"
    $serialPortBindingsDir = Join-Path $nodeModulesDir "serialport\node_modules\@serialport\bindings-cpp"

    $nodeHidVersion = Get-NpmPackageVersionFromDirectory $nodeHidDir
    $serialPortBindingsVersion = Get-NpmPackageVersionFromDirectory $serialPortBindingsDir
    $script:Report.versions.nodeHid = $nodeHidVersion
    $script:Report.versions.serialPortBindingsCpp = $serialPortBindingsVersion

    $nodeHidUtilHeader = Join-Path $nodeHidDir "src\util.h"
    $serialPortHeader = Join-Path $serialPortBindingsDir "src\serialport.h"
    if (Add-MsvcFrameAddressShim $nodeHidUtilHeader) {
        Add-Replacement "node-hid-source" "patched" "Electron 42 MSVC __builtin_frame_address compatibility"
    }
    if (Add-MsvcFrameAddressShim $serialPortHeader) {
        Add-Replacement "serialport-bindings-cpp-source" "patched" "Electron 42 MSVC __builtin_frame_address compatibility"
    }

    Invoke-NodeGypArm64ElectronRebuild $nodeHidDir $ElectronVersion
    Invoke-NodeGypArm64ElectronRebuild $serialPortBindingsDir $ElectronVersion

    $builtHidNode = Join-Path $nodeHidDir "build\Release\HID.node"
    $builtSerialPortNode = Join-Path $serialPortBindingsDir "build\Release\bindings.node"
    if (-not (Test-Path -LiteralPath $builtHidNode)) {
        throw "node-hid ARM64 build output was not found: $builtHidNode"
    }
    if (-not (Test-Path -LiteralPath $builtSerialPortNode)) {
        throw "serialport ARM64 build output was not found: $builtSerialPortNode"
    }

    Sync-WlDeviceKitNativeModuleBuilds $AsarDir $builtHidNode $builtSerialPortNode
    Add-Replacement "node-hid" "arm64" "rebuilt for Electron $ElectronVersion"
    Add-Replacement "serialport-bindings-cpp" "arm64" "rebuilt for Electron $ElectronVersion"
}

function Build-Arm64NativeModules {
    param(
        [string]$AsarDir,
        [string]$ElectronVersion,
        [string]$WorkDir
    )

    Write-Step "Building ARM64 native Node modules"
    Require-CommandPath "node" | Out-Null
    Require-CommandPath "pnpm" | Out-Null

    $betterSqliteVersion = Get-NpmPackageVersion $AsarDir "better-sqlite3"
    $nodePtyVersion = Get-NpmPackageVersion $AsarDir "node-pty"
    $script:Report.versions.betterSqlite3 = $betterSqliteVersion
    $script:Report.versions.nodePty = $nodePtyVersion

    $buildDir = New-CleanDirectory (Join-Path $WorkDir "native-build")
    Push-Location $buildDir
    try {
        $packageJson = [ordered]@{
            private = $true
            dependencies = [ordered]@{
                "better-sqlite3" = $betterSqliteVersion
                "node-pty" = $nodePtyVersion
            }
            devDependencies = [ordered]@{
                "electron" = $ElectronVersion
                "@electron/rebuild" = "latest"
            }
        } | ConvertTo-Json -Depth 8
        Set-TextUtf8NoBom (Join-Path $buildDir "package.json") $packageJson
        Set-TextUtf8NoBom (Join-Path $buildDir "pnpm-workspace.yaml") @"
packages:
  - .
allowBuilds:
  better-sqlite3: true
  node-pty: true
"@

        Invoke-Checked "pnpm" @("install", "--ignore-scripts", "--config.node-linker=hoisted")

        $betterSqliteDir = Join-Path $buildDir "node_modules\better-sqlite3"
        $nodePtyDir = Join-Path $buildDir "node_modules\node-pty"
        Patch-BetterSqlite3ForElectron42 $betterSqliteDir $ElectronVersion
        Disable-NodePtySpectreMitigation $nodePtyDir

        Push-Location $betterSqliteDir
        try {
            $prebuildExit = Invoke-Checked "pnpm" @(
                "dlx",
                "prebuild-install",
                "--runtime", "electron",
                "--target", $ElectronVersion,
                "--arch", "arm64",
                "--platform", "win32"
            ) @(0, 1)
            if ($prebuildExit -eq 0) {
                Add-Replacement "better-sqlite3" "prebuilt-arm64" "electron $ElectronVersion"
            }
            else {
                Add-Replacement "better-sqlite3" "prebuilt-miss" "falling back to @electron/rebuild"
            }
        }
        finally {
            Pop-Location
        }

        $electronRebuild = Join-Path $buildDir "node_modules\.bin\electron-rebuild.cmd"
        if (-not (Test-Path -LiteralPath $electronRebuild)) {
            throw "electron-rebuild command was not found: $electronRebuild"
        }

        Invoke-Checked $electronRebuild @(
            "-v", $ElectronVersion,
            "--arch", "arm64",
            "--force",
            "-w", "better-sqlite3",
            "-w", "node-pty"
        )

        Prune-NodePtyNonArm64Payloads $nodePtyDir
    }
    finally {
        Pop-Location
    }

    foreach ($moduleName in @("better-sqlite3", "node-pty")) {
        $source = Join-Path $buildDir "node_modules\$moduleName"
        $destination = Join-Path $AsarDir "node_modules\$moduleName"
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Native build did not produce $moduleName"
        }
        Remove-IfExists $destination
        Copy-DirectoryRobust $source $destination
        Add-Replacement $moduleName "arm64" "rebuilt for Electron $ElectronVersion"
    }

    Install-Arm64WlDeviceKitNativeModules $AsarDir $ElectronVersion
}



function Update-AppxManifest {
    param(
        [string]$ManifestPath,
        [string]$IdentityName,
        [string]$DisplayNameValue,
        [string]$PublisherValue,
        [string]$VersionValue = ""
    )

    Write-Step "Rewriting AppxManifest.xml"
    [xml]$manifest = Get-Content -LiteralPath $ManifestPath -Raw
    $ns = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
    $ns.AddNamespace("f", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
    $ns.AddNamespace("uap", "http://schemas.microsoft.com/appx/manifest/uap/windows10")
    $ns.AddNamespace("mp", "http://schemas.microsoft.com/appx/2014/phone/manifest")

    $identity = $manifest.SelectSingleNode("/f:Package/f:Identity", $ns)
    if ($null -eq $identity) {
        throw "Manifest Identity node not found"
    }
    $identity.SetAttribute("Name", $IdentityName)
    $identity.SetAttribute("ProcessorArchitecture", "arm64")
    $identity.SetAttribute("Publisher", $PublisherValue)
    if (-not [string]::IsNullOrWhiteSpace($VersionValue)) {
        $identity.SetAttribute("Version", $VersionValue)
    }

    $properties = $manifest.SelectSingleNode("/f:Package/f:Properties", $ns)
    if ($null -ne $properties) {
        $displayNode = $properties.SelectSingleNode("f:DisplayName", $ns)
        if ($null -ne $displayNode) {
            $displayNode.InnerText = $DisplayNameValue
        }
        $publisherDisplayNode = $properties.SelectSingleNode("f:PublisherDisplayName", $ns)
        if ($null -ne $publisherDisplayNode) {
            $publisherDisplayNode.InnerText = $DisplayNameValue
        }
    }

    $visualElements = $manifest.SelectSingleNode("/f:Package/f:Applications/f:Application/uap:VisualElements", $ns)
    if ($null -ne $visualElements) {
        $visualElements.SetAttribute("DisplayName", $DisplayNameValue)
        $visualElements.SetAttribute("Description", $DisplayNameValue)
    }

    $phoneIdentity = $manifest.SelectSingleNode("/f:Package/mp:PhoneIdentity", $ns)
    if ($null -ne $phoneIdentity) {
        $phoneIdentity.ParentNode.RemoveChild($phoneIdentity) | Out-Null
    }

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [System.Xml.XmlWriter]::Create($ManifestPath, $settings)
    try {
        $manifest.Save($writer)
    }
    finally {
        $writer.Close()
    }
}

function Remove-SourcePackageMetadata {
    param([string]$PackageRoot)

    foreach ($relative in @(
        "AppxBlockMap.xml",
        "AppxSignature.p7x",
        "AppxMetadata",
        "microsoft.system.package.metadata"
    )) {
        Remove-IfExists (Join-Path $PackageRoot $relative)
    }
}

function Ensure-SigningCertificate {
    param(
        [string]$Subject,
        [string]$CertificateDir
    )

    New-Item -ItemType Directory -Path $CertificateDir -Force | Out-Null
    $cert = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $Subject -and $_.HasPrivateKey } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if ($null -eq $cert) {
        Write-Step "Creating self-signed code signing certificate"
        $cert = New-SelfSignedCertificate `
            -Type Custom `
            -Subject $Subject `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -KeyUsage DigitalSignature `
            -CertStoreLocation "Cert:\CurrentUser\My" `
            -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}false") `
            -NotAfter (Get-Date).AddYears(5)
    }
    else {
        Write-Step "Reusing existing self-signed certificate $($cert.Thumbprint)"
    }

    $cerPath = Join-Path $CertificateDir "CodexWoA.cer"
    Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null

    $script:Report.outputs.certificate = $cerPath
    $script:Report.outputs.certificateThumbprint = $cert.Thumbprint
    return $cert
}

function New-InstallScript {
    param(
        [string]$OutputPath,
        [string]$MsixFileName,
        [string]$CerRelativePath
    )

    $content = Get-Content -LiteralPath (Join-Path $script:ScriptRoot "src\CodexWoA.Build\Templates\Install.ps1") -Raw

    $content = $content.
        Replace("__MSIX_FILE_NAME__", $MsixFileName).
        Replace("__CER_RELATIVE_PATH__", $CerRelativePath)

    Set-TextUtf8NoBom $OutputPath $content
}

function New-InstallBatchScript {
    param([string]$OutputPath)

    $content = Get-Content -LiteralPath (Join-Path $script:ScriptRoot "src\CodexWoA.Build\Templates\Install.bat") -Raw

    Set-TextUtf8NoBom $OutputPath $content
}

function Pack-And-SignMsix {
    param(
        [string]$PackageRoot,
        [string]$MsixPath,
        [string]$MakeAppxPath,
        [string]$SignToolPath,
        [object]$Certificate
    )

    Write-Step "Packing MSIX"
    Remove-IfExists $MsixPath
    Invoke-Checked $MakeAppxPath @("pack", "/d", $PackageRoot, "/p", $MsixPath, "/o")

    Write-Step "Signing MSIX"
    Invoke-Checked $SignToolPath @(
        "sign",
        "/fd", "SHA256",
        "/sha1", $Certificate.Thumbprint,
        $MsixPath
    )
}

function Test-MsixPackage {
    param(
        [string]$MsixPath,
        [string]$VerifyDir,
        [string]$MakeAppxPath,
        [string]$SignToolPath,
        [string]$MtPath,
        [string]$ExpectedIdentity,
        [string]$ExpectedSignerThumbprint
    )

    Write-Step "Verifying generated MSIX"
    New-CleanDirectory $VerifyDir | Out-Null
    Invoke-Checked $MakeAppxPath @("unpack", "/p", $MsixPath, "/d", $VerifyDir, "/o")

    [xml]$manifest = Get-Content -LiteralPath (Join-Path $VerifyDir "AppxManifest.xml") -Raw
    $ns = New-Object System.Xml.XmlNamespaceManager($manifest.NameTable)
    $ns.AddNamespace("f", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
    $ns.AddNamespace("uap", "http://schemas.microsoft.com/appx/manifest/uap/windows10")
    $identity = $manifest.SelectSingleNode("/f:Package/f:Identity", $ns)
    if ($identity.Name -ne $ExpectedIdentity) {
        throw "Manifest identity mismatch: $($identity.Name)"
    }
    if ($identity.ProcessorArchitecture -ne "arm64") {
        throw "Manifest architecture mismatch: $($identity.ProcessorArchitecture)"
    }

    $application = $manifest.SelectSingleNode("/f:Package/f:Applications/f:Application", $ns)
    if ($application.Executable -ne "app/Codex.exe") {
        throw "Manifest executable mismatch: $($application.Executable)"
    }

    $protocol = $manifest.SelectSingleNode("/f:Package/f:Applications/f:Application/f:Extensions/uap:Extension/uap:Protocol", $ns)
    if ($null -eq $protocol -or $protocol.Name -ne "codex") {
        throw "Manifest codex protocol was not preserved"
    }

    Assert-WindowsSandboxSetupAsInvokerManifest `
        (Join-Path $VerifyDir "app\resources\codex-windows-sandbox-setup.exe") `
        $MtPath `
        (Join-Path $VerifyDir "codex-windows-sandbox-setup.embedded.manifest")

    $fallbackX64 = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @(
        "app\resources\node_repl.exe",
        "app\resources\plugins\openai-bundled\plugins\latex\bin\tectonic.exe",
        "app\resources\plugins\openai-bundled\plugins\chrome\extension-host\windows\x64\extension-host.exe",
        "app\resources\plugins\openai-bundled\plugins\chrome\extension-host\windows\arm64\extension-host.exe",
        "app\resources\plugins\openai-bundled\plugins\computer-use\node_modules\%40oai\sky\bin\windows\codex-computer-use.exe",
        "app\resources\plugins\openai-bundled\plugins\computer-use\node_modules\@oai\sky\bin\windows\codex-computer-use.exe"
    )) {
        $fallbackX64.Add($path) | Out-Null
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $fallbacks = New-Object System.Collections.Generic.List[string]
    $peFiles = Get-ChildItem -LiteralPath (Join-Path $VerifyDir "app") -Recurse -File |
        Where-Object { $_.Extension.ToLowerInvariant() -in @(".exe", ".dll", ".node") }

    foreach ($file in $peFiles) {
        $relative = Get-RelativePath $VerifyDir $file.FullName
        $machine = Get-PeMachine $file.FullName
        if ($machine -eq "NotPE") {
            continue
        }

        $mustBeArm64 = $false
        if ($relative -match "^app\\resources\\app\.asar\.unpacked\\node_modules\\(better-sqlite3|node-pty)\\") {
            $mustBeArm64 = $true
        }
        elseif ($relative -match "\.node$") {
            $mustBeArm64 = $true
        }
        elseif ($relative -match "^app\\resources\\(node|rg)\.exe$") {
            $mustBeArm64 = $true
        }
        elseif ($relative -match "^app\\resources\\native\\") {
            $mustBeArm64 = $true
        }
        elseif ($relative -notmatch "^app\\resources\\") {
            $mustBeArm64 = $true
        }

        if ($mustBeArm64 -and $machine -ne "arm64") {
            $errors.Add("$relative is $machine, expected arm64")
            continue
        }

        if ($machine -eq "x64") {
            if ($fallbackX64.Contains($relative)) {
                $fallbacks.Add($relative)
            }
            else {
                $errors.Add("$relative is x64 and is not in the out-of-process fallback allowlist")
            }
        }
    }

    $wslElfPayloads = New-Object System.Collections.Generic.List[string]
    $requiredWslPayloads = @(
        (Join-Path $script:WslPayloadRelativeDir "codex"),
        (Join-Path $script:WslPayloadRelativeDir "codex-resources\bwrap")
    )
    foreach ($relative in $requiredWslPayloads) {
        $payloadPath = Join-Path $VerifyDir $relative
        if (-not (Test-Path -LiteralPath $payloadPath)) {
            $errors.Add("$relative is missing")
            continue
        }

        $machine = Get-ElfMachine $payloadPath
        if ($machine -ne "arm64") {
            $errors.Add("$relative is $machine, expected arm64")
        }
        elseif (-not $wslElfPayloads.Contains($relative)) {
            $wslElfPayloads.Add($relative) | Out-Null
        }
    }

    $elfFiles = Get-ChildItem -LiteralPath (Join-Path $VerifyDir "app") -Recurse -File
    foreach ($file in $elfFiles) {
        $machine = Get-ElfMachine $file.FullName
        if ($machine -eq "NotELF") {
            continue
        }

        $relative = Get-RelativePath $VerifyDir $file.FullName
        $isCodexWslPayload = $file.Name -eq "codex" -and (Test-IsWslCodexPayloadPath $relative)
        $isBwrapWslPayload = $file.Name -eq "bwrap" -and (Test-IsWslBwrapPayloadPath $relative)

        if ($isCodexWslPayload -or $isBwrapWslPayload) {
            if ($machine -ne "arm64") {
                $errors.Add("$relative is Linux $machine ELF, expected arm64")
            }
            elseif (-not $wslElfPayloads.Contains($relative)) {
                $wslElfPayloads.Add($relative) | Out-Null
            }
        }
        elseif ($machine -eq "x64" -and ($file.Name -eq "codex" -or $file.Name -eq "bwrap")) {
            $errors.Add("$relative is Linux x64 ELF and looks like an unpatched WSL runtime payload")
        }
    }

    if ($errors.Count -gt 0) {
        throw "Architecture validation failed:`n$($errors -join "`n")"
    }

    $authenticode = Get-AuthenticodeSignature -LiteralPath $MsixPath
    if ($null -eq $authenticode.SignerCertificate) {
        throw "MSIX does not contain an Authenticode signer"
    }
    if ($authenticode.SignerCertificate.Thumbprint -ne $ExpectedSignerThumbprint) {
        throw "MSIX signer thumbprint mismatch: $($authenticode.SignerCertificate.Thumbprint)"
    }

    try {
        Invoke-Checked $SignToolPath @("verify", "/pa", $MsixPath)
        $signToolVerify = "passed"
    }
    catch {
        $signToolVerify = "self-signed/untrusted before Install.ps1 trust step: $($_.Exception.Message)"
        Write-Warn "signtool verify did not build a trusted chain yet. This is expected before Install.ps1 imports the local certificate."
    }

    try {
        Add-AppxPackage -Path $MsixPath -WhatIf | Out-Null
        $whatIf = "passed"
    }
    catch {
        $whatIf = "skipped: $($_.Exception.Message)"
        Write-Warn "Add-AppxPackage -WhatIf did not complete: $($_.Exception.Message)"
    }

    $script:Report.validation = [ordered]@{
        manifestIdentity = $identity.Name
        manifestArchitecture = $identity.ProcessorArchitecture
        executable = $application.Executable
        protocol = $protocol.Name
        sandboxSetupManifest = "asInvoker"
        x64Fallbacks = @($fallbacks)
        wslElfPayloads = @($wslElfPayloads)
        signerThumbprint = $authenticode.SignerCertificate.Thumbprint
        signToolVerify = $signToolVerify
        addAppxPackageWhatIf = $whatIf
    }
}

function Main {
    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $OutputDir = $script:DefaultOutputDir
    }
    $resolvedPackageVersionOverride = Resolve-PackageVersionOverride $PackageVersionOverride

    $resolvedOutputDir = New-Item -ItemType Directory -Path $OutputDir -Force
    $resolvedOutputDir = (Resolve-Path -LiteralPath $resolvedOutputDir.FullName).Path
    $workDir = New-CleanDirectory (Join-Path $resolvedOutputDir "work")
    $cacheDir = New-Item -ItemType Directory -Path (Join-Path $resolvedOutputDir "cache") -Force
    $cacheDir = (Resolve-Path -LiteralPath $cacheDir.FullName).Path

    $makeAppx = Find-WindowsKitTool "makeappx.exe"
    $signTool = Find-WindowsKitTool "signtool.exe"
    $mt = Find-WindowsKitTool "mt.exe"
    $script:Report.tools = [ordered]@{
        makeAppx = $makeAppx
        signTool = $signTool
        mt = $mt
    }

    Ensure-VisualStudioArm64Tools

    $effectiveSourceMode = Resolve-SourceMode $SourceMode
    $sourceRoot = Join-Path $workDir "source"
    switch ($effectiveSourceMode) {
        "StoreMsix" { Copy-StoreMsixSource $sourceRoot $cacheDir | Out-Null }
        "Installed" { Copy-InstalledSource $sourceRoot | Out-Null }
        "StoreLatest" { Copy-StoreInstalledSource $sourceRoot | Out-Null }
        "Msix" { Copy-MsixSource $SourceMsixPath $sourceRoot | Out-Null }
        default { throw "Unsupported source mode: $effectiveSourceMode" }
    }

    Assert-SourceShape $sourceRoot

    $stageRoot = Join-Path $workDir "stage"
    Write-Step "Preparing staging package"
    New-CleanDirectory $stageRoot | Out-Null
    Copy-DirectoryRobust $sourceRoot $stageRoot
    Remove-SourcePackageMetadata $stageRoot

    $appDir = Join-Path $stageRoot "app"
    $resourcesDir = Join-Path $appDir "resources"
    $asarExtractDir = Join-Path $workDir "app-asar"
    Normalize-PercentEncodedScopedPackageDirs $resourcesDir "resource-scoped-package-dirs"

    Write-Step "Extracting app.asar"
    Extract-AppAsar $resourcesDir $asarExtractDir
    Normalize-PercentEncodedScopedPackageDirs $asarExtractDir "asar-scoped-package-dirs"

    $electronVersion = Read-ElectronVersion $appDir $asarExtractDir
    $nodeVersion = Read-NodeVersion (Join-Path $resourcesDir "node.exe")
    $script:Report.versions.electron = $electronVersion
    $script:Report.versions.node = $nodeVersion

    Install-Arm64ElectronRuntime $appDir $electronVersion $cacheDir
    Install-Arm64Node $resourcesDir $nodeVersion $cacheDir
    Install-Arm64CodexHelpers $resourcesDir $cacheDir $CodexReleaseTag
    Patch-WindowsSandboxSetupAsInvokerManifest $resourcesDir $signTool $mt $workDir
    Install-Arm64WslCodexRuntime $stageRoot $resourcesDir $asarExtractDir $cacheDir $CodexReleaseTag
    Install-Arm64Ripgrep $resourcesDir $cacheDir
    Remove-WindowsUpdaterNative $resourcesDir
    Enable-ChromeExtensionHostX64Fallback $resourcesDir
    Prune-PluginClassicLevelNonArm64WindowsPrebuilds $resourcesDir
    Rebuild-PluginClassicLevelArm64NativeModules $resourcesDir
    Enable-ComputerUseX64Fallback $resourcesDir

    Build-Arm64NativeModules $asarExtractDir $electronVersion $workDir

    Write-Step "Repacking app.asar"
    Repack-AppAsar $asarExtractDir $resourcesDir

    $manifestPath = Join-Path $stageRoot "AppxManifest.xml"
    Update-AppxManifest $manifestPath $PackageIdentity $DisplayName $PublisherSubject $resolvedPackageVersionOverride
    if (-not [string]::IsNullOrWhiteSpace($resolvedPackageVersionOverride)) {
        Add-Replacement "package-version" "overridden" $resolvedPackageVersionOverride
    }

    [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
    $version = $manifest.Package.Identity.Version
    $script:Report.versions.package = $version

    $certDir = Join-Path $resolvedOutputDir "cert"
    $certificate = Ensure-SigningCertificate $PublisherSubject $certDir

    $msixFileName = "Codex-WoA_$version`_arm64.msix"
    $msixPath = Join-Path $resolvedOutputDir $msixFileName
    if ((Test-Path -LiteralPath $msixPath) -and -not $Force) {
        throw "Output MSIX already exists: $msixPath. Use -Force to overwrite."
    }

    Pack-And-SignMsix $stageRoot $msixPath $makeAppx $signTool $certificate
    Test-MsixPackage $msixPath (Join-Path $workDir "verify") $makeAppx $signTool $mt $PackageIdentity $certificate.Thumbprint

    $installScriptPath = Join-Path $resolvedOutputDir "Install.ps1"
    New-InstallScript $installScriptPath $msixFileName "cert\CodexWoA.cer"
    $installBatchPath = Join-Path $resolvedOutputDir "Install.bat"
    New-InstallBatchScript $installBatchPath

    $script:Report.outputs.msix = $msixPath
    $script:Report.outputs.installScript = $installScriptPath
    $script:Report.outputs.installBatch = $installBatchPath
    $script:Report.finishedAt = (Get-Date).ToString("o")

    $reportPath = Join-Path $resolvedOutputDir "build-report.json"
    $script:Report.outputs.report = $reportPath
    $script:Report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding UTF8

    if (-not $KeepWorkDir) {
        Remove-IfExists $workDir
    }

    Write-Host ""
    Write-Host "Codex WoA package created:" -ForegroundColor Green
    Write-Host "  MSIX: $msixPath"
    Write-Host "  Certificate: $(Join-Path $certDir 'CodexWoA.cer')"
    Write-Host "  Installer: $installScriptPath"
    Write-Host "  Installer batch: $installBatchPath"
    Write-Host "  Report: $reportPath"
}
