function New-BuildContext {
    param(
        [hashtable]$Options,
        [string]$RepoRoot
    )

    $report = [ordered]@{
        startedAt = (Get-Date).ToString("o")
        sourceMode = $Options.SourceMode
        packageIdentity = $Options.PackageIdentity
        displayName = $Options.DisplayName
        publisherSubject = $Options.PublisherSubject
        versions = [ordered]@{}
        replacements = New-Object System.Collections.Generic.List[object]
        warnings = New-Object System.Collections.Generic.List[string]
        validation = [ordered]@{}
        outputs = [ordered]@{}
    }

    return [pscustomobject][ordered]@{
        Options = $Options
        Paths = [ordered]@{
            RepoRoot = $RepoRoot
            DefaultOutputDir = Join-Path $RepoRoot "dist"
            WslPayloadRelativeDir = "app\resources"
        }
        Tools = [ordered]@{}
        Policy = [ordered]@{}
        Report = $report
    }
}
