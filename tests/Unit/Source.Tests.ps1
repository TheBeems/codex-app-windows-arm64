Describe "Source package resolution" {
    BeforeAll {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $repoRoot "src\CodexWoA.Build\CodexWoA.Build.psd1") -Force
        $html = Get-Content -LiteralPath (Join-Path $repoRoot "tests\Fixtures\store-packages.html") -Raw
    }

    It "selects the latest x64 Store package from fixture HTML" {
        $result = Resolve-CodexStorePackage -Html $html
        $result.storeVersion | Should -Be "26.2.3.4"
        $result.msixFile | Should -Be "OpenAI.Codex_26.2.3.4_x64__2p2nqsd0c76g0.msix"
        $result.msixSha1 | Should -Be "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    }

    It "applies a valid package version override" {
        $result = Resolve-CodexStorePackage -Html $html -VersionOverride "30.1.2.3"
        $result.packageVersion | Should -Be "30.1.2.3"
        $result.releaseTag | Should -Be "30.1.2.3"
        $result.shouldBuild | Should -BeTrue
    }

    It "rejects invalid package version overrides" {
        { Resolve-CodexStorePackage -Html $html -VersionOverride "30.1" } | Should -Throw
    }

    It "rejects Store package URLs outside the Microsoft delivery allowlist" {
        $badHtml = @"
<table>
  <tr><td><a href="https://example.test/latest.msix">OpenAI.Codex_26.2.3.4_x64__2p2nqsd0c76g0.msix</a></td><td>latest</td><td>BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB</td><td>2 MB</td></tr>
</table>
"@

        { Resolve-CodexStorePackage -Html $badHtml } | Should -Throw "*not allowlisted*"
    }

    It "rejects decoded Store metadata control characters" {
        $badHtml = @"
<table>
  <tr><td><a href="https://tlu.dl.delivery.mp.microsoft.com/latest.msix&#10;release_tag=evil">OpenAI.Codex_26.2.3.4_x64__2p2nqsd0c76g0.msix</a></td><td>latest</td><td>BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB</td><td>2 MB</td></tr>
</table>
"@

        { Resolve-CodexStorePackage -Html $badHtml } | Should -Throw "*control character*"
    }
}
