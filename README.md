# Pin-Taskbar

Pin or unpin items to the Windows taskbar.

Tested **from Windows Vista to Windows 11 25H2** (Build 26200+).

---

## How is this different from other solutions?

Every other taskbar pin tool either:
- Uses `InvokeVerb('taskbarpin')` - disabled by Microsoft a long time ago
- Uses `shell:::{4234d49b-0245-4df3-b780-3893943456e1}` COM - stubbed since Windows 10 21H2
- Uses UI automation / `SendKeys` - fragile, locale-dependent, unreliable
- Modifies `LayoutModification.xml` - requires an `explorer.exe` restart to take effect

This tool writes directly to the taskbar's internal data structures with proper synchronization, producing results indistinguishable from a native pin operation. No restart, no flicker, instant.

Starting with v1.6, the behavior is now identical to Windows (99% certain).
Even better: you can pin **anything**, including what Explorer itself refuses to pin (any file, folder, Control Panel applet `.cpl`, console `.msc`, etc.). Since v1.7, these pins also survive being updated.
If you have used a previous version, it is recommended that you run `Pin-Taskbar.ps1 -Repair`.


## Features

- **Pin** any file, application or folder to the taskbar
- **Unpin** supported
- **Repair** - checks every pinned item and repairs the malformed ones
- **AllUsers** mode - propagate pins across all user profiles and the Default profile (requires elevation, works from the SYSTEM account)
- Multiple input (Semicolon-delimited) / wildcard supported
- UWP apps via AUMID, `shell:AppsFolder\`, or `uwp:` prefix
- Special support for `.msc` and `.cpl` files (proper icon display)
- PowerShell 2.0+ compatible

## Which file to use

| File | Kind | Best for | What it offers |
|---|---|---|---|
| `Pin-Taskbar.ps1` | Standalone script | Command line, deployment tools, GPO logon scripts | Everything: pin, unpin, `-AllUsers`, `-Repair`, `-LogFile`, exit codes, `Get-Help` |
| `Pin-Taskbar.bat` | Standalone script (Batch/PowerShell hybrid) | Same, where the execution policy blocks `.ps1` files | Same as `Pin-Taskbar.ps1`; run it from `cmd`, a double-click or any tool that runs batch files |
| `Set-TaskbarPin.ps1` | PowerShell function | Your own scripts and modules: dot-source it (`. .\Set-TaskbarPin.ps1`) or paste it into your console or script, then call `Set-TaskbarPin` | Pin, unpin, `-AllUsers`, `-Silent`. No `-Repair` (the items it pins are still repaired), no `-LogFile`, no exit codes |

## Usage

### Pin

```powershell
# Pin by path
.\Pin-Taskbar.ps1 "C:\Windows\notepad.exe"

# Pin multiple items
.\Pin-Taskbar.ps1 "C:\App1.lnk;C:\App2.exe;C:\Tools\util.exe"

# Pin by name (resolved via PATH env)
.\Pin-Taskbar.ps1 "notepad"

# Pin a UWP app by AUMID
.\Pin-Taskbar.ps1 "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"

# Pin a UWP app by name
.\Pin-Taskbar.ps1 "UWP:copilot"

# Pin with wildcard
.\Pin-Taskbar.ps1 "C:\Tools\*.exe"

# Pin an MSC and a CPL applet
.\Pin-Taskbar.ps1 "C:\Windows\System32\services.msc;C:\Windows\System32\main.cpl"

# Pin for all users (requires admin)
.\Pin-Taskbar.ps1 "notepad" -AllUsers

# Silent with log
.\Pin-Taskbar.ps1 "notepad" -Silent -LogFile "C:\Temp\pin.log"
```

### Unpin

```powershell
# Unpin by name
.\Pin-Taskbar.ps1 -Unpin "Notepad*"

# Unpin for all users
.\Pin-Taskbar.ps1 -Unpin "Notepad*" -AllUsers

# Unpin everything
.\Pin-Taskbar.ps1 -Unpin * -AllUsers
```

### Repair

```powershell
# Check every pinned item and repair the malformed ones
.\Pin-Taskbar.ps1 -Repair

# Repair for all users (requires admin)
.\Pin-Taskbar.ps1 -Repair -AllUsers

# Repair, then pin
.\Pin-Taskbar.ps1 "notepad" -Repair
```

### Via the .bat hybrid

```batch
Pin-Taskbar.bat "notepad"
Pin-Taskbar.bat "C:\App1.lnk;C:\App2.exe" -AllUsers
Pin-Taskbar.bat -Unpin "Notepad*"
Pin-Taskbar.bat -Repair
Pin-Taskbar.bat -help
```

### As a function

```powershell
Set-TaskbarPin "notepad"
Set-TaskbarPin -Unpin "Calculator*" -AllUsers
Set-TaskbarPin "C:\Windows\System32\main.cpl" -Silent
```

## Parameters

| Parameter | Aliases | Description |
|---|---|---|
| `-Pin` | `-Path`, `-File`, `-Files` | First positional argument. Path(s) to pin: `.lnk`, `.exe`, `.msc`, `.cpl`, directories, application names, UWP AUMIDs. Semicolon-delimited (`;;` for a semicolon inside an item), wildcards supported. A bare name pins one application (exact display name first); a wildcard pins every match. |
| `-Unpin` | `-Remove` | Switch. Turns `-Pin` into a match pattern for removal. |
| `-Repair` | `-Fix` | Switch. Checks every pinned item and repairs the malformed ones (extension blocks, AppID, resolve records, entries whose shortcut is gone or listed twice, a second pin of the same application), and the pins earlier versions left fragile or damaged. Can be combined with `-Pin` or `-Unpin`. Standalone scripts only. |
| `-Silent` | `-S` | Suppresses console output. The log file is not affected. |
| `-LogFile` | `-Log` | Path to a `.txt` or `.log` file for detailed logging. Standalone scripts only. |
| `-AllUsers` | `-Everyone`, `-All` | Applies the operation to every user profile and to the Default profile (users created later). Requires elevation; also works from the SYSTEM account (deployment tools, startup scripts). |

## Exit codes (standalone script and .bat only)

| Code | Meaning |
|---|---|
| `0` | Success |
| `2` | Nothing found to pin/unpin/repair |
| `3` | Failure: an error, or an item that could not be pinned or unpinned |

## Requirements

- PowerShell 2.0+ (ships with Windows 7+)
- Administrator rights only required for `-AllUsers`

---

## License

Free for personal use, internal tooling, and non-commercial projects.

**For commercial use**, or business/enterprise context, a paid license is available. It includes:
- Reverse engineering *documentation.md* (3k lines) covering how DLL files related to the taskbar work (blob format, COM vtables, notification chains, WFC gating, PIDL structures, etc.)
- Support within reasonable limits

Contact: **freenitial@gmail.com**
