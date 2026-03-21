# Pin-Taskbar

Pin or unpin items to the Windows taskbar.

Tested **from Windows Vista to Windows 11 25H2** (Build 26200+).

---

## How is this different from other solutions?

Every other taskbar pin tool either:
- Uses `InvokeVerb('taskbarpin')` - disabled by Microsoft a long time ago
- Uses `IPinnedList3` COM - stubbed on recent Windows versions
- Uses UI automation / `SendKeys` - fragile, locale-dependent, unreliable
- Modifies `LayoutModification.xml` - requires an `explorer.exe` restart to take effect

This tool writes directly to the taskbar's internal data structures with proper synchronization, producing results indistinguishable from a native pin operation. No restart, no flicker, instant.


## Features

- **Pin** any file, application or folder to the taskbar
- **Unpin** supported
- **AllUsers** mode - propagate pins across all user profiles (requires elevation)
- Multiple input (Semicolon-delimited) / wildcard supported
- UWP apps via AUMID, `shell:AppsFolder\`, or `uwp:` prefix
- Special support for `.msc` and `.cpl` files (proper icon display)
- PowerShell 2.0+ compatible

## Three ways

| File | Format | Use case |
|---|---|---|
| `Pin-Taskbar.ps1` | Standalone PowerShell script | Command-line / deployment / GPO logon scripts. Supports `-LogFile` and returns exit codes. |
| `Pin-Taskbar.bat` | Batch/PowerShell hybrid | Same as above, but bypasses PowerShell execution policy restrictions. |
| `Set-TaskbarPin.ps1` | PowerShell function | Compact. Import into modules, call/integrate in other scripts. |

## Usage

### Pin

```powershell
# Pin by path
.\Pin-Taskbar.ps1 "C:\Windows\notepad.exe"

# Pin multiple items
.\Pin-Taskbar.ps1 "C:\App1.lnk;C:\App2.exe;C:\Tools\util.exe"

# Pin by name (resolved via PATH env)
.\Pin-Taskbar.ps1 "notepad"

# Pin a UWP app
.\Pin-Taskbar.ps1 "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"

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
```

### Via the .bat hybrid

```batch
Pin-Taskbar.bat "notepad"
Pin-Taskbar.bat "C:\App1.lnk;C:\App2.exe" -AllUsers
Pin-Taskbar.bat -Unpin "Notepad*"
Pin-Taskbar.bat -help
```

### As a function

```powershell
Set-TaskbarPin "notepad"
Set-TaskbarPin -Unpin "Calculator*" -AllUsers
Set-TaskbarPin "C:\Windows\System32\main.cpl" -Silent
```

## Parameters

| Parameter | `.ps1` / `.bat` | Function | Description |
|---|---|---|---|
| `-Pin` | Yes | Yes | Path(s) to pin. Supports `.lnk`, `.exe`, `.msc`, `.cpl`, UWP AUMIDs, directories. Semicolon-delimited. |
| `-Unpin` | Yes | Yes | Switch. Turns `-Pin` into a match pattern for removal. |
| `-Silent` | Yes | Yes | Suppresses console output. |
| `-LogFile` | Yes | No | Path to a `.txt` or `.log` file for detailed logging. |
| `-AllUsers` | Yes | Yes | Applies operation to all user profiles. Requires elevation. |

## Exit codes (standalone script and .bat only)

| Code | Meaning |
|---|---|
| `0` | Success |
| `2` | Nothing found to pin/unpin |
| `3` | Operation failed |

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
