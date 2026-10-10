# The widget package

This folder builds the Windows **widget provider**: a packaged app that registers a "Claude usage" widget with Windows so it appears under *Settings > Personalization > Lock screen > Widgets*.

```
widget/
  Provider/                  C# (.NET 9) out-of-process COM server implementing IWidgetProvider
    WidgetProvider.cs        shows widget-state.json + the tile PNG; watches the folder for changes
    StateReader.cs           reads what ClaudeLockWidget.ps1 published
    FactoryHelper.cs         COM class factory boilerplate
    Program.cs               registers the class object when Windows starts it with -RegisterProcessAsComServer
  Package/AppxManifest.template.xml   COM server + widget definition (small + medium) + WinRT class registrations
  New-WidgetAssets.ps1       draws the icons and picker screenshot (no binary assets in git)
  Build-Widget.ps1           publish -> manifest -> makeappx -> sign  =>  dist\ClaudeLockWidget.msix
  Install-Widget.ps1         trust the certificate (one UAC prompt) and install the package
```

## Build

Needs the .NET 9 SDK and internet access for NuGet. The Windows SDK is optional - `makeappx`/`signtool` are downloaded from the `Microsoft.Windows.SDK.BuildTools` NuGet package when it is missing.

```powershell
powershell -ExecutionPolicy Bypass -File widget\Build-Widget.ps1            # x64 (or -Arch arm64)
powershell -ExecutionPolicy Bypass -File widget\dist\Install-Widget.ps1
```

`Build-Widget.ps1` creates a self-signed code-signing certificate `CN=ClaudeLockWidget` in `Cert:\CurrentUser\My` the first time (5 years) and exports the public part next to the package. For CI or releases pass `-PfxPath`/`-PfxPassword` to sign with your own certificate; the manifest `Publisher` must equal the certificate subject (`-Publisher`).

The package is **self-contained**: the target PC needs neither the .NET runtime nor the Windows App SDK runtime.

## How the pieces fit

1. Windows starts `ClaudeLockWidget.Provider.exe -RegisterProcessAsComServer` when a widget of this package needs its provider.
2. The provider registers its class factory (`CoRegisterClassObject`) and answers `CreateWidget` / `Activate` / `OnWidgetContextChanged` by sending an Adaptive Card (v1.6) with `"header": null` - so the picture uses the whole tile - whose only content is the tile picture (as a `data:` URI) with a spoken summary as alt text. Two pictures are sent: a transparent "glass" one with light text (used unless `$host.hostTheme` is `light`) and an opaque "card" one for light-theme hosts.
3. A `FileSystemWatcher` (plus a 30 s safety poll) on `%LOCALAPPDATA%\ClaudeLockWidget\widget` re-sends the card whenever `widget-state.json` changes. The state file is written last and atomically, pointing at a uniquely named image.
4. When the last widget is removed the provider exits; Windows starts it again when needed.

The CLSID lives in `Provider/WidgetProvider.cs` (`ClsIdText`); the build script substitutes it into the manifest, so there is a single source of truth.

## Debugging

- `Get-AppxPackage ClaudeLockWidget.Provider` shows whether Windows registered the package.
- The provider logs to `provider.log` (see the setup guide for where Windows places it for packaged apps).
- Run the provider by hand to see COM registration errors: `ClaudeLockWidget.Provider.exe -RegisterProcessAsComServer` from the package folder (it needs package identity, so use *Debug installed app package* in Visual Studio or check the log).
- Adaptive Card support in the Widgets host is a subset; test card changes on the real widget, not only in a designer.
