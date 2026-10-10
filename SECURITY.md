# Security and privacy

Claude Lock Widget runs on your PC, reads your Claude Code activity, and (with your consent) edits two Claude Code files. This page lists exactly what it touches so you can verify it by reading the (short, plain-text) source.

## What it reads

| Data | Where | Used for | Leaves your PC? |
|---|---|---|---|
| Transcript metadata: timestamps, model name, token counts | `%USERPROFILE%\.claude\projects\**\*.jsonl` | the headline numbers and the calendar | **No** |
| Plan usage percentages and reset times | pushed by Claude (`get_usage`), the status line, or the usage endpoint | the usage bars | **No** |
| Claude Code OAuth token | `%USERPROFILE%\.claude\.credentials.json` (or `CLAUDE_CODE_OAUTH_TOKEN`) | **only if you set `apiFallback` to `true`** (default `false`): one `GET https://api.anthropic.com/api/oauth/usage` | Token goes **only** to `api.anthropic.com` over HTTPS |

Transcript lines are parsed in memory to read those metadata fields. Prompt and response text is never stored, logged or transmitted. The per-file cache contains only per-day counters and token sums.

## What it writes

- `%LOCALAPPDATA%\ClaudeLockWidget\` - settings, per-day counters, last usage percentages, the widget tile PNGs (newest four) and a size-capped log
- one per-user Scheduled Task `ClaudeLockWidget` (no elevation)
- the widget package `ClaudeLockWidget.Provider` (per user), and its signing certificate in the machine's *Trusted People* store (the one step needing admin rights)
- **only if you agree during install:** one async `Stop` hook in `~/.claude/settings.json` (a timestamped backup is written first, at most three kept) and one marked block in `~/.claude/CLAUDE.md`. Both are removed by `uninstall.cmd` / `integrate -Action uninstall`.

The access token is **never** written to the log, cache, config, state file or any image. The widget never refreshes, rotates or modifies your Claude Code credentials.

## About the widget certificate

The package is signed with a **self-signed** certificate (`CN=ClaudeLockWidget`) that you trust once. Trusting it in *Trusted People* lets Windows install packages signed with the matching private key. If you build the package yourself, the private key lives in your own `CurrentUser\My` store and never leaves your PC; releases use the maintainer's certificate. If you do not want to keep trusting it after installing, remove it in `certlm.msc` (Trusted People > ClaudeLockWidget) - the installed widget keeps working, but updates will need the certificate again.

## About the CLAUDE.md note

The block in `CLAUDE.md` is an instruction for Claude: call `get_usage` and run one local command after each task. It contains no secrets. Because it changes Claude's behaviour in **every** session, it is optional, clearly marked, and removable at any time. Review it: `integrate -Action status` shows whether it is installed, and the text is in `src/lib/Integration.ps1` (`Get-ClwClaudeMdBlock`).

## What it does not do

No telemetry, analytics, auto-update or remote code. No network calls in the default configuration. Administrator rights are used for exactly one thing: trusting the widget certificate.

## Things to be aware of

- The lock screen is visible to anyone who can see your monitor. The widget shows usage totals and percentages (not prompts, code or account identifiers).
- The usage endpoint (fallback only) is undocumented and may change or rate-limit requests; the widget treats any failure as "unknown" and keeps the last good values.
- `.credentials.json` is stored by Claude Code in plain text in your profile, with or without this tool. Protect your profile as you normally would.

## Reporting a vulnerability

Please open a **private security advisory** on the repository (Security > Report a vulnerability) rather than a public issue. Include steps to reproduce and your Windows build. We aim to respond within a few days.
