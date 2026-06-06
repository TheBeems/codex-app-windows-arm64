function Assert-WindowsSandboxSetupAsInvokerManifest {
    param(
        [string]$SetupExePath,
        [string]$MtPath,
        [string]$ExtractedManifestPath
    )

    Remove-IfExists $ExtractedManifestPath
    try {
        Invoke-Checked $MtPath @(
            "-inputresource:$SetupExePath;#1",
            "-out:$ExtractedManifestPath"
        )

        $manifestText = Get-Content -LiteralPath $ExtractedManifestPath -Raw
        if (
            $manifestText -notmatch "requestedExecutionLevel" -or
            $manifestText -notmatch 'level\s*=\s*["'']asInvoker["'']'
        ) {
            throw "Sandbox setup helper does not contain an asInvoker requestedExecutionLevel manifest: $SetupExePath"
        }
    }
    finally {
        Remove-IfExists $ExtractedManifestPath
    }
}

function Patch-WindowsSandboxSetupAsInvokerManifest {
    param(
        [string]$ResourcesDir,
        [string]$SignToolPath,
        [string]$MtPath,
        [string]$WorkDir
    )

    $setupExePath = Join-Path $ResourcesDir "codex-windows-sandbox-setup.exe"
    if (-not (Test-Path -LiteralPath $setupExePath)) {
        throw "Windows sandbox setup helper was not found: $setupExePath"
    }

    Write-Step "Embedding asInvoker manifest in Windows sandbox setup helper"
    $signature = Get-AuthenticodeSignature -LiteralPath $setupExePath
    if ($null -ne $signature.SignerCertificate) {
        Invoke-Checked $SignToolPath @("remove", "/s", $setupExePath)
    }

    $manifestPath = Join-Path $WorkDir "codex-windows-sandbox-setup.asInvoker.manifest"
    $manifest = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity
    version="1.0.0.0"
    processorArchitecture="*"
    name="OpenAI.Codex.WindowsSandboxSetup"
    type="win32"
  />
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false" />
      </requestedPrivileges>
    </security>
  </trustInfo>
</assembly>
'@
    Set-TextUtf8NoBom $manifestPath $manifest

    Invoke-Checked $MtPath @(
        "-manifest", $manifestPath,
        "-outputresource:$setupExePath;#1"
    )

    Assert-WindowsSandboxSetupAsInvokerManifest `
        $setupExePath `
        $MtPath `
        (Join-Path $WorkDir "codex-windows-sandbox-setup.embedded.manifest")
    Add-Replacement "codex-windows-sandbox-setup.exe-manifest" "patched" "embedded requestedExecutionLevel=asInvoker"
}
