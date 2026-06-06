Describe "Supply-chain policy" {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $policy = Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot "src\CodexWoA.Build\Data\SupplyChainPolicy.psd1")
    }

    It "pins every executable release asset with a SHA-256" {
        foreach ($asset in @(
                "electron-v42.1.0-win32-arm64.zip",
                "node-v24.14.0-win-arm64.zip",
                "codex-aarch64-pc-windows-msvc.exe",
                "codex-command-runner-aarch64-pc-windows-msvc.exe",
                "codex-windows-sandbox-setup-aarch64-pc-windows-msvc.exe",
                "codex-aarch64-unknown-linux-musl.tar.gz",
                "bwrap-aarch64-unknown-linux-musl.tar.gz",
                "ripgrep-15.1.0-aarch64-pc-windows-msvc.zip")) {
            $policy.AssetHashes[$asset] | Should -Match "^[A-F0-9]{64}$"
        }
    }

    It "does not allow mutable release tags for release-bound assets" {
        $policy.CodexReleaseTag | Should -Not -Be "latest"
        $policy.RipgrepReleaseTag | Should -Not -Be "latest"
    }

    It "pins the expected Store source identity" {
        $policy.StoreSource.ExpectedIdentityName | Should -Be "OpenAI.Codex"
        $policy.StoreSource.ExpectedArchitecture | Should -Be "x64"
        $policy.StoreSource.ExpectedPublisher | Should -Match "^CN="
        $policy.StoreSource.AllowedUrlHosts | Should -Contain "tlu.dl.delivery.mp.microsoft.com"
    }
}
