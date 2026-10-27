# Cleanup-Windows.bat

A single, self-contained batch file that reclaims space on the Windows system drive. Copy it to any Windows 10 or 11 machine and double-click it. It detects what is present on that machine and cleans by fixed rules. There are no hardcoded paths and no machine-specific logic.

It exists because the usual tools miss the biggest offenders. Disk Cleanup and Storage Sense never touch the DriverStore, where every GPU driver update leaves the previous 1.5 to 2.6 GB package staged. On a typical Lenovo developer laptop that alone was 28 GB, with another 30 GB in vendor installer caches, NVIDIA model sets and package-manager caches.

## Quick start

```
Cleanup-Windows.bat -DryRun       preview everything it would remove, deletes nothing, no admin needed
Cleanup-Windows.bat               run the standard cleanup, prompts for admin via UAC
```

Reboot afterwards. DriverStore and WinSxS space is released on restart.

A timestamped `cleanup-*.log` is written next to the batch file. Keep the file somewhere outside `C:\Users\<you>\AppData\Local\Temp`, because that folder is one of the things it empties.

## All options

| Option | Effect |
|---|---|
| `-DryRun` | List every item with its size. Nothing is deleted. Runs without elevation. |
| `-Report` | Write `space-report.txt` with the largest folders at each level and the 50 largest files on the drive. No cleanup. Takes a few minutes. |
| `-IncludeOptional` | Also run tier C (see below). |
| `-SkipDevCaches` | Leave package-manager caches alone. |
| `-SkipBrowsers` | Leave browser and Electron-app caches alone. |
| `-ResetBase` | Deeper WinSxS cleanup. Installed Windows updates can no longer be uninstalled afterwards. |
| `-DisableHibernation` | Turn hibernation off, which deletes `hiberfil.sys`. |
| `-LimitShadowStorageGB <n>` | Cap System Restore storage on the system drive to `n` GB. |
| `-StaleLogDays <n>` | Age threshold for deleting large log files. Default 30. |

Options combine, for example `Cleanup-Windows.bat -DryRun -IncludeOptional`.

## What it removes

### Tier A: always

| Area | Rule |
|---|---|
| Driver packages | For every third-party INF with more than one staged version, keep the newest and delete the rest with `pnputil /delete-driver`. The force flag is never used, so Windows refuses any package a device is still using. |
| Windows leftovers | `Windows\Temp`, downloaded Windows Update payloads, `MEMORY.DMP`, minidumps, live kernel reports, archived CBS logs older than 7 days, Windows Error Reporting queue and archive, `$WINDOWS.~WS`, `ESD`. |
| Vendor caches | Downloaded installers and update repositories left behind by the NVIDIA App, GeForce Experience, Lenovo Vantage and System Update, Dell Update and SupportAssist, HP Support, Adobe ARM, Chocolatey. Also the `C:\NVIDIA` and `C:\AMD` driver extraction folders. |
| NVIDIA Broadcast models | When per-feature model sets exist, delete the legacy monolithic set and keep only the newest version of each family. NGX re-downloads on demand. |
| Stale logs | Any `*.log`, `*.etl` or `*.trace` over 100 MB under ProgramData or a profile's AppData that has not been written for 30 days. Event logs and System32 are excluded. |
| Per profile | User Temp, crash dumps, error reports, IE and WebView cache, RDP bitmap cache, Direct3D, NVIDIA, AMD and Intel shader caches, Squirrel updater payloads, Teams temp. |
| Superseded versions | Keep the newest and delete older: Squirrel app packages (GitHub Desktop and similar), Zoom version folders that do not match the installed `Zoom.exe`, Playwright browser builds per family, Claude Code builds and installers, Codex CLI builds, abandoned plugin staging folders, staged installers. |
| Housekeeping | Empty Recycle Bin on all drives, clear Delivery Optimization cache, run `DISM /StartComponentCleanup`, run Disk Cleanup with every category enabled including previous Windows installations. |

### Tier B: on by default, skip with `-SkipDevCaches` or `-SkipBrowsers`

| Area | Rule |
|---|---|
| Package managers | Caches for uv, pip, npm, npx, yarn, pnpm, NuGet, Gradle, Cargo, Go, Composer, Poetry, conda, electron, electron-builder, Cypress, node-gyp, pre-commit, puppeteer. These rebuild on the next install. |
| Browsers | Cache, Code Cache, GPU and shader caches, service-worker cache, version snapshots and component cache for Chrome, Edge, Brave, Chromium, Vivaldi, Opera and Firefox. Only when that browser is not running. History, cookies, passwords and extensions are untouched. |
| Electron apps | The same cache folders for VS Code, Cursor, Windsurf, Slack, Discord, Postman, Obsidian, Notion, Figma, Teams and Spotify. Only when that app is not running. |

### Tier C: only with `-IncludeOptional`

Visual Studio Installer package cache, Windows Installer `$PatchCache$`, OEM driver extraction folders (`C:\DRIVERS`, `C:\Dell`, `C:\swsetup`, `C:\SWTOOLS`), nvm Node versions other than the active one, Claude Desktop warm VM image, Pearson OnVUE exam browser, Office upload cache.

## What it never touches

Program Files, user documents and desktop, OneDrive, Docker and WSL virtual disks, Hugging Face and Ollama model stores, the Windows Installer database, antivirus and device-management agents such as McAfee and ManageEngine. Those last ones are listed in the log under "reported only" with their sizes so you can raise them with whoever owns them.

## How it works

The file is a batch and PowerShell polyglot. The first lines are a batch launcher wrapped in a PowerShell block comment. `cmd.exe` runs the launcher, which checks for administrator rights, re-launches itself through UAC when needed, and then hands the whole file to PowerShell as a script block. PowerShell skips the launcher because it sits inside `<# ... #>`. `-DryRun` and `-Report` run without elevation.

Inside the PowerShell part:

- **Discovery.** Every profile under `C:\Users` with an `NTUSER.DAT` is cleaned, not just the current user. Every path in the rule tables is tested first and silently skipped when absent.
- **Sizing.** Folder sizes come from `robocopy /L`, which handles long paths and junctions and is far faster than `Get-ChildItem -Recurse` on large trees.
- **Deletion.** Folders are emptied by mirroring an empty directory over them with `robocopy /MIR`, which copes with paths over 260 characters and trees with hundreds of thousands of files. Locked files are left in place and the log says how much remains.
- **Driver matching.** Each superseded `oemNN.inf` is matched to its DriverStore folder by comparing the MD5 of `C:\Windows\INF\oemNN.inf` with the INF inside each candidate folder, so the log reports the true size of every package before it is removed.
- **Accounting.** Every item is measured before and after, and the summary reports the total reclaimed and the free-space change.

The script is plain PowerShell 5.1 with no modules or downloads, so it runs on a stock Windows install.

## Testing it on a new machine

1. Copy the file to a folder outside the user profile, for example `D:\Tools`.
2. Run `Cleanup-Windows.bat -Report` and look at `space-report.txt` to see where the space is.
3. Run `Cleanup-Windows.bat -DryRun` and read the list.
4. Run `Cleanup-Windows.bat`, then reboot.
5. Compare free space before and after. The log has both numbers in its last lines.
