Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:ModuleRoot = $PSScriptRoot
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$privateScripts = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "Private") -File -Filter "*.ps1" |
    Sort-Object Name
foreach ($scriptFile in $privateScripts) {
    . $scriptFile.FullName
}

$publicScripts = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "Public") -File -Filter "*.ps1" |
    Sort-Object Name
foreach ($scriptFile in $publicScripts) {
    . $scriptFile.FullName
}

Export-ModuleMember -Function @("Invoke-CodexWoABuild", "Resolve-CodexStorePackage")
