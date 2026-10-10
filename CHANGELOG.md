# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/) and the project uses [Semantic Versioning](https://semver.org/).

## [2.0.1] - 2026-10-10

### Fixed
- **The widget now fills its tile and looks seamless.** The picture used to sit inside Windows' own tile as a box within a box, shrunk to fit under the title bar, with text far too small. The card header is now empty (`"header": null`) so the content uses the full tile, the picture has a transparent background with light text (an opaque card variant is used only for a light-theme Widgets board, via `$host.hostTheme`), the type is larger, and the layout matches the ~2.1:1 lock screen tile.
- Status text in the tile header is short ("Updated 9:05 AM", "Stale since 3:10 AM", "No usage reported yet").

### Changed
- `widgetWeeks` defaults to 30 (a calendar that fits the tile's proportions).

## [2.0.0] - 2026-10-10

### Changed (breaking)
- **Real Windows lock screen widget.** The widget is now a packaged Windows widget provider that you add from *Settings > Personalization > Lock screen > Widgets > Add widget*. It no longer replaces your lock screen picture or wallpaper. The old behaviour is still available as the explicit `lockscreen-image` command.
- The scheduled task now only refreshes the widget data; it no longer touches the lock screen picture.
- `preview` renders the widget tile (use `-Full` for the old full-screen picture).

### Added
- **Live plan usage that works in the Claude desktop app.** After each task Claude reads the desktop app's own `get_usage` and pushes the numbers with `push-usage`; the status line feed (`capture-statusline`) covers terminal and IDE sessions; Anthropic's usage endpoint remains as a fallback. A window whose reset time has passed is shown as 0%.
- **Updates after every Claude task:** an async `Stop` hook plus a short, clearly marked note in `~/.claude/CLAUDE.md`. `integrate -Action install | uninstall | status`; settings.json is backed up first and only the widget's own entries are touched.
- Widget tile with the activity calendar on top and the usage bars below, drawn on a transparent rounded card.
- Package build tooling (`widget\Build-Widget.ps1`) and installer (`widget\Install-Widget.ps1`): self-contained MSIX, self-signed certificate, one admin prompt to trust it.
- Reset times are rounded to the minute, as Claude's own UI does ("Resets Mon 8:00 AM").

### Removed
- The usage cache based on the OAuth login is replaced by the live-usage store; the login file is only read as a last resort and is never refreshed or rewritten.

## [1.0.0] - 2026-10-10

### Added
- First release: full-screen lock screen picture with Claude Code's Overview panel and Plan usage limits, local stats with the same definitions as `/stats`, scheduled refresh, `install` / `uninstall` / `preview` / `doctor`, JSON settings, tests and CI.
