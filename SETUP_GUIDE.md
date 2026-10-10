# Setup Guide

Everything you need to get the Claude lock screen widget running on a Windows 11 PC. Plan on about **five minutes**.

- [1. What you need](#1-what-you-need)
- [2. Install](#2-install)
- [3. Add the widget to your lock screen](#3-add-the-widget-to-your-lock-screen)
- [4. What "updates after every task" changes](#4-what-updates-after-every-task-changes)
- [5. Where the usage numbers come from](#5-where-the-usage-numbers-come-from)
- [Customising](#customising)
- [Everyday commands](#everyday-commands)
- [How the numbers are calculated](#how-the-numbers-are-calculated)
- [Troubleshooting](#troubleshooting)
- [Updating and uninstalling](#updating-and-uninstalling)
- [Sharing it with someone else](#sharing-it-with-someone-else)

---

## 1. What you need

| Requirement | How to check |
|---|---|
| Windows 11 with **lock screen widgets** (any edition, Home included) | *Settings > Personalization > Lock screen* shows a **Widgets** row |
| Windows PowerShell 5.1 | Built in. Nothing to install. |
| **Claude Code** used at least once (desktop app, terminal or IDE) | `%USERPROFILE%\.claude\projects` exists |
| A Pro / Max / Team plan (for the limit bars) | The calendar works on any plan |

You do **not** need Python, Node.js, the .NET SDK or the Windows SDK. Administrator rights are needed **once**, only to trust the widget's signing certificate.

> **Coming from version 1?** Version 1 replaced your lock screen *picture*. Version 2 does not touch it. If your lock screen still shows the generated image, open *Settings > Personalization > Lock screen > Personalize your lock screen* and click your previous picture under **Recent images**. The old behaviour is still available as `ClaudeLockWidget.ps1 lockscreen-image` if you ever want it.

## 2. Install

1. **Download** the latest release ZIP and **Extract All...** (don't run it from inside the ZIP). *Building from source instead? See [widget/README.md](widget/README.md).*
2. *(Optional)* Double-click **`preview.cmd`** to see the widget tile with your real stats. It changes nothing.
3. Double-click **`install.cmd`**. It will:
   1. copy the app to `%LOCALAPPDATA%\ClaudeLockWidget\app` (so you can delete the downloaded folder afterwards) and create `config.json`,
   2. register a small background task that keeps reset countdowns fresh (sign-in, unlock, every 10 minutes),
   3. ask **"Update the widget after every Claude task? [Y/n]"** - see [section 4](#4-what-updates-after-every-task-changes),
   4. publish the first widget image,
   5. install the widget package. Windows shows **one admin (UAC) prompt** - it only adds the widget's certificate to *Trusted People* so Windows accepts the package. The package itself installs without admin rights.
4. Continue with section 3.

If SmartScreen says *"Windows protected your PC"*, click **More info > Run anyway**. All scripts are plain text; read them first if you like.

## 3. Add the widget to your lock screen

1. Open **Settings > Personalization > Lock screen** (the installer opens it for you).
2. Under **Widgets** click **Add widget** and choose **Claude usage**.
3. Press <kbd>Win</kbd>+<kbd>L</kbd>. The widget sits in the widget row with the others (Weather, Focus session, ...).

Notes:

- Lock screen widgets are always **small** tiles and Windows lays them out (up to four). The Claude tile uses its whole area - no title bar, no inner box - for the calendar and both bars, and is the same size as Weather. Drag it up or down in the widget list to reorder.
- The picture is transparent with light text, so it sits directly on the tile like Windows' own widgets. On a **light-theme** Widgets board (<kbd>Win</kbd>+<kbd>W</kbd>) an opaque dark card version is used instead so the text stays readable.
- You can also pin it to the Widgets board (<kbd>Win</kbd>+<kbd>W</kbd>).
- The widget shows **"Waiting for the first update"** until the first data has been published - run `refresh-now.cmd` or finish a Claude task.

## 4. What "updates after every task" changes

If you answer **Y** during install (or run `integrate -Action install` later), exactly two things are added, both reversible:

| File | Change |
|---|---|
| `~/.claude/settings.json` | One async **`Stop` hook**: `powershell.exe ... ClaudeLockWidget.ps1 hook`. Claude Code runs it when it finishes responding; it does not delay Claude. A backup (`settings.json.clw-backup-<time>`) is written first and your other settings and hooks are left alone. |
| `~/.claude/CLAUDE.md` | One block between `<!-- BEGIN ClaudeLockWidget -->` and `<!-- END ClaudeLockWidget -->`. It asks Claude to call the desktop app's **`get_usage`** tool at the end of each task and pass the percentages to the widget (about two quick tool calls). |

`uninstall.cmd` (or `integrate -Action uninstall`) removes both again. `integrate -Action status` tells you what is installed.

For terminal / IDE sessions you can additionally add the **status line feed** (`integrate -Action install -StatusLine`): Claude Code then hands the widget `rate_limits` on every status line update. It is skipped automatically if you already have a custom status line.

## 5. Where the usage numbers come from

| Source | Works in | Notes |
|---|---|---|
| **Claude's push** (default) | Claude desktop app (Code tab) | After a task Claude reads `get_usage` - the same numbers as the app's usage card - and runs `push-usage`. |
| **Status line feed** (opt-in) | Terminal, IDE extensions | Claude Code passes `rate_limits.five_hour` / `seven_day` to the status line command. |
| **Usage endpoint** (`apiFallback`, off) | Anyone whose `~/.claude/.credentials.json` is current | The widget reads the token **in memory** and asks `api.anthropic.com`. The desktop app does not keep that file fresh, so this is only useful if you also use the terminal. |

The widget shows the freshest value, marks it **stale** after 6 hours (`staleAfterMinutes`), and shows a window as **0%** once its reset time has passed (until your next message starts a new one).

---

## Customising

Edit `%LOCALAPPDATA%\ClaudeLockWidget\config.json` in Notepad (paste the path into Explorer's address bar), save, then run **`refresh-now.cmd`**. Anything you leave out keeps its default; invalid values are ignored.

| Setting | Default | What it does |
|---|---|---|
| `refreshMinutes` | `10` | Background task interval (1-240). Re-run `install.cmd` after changing it. |
| `widgetWeeks` | `26` | Weeks shown in the calendar (8-52). Fewer weeks = bigger squares. |
| `statsRange` | `"all"` | Range for the headline numbers: `all`, `30d`, `7d`. The calendar always shows `widgetWeeks`. |
| `bars` | session + weekly | The usage bars, in order: `{ "key": "<name>", "label": "<text>" }`. |
| `accent` | `"#2A78D6"` | Bar colour. |
| `colorizeBars` | `true` | Bars turn amber at 75% and red at 90%. |
| `showUpdatedAt` | `true` | "Updated 9:05 AM" under the bars. |
| `staleAfterMinutes` | `360` | Age after which usage is flagged as stale. |
| `apiFallback` | `false` | Allow reading the Claude Code login file and asking Anthropic's usage endpoint when no live data exists. |
| `countMode` | `"claude-code"` | `claude-code` reproduces `/stats` exactly (every transcript line counts, which inflates tokens); `deduplicated` counts each API message once. |
| `fontFamily` | `"Segoe UI"` | Any installed font. |
| `claudeConfigDir` | `""` | Only if Claude Code's data is not in `%USERPROFILE%\.claude` (`CLAUDE_CONFIG_DIR` is honoured too). |

### Adding more usage bars

| `key` | Meaning |
|---|---|
| `five_hour` | Session limit (rolling 5-hour window) |
| `seven_day` | Weekly - all models |
| `seven_day_sonnet` | Weekly - Sonnet only |
| `seven_day_opus` | Weekly - Opus only |

```json
"bars": [
  { "key": "five_hour",        "label": "Session limit" },
  { "key": "seven_day",        "label": "Weekly - all models" },
  { "key": "seven_day_sonnet", "label": "Weekly - Sonnet only" }
]
```

A bar whose key is not in the data shows `--`. Windows labels pushed by Claude are matched by name ("Sonnet" -> `seven_day_sonnet`, "5-hour"/"session" -> `five_hour`, other "Weekly" -> `seven_day`).

*Legacy full-screen picture settings* (`position`, `background`, `scale`, ...) only matter for the `lockscreen-image` command; see `config.example.json`.

---

## Everyday commands

All double-clickable in the downloaded folder. After installing you can delete it and use `%LOCALAPPDATA%\ClaudeLockWidget\app\ClaudeLockWidget.ps1 <command>` (run through `powershell -ExecutionPolicy Bypass -File`).

| File / command | Does |
|---|---|
| `install.cmd` | Install or update (safe to repeat; keeps your settings). |
| `preview.cmd` | Render the widget tile to a PNG and open it. `-Demo` for sample data. |
| `refresh-now.cmd` | Recompute and publish to the widget immediately. |
| `doctor.cmd` | Diagnose problems (never prints tokens). |
| `uninstall.cmd` | Remove the task, hook, `CLAUDE.md` note, widget package and installed app. `-Purge` also deletes settings, cache and logs. |
| `... integrate -Action install\|uninstall\|status` | Manage the Claude Code hook + note (`-StatusLine` adds the terminal feed). |
| `... push-usage -Plan Pro -Windows "label\|percent\|resetsAt;..."` | What Claude runs after a task. |

Logs: `%LOCALAPPDATA%\ClaudeLockWidget\logs\widget.log`. The widget provider writes `provider.log`; because it runs as a packaged app Windows may redirect it to `%LOCALAPPDATA%\Packages\ClaudeLockWidget.Provider_*\LocalCache\Local\ClaudeLockWidget\logs\`.

---

## How the numbers are calculated

The six headline numbers and the calendar come from Claude Code's local transcripts (`%USERPROFILE%\.claude\projects`) with the same definitions as `/stats`:

| Number | Definition |
|---|---|
| Sessions | transcript files that start inside the range |
| Messages | every user and assistant line |
| Total tokens | input + output + cache-creation + cache-read tokens of every assistant line (so it reaches billions) |
| Active days | distinct local calendar days with a message |
| Peak hour | local hour in which most sessions started |
| Favorite model | model with the most tokens |

The calendar shades each day by its message count (three blue levels); weeks start on Sunday and the last column is the current week.

---

## Troubleshooting

**Run `doctor.cmd` first** - it names the broken piece.

| Symptom | Fix |
|---|---|
| "Claude usage" is **not in the Add widget list** | Check `doctor.cmd` says the widget package is installed. If not, run `install.cmd` again and approve the admin prompt. If it is, sign out and back in, or restart Windows Explorer, then open the Add widget list again. |
| Package install fails with **0x800B0109** / "certificate not trusted" | The admin prompt was cancelled. Right-click `widget\dist\ClaudeLockWidget.cer` > Install Certificate > Local Machine > *Place all certificates in the following store* > **Trusted People**, then run `install.cmd` again. |
| Widget says **"Waiting for the first update"** | Run `refresh-now.cmd`, or finish a Claude task. Check `%LOCALAPPDATA%\ClaudeLockWidget\widget` contains `widget-state.json`. |
| Bars show **`--`** and the footer says *No usage yet* | No source has reported yet. Finish a Claude task with the integration installed (section 4), or enable the status line feed / `apiFallback`. |
| Footer is amber: **"Usage as of ... finish a Claude task to refresh"** | The last numbers are more than 6 hours old. Finish a task, or check the `CLAUDE.md` note is still installed (`doctor.cmd`). |
| Numbers don't change after tasks | Check `integrate -Action status` shows both items installed, and that Claude has a `get_usage` tool in the session (desktop app Code tab). `widget.log` shows each `push-usage`. |
| All tiles show **0** | Claude Code stores data elsewhere (custom `CLAUDE_CONFIG_DIR`, WSL...). Set `claudeConfigDir`. |
| The tile still shows a title bar ("Claude usage") or looks small | Your Windows build ignores the empty widget header. Update Windows, then run `install.cmd` again to make sure you have the latest package (`doctor.cmd` shows its version). Please open an issue with your Windows build number. |
| Text is hard to read on the lock screen | The widget assumes the usual dark tile. If you use a very light lock screen picture, pick a darker one or tell us - the tile's own acrylic is drawn by Windows. |
| **Add widget** says a widget "does not support the required size" | That is another widget; ours declares the small size lock screen widgets need. |
| `Running scripts is disabled` | Use the `.cmd` files; they start PowerShell with `-ExecutionPolicy Bypass` for that run only. |
| Antivirus quarantines a file | The scripts are plain text. The package is signed with its own certificate (see `widget\dist\ClaudeLockWidget.cer`). Review the source or add an exclusion for `%LOCALAPPDATA%\ClaudeLockWidget`. |
| Your PC is managed (work/school) and the Widgets row is missing | An administrator controls lock screen widgets or sideloading. The widget cannot override that. |

When you open an issue, attach the output of `doctor.cmd` and the last lines of `widget.log`. **Never** paste `.credentials.json` or any token.

---

## Updating and uninstalling

- **Update:** download the new release and run `install.cmd` again. Settings are kept. The package is replaced in place.
- **Uninstall:** run `uninstall.cmd` (`-Purge` also wipes settings/cache/logs). This removes the background task, the Stop hook, the `CLAUDE.md` block, the widget package and the installed app.
  Remove the widget's certificate too if you want: `certlm.msc` > Trusted People > "ClaudeLockWidget".
  If you used version 1, set your lock screen picture back under *Recent images*.

## Sharing it with someone else

Send them the release ZIP and this guide. Nothing in it is specific to your PC: no paths, usernames or credentials are stored in the project. Each person's widget reads **their own** Claude Code statistics and usage on **their own** PC, and each person approves the one admin prompt themselves.
