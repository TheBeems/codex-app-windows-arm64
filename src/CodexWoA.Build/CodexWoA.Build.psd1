@{
    RootModule = "CodexWoA.Build.psm1"
    ModuleVersion = "1.0.0"
    GUID = "b995dc1a-7893-4ff2-8baf-7138ef367ad8"
    Author = "Codex WoA contributors"
    Description = "Build orchestration for the Codex Windows ARM64 repack."
    PowerShellVersion = "5.1"
    FunctionsToExport = @("Invoke-CodexWoABuild", "Resolve-CodexStorePackage")
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
