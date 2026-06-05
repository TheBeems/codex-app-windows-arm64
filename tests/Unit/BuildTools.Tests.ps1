Describe "Pinned build tools" {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $tools = Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Data\BuildTools.psd1")
    }

    It "pins every native build helper" {
        foreach ($name in @("Pnpm", "ElectronRebuild", "NodeGyp", "PrebuildInstall")) {
            $tools[$name] | Should -Match "^\d+\.\d+\.\d+$"
        }
    }

    It "does not use latest for native build dependencies" {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $nativeContent = Get-Content -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Private\NativeModules.ps1") -Raw
        $nativeContent | Should -Not -Match '"latest"'
    }
}
