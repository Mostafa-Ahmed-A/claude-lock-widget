# Contributing

Thanks for helping! The project is small on purpose: Windows PowerShell 5.1 for the data side, one C# file for the transcript scanner, and a small C# widget provider.

## Layout

```
src/
  ClaudeLockWidget.ps1     CLI entry point (refresh | hook | push-usage | capture-statusline | preview |
                           install | uninstall | integrate | status | doctor | lockscreen-image)
  lib/
    Common.ps1             paths, logging, config, formatting helpers
    Usage.ps1              live usage store, push/status-line/API sources, reset handling
    LocalStats.ps1         runs the scanner, applies range filters, demo data
    TranscriptScanner.cs   fast cached JSONL scanner (compiled at runtime by Add-Type)
    Render.ps1             GDI+ drawing: widget tile (+ the legacy full-screen picture)
    Widget.ps1             publishes widget-state.json + tile PNG atomically
    Integration.ps1        Stop hook / status line in settings.json, CLAUDE.md block
    Scheduler.ps1          Scheduled Task XML + register/unregister
    LockScreen.ps1         legacy lock screen picture helpers
widget/
  Provider/                C# widget provider (COM server)
  Package/                 AppxManifest template
  Build-Widget.ps1         publish + pack + sign;  Install-Widget.ps1 trusts the cert and installs
tests/
  run-tests.ps1            dependency-free test runner
  fixtures/                sample API responses
*.cmd                      double-click wrappers around the entry point
```

## Ground rules

- **Windows PowerShell 5.1 compatible.** No `??`, `?.`, ternaries, `ForEach-Object -Parallel`, or PowerShell 7-only cmdlets. Test with `powershell.exe`, not `pwsh`.
- **C# 5 only** in `TranscriptScanner.cs` (no `$"..."`, `?.`, `nameof`, expression-bodied members): it is compiled by the `csc.exe` that ships with Windows PowerShell. The widget provider is a normal modern .NET project.
- **ASCII-only source files** (`.ps1`, `.cs`, `.csproj`, `.xml`). Windows PowerShell 5.1 reads BOM-less files as ANSI; build symbols with `[char]0x00B7`. Do not write `\uXXXX` escapes into scripts - some editors/tools expand them. A test enforces ASCII.
- **Use double literals when clamping.** `[math]::Min(100, 23.5)` rounds to 24 in Windows PowerShell; write `[math]::Min(100.0, ...)`.
- **Never log or persist an access token.** Code that touches credentials needs a test with a made-up token.
- **No network in tests.** The HTTP call is isolated in `Invoke-ClwUsageRequest` so tests can shadow it.
- **Be careful with the user's Claude Code files.** Edits to `settings.json` / `CLAUDE.md` must be minimal, backed up, idempotent and removable; every path has tests.

## Workflow

```powershell
# run everything
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1

# look at the widget tile without touching anything
powershell -NoProfile -ExecutionPolicy Bypass -File src\ClaudeLockWidget.ps1 preview -Demo

# build the package
powershell -NoProfile -ExecutionPolicy Bypass -File widget\Build-Widget.ps1
```

Set `CLW_HOME` to a temp folder and `CLAUDE_CONFIG_DIR` to an empty folder to keep experiments away from your real settings, cache and Claude files.

### Adding a stat to the tile

1. Compute it in `ConvertTo-ClwStats` (`LocalStats.ps1`) and add a test with synthetic scanner output.
2. Draw it in `New-ClwWidgetImage` (`Render.ps1`).
3. Document it in the "How the numbers are calculated" table of `SETUP_GUIDE.md`.

### Adding a usage source

Sources write through `Save-ClwLiveUsage -Source <name>`; `Get-ClwUsage` already picks the freshest. Add parsing + tests next to `ConvertFrom-ClwStatusLineJson`.

## Pull requests

- One logical change per PR, with tests for logic changes and a before/after PNG for visual ones.
- Update `CHANGELOG.md` and the docs.
- Be kind. This is a hobby-sized project.
