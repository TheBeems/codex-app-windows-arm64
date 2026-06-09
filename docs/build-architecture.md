# Build Architecture

`Build-CodexWoA.ps1` is the stable CLI wrapper. It imports `CodexWoA.Build` and
forwards its established parameters to `Invoke-CodexWoABuild`.

The module exposes only:

- `Invoke-CodexWoABuild`
- `Resolve-CodexStorePackage`

Private implementation is grouped by the reason it changes:

- `Source.ps1` acquires and validates source packages.
- Runtime, WSL, sandbox, ASAR, and bundled-plugin files transform payloads.
- `VisualStudio.ps1` and `NativeModules.ps1` own native build prerequisites.
- `Packaging.ps1` creates artifacts; `Validation.ps1` validates them.
- `Orchestration.ps1` keeps the seven build phases linear and visible.
- `Common.ps1` contains only genuinely shared infrastructure.

Compatibility decisions belong in `Data\CompatibilityPolicy.psd1`. Build helper
versions belong in `Data\BuildTools.psd1`. Do not duplicate either policy in
implementation files.

Run `tests\Run-Checks.ps1` before every commit. Add focused tests beside a domain
change; avoid abstractions that only serve one caller.
