Describe "Get-CodexStorePackage wrapper" {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $scriptPath = Join-Path $repoRoot "scripts\Get-CodexStorePackage.ps1"
        $tokens = $null
        $errors = $null
        $script:Ast = [Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It "forwards every resolved wrapper parameter to the resolver" {
        $command = $script:Ast.Find(
            {
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq "Resolve-CodexStorePackage"
            },
            $true)

        $command | Should -Not -BeNullOrEmpty
        $command.Extent.Text | Should -Not -Match '@PSBoundParameters'
        foreach ($name in @("ProductId", "Repo", "Ring", "Lang", "VersionOverride")) {
            $command.Extent.Text | Should -Match "-$name\s+\`$$name\b"
        }
    }

    It "uses a scalar-safe helper for GitHub outputs" {
        $scriptText = $script:Ast.Extent.Text
        $scriptText | Should -Match "function Write-GitHubScalarOutput"
        $scriptText | Should -Match "\[\\x00-\\x1F\\x7F\]"
        $scriptText | Should -Not -Match '">>\s*\$env:GITHUB_OUTPUT'
    }
}
