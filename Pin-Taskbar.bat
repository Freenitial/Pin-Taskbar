<# ::
    @echo off & setlocal

    for %%A in ("" "/?" "-?" "--?" "/help" "-help" "--help") do if /I "%~1"=="%%~A" set "help=true"
    
    if exist %SystemRoot%\system32\WindowsPowerShell\v1.0\powershell.exe   set "powershell=%SystemRoot%\system32\WindowsPowerShell\v1.0\powershell.exe"
    if exist %SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe  set "powershell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    if not exist "%powershell%" set "powershell=powershell"

    set args=%*
    if defined args set args=%args:^=^^%
    if defined args set args=%args:<=^<%
    if defined args set args=%args:>=^>%
    if defined args set args=%args:&=^&%
    if defined args set args=%args:|=^|%
    if defined args set "args=%args:"=\"%"
    
    :: PowerShell self-read, skipping batch part
    if defined help (
        %powershell% -NoLogo -NoProfile -Command "$n=[IO.Path]::GetFileName('%~f0');$sb=[ScriptBlock]::Create([IO.File]::ReadAllText('%~f0'));Set-Item function:$n $sb;Get-Help $n" 
        pause & endlocal & exit /b
    )
    %powershell% -NoLogo -NoProfile -Command "Set-Location $([IO.Path]::GetDirectoryName('%~f0'));$sb=[ScriptBlock]::Create([IO.File]::ReadAllText('%~f0'));& $sb @args" %args%
    endlocal & exit /b %errorlevel%
#>

<#
.SYNOPSIS
    Pin or unpin shortcuts from the Windows taskbar programmatically.
    Version 1.6
.DESCRIPTION
    Pins or unpins items to/from the Windows taskbar across all Windows versions.

    PIN strategy :
      - Modern (Win7+) : writes a binary blob entry with a BEEF001D extension block directly
        into the Taskband registry (the only reliable method on Windows 11 where COM pin APIs
        are stubbed out), with its FavoritesResolve record, then notifies the taskbar by
        posting 0x446 to its pinned-items band.
      - Legacy (Vista) : copies a .lnk shortcut into the Quick Launch directory.
      - An item already pinned is updated in place (target, icon, name kept) and its entry
        repaired when malformed. A name already used by another application's pin gets
        ' (2)', ' (3)'..., as Windows does.

    UNPIN strategy :
      - Removes matching entries from the Taskband registry blob, deletes the .lnk files,
        and notifies the taskbar. On Vista, deletes the matching Quick Launch shortcuts.

    REPAIR : checks every pinned item and repairs the malformed ones, resolve records included.

    When -AllUsers is specified, the script loads each user's offline registry hive
    (NTUSER.DAT) and replicates the operation across all profiles, the Default profile
    included. Run from an account without a taskbar (SYSTEM : deployment tools, startup
    scripts), it pins for those profiles only.
.PARAMETER Pin
    Path to .lnk/.exe/.msc/.cpl, directory, bare application name, or shell:AppsFolder
    identifier. Supports semicolons and wildcards. A doubled semicolon ';;' escapes a
    literal semicolon inside an item (some AUMIDs contain one). A bare application name
    resolves to a single application : exact display-name match first, otherwise an
    elimination cascade narrows the substring matches down to one. An explicit wildcard
    matches display names and AUMIDs and pins every match.
.PARAMETER Unpin
    Triggers unpin mode. -Pin becomes a match pattern.
.PARAMETER Repair
    Checks every pinned item and repairs the malformed ones (extension blocks, AppID,
    FavoritesResolve records, entries whose shortcut is gone or listed twice). Can be
    combined with -Pin or -Unpin.
.PARAMETER Silent
    Suppresses all console output. Log file output is not affected.
.PARAMETER LogFile
    Path to a log file. Must end with .txt or .log.
.PARAMETER AllUsers
    Applies the operation to every user profile and to the Default profile, from which users
    created later get theirs (requires elevation; works from the SYSTEM account).
.EXAMPLE
    .\Pin-Taskbar "C:\Users\John\Desktop\MyApp.lnk"
    .\Pin-Taskbar "C:\Windows\regedit.exe;C:\MyFolder" -AllUsers
    .\Pin-Taskbar "shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
    .\Pin-Taskbar "uwp:Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
    .\Pin-Taskbar "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
    .\Pin-Taskbar "C:\App1.lnk;C:\App2.lnk;C:\App3.exe"
    .\Pin-Taskbar "notepad" -logfile C:\Windows\Temp\TaskbarPin.log
    .\Pin-Taskbar "C:\Tools\*.exe"
    .\Pin-Taskbar -Unpin "Notepad*" -AllUsers
    .\Pin-Taskbar "C:\MyApp.lnk" -LogFile "C:\Temp\pin.log" -Silent
    .\Pin-Taskbar "C:\Windows\System32\services.msc;C:\Windows\System32\main.cpl"
    .\Pin-Taskbar -Repair
.NOTES
    Exit codes : 0 = Success, 2 = Nothing found to pin/unpin/repair, 3 = Failure (an error,
    its message logged, or an item that could not be pinned or unpinned).
    Compatible with PowerShell 2.0+ (.NET 2.0+).
#>
param(
    [Parameter(Position = 0)]
    [Alias('Path', 'File', 'Files')][string]$Pin,
    [Alias('Remove')]               [switch]$Unpin,
    [Alias('Fix')]                  [switch]$Repair,
    [Alias('S')]                    [switch]$Silent,
    [Alias('Log')]                  [string]$LogFile,
    [Alias('Everyone', 'All')]      [switch]$AllUsers
)
$ErrorActionPreference = 'Stop'


#region LOGGING

# Write-Log : log file and console; Write-Console : console only; Write-Banner : both.
# SuppressLogToConsole keeps log lines out of a pending -NoNewline progress line.
$LogFileStreamWriter = $null
$script:SuppressLogToConsole = $false

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $FormattedLogLine = "[$([DateTime]::Now.ToString('HH:mm:ss.fff'))] $Message"
    if (-not $Silent -and -not $script:SuppressLogToConsole) { Write-Host $FormattedLogLine -ForegroundColor $Color }
    if ($LogFileStreamWriter) { $LogFileStreamWriter.WriteLine($FormattedLogLine) }
}

function Write-Console {
    param([string]$Message, [string]$Color = 'White', [switch]$NoNewline, [string]$BackgroundColor)
    if ($Silent) { return }
    $WriteHostParams = @{ Object = $Message; ForegroundColor = $Color }
    if ($NoNewline)       { $WriteHostParams['NoNewline'] = $true }
    if ($BackgroundColor) { $WriteHostParams['BackgroundColor'] = $BackgroundColor }
    Write-Host @WriteHostParams
    $script:SuppressLogToConsole = [bool]$NoNewline
}

function Write-Banner {
    param([string]$Label, [string]$LabelBackground, [string]$Detail)
    if (-not $Silent) {
        Write-Host ""
        Write-Host "  $Label  " -ForegroundColor White -BackgroundColor $LabelBackground -NoNewline
        Write-Host "  $Detail"
        Write-Host ""
    }
    if ($LogFileStreamWriter) { $LogFileStreamWriter.WriteLine("[$([DateTime]::Now.ToString('HH:mm:ss.fff'))] === $Label : $Detail ===") }
}

# This run's temporary shortcuts : one folder for the run, one subfolder per shortcut (two
# items may give shortcuts of the same name).
$script:TemporaryShortcutRoot  = [IO.Path]::Combine([IO.Path]::GetTempPath(), "Pin-Taskbar-$PID")
$script:TemporaryShortcutCount = 0
function Get-TemporaryShortcutPath {
    param([string]$ShortcutFileName)
    $script:TemporaryShortcutCount++
    $TemporaryShortcutDirectory = [IO.Path]::Combine($script:TemporaryShortcutRoot, [string]$script:TemporaryShortcutCount)
    $null = [IO.Directory]::CreateDirectory($TemporaryShortcutDirectory)
    return [IO.Path]::Combine($TemporaryShortcutDirectory, $ShortcutFileName)
}

# Ends the run : closes the log file and removes the temporary shortcuts.
function Complete-Run {
    if ($LogFileStreamWriter) { $LogFileStreamWriter.Close() }
    if ($script:TemporaryShortcutCount -gt 0) { try { [IO.Directory]::Delete($script:TemporaryShortcutRoot, $true) } catch { } }
}
# Any unexpected error ends the run with exit code 3, its message logged.
trap {
    if ($script:SuppressLogToConsole) { Write-Host '' }
    $script:SuppressLogToConsole = $false
    Write-Log "ERROR : $($_.Exception.Message)" 'Red'
    Complete-Run
    exit 3
}
# Absolute path : .NET resolves relative paths against the process directory, not $PWD.
if ($LogFile) {
    if ($LogFile -notmatch '\.(txt|log)$') { Write-Log "ERROR : -LogFile must end with .txt or .log" 'Red'; exit 3 }
    $LogFile = [IO.Path]::GetFullPath([IO.Path]::Combine($PWD.ProviderPath, $LogFile))
    $LogFileParentDirectory = [IO.Path]::GetDirectoryName($LogFile)
    if (-not [IO.Directory]::Exists($LogFileParentDirectory)) { $null = [IO.Directory]::CreateDirectory($LogFileParentDirectory) }
    $LogFileStreamWriter = New-Object System.IO.StreamWriter($LogFile, $false, [System.Text.Encoding]::UTF8)
    $LogFileStreamWriter.AutoFlush = $true
}

# Logs the operation header lines shared by the PIN, UNPIN and REPAIR flows.
function Write-OperationLogHeader {
    param([string]$OperationName, [string]$InputDetail)
    Write-Log "--- $OperationName operation starting ---"
    Write-Log "Input : $InputDetail"
    Write-Log "AllUsers : $AllUsers | Windows build : $WindowsBuildNumber$(if ($TaskbarUsesQuickLaunch) { ' (Quick Launch)' }) | Primary user : $EffectivePrimaryUserSID (pin list : $PrimaryUserHasPinList)"
    Write-Log "TaskBar directory : $TaskBarPinnedDirectory (exists : $TaskBarDirectoryExists)"
    Write-Log "QuickLaunch directory : $QuickLaunchDirectory (exists : $QuickLaunchDirectoryExists)"
    Write-Log "TaskBand registry key : $TaskBandRegistrySubKey (exists : $TaskBandRegistryKeyExists)"
    if ($IsRunningCrossUser) { Write-Log "Cross-user elevation : True (interactive SID : $InteractiveSessionUserSID, roaming AppData : $PrimaryRoamingAppDataDirectory)" }
}


#region ENVIRONMENT

# Returns $true when the given subkey exists under the given registry root.
function Test-RegistrySubKeyExists {
    param($RegistryRootKey, [string]$RegistrySubKeyPath)
    $ProbeHandle = $null
    try { $ProbeHandle = $RegistryRootKey.OpenSubKey($RegistrySubKeyPath, $false) } catch { }
    if ($ProbeHandle) { $ProbeHandle.Close(); return $true }
    return $false
}

# Account SIDs whose profile has a taskbar : local and domain accounts (S-1-5-21-...) and
# Microsoft Entra ID accounts (S-1-12-1-...). Service accounts, the '.bak' key of a profile
# Windows could not load and hives loaded under other names never match.
$UserAccountSidPattern = '^S-1-(5-21|12-1)(-\d+)+$'

# Filesystem and registry locations of the taskbar pin state.
$TaskBarRelativeAppDataPath     = 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
$QuickLaunchRelativeAppDataPath = 'Microsoft\Internet Explorer\Quick Launch'
$TaskBarRelativeProfilePath     = "AppData\Roaming\$TaskBarRelativeAppDataPath"
$QuickLaunchRelativePath        = "AppData\Roaming\$QuickLaunchRelativeAppDataPath"
$TaskBandRegistrySubKey         = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
# Registry value type constants used throughout blob read/write operations.
$DoNotExpandRegistryOption  = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
$BinaryRegistryValueKind    = [Microsoft.Win32.RegistryValueKind]::Binary
$DwordRegistryValueKind     = [Microsoft.Win32.RegistryValueKind]::DWord
# The build from the registry : Environment.OSVersion reports 6.2.9200 to a host not
# manifested for Windows 8.1 and later. Vista (before build 7600) pins to Quick Launch.
$WindowsBuildNumber = [Environment]::OSVersion.Version.Build
$CurrentVersionRegistryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion')
if ($CurrentVersionRegistryKey) {
    $RegistryBuildNumber = 0
    if ([int]::TryParse([string]$CurrentVersionRegistryKey.GetValue('CurrentBuildNumber', ''), [ref]$RegistryBuildNumber)) { $WindowsBuildNumber = $RegistryBuildNumber }
    $CurrentVersionRegistryKey.Close()
}
$TaskbarUsesQuickLaunch        = $WindowsBuildNumber -lt 7600
$CurrentWindowsIdentity        = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentUserSecurityIdentifier = $CurrentWindowsIdentity.User.Value

# The primary user, whose taskbar is pinned : this process's account or, under cross-user
# elevation (RunAs under another account, HKCU and %APPDATA% then being the elevated
# account's), the session's user, whose hive holds a Volatile Environment subkey for this
# session. Its APPDATA value is that session's roaming folder, a redirected one included.
$IsRunningCrossUser             = $false
$InteractiveSessionUserSID      = $null
$EffectivePrimaryUserSID        = $CurrentUserSecurityIdentifier
$PrimaryRoamingAppDataDirectory = [Environment]::GetFolderPath('ApplicationData')
$CurrentProcessSessionId        = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
foreach ($CandidateSidKeyName in [Microsoft.Win32.Registry]::Users.GetSubKeyNames()) {
    if ($CandidateSidKeyName -notmatch $UserAccountSidPattern) { continue }
    if (Test-RegistrySubKeyExists ([Microsoft.Win32.Registry]::Users) "$CandidateSidKeyName\Volatile Environment\$CurrentProcessSessionId") { $InteractiveSessionUserSID = $CandidateSidKeyName; break }
}
if ($InteractiveSessionUserSID -and $InteractiveSessionUserSID -ne $CurrentUserSecurityIdentifier) {
    $IsRunningCrossUser             = $true
    $EffectivePrimaryUserSID        = $InteractiveSessionUserSID
    $PrimaryRoamingAppDataDirectory = ''
    $VolatileEnvironmentKey = [Microsoft.Win32.Registry]::Users.OpenSubKey("$InteractiveSessionUserSID\Volatile Environment")
    if ($VolatileEnvironmentKey) {
        $PrimaryRoamingAppDataDirectory = [string]$VolatileEnvironmentKey.GetValue('APPDATA', '')
        $VolatileEnvironmentKey.Close()
    }
    if (-not $PrimaryRoamingAppDataDirectory) {
        $ProfileListKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$InteractiveSessionUserSID")
        if ($ProfileListKey) {
            $InteractiveUserProfilePath = [string]$ProfileListKey.GetValue('ProfileImagePath', '')
            $ProfileListKey.Close()
            if ($InteractiveUserProfilePath) { $PrimaryRoamingAppDataDirectory = [IO.Path]::Combine($InteractiveUserProfilePath, 'AppData\Roaming') }
        }
    }
}
# Without the primary user's roaming folder, the pin directories stay unset : nothing is
# written in another account's.
$TaskBarPinnedDirectory = ''
$QuickLaunchDirectory   = ''
if ($PrimaryRoamingAppDataDirectory) {
    $TaskBarPinnedDirectory = [IO.Path]::Combine($PrimaryRoamingAppDataDirectory, $TaskBarRelativeAppDataPath)
    $QuickLaunchDirectory   = [IO.Path]::Combine($PrimaryRoamingAppDataDirectory, $QuickLaunchRelativeAppDataPath)
}

# The primary user's pin list : the TaskBar directory and the Taskband key, which an account
# without a taskbar (SYSTEM) does not have.
$TaskBarDirectoryExists     = [IO.Directory]::Exists($TaskBarPinnedDirectory)
$QuickLaunchDirectoryExists = [IO.Directory]::Exists($QuickLaunchDirectory)
$TaskBandRegistryKeyExists  = if ($IsRunningCrossUser) { Test-RegistrySubKeyExists ([Microsoft.Win32.Registry]::Users) "$EffectivePrimaryUserSID\$TaskBandRegistrySubKey" } else { Test-RegistrySubKeyExists ([Microsoft.Win32.Registry]::CurrentUser) $TaskBandRegistrySubKey }
$PrimaryUserHasPinList      = -not $TaskbarUsesQuickLaunch -and $TaskBarDirectoryExists -and $TaskBandRegistryKeyExists


#region INPUT VALIDATION

# Split the input on ';' (';;' is a literal semicolon), then turn 'uwp:' prefixes and bare
# AUMIDs (containing !) into 'shell:AppsFolder\' items.
$LiteralSemicolonSentinel = [string][char]1
$ParsedInputItems = @("$Pin".Replace(';;', $LiteralSemicolonSentinel) -split ';' | ForEach-Object { $_.Replace($LiteralSemicolonSentinel, ';').Trim() } | Where-Object { $_ })
if ($ParsedInputItems.Count -eq 0 -and -not $Repair) {
    Write-Log "ERROR : Specify -Pin" -Color Red
    Complete-Run; exit 3
}
$ParsedInputItems = @($ParsedInputItems | ForEach-Object {
    if     ($_.StartsWith('uwp:', [StringComparison]::OrdinalIgnoreCase))              { 'shell:AppsFolder\' + $_.Substring(4) }
    elseif ($_.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase)) { 'shell:AppsFolder\' + $_.Substring(17) }
    elseif ($_ -match '!' -and $_ -notmatch '[/\\]')                                   { 'shell:AppsFolder\' + $_ }
    else                                                                               { $_ }
})


#region ELEVATION CHECK

function Test-IsAdmin {
    $CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal($CurrentWindowsIdentity)
    return $CurrentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if ($AllUsers -and -not (Test-IsAdmin)) {
    Write-Log "ERROR : -AllUsers requires elevation (run as Administrator)" -Color Red
    Complete-Run; exit 3
}


#region NATIVE HELPER

# Compiles the C# interop classes :
#   TaskbandPinList                    : Favorites entries and FavoritesResolve records, edited together.
#   GetBlobEntryEx/Fs, FixEntry...     : Favorites entry construction, repair and inspection.
#   BuildResolveRecord(ForPath)        : FavoritesResolve record of a pin.
#   GetShortcutAppId                   : the AppID Windows gives a .lnk.
#   WriteInPlace, EmbedStreamIcon, NotifyShortcutChanged : in-place update of a pinned .lnk.
#   SendPinNotify, Acquire/ReleasePinMutex : taskbar notification, write serialization.
#   CreateAppShortcut, CreatePidlShortcut, GetAumid : .lnk creation and AUMID reading.
#   GetLnkCatalog, GetIconResourceCount : native .lnk catalog, icon resource count.
#   GetAppsFolderEntries, GetShellDisplayName : installed applications, shell names.
#   LoadUserHive, UnloadUserHive       : another user's NTUSER.DAT under HKEY_USERS.
# A type cannot be replaced in a PowerShell session : a helper of another version is detected
# through its HelperVersion.
function Initialize-NativeHelper {
    $NativeHelperType = 'TaskbarPin' -as [Type]
    if ($NativeHelperType) {
        $HelperVersionField = $NativeHelperType.GetField('HelperVersion')
        if (-not $HelperVersionField -or $HelperVersionField.GetValue($null) -ne '1.6') { throw 'This PowerShell session holds the helper of another Pin-Taskbar version : run the script in a new PowerShell session.' }
        return
    }
    Write-Log "[init] Compiling C# native helper..."
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public class TaskbarPin {
    public const string HelperVersion = "1.6";

    // Win32 imports : PIDLs, shell parsing, taskbar window lookup, COM, mutex, files.
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern IntPtr ILCreateFromPathW(string pszPath);
    [DllImport("shell32.dll")] static extern void ILFree(IntPtr pidl);
    [DllImport("shell32.dll")] static extern IntPtr ILFindLastID(IntPtr pidl);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHParseDisplayName(string pszName, IntPtr pbc, out IntPtr ppidl, uint sfgaoIn, out uint psfgaoOut);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern uint ExtractIconExW(string lpszFile, int nIconIndex, IntPtr phiconLarge, IntPtr phiconSmall, uint nIcons);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr hWndParent, IntPtr hWndChildAfter, string lpszClass, string lpszWindow);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("ole32.dll")] static extern int CoCreateInstance(ref Guid rclsid, IntPtr pUnk, uint ctx, ref Guid riid, out IntPtr ppv);
    [DllImport("ole32.dll")] static extern int PropVariantClear(IntPtr pvar);
    [DllImport("ole32.dll")] static extern int CreateStreamOnHGlobal(IntPtr hGlobal, bool fDeleteOnRelease, out IntPtr ppstm);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateMutexExW(IntPtr lpMutexAttributes, string lpName, uint dwFlags, uint dwDesiredAccess);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReleaseMutex(IntPtr hMutex);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr hObject);
    [DllImport("shell32.dll")] static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHCreateItemFromParsingName(string pszPath, IntPtr pbc, ref Guid riid, out IntPtr ppv);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern bool SHGetPathFromIDListW(IntPtr pidl, System.Text.StringBuilder pszPath);
    [DllImport("shell32.dll")] static extern int SHGetSpecialFolderLocation(IntPtr hwnd, int csidl, out IntPtr ppidl);
    [DllImport("shell32.dll")] static extern IntPtr ILCombine(IntPtr pidl1, IntPtr pidl2);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegLoadKeyW(IntPtr hKey, string lpSubKey, string lpFile);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern int RegUnLoadKeyW(IntPtr hKey, string lpSubKey);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool LookupPrivilegeValueW(string lpSystemName, string lpName, out long lpLuid);
    [DllImport("advapi32.dll", EntryPoint = "AdjustTokenPrivileges", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr tokenHandle, bool disableAll, ref TokenPrivilegePair newState, int bufferLength, ref TokenPrivilegePair previousState, out int returnLength);
    [DllImport("advapi32.dll", EntryPoint = "AdjustTokenPrivileges", SetLastError = true)] static extern bool RestoreTokenPrivileges(IntPtr tokenHandle, bool disableAll, ref TokenPrivilegePair newState, int bufferLength, IntPtr previousState, IntPtr returnLength);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();

    // Delegates mapped onto raw COM vtable slots (PowerShell 2.0 lacks modern COM wrappers).
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint FnRelease(IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnQueryInterface(IntPtr p, ref Guid riid, out IntPtr ppv);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSetIDList(IntPtr p, IntPtr pidl);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSetValue(IntPtr p, IntPtr key, IntPtr propvar);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnCommitStore(IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSaveFile(IntPtr p, IntPtr pszFileName, int fRemember);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnLoadFile(IntPtr p, IntPtr pszFileName, uint dwMode);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnGetValue(IntPtr p, IntPtr key, IntPtr propvar);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnGetAppIDForShortcut(IntPtr p, IntPtr psi, out IntPtr appId);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnGetIconLocation(IntPtr p, IntPtr pszIconPath, int cch, out int piIcon);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSetIconLocation(IntPtr p, IntPtr pszIconPath, int iIcon);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnGetFlags(IntPtr p, out uint flags);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSetFlags(IntPtr p, uint flags);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnPersistStreamSave(IntPtr p, IntPtr stream, int clearDirty);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnStreamSeek(IntPtr p, long offset, uint origin, out long position);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnStreamRead(IntPtr p, [Out] byte[] data, uint count, out uint read);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnBindToHandler(IntPtr p, IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnEnumNext(IntPtr p, uint count, out IntPtr item, out uint fetched);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnGetDisplayName(IntPtr p, uint form, out IntPtr name);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnGetString(IntPtr p, ref PropertyKey key, out IntPtr value);

    // PROPERTYKEY, and TOKEN_PRIVILEGES with room for the two privileges of a hive load.
    [StructLayout(LayoutKind.Sequential)] struct PropertyKey {
        public Guid FormatId; public uint PropertyId;
        public PropertyKey(Guid formatId, uint propertyId) { FormatId = formatId; PropertyId = propertyId; }
    }
    [StructLayout(LayoutKind.Sequential, Pack = 4)] struct TokenPrivilegePair { public int Count; public long FirstLuid; public int FirstAttributes; public long SecondLuid; public int SecondAttributes; }

    static readonly Guid CLSID_AppResolver      = new Guid("660B90C8-73A9-4B58-8CAE-355B7F55341B");
    static readonly Guid[] IID_AppResolvers     = { new Guid("DE25675A-72DE-44B4-9373-05170450C140"), new Guid("46A6EEFF-908E-4DC6-92A6-64BE9177B41C") };
    static readonly Guid IID_IShellItem         = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
    static readonly Guid CLSID_ShellLink        = new Guid("00021401-0000-0000-C000-000000000046");
    static readonly Guid IID_IShellLinkW        = new Guid("000214F9-0000-0000-C000-000000000046");
    static readonly Guid IID_IShellLinkDataList = new Guid("45E2B4AE-B1C3-11D0-B92F-00A0C90312E1");
    static readonly Guid IID_IPropertyStore     = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    static readonly Guid IID_IPersistFile       = new Guid("0000010B-0000-0000-C000-000000000046");
    static readonly Guid IID_IPersistStream     = new Guid("00000109-0000-0000-C000-000000000046");
    static readonly Guid FMTID_AppUserModel     = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    static readonly Guid CLSID_UsersFilesFolder = new Guid("59031A47-3F72-44A7-89C5-5595FE6B30EE");
    static readonly Guid CLSID_UserPinnedFolder = new Guid("1F3427C8-5C10-4210-AA03-2EE45287D668");
    static readonly Guid IID_IShellItem2        = new Guid("7E9FB0D3-919F-4307-AB2E-9B1860310C93");
    static readonly Guid IID_IEnumShellItems    = new Guid("70629033-E363-4A28-A567-0DB78006E6D7");
    static readonly Guid BHID_EnumItems         = new Guid("94F60519-2850-4924-AA5A-D15E84868039");
    static readonly PropertyKey PKEY_Link_TargetParsingPath = new PropertyKey(new Guid("B9B4B3FC-2B51-4A42-B5D8-324146AFCF25"), 2);
    static readonly IntPtr HKEY_USERS = new IntPtr(unchecked((int)0x80000003));

    // Runs a shell COM operation on an STA thread (PowerShell 2.0 runs in MTA); an exception
    // thrown there is rethrown here with its message.
    delegate T StaFunc<T>();
    static T RunOnSTA<T>(StaFunc<T> fn) {
        if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA) return fn();
        T result = default(T);
        Exception error = null;
        Thread staThread = new Thread(delegate() {
            try { result = fn(); }
            catch (Exception ex) { error = ex; }
        });
        staThread.SetApartmentState(ApartmentState.STA);
        staThread.Start();
        staThread.Join();
        if (error != null) throw new InvalidOperationException(error.Message, error);
        return result;
    }

    // Reads a delegate of type T from a COM vtable slot (Slot : from the object itself);
    // Release calls IUnknown slot 2.
    static T Vtbl<T>(IntPtr vtbl, int slot) where T : class {
        return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vtbl, slot * IntPtr.Size), typeof(T));
    }
    static T Slot<T>(IntPtr comObject, int slot) where T : class { return Vtbl<T>(Marshal.ReadIntPtr(comObject), slot); }
    static void Release(IntPtr ppv) { Vtbl<FnRelease>(Marshal.ReadIntPtr(ppv), 2)(ppv); }
    static void Release(IntPtr ppv, IntPtr vtbl) { Vtbl<FnRelease>(vtbl, 2)(ppv); }

    // SHParseDisplayName wrapper returning IntPtr.Zero on failure instead of an HRESULT.
    static IntPtr ParseDisplayName(string name) {
        IntPtr pidl; uint sfgao;
        if (SHParseDisplayName(name, IntPtr.Zero, out pidl, 0, out sfgao) == 0) return pidl;
        return IntPtr.Zero;
    }

    // Allocates a PROPERTYKEY structure for PKEY_AppUserModel_ID (FMTID + PID 5).
    static IntPtr AllocPropertyKey() {
        byte[] propertyKeyBytes = new byte[20];
        Array.Copy(FMTID_AppUserModel.ToByteArray(), 0, propertyKeyBytes, 0, 16);
        propertyKeyBytes[16] = 5;
        IntPtr propertyKeyPtr = Marshal.AllocCoTaskMem(20);
        Marshal.Copy(propertyKeyBytes, 0, propertyKeyPtr, 20);
        return propertyKeyPtr;
    }

    // Writes an AUMID to an IShellLink's property store as VT_LPWSTR and commits the store
    // (false when either call fails).
    static bool WriteAumidToStore(IntPtr psl, IntPtr vtLink, string aumid) {
        Guid iid = IID_IPropertyStore; IntPtr pps;
        if (Vtbl<FnQueryInterface>(vtLink, 0)(psl, ref iid, out pps) != 0) return false;
        try {
            IntPtr pkPtr = AllocPropertyKey();
            IntPtr pvPtr = Marshal.AllocCoTaskMem(24);
            for (int i = 0; i < 24; i++) Marshal.WriteByte(pvPtr, i, 0);
            Marshal.WriteInt16(pvPtr, 0, 31);
            IntPtr strPtr = Marshal.StringToCoTaskMemUni(aumid);
            Marshal.WriteIntPtr(pvPtr, 8, strPtr);
            try {
                IntPtr vt = Marshal.ReadIntPtr(pps);
                return Vtbl<FnSetValue>(vt, 6)(pps, pkPtr, pvPtr) >= 0 && Vtbl<FnCommitStore>(vt, 7)(pps) >= 0;
            } finally { Marshal.FreeCoTaskMem(strPtr); Marshal.FreeCoTaskMem(pvPtr); Marshal.FreeCoTaskMem(pkPtr); }
        } finally { Release(pps); }
    }

    // Loads (IPersistFile::Load, read-only) or saves (IPersistFile::Save) an IShellLink file.
    static bool PersistLoad(IntPtr psl, IntPtr vtLink, string lnkPath) { return PersistFile(psl, vtLink, lnkPath, false); }
    static bool PersistSave(IntPtr psl, IntPtr vtLink, string lnkPath) { return PersistFile(psl, vtLink, lnkPath, true); }
    static bool PersistFile(IntPtr psl, IntPtr vtLink, string lnkPath, bool save) {
        Guid iid = IID_IPersistFile; IntPtr ppf;
        if (Vtbl<FnQueryInterface>(vtLink, 0)(psl, ref iid, out ppf) != 0) return false;
        try {
            IntPtr pathPtr = Marshal.StringToCoTaskMemUni(lnkPath);
            try { return (save ? Slot<FnSaveFile>(ppf, 6)(ppf, pathPtr, 1) : Slot<FnLoadFile>(ppf, 5)(ppf, pathPtr, 0)) == 0; }
            finally { Marshal.FreeCoTaskMem(pathPtr); }
        } finally { Release(ppf); }
    }

    // Extension blocks of a SHITEMID : [cb][version][signature][data][first-block offset],
    // the item's last WORD being the first block's offset. BEEF001D data : [type 2][AppID\0].
    static bool IsBlock(byte[] item, int pos, int cb) {
        if (pos + 8 > cb) return false;
        int size = BitConverter.ToUInt16(item, pos);
        return size >= 8 && pos + size <= cb && BitConverter.ToUInt16(item, pos + 6) == 0xBEEF;
    }
    // Offset of the first block when the chain runs exactly to the end of the item, else 0.
    static int FirstBlock(byte[] item, int cb) {
        if (cb < 12) return 0;
        int first = BitConverter.ToUInt16(item, cb - 2);
        if (first < 4 || first >= cb) return 0;
        int pos = first;
        while (pos < cb && IsBlock(item, pos, cb)) pos += BitConverter.ToUInt16(item, pos);
        return pos == cb ? first : 0;
    }
    static void Put16(byte[] data, int pos, int value) { data[pos] = (byte)value; data[pos + 1] = (byte)(value >> 8); }
    // Appends a BEEF001D block at the end of the item; its trailing WORD holds the first-block
    // offset (its own position when the item has none).
    static byte[] InjectBeef001D(byte[] item, string appId) {
        int cb = BitConverter.ToUInt16(item, 0);
        if (cb < 4 || cb > item.Length) return null;
        byte[] nameBytes = System.Text.Encoding.Unicode.GetBytes(appId + "\0");
        int blockCb = 12 + nameBytes.Length, newCb = cb + blockCb, first = FirstBlock(item, cb);
        if (first == 0) first = cb;
        if (newCb > 0xFFFF) return null;
        byte[] result = new byte[newCb];
        Array.Copy(item, 0, result, 0, cb);
        Put16(result, cb, blockCb);
        Array.Copy(BitConverter.GetBytes(0xBEEF001Du), 0, result, cb + 4, 4);
        Put16(result, cb + 8, 2);
        Array.Copy(nameBytes, 0, result, cb + 10, nameBytes.Length);
        Put16(result, newCb - 2, first);
        Put16(result, 0, newCb);
        return result;
    }

    // Returns the item with its extension blocks back in one chain (an offset WORD written
    // outside its block goes back into it, a block repeated byte for byte is kept once), or
    // null when the chain is whole or its layout is not recognized.
    static byte[] RepairItem(byte[] item) {
        int cb = item.Length;
        if (cb < 12) return null;
        int first = BitConverter.ToUInt16(item, cb - 2);
        if (first < 4 || first >= cb) return null;
        List<int> starts = new List<int>(), sizes = new List<int>();
        bool changed = false;
        int pos = first;
        while (pos < cb) {
            if (IsBlock(item, pos, cb)) { starts.Add(pos); sizes.Add(BitConverter.ToUInt16(item, pos)); pos += BitConverter.ToUInt16(item, pos); }
            else if (starts.Count > 0 && pos + 2 <= cb && BitConverter.ToUInt16(item, pos) == first && (pos + 2 == cb || IsBlock(item, pos + 2, cb))) { sizes[sizes.Count - 1] += 2; pos += 2; changed = true; }
            else return null;
        }
        if (!changed) return null;
        List<string> seen = new List<string>();
        System.IO.MemoryStream ms = new System.IO.MemoryStream();
        ms.Write(item, 0, first);
        List<int> written = new List<int>();
        for (int i = 0; i < starts.Count; i++) {
            string content = sizes[i] + ":" + Convert.ToBase64String(item, starts[i] + 2, sizes[i] - 4);
            if (seen.Contains(content)) continue;
            seen.Add(content);
            written.Add((int)ms.Length); written.Add(sizes[i]);
            ms.Write(item, starts[i], sizes[i]);
        }
        byte[] result = ms.ToArray();
        for (int i = 0; i < written.Count; i += 2) Put16(result, written[i], written[i + 1]);
        Put16(result, 0, result.Length);
        return result;
    }
    static byte[] WithoutBlock(byte[] item, uint signature) {
        int cb = item.Length, first = FirstBlock(item, cb);
        if (first == 0) return item;
        System.IO.MemoryStream ms = new System.IO.MemoryStream();
        ms.Write(item, 0, first);
        for (int pos = first; pos < cb; pos += BitConverter.ToUInt16(item, pos)) {
            if (BitConverter.ToUInt32(item, pos + 4) != signature) ms.Write(item, pos, BitConverter.ToUInt16(item, pos));
        }
        byte[] result = ms.ToArray();
        Put16(result, 0, result.Length);
        return result;
    }
    // Position of the first block with this signature in a whole chain, or -1.
    static int FindBlock(byte[] item, uint signature) {
        int cb = item.Length, first = FirstBlock(item, cb);
        for (int pos = first; first != 0 && pos < cb; pos += BitConverter.ToUInt16(item, pos)) {
            if (BitConverter.ToUInt32(item, pos + 4) == signature) return pos;
        }
        return -1;
    }
    static string ItemAppId(byte[] item) {
        int pos = FindBlock(item, 0xBEEF001D);
        if (pos < 0) return "";
        int end = pos + BitConverter.ToUInt16(item, pos);
        if (end < pos + 12) return "";
        int stop = pos + 10;
        while (stop + 1 < end && (item[stop] != 0 || item[stop + 1] != 0)) stop += 2;
        return System.Text.Encoding.Unicode.GetString(item, pos + 10, stop - pos - 10);
    }

    // A Favorites entry is [1 byte CSIDL root][uint32 pidlSize][PIDL]; these helpers work on
    // the last SHITEMID of its PIDL, with its extension chain repaired when it is broken.
    static int LastItemOffset(byte[] entry) {
        int pos = 5, last = 0;
        while (pos + 2 <= entry.Length) {
            int size = BitConverter.ToUInt16(entry, pos);
            if (size == 0) break;
            if (size < 2 || pos + size > entry.Length) return 0;
            last = pos; pos += size;
        }
        return last;
    }
    static byte[] LastItem(byte[] entry, int last, out bool repaired) {
        byte[] item = new byte[BitConverter.ToUInt16(entry, last)];
        Array.Copy(entry, last, item, 0, item.Length);
        byte[] repairedItem = RepairItem(item);
        repaired = repairedItem != null;
        return repaired ? repairedItem : item;
    }
    static byte[] WithLastItem(byte[] entry, int last, byte[] item) {
        int pidlSize = (last - 5) + item.Length + 2;
        byte[] result = new byte[5 + pidlSize];
        Array.Copy(entry, 0, result, 0, last);
        Array.Copy(BitConverter.GetBytes((uint)pidlSize), 0, result, 1, 4);
        Array.Copy(item, 0, result, last, item.Length);
        return result;
    }
    public static string GetEntryAppId(byte[] entry) {
        int last = LastItemOffset(entry);
        bool repaired;
        return last == 0 ? "" : ItemAppId(LastItem(entry, last, out repaired));
    }
    // An entry Windows retired (its .lnk moved to Tombstones) carries BEEF002C.
    public static bool IsRetiredEntry(byte[] entry) {
        int last = LastItemOffset(entry);
        bool repaired;
        return last != 0 && FindBlock(LastItem(entry, last, out repaired), 0xBEEF002C) >= 0;
    }
    // Returns the entry with its extension blocks repaired and, when appId is set, its
    // BEEF001D holding appId; null when the entry needs no change.
    public static byte[] FixEntry(byte[] entry, string appId) {
        int last = LastItemOffset(entry);
        if (last == 0) return null;
        bool changed;
        byte[] item = LastItem(entry, last, out changed);
        if (!string.IsNullOrEmpty(appId) && !string.Equals(ItemAppId(item), appId, StringComparison.OrdinalIgnoreCase)) {
            byte[] injected = InjectBeef001D(WithoutBlock(item, 0xBEEF001D), appId);
            if (injected != null) { item = injected; changed = true; }
        }
        return changed ? WithLastItem(entry, last, item) : null;
    }
    // Absolute PIDL of an entry (its CSIDL root combined with the stored PIDL), to be freed
    // with ILFree; IntPtr.Zero when the entry is malformed or its root folder is unknown.
    static IntPtr EntryPidl(byte[] entry) {
        if (entry == null || entry.Length < 7) return IntPtr.Zero;
        int size = (int)BitConverter.ToUInt32(entry, 1);
        if (size < 2 || 5 + size > entry.Length) return IntPtr.Zero;
        IntPtr pidl = Marshal.AllocCoTaskMem(size + 2);
        Marshal.Copy(entry, 5, pidl, size);
        Marshal.WriteInt16(pidl, size, 0);
        if (entry[0] == 0) return pidl;
        IntPtr root = IntPtr.Zero;
        try {
            if (SHGetSpecialFolderLocation(IntPtr.Zero, entry[0], out root) != 0) return IntPtr.Zero;
            return ILCombine(root, pidl);
        } finally {
            Marshal.FreeCoTaskMem(pidl);
            if (root != IntPtr.Zero) ILFree(root);
        }
    }
    // True when the entry's PIDL is relative to the user's profile (UsersFiles or User Pinned root).
    public static bool IsProfileRelativeEntry(byte[] entry) {
        if (entry == null || entry.Length < 25 || entry[0] != 0 || BitConverter.ToUInt16(entry, 5) < 20 || entry[7] != 0x1F) return false;
        byte[] rootGuid = new byte[16];
        Array.Copy(entry, 9, rootGuid, 0, 16);
        Guid root = new Guid(rootGuid);
        return root == CLSID_UsersFilesFolder || root == CLSID_UserPinnedFolder;
    }
    // Filesystem path of the item an entry points to, "" when it has none. Paths under a
    // profile resolve against this process's profile.
    public static string GetEntryPath(byte[] entry) {
        IntPtr pidl = EntryPidl(entry);
        if (pidl == IntPtr.Zero) return "";
        try {
            System.Text.StringBuilder path = new System.Text.StringBuilder(1024);
            return SHGetPathFromIDListW(pidl, path) ? path.ToString() : "";
        } finally { ILFree(pidl); }
    }

    // The AppID Windows gives a shortcut, which the taskbar stores in BEEF001D; "" when the
    // application resolver is unavailable.
    public static string GetShortcutAppId(string lnkPath) {
        return RunOnSTA<string>(delegate() {
            Guid iidItem = IID_IShellItem; IntPtr psi;
            if (SHCreateItemFromParsingName(lnkPath, IntPtr.Zero, ref iidItem, out psi) != 0) return "";
            try {
                foreach (Guid candidate in IID_AppResolvers) {
                    Guid cls = CLSID_AppResolver; Guid iid = candidate; IntPtr resolver;
                    if (CoCreateInstance(ref cls, IntPtr.Zero, 0x17, ref iid, out resolver) != 0) continue;
                    try {
                        IntPtr appIdPtr;
                        if (Slot<FnGetAppIDForShortcut>(resolver, 3)(resolver, psi, out appIdPtr) != 0 || appIdPtr == IntPtr.Zero) return "";
                        try { return Marshal.PtrToStringUni(appIdPtr) ?? ""; } finally { Marshal.FreeCoTaskMem(appIdPtr); }
                    } finally { Release(resolver); }
                }
                return "";
            } finally { Release(psi); }
        });
    }

    // Writes a pinned shortcut in place when its content differs, the target's last access time
    // aside. Returns true when it did.
    public static bool WriteInPlace(string path, byte[] content) {
        byte[] current = System.IO.File.ReadAllBytes(path);
        if (BytesEqual(current, WithAccessTimeOf(content, current))) return false;
        using (System.IO.FileStream fs = new System.IO.FileStream(path, System.IO.FileMode.Open, System.IO.FileAccess.Write, System.IO.FileShare.Read)) {
            fs.Write(content, 0, content.Length);
            fs.SetLength(content.Length);
        }
        return true;
    }
    // The shortcut with the last access times (target in the header, every item of the target
    // path in its BEEF0004 block) taken from another shortcut of the same layout.
    static byte[] WithAccessTimeOf(byte[] content, byte[] other) {
        if (content.Length != other.Length || content.Length < 0x4E || BitConverter.ToUInt32(content, 0) != 0x4C) return content;
        byte[] result = (byte[])content.Clone();
        Array.Copy(other, 0x24, result, 0x24, 8);
        if ((BitConverter.ToUInt32(content, 0x14) & 1) == 0) return result;
        int end = Math.Min(content.Length, 0x4E + BitConverter.ToUInt16(content, 0x4C));
        for (int pos = 0x4E, cb; pos + 2 <= end && (cb = BitConverter.ToUInt16(content, pos)) >= 2 && pos + cb <= end; pos += cb) {
            byte[] item = new byte[cb];
            Array.Copy(content, pos, item, 0, cb);
            int block = FindBlock(item, 0xBEEF0004);
            if (block >= 0 && block + 16 <= cb) Array.Copy(other, pos + block + 12, result, pos + block + 12, 4);
        }
        return result;
    }

    // Icons embedded in an alternate data stream (IconLocation <file>:<stream>), which the
    // .NET Framework file APIs cannot open.
    static byte[] ReadStream(string streamPath) {
        using (Microsoft.Win32.SafeHandles.SafeFileHandle handle = CreateFileW(streamPath, 0x80000000, 1, IntPtr.Zero, 3, 0x80, IntPtr.Zero)) {
            if (handle.IsInvalid) return null;
            using (System.IO.FileStream fs = new System.IO.FileStream(handle, System.IO.FileAccess.Read)) {
                byte[] data = new byte[fs.Length];
                int offset = 0;
                while (offset < data.Length) { int read = fs.Read(data, offset, data.Length - offset); if (read <= 0) break; offset += read; }
                return data;
            }
        }
    }
    static bool WriteStream(string streamPath, byte[] data) {
        using (Microsoft.Win32.SafeHandles.SafeFileHandle handle = CreateFileW(streamPath, 0x40000000, 0, IntPtr.Zero, 2, 0x80, IntPtr.Zero)) {
            if (handle.IsInvalid) return false;
            using (System.IO.FileStream fs = new System.IO.FileStream(handle, System.IO.FileAccess.Write)) fs.Write(data, 0, data.Length);
        }
        return true;
    }
    // A shortcut whose icon lives in an alternate data stream of another file gets that icon in
    // a stream of its own, named after the icon's content (a new icon, a new location). The
    // stream is written after the save, which drops the file's streams. Returns true when the
    // shortcut changed.
    public static bool EmbedStreamIcon(string lnkPath) {
        return RunOnSTA<bool>(delegate() {
            Guid cls = CLSID_ShellLink; Guid iid = IID_IShellLinkW; IntPtr psl;
            if (CoCreateInstance(ref cls, IntPtr.Zero, 1, ref iid, out psl) != 0) return false;
            IntPtr vtLink = Marshal.ReadIntPtr(psl);
            try {
                if (!PersistLoad(psl, vtLink, lnkPath)) return false;
                IntPtr buffer = Marshal.AllocCoTaskMem(2048 * 2);
                string location; int index;
                try {
                    if (Vtbl<FnGetIconLocation>(vtLink, 16)(psl, buffer, 2048, out index) != 0) return false;
                    location = Environment.ExpandEnvironmentVariables(Marshal.PtrToStringUni(buffer) ?? "");
                } finally { Marshal.FreeCoTaskMem(buffer); }
                int colon = location.LastIndexOf(':');
                if (colon <= 2 || location.IndexOfAny(new char[] { '\\', '/' }, colon) >= 0) return false;
                if (string.Equals(location.Substring(0, colon), lnkPath, StringComparison.OrdinalIgnoreCase)) return false;
                byte[] icon = ReadStream(location);
                if (icon == null || icon.Length == 0) icon = ReadStream(lnkPath + location.Substring(colon));
                if (icon == null || icon.Length == 0) return false;
                uint hash = 2166136261;
                foreach (byte b in icon) { hash ^= b; hash *= 16777619; }
                string ownLocation = lnkPath + ":icon-" + hash.ToString("X8") + ".ico";
                IntPtr ownPtr = Marshal.StringToCoTaskMemUni(ownLocation);
                try { if (Vtbl<FnSetIconLocation>(vtLink, 17)(psl, ownPtr, index) != 0) return false; }
                finally { Marshal.FreeCoTaskMem(ownPtr); }
                return PersistSave(psl, vtLink, lnkPath) && WriteStream(ownLocation, icon);
            } finally { Release(psl, vtLink); }
        });
    }

    // Makes the taskbar reload a pinned shortcut (icon and AppID); both notifications are
    // delivered in order before returning.
    public static void NotifyShortcutChanged(string lnkPath) {
        IntPtr pathPtr = Marshal.StringToHGlobalUni(lnkPath);
        try {
            SHChangeNotify(0x00000001, 0x1005, pathPtr, pathPtr);
            SHChangeNotify(0x00002000, 0x1005, pathPtr, IntPtr.Zero);
        } finally { Marshal.FreeHGlobal(pathPtr); }
    }

    // Builds one Favorites blob entry from a PIDL : [1 byte category = 0x00 (Desktop root)]
    // [uint32 pidlSize][PIDL data with BEEF001D injected into the last SHITEMID].
    static byte[] BuildBlobEntry(IntPtr pidl, string beef001dContent) {
        IntPtr lastPtr = ILFindLastID(pidl);
        if (lastPtr == IntPtr.Zero) return null;
        int prefixLen = (int)((long)lastPtr - (long)pidl);
        ushort lastCb = (ushort)Marshal.ReadInt16(lastPtr);
        if (lastCb < 4) return null;
        byte[] lastItem = new byte[lastCb];
        Marshal.Copy(lastPtr, lastItem, 0, lastCb);
        byte[] patched = InjectBeef001D(lastItem, beef001dContent);
        if (patched == null) return null;
        int newPidlLen = prefixLen + patched.Length + 2;
        byte[] result = new byte[1 + 4 + newPidlLen];
        Array.Copy(BitConverter.GetBytes((uint)newPidlLen), 0, result, 1, 4);
        Marshal.Copy(pidl, result, 5, prefixLen);
        Array.Copy(patched, 0, result, 5 + prefixLen, patched.Length);
        return result;
    }

    // GetBlobEntryEx : namespace PIDL; GetBlobEntryFs : filesystem PIDL, for a path under
    // another user's profile.
    static byte[] GetBlobEntryInternal(string path, string beef001dContent, bool useFilesystem) {
        IntPtr pidl = useFilesystem ? ILCreateFromPathW(path) : ParseDisplayName(path);
        if (pidl == IntPtr.Zero) return null;
        try { return BuildBlobEntry(pidl, beef001dContent); } finally { ILFree(pidl); }
    }
    public static byte[] GetBlobEntryEx(string lnkFullPath, string beef001dContent) {
        return RunOnSTA<byte[]>(delegate() { return GetBlobEntryInternal(lnkFullPath, beef001dContent, false); });
    }
    public static byte[] GetBlobEntryFs(string lnkFullPath, string beef001dContent) {
        return RunOnSTA<byte[]>(delegate() { return GetBlobEntryInternal(lnkFullPath, beef001dContent, true); });
    }

    // Notifies the taskbar that the pinned-items list changed by posting 0x446 to its
    // pinned-items band (Shell_TrayWnd > ReBarWindow32 > MSTaskSwWClass).
    public static void SendPinNotify() {
        IntPtr reBarWindow = FindWindowEx(FindWindow("Shell_TrayWnd", null), IntPtr.Zero, "ReBarWindow32", null);
        IntPtr pinnedItemsBand = FindWindowEx(reBarWindow, IntPtr.Zero, "MSTaskSwWClass", null);
        if (pinnedItemsBand != IntPtr.Zero) PostMessage(pinnedItemsBand, 0x446, IntPtr.Zero, IntPtr.Zero);
    }

    // TaskbarPinListMutex acquisition and release, serializing blob writes with explorer.exe.
    static IntPtr _mutexHandle = IntPtr.Zero;
    public static bool AcquirePinMutex(int timeoutMs) {
        IntPtr mutexHandle = CreateMutexExW(IntPtr.Zero, "TaskbarPinListMutex", 0, 0x001F0001);
        if (mutexHandle == IntPtr.Zero) return false;
        uint waitResult = WaitForSingleObject(mutexHandle, (uint)timeoutMs);
        if (waitResult == 0 || waitResult == 0x80) { _mutexHandle = mutexHandle; return true; }
        CloseHandle(mutexHandle);
        return false;
    }
    public static void ReleasePinMutex() {
        if (_mutexHandle == IntPtr.Zero) return;
        ReleaseMutex(_mutexHandle); CloseHandle(_mutexHandle); _mutexHandle = IntPtr.Zero;
    }

    // Loads a hive file under HKEY_USERS\name, or unloads it (file null), with SeBackupPrivilege
    // and SeRestorePrivilege enabled for the call only, as reg.exe does. Returns the Win32
    // error, 0 on success.
    public static int LoadUserHive(string name, string file) { return CallWithHivePrivileges(name, file); }
    public static int UnloadUserHive(string name) { return CallWithHivePrivileges(name, null); }
    static int CallWithHivePrivileges(string name, string file) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0028, out token)) return Marshal.GetLastWin32Error();   // TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY
        try {
            TokenPrivilegePair wanted = new TokenPrivilegePair(), previous = new TokenPrivilegePair();
            wanted.Count = 2;
            wanted.FirstAttributes = wanted.SecondAttributes = 2;   // SE_PRIVILEGE_ENABLED
            if (!LookupPrivilegeValueW(null, "SeBackupPrivilege", out wanted.FirstLuid) || !LookupPrivilegeValueW(null, "SeRestorePrivilege", out wanted.SecondLuid)) return Marshal.GetLastWin32Error();
            int previousSize;
            if (!AdjustTokenPrivileges(token, false, ref wanted, Marshal.SizeOf(typeof(TokenPrivilegePair)), ref previous, out previousSize)) return Marshal.GetLastWin32Error();
            int error = Marshal.GetLastWin32Error();   // ERROR_NOT_ALL_ASSIGNED : the token lacks one of them
            try {
                if (error != 0) return error;
                return file != null ? RegLoadKeyW(HKEY_USERS, name, file) : RegUnLoadKeyW(HKEY_USERS, name);
            } finally { RestoreTokenPrivileges(token, false, ref previous, 0, IntPtr.Zero, IntPtr.Zero); }
        } finally { CloseHandle(token); }
    }

    // FavoritesResolve record : [uint32 size][serialized ShellLink], built as Windows builds it :
    // a link to the pinned item itself (SLDF_ALLOW_LINK_TO_LINK).
    static byte[] BuildRecordFromPidl(IntPtr pidl) {
        Guid cls = CLSID_ShellLink, iid = IID_IShellLinkW;
        IntPtr link = IntPtr.Zero, dataList = IntPtr.Zero, persist = IntPtr.Zero, stream = IntPtr.Zero;
        try {
            RequireSuccess(CoCreateInstance(ref cls, IntPtr.Zero, 1, ref iid, out link));
            iid = IID_IShellLinkDataList;
            RequireSuccess(Slot<FnQueryInterface>(link, 0)(link, ref iid, out dataList));
            uint linkFlags;
            RequireSuccess(Slot<FnGetFlags>(dataList, 6)(dataList, out linkFlags));
            RequireSuccess(Slot<FnSetFlags>(dataList, 7)(dataList, linkFlags | 0x00800000));
            RequireSuccess(Slot<FnSetIDList>(link, 5)(link, pidl));
            iid = IID_IPersistStream;
            RequireSuccess(Slot<FnQueryInterface>(link, 0)(link, ref iid, out persist));
            RequireSuccess(CreateStreamOnHGlobal(IntPtr.Zero, true, out stream));
            RequireSuccess(Slot<FnPersistStreamSave>(persist, 6)(persist, stream, 1));
            long size, position; uint read;
            RequireSuccess(Slot<FnStreamSeek>(stream, 5)(stream, 0, 1, out size));
            RequireSuccess(Slot<FnStreamSeek>(stream, 5)(stream, 0, 0, out position));
            byte[] payload = new byte[size];
            RequireSuccess(Slot<FnStreamRead>(stream, 3)(stream, payload, (uint)size, out read));
            if (read != size) throw new InvalidOperationException("Incomplete ShellLink serialization.");
            byte[] record = new byte[4 + size];
            Array.Copy(BitConverter.GetBytes((uint)size), record, 4);
            Array.Copy(payload, 0, record, 4, payload.Length);
            return record;
        } finally {
            foreach (IntPtr comObject in new IntPtr[] { stream, persist, dataList, link }) if (comObject != IntPtr.Zero) Release(comObject);
        }
    }
    // Record built from the entry's own PIDL (list of this process's user).
    public static byte[] BuildResolveRecord(byte[] entry) {
        return RunOnSTA<byte[]>(delegate() {
            IntPtr pidl = EntryPidl(entry);
            if (pidl == IntPtr.Zero) throw new InvalidOperationException("Malformed Favorites entry.");
            try { return BuildRecordFromPidl(pidl); } finally { ILFree(pidl); }
        });
    }
    // Record built from the .lnk's path (list of another user).
    public static byte[] BuildResolveRecordForPath(string lnkPath) {
        return RunOnSTA<byte[]>(delegate() {
            IntPtr pidl = ILCreateFromPathW(lnkPath);
            if (pidl == IntPtr.Zero) throw new System.IO.FileNotFoundException("Shortcut not found.", lnkPath);
            try { return BuildRecordFromPidl(pidl); } finally { ILFree(pidl); }
        });
    }
    // True when the record has the form Windows writes.
    internal static bool IsWindowsRecord(byte[] record) {
        return record.Length >= 4 + 0x4C && BitConverter.ToUInt32(record, 4) == 0x4C && (BitConverter.ToUInt32(record, 24) & 0x00800001) == 0x00800001;
    }
    static void RequireSuccess(int hr) { if (hr < 0) Marshal.ThrowExceptionForHR(hr); }
    public static bool BytesEqual(byte[] left, byte[] right) {
        int leftLength = left == null ? 0 : left.Length, rightLength = right == null ? 0 : right.Length;
        if (leftLength != rightLength) return false;
        for (int i = 0; i < leftLength; i++) if (left[i] != right[i]) return false;
        return true;
    }

    // Creates an IShellLink from a PIDL, optionally writes the AUMID property, saves to disk
    // (false when any of the three fails).
    static bool CreateShortcutFromPidl(IntPtr pidl, string lnkPath, string aumid) {
        Guid cls = CLSID_ShellLink; Guid iid = IID_IShellLinkW; IntPtr psl;
        if (CoCreateInstance(ref cls, IntPtr.Zero, 1, ref iid, out psl) != 0) return false;
        IntPtr vtLink = Marshal.ReadIntPtr(psl);
        try {
            if (Vtbl<FnSetIDList>(vtLink, 5)(psl, pidl) < 0) return false;
            if (aumid != null && aumid.Length > 0 && !WriteAumidToStore(psl, vtLink, aumid)) return false;
            return PersistSave(psl, vtLink, lnkPath);
        } finally { Release(psl, vtLink); }
    }

    // Creates a .lnk from a shell display name (Control Panel item, shell:AppsFolder entry),
    // storing the given AppUserModelID on the shortcut. CreateAppShortcut is the UWP/MSIX
    // convenience form taking the AUMID directly.
    public static bool CreatePidlShortcut(string displayName, string lnkPath, string appUserModelId) {
        return RunOnSTA<bool>(delegate() {
            IntPtr pidl = ParseDisplayName(displayName);
            if (pidl == IntPtr.Zero) return false;
            try { return CreateShortcutFromPidl(pidl, lnkPath, appUserModelId); } finally { ILFree(pidl); }
        });
    }
    public static bool CreateAppShortcut(string aumid, string lnkPath) {
        return CreatePidlShortcut("shell:AppsFolder\\" + aumid, lnkPath, aumid);
    }

    // An IShellItem's display name in the given SIGDN form, "" when it has none.
    static string ItemDisplayName(IntPtr item, uint form) {
        IntPtr name;
        if (Slot<FnGetDisplayName>(item, 5)(item, form, out name) != 0 || name == IntPtr.Zero) return "";
        try { return Marshal.PtrToStringUni(name) ?? ""; } finally { Marshal.FreeCoTaskMem(name); }
    }
    // A string property of an IShellItem (IShellItem2::GetString), "" when it has none.
    static string ItemString(IntPtr item, PropertyKey key) {
        Guid iid = IID_IShellItem2; IntPtr item2;
        if (Slot<FnQueryInterface>(item, 0)(item, ref iid, out item2) != 0) return "";
        try {
            IntPtr value;
            if (Slot<FnGetString>(item2, 17)(item2, ref key, out value) != 0 || value == IntPtr.Zero) return "";
            try { return Marshal.PtrToStringUni(value) ?? ""; } finally { Marshal.FreeCoTaskMem(value); }
        } finally { Release(item2); }
    }

    // The name the shell shows for an item ("Local Disk (C:)" for a drive), "" when it has none.
    public static string GetShellDisplayName(string path) {
        return RunOnSTA<string>(delegate() {
            Guid iid = IID_IShellItem; IntPtr item;
            if (SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out item) != 0) return "";
            try { return ItemDisplayName(item, 0); } finally { Release(item); }
        });
    }

    // The applications of shell:AppsFolder (Windows 8 and later) as the shell lists them :
    // parsing name (the AUMID), name and target parsing path; none without the folder.
    public static AppEntry[] GetAppsFolderEntries() {
        return RunOnSTA<AppEntry[]>(delegate() {
            List<AppEntry> entries = new List<AppEntry>();
            Guid iidItem = IID_IShellItem, handler = BHID_EnumItems, iidEnum = IID_IEnumShellItems;
            IntPtr folder, items, item;
            uint fetched;
            if (SHCreateItemFromParsingName("shell:AppsFolder", IntPtr.Zero, ref iidItem, out folder) != 0) return entries.ToArray();
            try {
                if (Slot<FnBindToHandler>(folder, 3)(folder, IntPtr.Zero, ref handler, ref iidEnum, out items) != 0) return entries.ToArray();
                try {
                    FnEnumNext next = Slot<FnEnumNext>(items, 3);
                    while (next(items, 1, out item, out fetched) == 0 && fetched == 1) {
                        try {
                            AppEntry entry = new AppEntry();
                            entry.Aumid             = ItemDisplayName(item, 0x80018001);   // SIGDN_PARENTRELATIVEPARSING
                            entry.DisplayName       = ItemDisplayName(item, 0x80080001);   // SIGDN_PARENTRELATIVE
                            entry.TargetParsingPath = ItemString(item, PKEY_Link_TargetParsingPath);
                            entries.Add(entry);
                        } finally { Release(item); }
                    }
                } finally { Release(items); }
            } finally { Release(folder); }
            return entries.ToArray();
        });
    }

    // Reads PKEY_AppUserModel_ID from an existing .lnk through IPersistFile + IPropertyStore.
    public static string GetAumid(string lnkPath) {
        return RunOnSTA<string>(delegate() {
            Guid cls = CLSID_ShellLink; Guid iid = IID_IShellLinkW; IntPtr psl;
            if (CoCreateInstance(ref cls, IntPtr.Zero, 1, ref iid, out psl) != 0) return "";
            IntPtr vtLink = Marshal.ReadIntPtr(psl);
            try {
                if (!PersistLoad(psl, vtLink, lnkPath)) return "";
                Guid iidStore = IID_IPropertyStore; IntPtr pps;
                if (Vtbl<FnQueryInterface>(vtLink, 0)(psl, ref iidStore, out pps) != 0) return "";
                try {
                    IntPtr pkPtr = AllocPropertyKey();
                    IntPtr pvPtr = Marshal.AllocCoTaskMem(24);
                    for (int i = 0; i < 24; i++) Marshal.WriteByte(pvPtr, i, 0);
                    try {
                        if (Vtbl<FnGetValue>(Marshal.ReadIntPtr(pps), 5)(pps, pkPtr, pvPtr) != 0) return "";
                        if (Marshal.ReadInt16(pvPtr) != 31) return "";
                        IntPtr stringPtr = Marshal.ReadIntPtr(pvPtr, 8);
                        if (stringPtr == IntPtr.Zero) return "";
                        return Marshal.PtrToStringUni(stringPtr) ?? "";
                    } finally { PropVariantClear(pvPtr); Marshal.FreeCoTaskMem(pvPtr); Marshal.FreeCoTaskMem(pkPtr); }
                } finally { Release(pps); }
            } finally { Release(psl, vtLink); }
        });
    }

    // Reads a null-terminated ANSI string from a byte array.
    static string ReadAnsiZ(byte[] d, int pos) {
        int end = pos;
        while (end < d.Length && d[end] != 0) end++;
        return System.Text.Encoding.Default.GetString(d, pos, end - pos);
    }

    // Reads a null-terminated Unicode string from a byte array.
    static string ReadUniZ(byte[] d, int pos) {
        int end = pos;
        while (end + 1 < d.Length && (d[end] != 0 || d[end + 1] != 0)) end += 2;
        return System.Text.Encoding.Unicode.GetString(d, pos, end - pos);
    }

    // PKEY_AppUserModel_ID (VT_LPWSTR, Id 5) of a PropertyStoreDataBlock, "" when absent.
    static string ReadStoreAumid(byte[] d, int pos, int end) {
        byte[] fmtid = FMTID_AppUserModel.ToByteArray();
        while (pos + 28 <= end) {
            uint storageSize = BitConverter.ToUInt32(d, pos);
            if (storageSize == 0 || pos + storageSize > end) break;
            bool fmtidMatch = true;
            for (int i = 0; i < 16; i++) { if (d[pos + 8 + i] != fmtid[i]) { fmtidMatch = false; break; } }
            if (fmtidMatch) {
                int vpos = pos + 24;
                int vend = pos + (int)storageSize;
                while (vpos + 13 <= vend) {
                    uint valueSize = BitConverter.ToUInt32(d, vpos);
                    if (valueSize == 0 || vpos + valueSize > vend) break;
                    uint propId = BitConverter.ToUInt32(d, vpos + 4);
                    ushort vt   = BitConverter.ToUInt16(d, vpos + 9);
                    if (propId == 5 && vt == 0x1F && vpos + 17 <= vend) return ReadUniZ(d, vpos + 17);
                    vpos += (int)valueSize;
                }
            }
            pos += (int)storageSize;
        }
        return "";
    }

    // Parses a .lnk without COM : target path (LinkInfo, else environment block, else relative
    // path), AppUserModelID and icon location.
    static void ParseLnk(byte[] d, string lnkDirectory, out string target, out string aumid, out string iconPath) {
        target = ""; aumid = ""; iconPath = "";
        if (d.Length < 0x4C || BitConverter.ToInt32(d, 0) != 0x4C) return;
        uint flags = BitConverter.ToUInt32(d, 20);
        int pos = 0x4C;
        if ((flags & 0x01) != 0) {                          // HasLinkTargetIDList
            if (pos + 2 > d.Length) return;
            pos += 2 + BitConverter.ToUInt16(d, pos);
        }
        if ((flags & 0x02) != 0 && pos + 36 <= d.Length) {  // HasLinkInfo
            int li = pos;
            uint liSize  = BitConverter.ToUInt32(d, li);
            uint liHead  = BitConverter.ToUInt32(d, li + 4);
            uint liFlags = BitConverter.ToUInt32(d, li + 8);
            if ((liFlags & 0x01) != 0) {                    // VolumeIDAndLocalBasePath
                if (liHead >= 0x24) {
                    target = ReadUniZ(d, li + (int)BitConverter.ToUInt32(d, li + 28))
                           + ReadUniZ(d, li + (int)BitConverter.ToUInt32(d, li + 32));
                } else {
                    target = ReadAnsiZ(d, li + (int)BitConverter.ToUInt32(d, li + 16))
                           + ReadAnsiZ(d, li + (int)BitConverter.ToUInt32(d, li + 24));
                }
            }
            pos = li + (int)liSize;
        }
        // StringData : RelativePath (0x08) and IconLocation (0x40); counted, not null-terminated.
        bool isUnicode = (flags & 0x80) != 0;               // IsUnicode
        string relativePath = "";
        uint[] stringDataFlags = new uint[] { 0x04, 0x08, 0x10, 0x20, 0x40 };
        for (int i = 0; i < stringDataFlags.Length; i++) {
            if ((flags & stringDataFlags[i]) == 0) continue;
            if (pos + 2 > d.Length) return;
            int charCount = BitConverter.ToUInt16(d, pos);
            int byteCount = charCount * (isUnicode ? 2 : 1);
            if (pos + 2 + byteCount > d.Length) return;
            if (stringDataFlags[i] == 0x08) {               // HasRelativePath
                relativePath = isUnicode ? System.Text.Encoding.Unicode.GetString(d, pos + 2, byteCount)
                                         : System.Text.Encoding.Default.GetString(d, pos + 2, byteCount);
            }
            else if (stringDataFlags[i] == 0x40) {          // HasIconLocation
                iconPath = isUnicode ? System.Text.Encoding.Unicode.GetString(d, pos + 2, byteCount)
                                     : System.Text.Encoding.Default.GetString(d, pos + 2, byteCount);
            }
            pos += 2 + byteCount;
        }
        // Walk the extra data blocks for the environment target and the property store
        while (pos + 8 <= d.Length) {
            uint blockSize = BitConverter.ToUInt32(d, pos);
            if (blockSize < 8 || pos + blockSize > d.Length) break;
            uint blockSig = BitConverter.ToUInt32(d, pos + 4);
            if (blockSig == 0xA0000001 && target.Length == 0 && blockSize >= 8 + 260 + 520) {
                string envTarget = ReadUniZ(d, pos + 8 + 260);
                if (envTarget.Length == 0) envTarget = ReadAnsiZ(d, pos + 8);
                if (envTarget.Length > 0) target = Environment.ExpandEnvironmentVariables(envTarget);
            }
            if (blockSig == 0xA0000009 && aumid.Length == 0) {
                aumid = ReadStoreAumid(d, pos + 8, pos + (int)blockSize);
            }
            if (blockSig == 0xA0000007 && iconPath.Length == 0 && blockSize >= 8 + 260 + 520) {
                string envIconPath = ReadUniZ(d, pos + 8 + 260);
                if (envIconPath.Length == 0) envIconPath = ReadAnsiZ(d, pos + 8);
                if (envIconPath.Length > 0) iconPath = envIconPath;
            }
            pos += (int)blockSize;
        }
        if (iconPath.Length > 0) iconPath = Environment.ExpandEnvironmentVariables(iconPath);
        // Last resort : resolve the relative path against the .lnk location
        if (target.Length == 0 && relativePath.Length > 0 && lnkDirectory.Length > 0) {
            try { target = System.IO.Path.GetFullPath(System.IO.Path.Combine(lnkDirectory, relativePath)); } catch { }
        }
    }

    // Number of icon resources of a file, 0 for a missing or icon-less file.
    public static int GetIconResourceCount(string filePath) {
        if (!System.IO.File.Exists(filePath)) return 0;
        uint iconResourceCount = ExtractIconExW(filePath, -1, IntPtr.Zero, IntPtr.Zero, 0);
        if (iconResourceCount == 0xFFFFFFFF) return 0;
        return (int)iconResourceCount;
    }

    // Adds the .lnk files of one directory (GetFiles("*.lnk") also returns .lnk* files).
    static void AddLnkFiles(string directory, List<string> lnkPaths) {
        string[] matchedFiles;
        try { matchedFiles = System.IO.Directory.GetFiles(directory, "*.lnk"); } catch { return; }
        for (int i = 0; i < matchedFiles.Length; i++) {
            if (matchedFiles[i].EndsWith(".lnk", StringComparison.OrdinalIgnoreCase)) lnkPaths.Add(matchedFiles[i]);
        }
    }

    // Collects the .lnk files of a directory tree, skipping reparse points (denied Start Menu
    // compatibility junctions) and unreadable folders.
    static void CollectLnkFiles(string directory, List<string> lnkPaths) {
        AddLnkFiles(directory, lnkPaths);
        string[] subDirectories;
        try { subDirectories = System.IO.Directory.GetDirectories(directory); } catch { return; }
        for (int i = 0; i < subDirectories.Length; i++) {
            try { if ((System.IO.File.GetAttributes(subDirectories[i]) & System.IO.FileAttributes.ReparsePoint) != 0) continue; }
            catch { continue; }
            CollectLnkFiles(subDirectories[i], lnkPaths);
        }
    }

    // One LnkEntry per .lnk of a directory, built in a single interop call.
    public static LnkEntry[] GetLnkCatalog(string directory, bool recurse, int rank) {
        List<string> files = new List<string>();
        if (recurse) CollectLnkFiles(directory, files);
        else AddLnkFiles(directory, files);
        LnkEntry[] entries = new LnkEntry[files.Count];
        for (int i = 0; i < files.Count; i++) {
            LnkEntry entry    = new LnkEntry();
            entry.LnkPath     = files[i];
            entry.DisplayName = System.IO.Path.GetFileNameWithoutExtension(files[i]);
            entry.Rank        = rank;
            string target = ""; string aumid = ""; string iconPath = "";
            try {
                byte[] d = System.IO.File.ReadAllBytes(files[i]);
                ParseLnk(d, System.IO.Path.GetDirectoryName(files[i]), out target, out aumid, out iconPath);
            } catch { }
            entry.TargetPath = target;
            entry.Aumid      = aumid;
            entry.IconPath   = iconPath;
            entries[i] = entry;
        }
        return entries;
    }
}

// One catalogued shortcut.
public class LnkEntry {
    public string LnkPath;
    public string DisplayName;
    public string TargetPath;
    public string Aumid;
    public string IconPath;
    public int Rank;
}

// One application of shell:AppsFolder.
public class AppEntry {
    public string Aumid;
    public string DisplayName;
    public string TargetParsingPath;
}

// The pin list of one Taskband key : Favorites entries ([CSIDL][uint32 size][PIDL], then 0xFF)
// and FavoritesResolve records ([uint32 size][data], one per entry), always kept aligned.
public class TaskbandPinList {
    readonly List<byte[]> entries = new List<byte[]>();
    readonly List<byte[]> records = new List<byte[]>();

    // A malformed Favorites throws (nothing is written over it); missing or malformed records
    // are read as empty, extra ones dropped.
    public static TaskbandPinList Parse(byte[] favorites, byte[] resolve) {
        TaskbandPinList pinList = new TaskbandPinList();
        int pos = 0;
        while (favorites != null && pos < favorites.Length && favorites[pos] != 0xFF) {
            if (pos + 5 > favorites.Length) throw new InvalidOperationException("Truncated Favorites entry.");
            uint pidlSize = BitConverter.ToUInt32(favorites, pos + 1);
            if (pidlSize < 2 || pidlSize > (long)favorites.Length - pos - 5) throw new InvalidOperationException("Invalid Favorites entry size.");
            int end = pos + 5 + (int)pidlSize, item = pos + 5;
            while (item + 2 <= end && BitConverter.ToUInt16(favorites, item) != 0) {
                int itemSize = BitConverter.ToUInt16(favorites, item);
                if (itemSize < 2 || itemSize > end - item) throw new InvalidOperationException("Invalid Favorites PIDL.");
                item += itemSize;
            }
            if (item + 2 != end) throw new InvalidOperationException("Invalid Favorites PIDL terminator.");
            byte[] entry = new byte[end - pos];
            Array.Copy(favorites, pos, entry, 0, entry.Length);
            pinList.entries.Add(entry);
            pos = end;
        }
        if (favorites != null && favorites.Length > 0 && pos != favorites.Length - 1) throw new InvalidOperationException("Invalid Favorites list terminator.");
        pos = 0;
        while (resolve != null && pos + 4 <= resolve.Length && pinList.records.Count < pinList.entries.Count) {
            uint recordSize = BitConverter.ToUInt32(resolve, pos);
            if (recordSize > (long)resolve.Length - pos - 4) { pinList.records.Clear(); break; }
            byte[] record = new byte[4 + recordSize];
            Array.Copy(resolve, pos, record, 0, record.Length);
            pinList.records.Add(record);
            pos += record.Length;
        }
        while (pinList.records.Count < pinList.entries.Count) pinList.records.Add(new byte[4]);
        return pinList;
    }

    public int Count { get { return entries.Count; } }
    public byte[] GetEntry(int index) { return entries[index]; }
    // A repaired entry keeps its record (same item); a replaced one gets an empty record.
    public void SetEntry(int index, byte[] entry, bool resetRecord) { entries[index] = entry; if (resetRecord) records[index] = new byte[4]; }
    public void SetRecord(int index, byte[] record) { records[index] = record; }
    public int Add(byte[] entry) { entries.Add(entry); records.Add(new byte[4]); return entries.Count - 1; }
    public void RemoveAt(int index) { entries.RemoveAt(index); records.RemoveAt(index); }

    // True when the entry is active and its record is empty or, with replaceForeign, not in
    // Windows' form.
    public bool NeedsRecord(int index, bool replaceForeign) {
        if (TaskbarPin.IsRetiredEntry(entries[index])) return false;
        return records[index].Length == 4 || (replaceForeign && !TaskbarPin.IsWindowsRecord(records[index]));
    }

    // Index of the entry pointing to this shortcut (same path, else with matchFileName the
    // same file name), an active entry before a retired one; -1 when there is none.
    public int IndexOfPath(string lnkPath, bool matchFileName) {
        string fileName = System.IO.Path.GetFileName(lnkPath);
        int bestIndex = -1, bestRank = 4;
        for (int i = 0; i < entries.Count; i++) {
            string entryPath = TaskbarPin.GetEntryPath(entries[i]);
            int rank;
            if (string.Equals(entryPath, lnkPath, StringComparison.OrdinalIgnoreCase)) rank = 0;
            else if (matchFileName && entryPath.Length > 0 && string.Equals(System.IO.Path.GetFileName(entryPath), fileName, StringComparison.OrdinalIgnoreCase)) rank = 1;
            else continue;
            if (TaskbarPin.IsRetiredEntry(entries[i])) rank += 2;
            if (rank < bestRank) { bestIndex = i; bestRank = rank; }
        }
        return bestIndex;
    }

    // Index of the entry holding this AppID in BEEF001D, an active entry before a retired one;
    // -1 when there is none.
    public int IndexOfAppId(string appId) {
        if (string.IsNullOrEmpty(appId)) return -1;
        int retiredIndex = -1;
        for (int i = 0; i < entries.Count; i++) {
            if (!string.Equals(TaskbarPin.GetEntryAppId(entries[i]), appId, StringComparison.OrdinalIgnoreCase)) continue;
            if (!TaskbarPin.IsRetiredEntry(entries[i])) return i;
            if (retiredIndex < 0) retiredIndex = i;
        }
        return retiredIndex;
    }

    public byte[] Favorites { get { return Join(entries, true); } }
    public byte[] Resolve { get { return Join(records, false); } }
    static byte[] Join(List<byte[]> parts, bool terminate) {
        System.IO.MemoryStream ms = new System.IO.MemoryStream();
        foreach (byte[] part in parts) ms.Write(part, 0, part.Length);
        if (terminate) ms.WriteByte(0xFF);
        return ms.ToArray();
    }
}
'@
    Write-Log "[init] C# native helper compiled successfully"
}

# Opens the Taskband registry key of the effective primary user (HKU\{SID} in cross-user mode).
function Open-EffectiveTaskbandKey {
    param([bool]$Writable = $false)
    if ($IsRunningCrossUser) { return [Microsoft.Win32.Registry]::Users.OpenSubKey("$EffectivePrimaryUserSID\$TaskBandRegistrySubKey", $Writable) }
    return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($TaskBandRegistrySubKey, $Writable)
}


#region RESOLUTION HELPERS

# Control Panel namespace item (Name, Path) owning a .cpl file, or $null.
function Resolve-CplControlPanelItem {
    param([string]$CplFilePath)
    $CplFileName = [IO.Path]::GetFileName($CplFilePath).ToLower()
    $CplBaseName = [IO.Path]::GetFileNameWithoutExtension($CplFilePath).ToLower()
    $CplShellApplication   = New-Object -ComObject Shell.Application
    $ControlPanelNamespace = $CplShellApplication.Namespace('shell:ControlPanelFolder')
    $MatchedResult = $null
    foreach ($ControlPanelItem in $ControlPanelNamespace.Items()) {
        $ControlPanelItemPath = $ControlPanelItem.Path
        foreach ($GuidMatch in [regex]::Matches($ControlPanelItemPath, '\{[0-9A-Fa-f\-]+\}')) {
            $InprocRegistryKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("CLSID\$($GuidMatch.Value)\InprocServer32")
            if ($InprocRegistryKey) {
                $ModulePath = $InprocRegistryKey.GetValue($null, ''); $InprocRegistryKey.Close()
                if ($ModulePath -and [IO.Path]::GetFileName($ModulePath).ToLower() -eq $CplFileName) { $MatchedResult = @{ Name = $ControlPanelItem.Name; Path = $ControlPanelItemPath }; break }
            }
            $DefaultIconKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("CLSID\$($GuidMatch.Value)\DefaultIcon")
            if ($DefaultIconKey) {
                $IconValue = $DefaultIconKey.GetValue($null, ''); $DefaultIconKey.Close()
                if ($IconValue -and $IconValue.ToLower().Contains($CplBaseName)) { $MatchedResult = @{ Name = $ControlPanelItem.Name; Path = $ControlPanelItemPath }; break }
            }
        }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ControlPanelItem)
        if ($MatchedResult) { break }
    }
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ControlPanelNamespace)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($CplShellApplication)
    return $MatchedResult
}

# Resolves a filesystem input to absolute paths : direct paths, wildcards, bare names searched
# through the current directory and PATH (with PATHEXT extensions and .lnk).
function Resolve-FilesystemInput {
    param([string]$InputPath)
    $InputContainsWildcard      = $InputPath.Contains('*') -or $InputPath.Contains('?')
    $InputContainsDirectoryPart = $InputPath.Contains('\') -or $InputPath.Contains('/')
    if (-not $InputContainsWildcard) {
        try {
            $AbsoluteDirectPath = [IO.Path]::GetFullPath([IO.Path]::Combine($PWD.ProviderPath, $InputPath))
            if ([IO.File]::Exists($AbsoluteDirectPath))      { return $AbsoluteDirectPath }
            if ([IO.Directory]::Exists($AbsoluteDirectPath)) { return $AbsoluteDirectPath }
        } catch { }
    }
    $FileNamePattern = [IO.Path]::GetFileName($InputPath)
    if ($InputContainsDirectoryPart) {
        try {
            $ExplicitSearchDirectory = [IO.Path]::GetFullPath([IO.Path]::Combine($PWD.ProviderPath, [IO.Path]::GetDirectoryName($InputPath)))
            if ([IO.Directory]::Exists($ExplicitSearchDirectory)) {
                $FoundFilesInDirectory = @([IO.Directory]::GetFiles($ExplicitSearchDirectory, $FileNamePattern))
                if ($FoundFilesInDirectory.Count -gt 0) { return $FoundFilesInDirectory }
            }
        } catch { }
    } else {
        $DirectoriesToSearch = @($PWD.ProviderPath)
        foreach ($PathEntry in ($env:PATH -split ';')) {
            if ($PathEntry -and [IO.Directory]::Exists($PathEntry)) { $DirectoriesToSearch += $PathEntry }
        }
        $PatternsToTry = @($FileNamePattern)
        if (-not $InputContainsWildcard -and -not [IO.Path]::HasExtension($FileNamePattern)) {
            foreach ($ExecutableExtension in ($env:PATHEXT -split ';')) { $PatternsToTry += "$FileNamePattern$ExecutableExtension" }
            $PatternsToTry += "$FileNamePattern.lnk"
        }
        foreach ($SearchDirectory in $DirectoriesToSearch) {
            foreach ($SearchPattern in $PatternsToTry) {
                try {
                    $FoundFiles = @([IO.Directory]::GetFiles($SearchDirectory, $SearchPattern))
                    if ($FoundFiles.Count -gt 0) { return $FoundFiles }
                } catch { }
            }
        }
    }
    return
}

# Cached snapshot of shell:AppsFolder : AUMID, display name, target parsing path.
$script:AppsFolderSnapshot = $null
function Get-AppsFolderSnapshot {
    if ($null -ne $script:AppsFolderSnapshot) { return $script:AppsFolderSnapshot }
    Initialize-NativeHelper
    try { $script:AppsFolderSnapshot = [TaskbarPin]::GetAppsFolderEntries() }
    catch { $script:AppsFolderSnapshot = @(); Write-Log "  [apps] shell:AppsFolder could not be listed : $($_.Exception.Message)" 'Yellow' }
    Write-Log "  [apps] shell:AppsFolder : $(@($script:AppsFolderSnapshot).Count) installed application(s)"
    return $script:AppsFolderSnapshot
}

# Cached catalog of .lnk shortcuts, by rank : 1 = Start Menu (from its root, machine-wide and
# primary user), 2 = Quick Launch (not recursive : User Pinned stays out). AllUsers adds every
# other profile. Paths come from environment variables (.NET 3.5 lacks the Common* folders).
$script:ShortcutCatalog = $null
function Get-ShortcutCatalog {
    if ($null -ne $script:ShortcutCatalog) { return $script:ShortcutCatalog }
    Initialize-NativeHelper
    $StartMenuRelativeProfilePath  = 'AppData\Roaming\Microsoft\Windows\Start Menu'
    $PrimaryUserStartMenuDirectory = if (-not $IsRunningCrossUser) { [Environment]::GetFolderPath('StartMenu') } elseif ($PrimaryRoamingAppDataDirectory) { [IO.Path]::Combine($PrimaryRoamingAppDataDirectory, 'Microsoft\Windows\Start Menu') } else { '' }
    $ShortcutSearchRoots = @(
        @{ Directory = [IO.Path]::Combine($env:ProgramData, 'Microsoft\Windows\Start Menu'); Rank = 1; Recurse = $true },
        @{ Directory = $PrimaryUserStartMenuDirectory;                                       Rank = 1; Recurse = $true },
        @{ Directory = $QuickLaunchDirectory;                                                Rank = 2; Recurse = $false }
    )
    if ($AllUsers) {
        foreach ($UserProfile in @(Get-UserProfiles)) {
            $ShortcutSearchRoots += @{ Directory = [IO.Path]::Combine($UserProfile.ProfilePath, $StartMenuRelativeProfilePath); Rank = 1; Recurse = $true }
            $ShortcutSearchRoots += @{ Directory = [IO.Path]::Combine($UserProfile.ProfilePath, $QuickLaunchRelativePath);      Rank = 2; Recurse = $false }
        }
    }
    $CollectedShortcutEntries = New-Object System.Collections.ArrayList
    foreach ($SearchRoot in $ShortcutSearchRoots) {
        if (-not $SearchRoot.Directory -or -not [IO.Directory]::Exists($SearchRoot.Directory)) { continue }
        $CollectedShortcutEntries.AddRange([TaskbarPin]::GetLnkCatalog($SearchRoot.Directory, $SearchRoot.Recurse, $SearchRoot.Rank))
    }
    Write-Log "  [apps] Shortcut catalog : $($CollectedShortcutEntries.Count) shortcut(s) indexed from $($ShortcutSearchRoots.Count) location(s)"
    $script:ShortcutCatalog = @($CollectedShortcutEntries.ToArray())
    return $script:ShortcutCatalog
}

# Application identity (Aumid, DisplayName) of an executable : its shell:AppsFolder entry, else
# a catalogued shortcut to it carrying an AUMID; $null when there is none.
function Resolve-ExecutableIdentity {
    param([string]$ExecutableFullPath)
    foreach ($ApplicationEntry in (Get-AppsFolderSnapshot)) {
        if ($ApplicationEntry.TargetParsingPath -and $ApplicationEntry.TargetParsingPath -eq $ExecutableFullPath) { return $ApplicationEntry }
    }
    foreach ($CatalogRank in 1, 2) {
        foreach ($ShortcutEntry in (Get-ShortcutCatalog)) {
            if ($ShortcutEntry.Rank -ne $CatalogRank -or $ShortcutEntry.TargetPath -ne $ExecutableFullPath) { continue }
            if ($ShortcutEntry.Aumid) { return @{ Aumid = $ShortcutEntry.Aumid; DisplayName = $ShortcutEntry.DisplayName } }
        }
    }
    return $null
}

# Matches installed applications (shell:AppsFolder, then Start Menu, then Quick Launch). A
# wildcard pattern matches display names and AUMIDs and returns every match, deduplicated; a
# bare name matches display names only and resolves to a single application. Each result is
# of Kind 'Aumid' or 'Lnk'.
function Find-ApplicationMatches {
    param([string]$NameOrAumidPattern)
    if ($NameOrAumidPattern -match '[*?]') {
        # Invalid wildcard syntax (a stray '[') degrades to a literal pattern.
        try { $null = ('' -like $NameOrAumidPattern) } catch { $NameOrAumidPattern = [System.Management.Automation.WildcardPattern]::Escape($NameOrAumidPattern) }
        $MatchedApplications   = @()
        $AlreadyMatchedAumids  = @{}
        $AlreadyMatchedTargets = @{}
        foreach ($ApplicationEntry in (Get-AppsFolderSnapshot)) {
            if ($ApplicationEntry.DisplayName -like $NameOrAumidPattern -or $ApplicationEntry.Aumid -like $NameOrAumidPattern) {
                $MatchedApplications += @{ Kind = 'Aumid'; Aumid = $ApplicationEntry.Aumid; DisplayName = $ApplicationEntry.DisplayName }
                $AlreadyMatchedAumids[$ApplicationEntry.Aumid] = $true
                if ($ApplicationEntry.TargetParsingPath) { $AlreadyMatchedTargets[$ApplicationEntry.TargetParsingPath.ToLower()] = $true }
            }
        }
        foreach ($ShortcutEntry in (Get-ShortcutCatalog)) {
            if ($ShortcutEntry.DisplayName -notlike $NameOrAumidPattern) { continue }
            if ($ShortcutEntry.TargetPath -and $AlreadyMatchedTargets.ContainsKey($ShortcutEntry.TargetPath.ToLower())) { continue }
            if ($ShortcutEntry.Aumid -and $AlreadyMatchedAumids.ContainsKey($ShortcutEntry.Aumid)) { continue }
            $MatchedApplications += @{ Kind = 'Lnk'; LnkPath = $ShortcutEntry.LnkPath; DisplayName = $ShortcutEntry.DisplayName }
            if ($ShortcutEntry.Aumid) { $AlreadyMatchedAumids[$ShortcutEntry.Aumid] = $true }
            if ($ShortcutEntry.TargetPath) { $AlreadyMatchedTargets[$ShortcutEntry.TargetPath.ToLower()] = $true }
        }
        return $MatchedApplications
    }
    # Bare name : one pass per source collects substring and exact matches (the name is escaped
    # for -like, where [ ] form a character class).
    $SubstringMatchPattern = '*' + [System.Management.Automation.WildcardPattern]::Escape($NameOrAumidPattern) + '*'
    $ExactNameMatches      = @()
    $SubstringNameMatches  = @()
    foreach ($ApplicationEntry in (Get-AppsFolderSnapshot)) {
        if ($ApplicationEntry.DisplayName -notlike $SubstringMatchPattern) { continue }
        $CandidateMatch = @{ Kind = 'Aumid'; Aumid = $ApplicationEntry.Aumid; DisplayName = $ApplicationEntry.DisplayName; CandidateTargetPath = [string]$ApplicationEntry.TargetParsingPath; CandidateIconPath = '' }
        if ([string]::Equals($ApplicationEntry.DisplayName, $NameOrAumidPattern, [StringComparison]::OrdinalIgnoreCase)) { $ExactNameMatches += $CandidateMatch } else { $SubstringNameMatches += $CandidateMatch }
    }
    # Direct assignment (no if-expression) : assigning a one-element array out of an
    # if-expression unwraps it to the bare hashtable, whose .Count counts its keys.
    $CandidateSet = $SubstringNameMatches
    if ($ExactNameMatches.Count -gt 0) { $CandidateSet = $ExactNameMatches }
    if ($CandidateSet.Count -eq 1) { return $CandidateSet }
    if ($CandidateSet.Count -gt 1) { return @(Select-SingleApplicationMatch $CandidateSet $NameOrAumidPattern) }
    foreach ($CatalogRank in 1, 2) {
        $ExactNameMatches     = @()
        $SubstringNameMatches = @()
        foreach ($ShortcutEntry in (Get-ShortcutCatalog)) {
            if ($ShortcutEntry.Rank -ne $CatalogRank -or $ShortcutEntry.DisplayName -notlike $SubstringMatchPattern) { continue }
            $CandidateMatch = @{ Kind = 'Lnk'; LnkPath = $ShortcutEntry.LnkPath; DisplayName = $ShortcutEntry.DisplayName; Aumid = [string]$ShortcutEntry.Aumid; CandidateTargetPath = [string]$ShortcutEntry.TargetPath; CandidateIconPath = [string]$ShortcutEntry.IconPath }
            if ([string]::Equals($ShortcutEntry.DisplayName, $NameOrAumidPattern, [StringComparison]::OrdinalIgnoreCase)) { $ExactNameMatches += $CandidateMatch } else { $SubstringNameMatches += $CandidateMatch }
        }
        $CandidateSet = $SubstringNameMatches
        if ($ExactNameMatches.Count -gt 0) { $CandidateSet = $ExactNameMatches }
        if ($CandidateSet.Count -eq 1) { return $CandidateSet }
        if ($CandidateSet.Count -gt 1) { return @(Select-SingleApplicationMatch $CandidateSet $NameOrAumidPattern) }
    }
    return @()
}

# Keeps the candidates whose EliminationMetric equals the smallest value of the set.
function Select-MinimumMetricCandidates {
    param($ScoredCandidates)
    $SmallestMetricValue = $ScoredCandidates[0].EliminationMetric
    for ($CandidateIndex = 1; $CandidateIndex -lt $ScoredCandidates.Count; $CandidateIndex++) {
        if ($ScoredCandidates[$CandidateIndex].EliminationMetric -lt $SmallestMetricValue) { $SmallestMetricValue = $ScoredCandidates[$CandidateIndex].EliminationMetric }
    }
    $CandidatesAtMinimum = @()
    foreach ($ScoredCandidate in $ScoredCandidates) {
        if ($ScoredCandidate.EliminationMetric -eq $SmallestMetricValue) { $CandidatesAtMinimum += $ScoredCandidate }
    }
    return $CandidatesAtMinimum
}

# True when a candidate displays an icon of its own : UWP applications and targets under the
# Windows directory always do; otherwise the icon source (IconLocation, else the target) must
# be a UNC path (not probed), a stream or .ico file, or a file with icon resources outside the
# Windows directory.
function Test-CandidateOwnsIcon {
    param($Candidate)
    if ($Candidate.IsUwpApplication) { return $true }
    $WindowsDirectoryPrefix = $env:SystemRoot
    if (-not $WindowsDirectoryPrefix.EndsWith('\')) { $WindowsDirectoryPrefix = $WindowsDirectoryPrefix + '\' }
    $CandidateTargetPath = $Candidate.CandidateTargetPath
    if ($CandidateTargetPath -and $CandidateTargetPath.StartsWith($WindowsDirectoryPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $IconSourcePath = $Candidate.CandidateIconPath
    if (-not $IconSourcePath) { $IconSourcePath = $CandidateTargetPath }
    if (-not $IconSourcePath) { return $false }
    if ($IconSourcePath.StartsWith('\\')) { return $true }
    if ($IconSourcePath -match '^.{3,}:[^\\/:]+$') { return $true }
    if ($IconSourcePath.StartsWith($WindowsDirectoryPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($IconSourcePath.EndsWith('.ico', [StringComparison]::OrdinalIgnoreCase)) { return [IO.File]::Exists($IconSourcePath) }
    return ([TaskbarPin]::GetIconResourceCount($IconSourcePath) -gt 0)
}

# Reduces several bare-name matches to exactly one application through successive
# elimination stages, each applied only when at least one candidate survives it :
#   1. drop candidates that are neither UWP applications nor .exe-backed
#   2. drop candidates without an icon of their own (their displayed icon is synthesized)
#   3. keep the shortest display name
#   4. keep the shallowest target path -- a single candidate without a measurable target
#      (UWP application, registered-AUMID entry) among measurable ones wins instead
#   5. keep the earliest position of the typed name inside the display name
#   6. keep the first display name in ordinal order (deterministic last resort)
# Every stage is skipped once a single candidate remains.
function Select-SingleApplicationMatch {
    param($CandidateMatches, [string]$BareNameInput)
    Initialize-NativeHelper
    $RemainingCandidates = @($CandidateMatches)
    Write-Log "  [select] '$BareNameInput' matched $($RemainingCandidates.Count) applications -- reducing to a single one"
    foreach ($Candidate in $RemainingCandidates) {
        # UWP is recognized by the AUMID shape (PackageFamily!AppId), whatever the source.
        $CandidateAumid = [string]$Candidate.Aumid
        $Candidate.IsUwpApplication = ($CandidateAumid.IndexOf('!') -ge 0 -and $CandidateAumid.IndexOf('\') -lt 0)
    }
    if ($RemainingCandidates.Count -gt 1) {
        $ExecutableBackedCandidates = @()
        foreach ($Candidate in $RemainingCandidates) {
            if ($Candidate.IsUwpApplication -or $Candidate.CandidateTargetPath.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { $ExecutableBackedCandidates += $Candidate }
        }
        if ($ExecutableBackedCandidates.Count -gt 0 -and $ExecutableBackedCandidates.Count -lt $RemainingCandidates.Count) {
            Write-Log "  [select] executable/UWP filter : $($RemainingCandidates.Count) -> $($ExecutableBackedCandidates.Count)"
            $RemainingCandidates = $ExecutableBackedCandidates
        }
    }
    if ($RemainingCandidates.Count -gt 1) {
        $OwnIconCandidates = @()
        foreach ($Candidate in $RemainingCandidates) {
            if (Test-CandidateOwnsIcon $Candidate) { $OwnIconCandidates += $Candidate }
        }
        if ($OwnIconCandidates.Count -gt 0 -and $OwnIconCandidates.Count -lt $RemainingCandidates.Count) {
            Write-Log "  [select] own-icon filter : $($RemainingCandidates.Count) -> $($OwnIconCandidates.Count)"
            $RemainingCandidates = $OwnIconCandidates
        }
    }
    if ($RemainingCandidates.Count -gt 1) {
        foreach ($Candidate in $RemainingCandidates) { $Candidate.EliminationMetric = $Candidate.DisplayName.Length }
        $RemainingCandidates = @(Select-MinimumMetricCandidates $RemainingCandidates)
    }
    if ($RemainingCandidates.Count -gt 1) {
        # Depth of the filesystem target : a single candidate without one wins, several make
        # the stage inapplicable.
        $MeasurableCandidates   = @()
        $UnmeasurableCandidates = @()
        foreach ($Candidate in $RemainingCandidates) {
            if ($Candidate.CandidateTargetPath) { $MeasurableCandidates += $Candidate } else { $UnmeasurableCandidates += $Candidate }
        }
        if ($UnmeasurableCandidates.Count -eq 0) {
            foreach ($Candidate in $RemainingCandidates) { $Candidate.EliminationMetric = $Candidate.CandidateTargetPath.Split('\').Length }
            $RemainingCandidates = @(Select-MinimumMetricCandidates $RemainingCandidates)
        } elseif ($UnmeasurableCandidates.Count -eq 1 -and $MeasurableCandidates.Count -gt 0) {
            $RemainingCandidates = $UnmeasurableCandidates
        }
    }
    if ($RemainingCandidates.Count -gt 1) {
        # -like may match where an ordinal IndexOf finds nothing (-1) : worst rank then.
        foreach ($Candidate in $RemainingCandidates) {
            $PatternPositionInTitle = $Candidate.DisplayName.IndexOf($BareNameInput, [StringComparison]::OrdinalIgnoreCase)
            if ($PatternPositionInTitle -lt 0) { $PatternPositionInTitle = [int]::MaxValue }
            $Candidate.EliminationMetric = $PatternPositionInTitle
        }
        $RemainingCandidates = @(Select-MinimumMetricCandidates $RemainingCandidates)
    }
    $SelectedApplicationMatch = $RemainingCandidates[0]
    for ($CandidateIndex = 1; $CandidateIndex -lt $RemainingCandidates.Count; $CandidateIndex++) {
        if ([string]::CompareOrdinal($RemainingCandidates[$CandidateIndex].DisplayName, $SelectedApplicationMatch.DisplayName) -lt 0) { $SelectedApplicationMatch = $RemainingCandidates[$CandidateIndex] }
    }
    Write-Log "  [select] selected : '$($SelectedApplicationMatch.DisplayName)'"
    return $SelectedApplicationMatch
}

# Name of the shortcut pinning a folder : the folder's whole name (dots included); for a
# drive, the name the shell shows less the characters a file name cannot hold ("Local Disk (C)").
function Get-DirectoryShortcutName {
    param([string]$DirectoryPath)
    $DirectoryName = [IO.Path]::GetFileName($DirectoryPath.TrimEnd('\', '/'))
    if (-not $DirectoryName) { Initialize-NativeHelper; $DirectoryName = ([TaskbarPin]::GetShellDisplayName($DirectoryPath) -replace '[<>:"/\\|?*]', '').Trim() }
    if (-not $DirectoryName) { $DirectoryName = $DirectoryPath -replace '[<>:"/\\|?*]', '' }
    return $DirectoryName
}

# Produces a .lnk to pin from a resolved path, and reports through $Beef001dContentRef a
# fallback AppID (unique per item) for when Windows cannot compute one :
#   .lnk        : returned as-is; its AUMID, or its target path without one.
#   .cpl        : resolved through the Control Panel namespace (proper icon and name), with
#                 a rundll32 shortcut as second chance; the namespace or .cpl path.
#   directories : temporary explorer.exe shortcut named after the folder (a drive after the
#                 name the shell shows, "Local Disk (C)"); the directory path.
#   .exe/other  : temporary shortcut named after the FileDescription when available; the
#                 target path.
function New-TargetShortcut {
    param([string]$ResolvedTargetPath, [ref]$Beef001dContentRef, [ref]$WshShellComObjectRef)
    $TargetFileExtension = [IO.Path]::GetExtension($ResolvedTargetPath).ToLower()
    if (-not $WshShellComObjectRef.Value) { $WshShellComObjectRef.Value = New-Object -ComObject WScript.Shell }
    if ($TargetFileExtension -eq '.lnk') {
        $ShortcutObject = $WshShellComObjectRef.Value.CreateShortcut($ResolvedTargetPath)
        $ShortcutTargetPath = $ShortcutObject.TargetPath
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ShortcutObject)
        $ShortcutAppUserModelId = ''
        if ('TaskbarPin' -as [Type]) { $ShortcutAppUserModelId = [TaskbarPin]::GetAumid($ResolvedTargetPath) }
        if ($ShortcutAppUserModelId) { $Beef001dContentRef.Value = $ShortcutAppUserModelId } else { $Beef001dContentRef.Value = $ShortcutTargetPath }
        return $ResolvedTargetPath
    }
    if ($TargetFileExtension -eq '.cpl') {
        Initialize-NativeHelper
        $CplControlPanelMatch = Resolve-CplControlPanelItem $ResolvedTargetPath
        if ($CplControlPanelMatch) {
            $CplTemporaryLnkPath = Get-TemporaryShortcutPath "$($CplControlPanelMatch.Name -replace '[<>:"/\\|?*]', '_').lnk"
            if ([TaskbarPin]::CreatePidlShortcut($CplControlPanelMatch.Path, $CplTemporaryLnkPath, $CplControlPanelMatch.Path)) {
                $Beef001dContentRef.Value = $CplControlPanelMatch.Path
                return $CplTemporaryLnkPath
            }
        }
    }
    $TargetIsDirectory = [IO.Directory]::Exists($ResolvedTargetPath)
    if ($TargetIsDirectory) {
        if ($ResolvedTargetPath.Length -gt [IO.Path]::GetPathRoot($ResolvedTargetPath).Length) { $ResolvedTargetPath = $ResolvedTargetPath.TrimEnd('\', '/') }
        $ShortcutDisplayName = Get-DirectoryShortcutName $ResolvedTargetPath
    } else {
        $ShortcutDisplayName = [IO.Path]::GetFileNameWithoutExtension($ResolvedTargetPath)
    }
    if ($TargetFileExtension -eq '.exe' -and -not $TargetIsDirectory) {
        try {
            $FileVersionDescription = [Diagnostics.FileVersionInfo]::GetVersionInfo($ResolvedTargetPath).FileDescription
            if ($FileVersionDescription -and $FileVersionDescription.Trim()) { $ShortcutDisplayName = $FileVersionDescription.Trim() -replace '[<>:"/\\|?*]', '_' }
        } catch { }
    }
    $TemporaryLnkPath = Get-TemporaryShortcutPath "$ShortcutDisplayName.lnk"
    $NewShortcutObject = $WshShellComObjectRef.Value.CreateShortcut($TemporaryLnkPath)
    if ($TargetIsDirectory) {
        # Checked before the .cpl extension (a directory may be named *.cpl).
        $NewShortcutObject.TargetPath       = [IO.Path]::Combine($env:SystemRoot, 'explorer.exe')
        $NewShortcutObject.Arguments        = "`"$ResolvedTargetPath`""
        $NewShortcutObject.IconLocation     = [IO.Path]::Combine($env:SystemRoot, 'System32\shell32.dll') + ',3'
        $NewShortcutObject.WorkingDirectory = $ResolvedTargetPath
    } elseif ($TargetFileExtension -eq '.cpl') {
        # AppID : the .cpl, not rundll32.exe, which many items share.
        $NewShortcutObject.TargetPath       = [IO.Path]::Combine($env:SystemRoot, 'System32\rundll32.exe')
        $NewShortcutObject.Arguments        = "shell32.dll,Control_RunDLL `"$ResolvedTargetPath`""
        $NewShortcutObject.IconLocation     = "$ResolvedTargetPath,0"
        $NewShortcutObject.WorkingDirectory = [IO.Path]::GetDirectoryName($ResolvedTargetPath)
    } else {
        $NewShortcutObject.TargetPath       = $ResolvedTargetPath
        $NewShortcutObject.WorkingDirectory = [IO.Path]::GetDirectoryName($ResolvedTargetPath)
    }
    $Beef001dContentRef.Value = $ResolvedTargetPath
    $NewShortcutObject.Save()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($NewShortcutObject)
    return $TemporaryLnkPath
}


#region PIN STATE HELPERS

# Runs an action on the writable Taskband key of the effective primary user while holding
# TaskbarPinListMutex, as Windows does for its own pin changes. Returns what the action returns.
function Invoke-WithTaskbandKey {
    param([scriptblock]$ActionToPerform)
    if (-not [TaskbarPin]::AcquirePinMutex(5000)) { throw 'The taskbar pin list is busy (TaskbarPinListMutex held for 5 s) : nothing was written.' }
    Write-Log "[mutex] TaskbarPinListMutex acquired"
    try {
        $TaskBandRegistryKey = Open-EffectiveTaskbandKey $true
        if (-not $TaskBandRegistryKey) { throw 'The Taskband registry key cannot be opened for writing.' }
        try { & $ActionToPerform $TaskBandRegistryKey } finally { $TaskBandRegistryKey.Close() }
    } finally {
        [TaskbarPin]::ReleasePinMutex()
        Write-Log "[mutex] TaskbarPinListMutex released"
    }
}

# Reads the pin list of a Taskband key, keeping the raw values it was parsed from.
function Read-TaskbandPinList {
    param($RegistryKeyHandle)
    $FavoritesBlob = $RegistryKeyHandle.GetValue('Favorites', $null, $DoNotExpandRegistryOption)
    $ResolveBlob   = $RegistryKeyHandle.GetValue('FavoritesResolve', $null, $DoNotExpandRegistryOption)
    return @{ FavoritesBlob = $FavoritesBlob; ResolveBlob = $ResolveBlob; PinList = [TaskbandPinList]::Parse($FavoritesBlob, $ResolveBlob) }
}

# Writes a pin list back : FavoritesResolve, Favorites, FavoritesVersion, then FavoritesChanges
# last (a DWORD that wraps around). Nothing is written when either value changed since it was
# read; a failed write puts back the values already written. Returns $false when the pin list
# is unchanged.
function Save-TaskbandPinList {
    param($RegistryKeyHandle, $PinListState)
    $FavoritesBlob = $PinListState.PinList.Favorites
    $ResolveBlob   = $PinListState.PinList.Resolve
    if ([TaskbarPin]::BytesEqual($FavoritesBlob, $PinListState.FavoritesBlob) -and [TaskbarPin]::BytesEqual($ResolveBlob, $PinListState.ResolveBlob)) { return $false }
    if (-not [TaskbarPin]::BytesEqual($RegistryKeyHandle.GetValue('Favorites', $null, $DoNotExpandRegistryOption), $PinListState.FavoritesBlob) -or
        -not [TaskbarPin]::BytesEqual($RegistryKeyHandle.GetValue('FavoritesResolve', $null, $DoNotExpandRegistryOption), $PinListState.ResolveBlob)) {
        throw 'The pin list changed while it was being prepared : nothing was written, run the script again.'
    }
    $FavoritesChangesCounter     = [int]$RegistryKeyHandle.GetValue('FavoritesChanges', 0, $DoNotExpandRegistryOption)
    $NextFavoritesChangesCounter = [BitConverter]::ToInt32([BitConverter]::GetBytes([long]$FavoritesChangesCounter + 1), 0)
    $ValuesToWrite = @(
        @{ Name = 'FavoritesResolve'; Data = $ResolveBlob;                 Kind = $BinaryRegistryValueKind },
        @{ Name = 'Favorites';        Data = $FavoritesBlob;               Kind = $BinaryRegistryValueKind },
        @{ Name = 'FavoritesVersion'; Data = 3;                            Kind = $DwordRegistryValueKind },
        @{ Name = 'FavoritesChanges'; Data = $NextFavoritesChangesCounter; Kind = $DwordRegistryValueKind })
    $PreviousValues = @()
    try {
        foreach ($ValueToWrite in $ValuesToWrite) {
            $PreviousData = $RegistryKeyHandle.GetValue($ValueToWrite.Name, $null, $DoNotExpandRegistryOption)
            $PreviousValues += @{ Name = $ValueToWrite.Name; Data = $PreviousData; Kind = $(if ($null -ne $PreviousData) { $RegistryKeyHandle.GetValueKind($ValueToWrite.Name) }) }
            $RegistryKeyHandle.SetValue($ValueToWrite.Name, $ValueToWrite.Data, $ValueToWrite.Kind)
        }
    } catch {
        foreach ($PreviousValue in $PreviousValues) {
            try {
                if ($null -eq $PreviousValue.Data) { $RegistryKeyHandle.DeleteValue($PreviousValue.Name, $false) }
                else { $RegistryKeyHandle.SetValue($PreviousValue.Name, $PreviousValue.Data, $PreviousValue.Kind) }
            } catch { }
        }
        throw
    }
    Write-Log "    [blob] $($PinListState.PinList.Count) entries written (Favorites $($FavoritesBlob.Length) bytes, FavoritesResolve $($ResolveBlob.Length) bytes) | FavoritesChanges : $FavoritesChangesCounter -> $NextFavoritesChangesCounter"
    return $true
}

# Path of the .lnk an entry points to. In another user's list, its file name in that user's
# TaskBar directory ('' for an entry outside a TaskBar directory).
function Get-EntryShortcutPath {
    param([byte[]]$PinnedEntry, [bool]$IsOwnerSession, [string]$OwnerTaskBarDirectory)
    $EntryPath = [TaskbarPin]::GetEntryPath($PinnedEntry)
    if ($IsOwnerSession -or -not $EntryPath) { return $EntryPath }
    if (-not ([string][IO.Path]::GetDirectoryName($EntryPath)).EndsWith('\User Pinned\TaskBar', [StringComparison]::OrdinalIgnoreCase)) { return '' }
    return [IO.Path]::Combine($OwnerTaskBarDirectory, [IO.Path]::GetFileName($EntryPath))
}

# Gives an active entry its FavoritesResolve record when the record is empty or, with
# $ReplaceForeignRecord, not in Windows' form. Returns $true when the record changed.
function Set-EntryResolveRecord {
    param($PinList, [int]$EntryIndex, [bool]$IsOwnerSession, [string]$OwnerTaskBarDirectory, [bool]$ReplaceForeignRecord)
    if (-not $PinList.NeedsRecord($EntryIndex, $ReplaceForeignRecord)) { return $false }
    $PinnedEntry = $PinList.GetEntry($EntryIndex)
    $ShortcutPathInProfile = ''
    if (-not $IsOwnerSession -and [TaskbarPin]::GetEntryPath($PinnedEntry)) {
        $ShortcutPathInProfile = Get-EntryShortcutPath $PinnedEntry $false $OwnerTaskBarDirectory
        if (-not ($ShortcutPathInProfile -and [IO.File]::Exists($ShortcutPathInProfile))) { return $false }
    }
    try {
        if ($ShortcutPathInProfile) { $PinList.SetRecord($EntryIndex, [TaskbarPin]::BuildResolveRecordForPath($ShortcutPathInProfile)) }
        else                        { $PinList.SetRecord($EntryIndex, [TaskbarPin]::BuildResolveRecord($PinnedEntry)) }
        return $true
    } catch {
        Write-Log "    [resolve] The record of entry $EntryIndex could not be built : $($_.Exception.Message)" 'Yellow'
        return $false
    }
}

# Adds the prepared entries to a pin list, or updates the entry already holding the item (same
# .lnk, else same AppID) : a retired entry is replaced in place, an active one repaired when
# needed. Empty records are filled. Returns the number of entries added, replaced or repaired.
function Write-BlobToRegistryKey {
    param($RegistryKeyHandle, $PreparedBlobEntries, [bool]$IsOwnerSession, [string]$OwnerTaskBarDirectory)
    $PinListState = Read-TaskbandPinList $RegistryKeyHandle
    $PinList = $PinListState.PinList
    $ChangedEntryCount = 0
    foreach ($PreparedEntry in $PreparedBlobEntries) {
        $ShortcutFileName = [IO.Path]::GetFileName($PreparedEntry.DestinationLnkPath)
        $EntryIndex = $PinList.IndexOfPath($PreparedEntry.DestinationLnkPath, -not $IsOwnerSession)
        if ($EntryIndex -lt 0) { $EntryIndex = $PinList.IndexOfAppId($PreparedEntry.Beef001dContent) }
        if ($EntryIndex -lt 0) {
            $EntryIndex = $PinList.Add($PreparedEntry.SerializedBlobEntry)
            $ChangedEntryCount++
            Write-Log "    [blob] '$ShortcutFileName' appended at index $EntryIndex"
        } elseif ([TaskbarPin]::IsRetiredEntry($PinList.GetEntry($EntryIndex))) {
            $PinList.SetEntry($EntryIndex, $PreparedEntry.SerializedBlobEntry, $true)
            $PreparedEntry.EntryWasRepaired = $true
            $ChangedEntryCount++
            Write-Log "    [blob] '$ShortcutFileName' replaces the retired entry at index $EntryIndex"
        } else {
            $RepairedEntry = [TaskbarPin]::FixEntry($PinList.GetEntry($EntryIndex), $PreparedEntry.Beef001dContent)
            if ($RepairedEntry) {
                $PinList.SetEntry($EntryIndex, $RepairedEntry, $false)
                $PreparedEntry.EntryWasRepaired = $true
                $ChangedEntryCount++
                Write-Log "    [blob] '$ShortcutFileName' already pinned at index $EntryIndex : entry repaired"
            } else { Write-Log "    [blob] '$ShortcutFileName' already pinned at index $EntryIndex" }
        }
        $null = Set-EntryResolveRecord $PinList $EntryIndex $IsOwnerSession $OwnerTaskBarDirectory $true
    }
    for ($EntryIndex = 0; $EntryIndex -lt $PinList.Count; $EntryIndex++) {
        if (Set-EntryResolveRecord $PinList $EntryIndex $IsOwnerSession $OwnerTaskBarDirectory $false) { Write-Log "    [resolve] Empty record of entry $EntryIndex filled" }
    }
    if (-not (Save-TaskbandPinList $RegistryKeyHandle $PinListState)) { Write-Log "    [blob] Pin list unchanged : nothing written" }
    return $ChangedEntryCount
}

# The primary user's pin list as it is now, $null when its key cannot be opened.
function Read-PrimaryPinList {
    $TaskBandRegistryKey = Open-EffectiveTaskbandKey $false
    if (-not $TaskBandRegistryKey) { return $null }
    try { return (Read-TaskbandPinList $TaskBandRegistryKey).PinList } finally { $TaskBandRegistryKey.Close() }
}

# Looks in a pin list for the active entry holding this AppID. Returns $null when there is
# none, else its ShortcutPath : its .lnk in the TaskBar directory (present or missing), or ''
# (an application pinned through shell:AppsFolder).
function Find-PinnedApplication {
    param($PinList, [string]$ApplicationId)
    if (-not $ApplicationId -or -not $PinList) { return $null }
    $EntryIndex = $PinList.IndexOfAppId($ApplicationId)
    if ($EntryIndex -lt 0 -or [TaskbarPin]::IsRetiredEntry($PinList.GetEntry($EntryIndex))) { return $null }
    $PinnedShortcutPath = Get-EntryShortcutPath $PinList.GetEntry($EntryIndex) (-not $IsRunningCrossUser) $TaskBarPinnedDirectory
    if (-not ($PinnedShortcutPath.EndsWith('.lnk', [StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([IO.Path]::GetDirectoryName($PinnedShortcutPath), $TaskBarPinnedDirectory, [StringComparison]::OrdinalIgnoreCase))) { $PinnedShortcutPath = '' }
    return @{ ShortcutPath = $PinnedShortcutPath }
}

# Path for the pinned .lnk of an application : the proposed one when it is free or holds this
# application's shortcut, else ' (2)', ' (3)'..., as Windows names a new pin : a .lnk of
# another application, or whose AppID cannot be read, is never written over.
function Get-AvailablePinnedShortcutPath {
    param([string]$ProposedShortcutPath, [string]$ApplicationId)
    $ShortcutDirectory     = [IO.Path]::GetDirectoryName($ProposedShortcutPath)
    $ShortcutBaseName      = [IO.Path]::GetFileNameWithoutExtension($ProposedShortcutPath)
    $CandidateShortcutPath = $ProposedShortcutPath
    for ($NameSuffix = 2; [IO.File]::Exists($CandidateShortcutPath); $NameSuffix++) {
        $ExistingApplicationId = [TaskbarPin]::GetShortcutAppId($CandidateShortcutPath)
        if ($ExistingApplicationId -and [string]::Equals($ExistingApplicationId, $ApplicationId, [StringComparison]::OrdinalIgnoreCase)) { break }
        $CandidateShortcutPath = [IO.Path]::Combine($ShortcutDirectory, "$ShortcutBaseName ($NameSuffix).lnk")
    }
    return $CandidateShortcutPath
}

# Brings a pinned .lnk up to date from its source, in place (same position and name). A changed
# file gets a write time at least 2 seconds later, an unchanged one keeps its time. Returns
# $true when the pinned file changed.
function Update-PinnedShortcut {
    param([string]$PinnedShortcutPath, [string]$SourceShortcutPath)
    $PreviousContent   = [IO.File]::ReadAllBytes($PinnedShortcutPath)
    $PreviousWriteTime = [IO.File]::GetLastWriteTimeUtc($PinnedShortcutPath)
    if ($SourceShortcutPath -and -not [string]::Equals($SourceShortcutPath, $PinnedShortcutPath, [StringComparison]::OrdinalIgnoreCase)) {
        $null = [TaskbarPin]::WriteInPlace($PinnedShortcutPath, [IO.File]::ReadAllBytes($SourceShortcutPath))
    }
    $null = [TaskbarPin]::EmbedStreamIcon($PinnedShortcutPath)
    if ([TaskbarPin]::BytesEqual([IO.File]::ReadAllBytes($PinnedShortcutPath), $PreviousContent)) {
        if ([IO.File]::GetLastWriteTimeUtc($PinnedShortcutPath) -ne $PreviousWriteTime) { [IO.File]::SetLastWriteTimeUtc($PinnedShortcutPath, $PreviousWriteTime) }
        return $false
    }
    if (([IO.File]::GetLastWriteTimeUtc($PinnedShortcutPath) - $PreviousWriteTime).TotalSeconds -lt 2) { [IO.File]::SetLastWriteTimeUtc($PinnedShortcutPath, $PreviousWriteTime.AddSeconds(2)) }
    return $true
}

# Checks every active entry of a pin list : entries whose .lnk is gone or listed twice are
# removed, extension blocks and records repaired. In the list owner's session, BEEF001D is set
# to the AppID Windows gives the .lnk and an icon living in another file's stream is embedded.
# Returns the number of repairs.
function Repair-PinnedItems {
    param($RegistryKeyHandle, [bool]$IsOwnerSession, [string]$OwnerTaskBarDirectory, [bool]$NotifyTaskbar)
    $PinListState = Read-TaskbandPinList $RegistryKeyHandle
    $PinList = $PinListState.PinList
    if ($PinList.Count -eq 0) { Write-Log "    [repair] No pinned item"; return 0 }
    $RepairCount       = 0
    $SeenShortcutPaths = @{}
    $ShortcutsToReload = @()
    $EntryIndex        = 0
    while ($EntryIndex -lt $PinList.Count) {
        $PinnedEntry = $PinList.GetEntry($EntryIndex)
        if ([TaskbarPin]::IsRetiredEntry($PinnedEntry)) { $EntryIndex++; continue }
        $PinnedShortcutPath = Get-EntryShortcutPath $PinnedEntry $IsOwnerSession $OwnerTaskBarDirectory
        $PreviousAppId      = [TaskbarPin]::GetEntryAppId($PinnedEntry)
        $EntryLabel         = if ($PinnedShortcutPath) { [IO.Path]::GetFileName($PinnedShortcutPath) } else { "entry $EntryIndex ($PreviousAppId)" }
        $RemovalReason      = ''
        if ($PinnedShortcutPath -and $SeenShortcutPaths.ContainsKey($PinnedShortcutPath.ToLower())) { $RemovalReason = 'listed twice' }
        elseif ($PinnedShortcutPath -and -not [IO.File]::Exists($PinnedShortcutPath) -and -not [IO.Directory]::Exists($PinnedShortcutPath)) { $RemovalReason = 'its shortcut no longer exists' }
        if ($RemovalReason) {
            $PinList.RemoveAt($EntryIndex)
            $RepairCount++
            Write-Log "    [repair] '$EntryLabel' removed ($RemovalReason)" 'Yellow'
            continue
        }
        if ($PinnedShortcutPath) { $SeenShortcutPaths[$PinnedShortcutPath.ToLower()] = $true }
        $ExpectedAppId = ''
        if ($IsOwnerSession -and $PinnedShortcutPath.EndsWith('.lnk', [StringComparison]::OrdinalIgnoreCase)) {
            if (Update-PinnedShortcut $PinnedShortcutPath $null) {
                $RepairCount++
                $ShortcutsToReload += $PinnedShortcutPath
                Write-Log "    [repair] '$EntryLabel' : icon embedded in the pinned shortcut"
            }
            $ExpectedAppId = [TaskbarPin]::GetShortcutAppId($PinnedShortcutPath)
        }
        $RepairedEntry = [TaskbarPin]::FixEntry($PinnedEntry, $ExpectedAppId)
        if ($RepairedEntry) {
            $PinList.SetEntry($EntryIndex, $RepairedEntry, $false)
            $RepairCount++
            if ($ExpectedAppId -and $ExpectedAppId -ne $PreviousAppId) {
                $ShortcutsToReload += $PinnedShortcutPath
                Write-Log "    [repair] '$EntryLabel' : AppID '$PreviousAppId' -> '$ExpectedAppId'"
            } else { Write-Log "    [repair] '$EntryLabel' : extension blocks repaired" }
        }
        if (Set-EntryResolveRecord $PinList $EntryIndex $IsOwnerSession $OwnerTaskBarDirectory $true) {
            $RepairCount++
            Write-Log "    [repair] '$EntryLabel' : resolve record rebuilt"
        }
        $EntryIndex++
    }
    $PinListWasWritten = Save-TaskbandPinList $RegistryKeyHandle $PinListState
    if ($RepairCount -eq 0) { Write-Log "    [repair] Nothing to repair"; return 0 }
    if ($NotifyTaskbar) {
        if ($PinListWasWritten) { [TaskbarPin]::SendPinNotify() }
        foreach ($ShortcutToReload in @($ShortcutsToReload | Select-Object -Unique)) { [TaskbarPin]::NotifyShortcutChanged($ShortcutToReload) }
    }
    return $RepairCount
}

# Profiles for AllUsers mode (SID, ProfilePath), listed once : every account with a taskbar
# but the primary user, plus the Default profile (ProfileList's Default value), from which
# users created later get theirs.
$script:UserProfiles = $null
function Get-UserProfiles {
    if ($null -ne $script:UserProfiles) { return $script:UserProfiles }
    $DiscoveredProfiles = @()
    $ProfileListRegistryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList')
    if ($ProfileListRegistryKey) {
        try {
            foreach ($ProfileSid in $ProfileListRegistryKey.GetSubKeyNames()) {
                if ($ProfileSid -notmatch $UserAccountSidPattern -or $ProfileSid -eq $EffectivePrimaryUserSID) { continue }
                $ProfileSubKey = $ProfileListRegistryKey.OpenSubKey($ProfileSid)
                if (-not $ProfileSubKey) { continue }
                $ProfileImagePath = [string]$ProfileSubKey.GetValue('ProfileImagePath', '')
                $ProfileSubKey.Close()
                if ($ProfileImagePath -and [IO.Directory]::Exists($ProfileImagePath)) { $DiscoveredProfiles += @{ SID = $ProfileSid; ProfilePath = $ProfileImagePath } }
            }
            $DefaultProfilePath = [string]$ProfileListRegistryKey.GetValue('Default', '')
            if ($DefaultProfilePath -and [IO.File]::Exists([IO.Path]::Combine($DefaultProfilePath, 'NTUSER.DAT'))) { $DiscoveredProfiles += @{ SID = 'Default'; ProfilePath = $DefaultProfilePath } }
        } finally { $ProfileListRegistryKey.Close() }
    }
    $script:UserProfiles = $DiscoveredProfiles
    return $DiscoveredProfiles
}

# Runs an action on a user's Taskband key : in the user's hive when it is loaded (the user is
# logged on), else in their NTUSER.DAT loaded under HKU for the time of the action, named after
# the whole SID (a hive left loaded never blocks another profile). A GC pass before unloading
# releases the .NET key handles.
function Invoke-WithOfflineHive {
    param([string]$ProfileSID, [string]$ProfileDirectoryPath, [scriptblock]$ActionToPerform)
    $NtUserDatFilePath      = [IO.Path]::Combine($ProfileDirectoryPath, 'NTUSER.DAT')
    $LoadedHiveRegistryPath = $ProfileSID
    $HiveRequiresUnload     = $false
    if ($ProfileSID -ne 'Default' -and (Test-RegistrySubKeyExists ([Microsoft.Win32.Registry]::Users) $ProfileSID)) {
        Write-Log "    [hive] Hive of SID $ProfileSID already loaded (user logged on)"
    } else {
        if (-not [IO.File]::Exists($NtUserDatFilePath)) { Write-Log "    [hive] NTUSER.DAT not found at '$NtUserDatFilePath'" 'Yellow'; return $false }
        $LoadedHiveRegistryPath = "TempPin_$ProfileSID"
        Write-Log "    [hive] Loading NTUSER.DAT as HKU\$LoadedHiveRegistryPath..."
        $HiveLoadError = [TaskbarPin]::LoadUserHive($LoadedHiveRegistryPath, $NtUserDatFilePath)
        if ($HiveLoadError -ne 0) {
            Write-Log "    [hive] NTUSER.DAT could not be loaded : $((New-Object ComponentModel.Win32Exception($HiveLoadError)).Message) (error $HiveLoadError)" 'Yellow'
            return $false
        }
        $HiveRequiresUnload = $true
    }
    try {
        $TaskBandKeyHandle = [Microsoft.Win32.Registry]::Users.OpenSubKey("$LoadedHiveRegistryPath\$TaskBandRegistrySubKey", $true)
        if (-not $TaskBandKeyHandle) { $TaskBandKeyHandle = [Microsoft.Win32.Registry]::Users.CreateSubKey("$LoadedHiveRegistryPath\$TaskBandRegistrySubKey") }
        if ($TaskBandKeyHandle) {
            try { & $ActionToPerform $TaskBandKeyHandle } finally { $TaskBandKeyHandle.Close(); $TaskBandKeyHandle = $null }
        }
    } finally {
        if ($HiveRequiresUnload) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            $HiveUnloadError = [TaskbarPin]::UnloadUserHive($LoadedHiveRegistryPath)
            if ($HiveUnloadError -ne 0) { Write-Log "    [hive] WARNING : HKU\$LoadedHiveRegistryPath could not be unloaded : $((New-Object ComponentModel.Win32Exception($HiveUnloadError)).Message) (error $HiveUnloadError)" 'Yellow' }
            else { Write-Log "    [hive] Unloaded HKU\$LoadedHiveRegistryPath" }
        }
    }
    return $true
}

# Pinned shortcuts of a directory matching the unpin patterns (by name, target or AUMID).
function Find-MatchingPins {
    param([string]$PinnedShortcutDirectory, [string[]]$PatternsToMatch)
    $MatchedShortcutPaths = @()
    foreach ($PinnedShortcutEntry in @([TaskbarPin]::GetLnkCatalog($PinnedShortcutDirectory, $false, 0))) {
        foreach ($Pattern in $PatternsToMatch) {
            $ShortcutTargetPath = $PinnedShortcutEntry.TargetPath
            if ($Pattern -match '[/\\]') {
                $PatternMatched = [bool]($ShortcutTargetPath -and $ShortcutTargetPath -like $Pattern)
            } else {
                $PatternMatched = ($PinnedShortcutEntry.DisplayName -like $Pattern) -or
                                  ($ShortcutTargetPath -and ([IO.Path]::GetFileNameWithoutExtension($ShortcutTargetPath) -like $Pattern -or [IO.Path]::GetFileName($ShortcutTargetPath) -like $Pattern)) -or
                                  ($PinnedShortcutEntry.Aumid -and $PinnedShortcutEntry.Aumid -like $Pattern)
            }
            if ($PatternMatched) {
                Write-Log "    [match] '$([IO.Path]::GetFileName($PinnedShortcutEntry.LnkPath))' matched pattern '$Pattern'"
                $MatchedShortcutPaths += $PinnedShortcutEntry.LnkPath
                break
            }
        }
    }
    Write-Log "  [scan] '$PinnedShortcutDirectory' : $($MatchedShortcutPaths.Count) matching shortcut(s)"
    return $MatchedShortcutPaths
}

# Removes from a pin list the entries pointing to the given shortcuts (by file name in another
# user's list) and the entries without a shortcut file whose AppID matches a pattern. Returns
# the AppIDs of the latter.
function Invoke-UnpinFromBlob {
    param($RegistryKeyHandle, [string[]]$ShortcutPathsToRemove, [string[]]$ApplicationIdPatterns, [bool]$IsOwnerSession)
    $PinListState = Read-TaskbandPinList $RegistryKeyHandle
    $PinList = $PinListState.PinList
    $RemovedEntryCount = 0
    foreach ($ShortcutPath in $ShortcutPathsToRemove) {
        $ShortcutFilename = [IO.Path]::GetFileName($ShortcutPath)
        $EntryIndex = $PinList.IndexOfPath($ShortcutPath, -not $IsOwnerSession)
        if ($EntryIndex -lt 0) { Write-Log "    [blob] '$ShortcutFilename' not found in blob -- already absent or never pinned" }
        while ($EntryIndex -ge 0) {
            $PinList.RemoveAt($EntryIndex)
            $RemovedEntryCount++
            Write-Log "    [blob] Removed '$ShortcutFilename' (was at index $EntryIndex)"
            $EntryIndex = $PinList.IndexOfPath($ShortcutPath, -not $IsOwnerSession)
        }
    }
    $RemovedApplicationIds = @()
    for ($EntryIndex = $PinList.Count - 1; $EntryIndex -ge 0; $EntryIndex--) {
        if ([TaskbarPin]::GetEntryPath($PinList.GetEntry($EntryIndex))) { continue }
        $ApplicationId = [TaskbarPin]::GetEntryAppId($PinList.GetEntry($EntryIndex))
        if (-not $ApplicationId -or -not @($ApplicationIdPatterns | Where-Object { $ApplicationId -like $_ }).Count) { continue }
        $PinList.RemoveAt($EntryIndex)
        $RemovedEntryCount++
        $RemovedApplicationIds += $ApplicationId
        Write-Log "    [blob] Removed application '$ApplicationId' (was at index $EntryIndex)"
    }
    if ($RemovedEntryCount -gt 0) { $null = Save-TaskbandPinList $RegistryKeyHandle $PinListState }
    return $RemovedApplicationIds
}


#region REPAIR FLOW

if ($Repair) {
    Write-Banner 'REPAIR' 'DarkMagenta' "Taskbar pins$(if ($AllUsers) { ' (AllUsers)' })"
    Write-OperationLogHeader 'REPAIR' 'every pinned item'
    Initialize-NativeHelper
    $TotalRepairCount = 0
    if ($TaskBandRegistryKeyExists -and -not $TaskbarUsesQuickLaunch) {
        $TotalRepairCount += Invoke-WithTaskbandKey { param($TaskBandRegistryKey) Repair-PinnedItems $TaskBandRegistryKey (-not $IsRunningCrossUser) $TaskBarPinnedDirectory $true }
    }
    if ($AllUsers) {
        foreach ($UserProfile in @(Get-UserProfiles)) {
            Write-Log "  [profile] $($UserProfile.ProfilePath) (SID : $($UserProfile.SID))"
            $ProfileTaskBarDirectory   = [IO.Path]::Combine($UserProfile.ProfilePath, $TaskBarRelativeProfilePath)
            $script:ProfileRepairCount = 0
            $null = Invoke-WithOfflineHive $UserProfile.SID $UserProfile.ProfilePath { param($OfflineRegistryKey) $script:ProfileRepairCount = Repair-PinnedItems $OfflineRegistryKey $false $ProfileTaskBarDirectory $false }
            $TotalRepairCount += $script:ProfileRepairCount
        }
    }
    if ($TotalRepairCount -gt 0) { Write-Banner 'OK' 'DarkGreen' "$TotalRepairCount repair(s)$(if ($AllUsers) { ' (AllUsers)' })" }
    else { Write-Console "  [=] Nothing to repair" -Color DarkGray; Write-Console "" }
    Write-Log "--- REPAIR complete : $TotalRepairCount repair(s) ---"
    if ($ParsedInputItems.Count -eq 0) {
        Complete-Run
        if ($TotalRepairCount -gt 0) { exit 0 } else { exit 2 }
    }
}


#region UNPIN FLOW

if ($Unpin) {
    # One match pattern per input : AUMID for AppsFolder items, Control Panel name for .cpl,
    # file name without extension for paths and .msc/.exe, else the input as is.
    $UnpinMatchPatterns = @()
    foreach ($InputItem in $ParsedInputItems) {
        if ($InputItem.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase)) { $UnpinMatchPatterns += $InputItem.Substring(17); continue }
        $InputHasWildcard = $InputItem -match '[*?]'
        $InputExtension   = [IO.Path]::GetExtension($InputItem).ToLower()
        if ($InputExtension -eq '.cpl' -and -not $InputHasWildcard) {
            $CplResolvedPattern = $null
            foreach ($ResolvedCplPath in @(Resolve-FilesystemInput $InputItem)) {
                if ($ResolvedCplPath -and [IO.File]::Exists($ResolvedCplPath)) {
                    $CplMatch = Resolve-CplControlPanelItem $ResolvedCplPath
                    if ($CplMatch) { $CplResolvedPattern = $CplMatch.Name -replace '[<>:"/\\|?*]', '_'; break }
                }
            }
            # Literal names are escaped before use as -like patterns ([ ] would misfire).
            if ($CplResolvedPattern) { $UnpinMatchPatterns += [System.Management.Automation.WildcardPattern]::Escape($CplResolvedPattern); Write-Log "  [pattern] CPL '$InputItem' resolved to display name pattern '$CplResolvedPattern'" }
            else { $UnpinMatchPatterns += [System.Management.Automation.WildcardPattern]::Escape([IO.Path]::GetFileNameWithoutExtension($InputItem)); Write-Log "  [pattern] CPL '$InputItem' could not be resolved via namespace -- using its base name" 'Yellow' }
        } else {
            # Mirror the pin resolution : the names of the files the input resolves to (a folder's
            # pin has the folder's whole name), and the display name and AUMID of the application
            # identity it was pinned under.
            $ResolvedUnpinPaths = @(Resolve-FilesystemInput $InputItem)
            if (-not ($ResolvedUnpinPaths.Count -eq 1 -and [IO.Directory]::Exists($ResolvedUnpinPaths[0]))) {
                if (($InputItem -match '[/\\]' -and -not $InputHasWildcard) -or $InputExtension -eq '.msc' -or $InputExtension -eq '.exe') { $UnpinMatchPatterns += [IO.Path]::GetFileNameWithoutExtension($InputItem) }
                else { $UnpinMatchPatterns += $InputItem }
            }
            if ($ResolvedUnpinPaths.Count -gt 0) {
                foreach ($ResolvedUnpinPath in $ResolvedUnpinPaths) {
                    if ([IO.Directory]::Exists($ResolvedUnpinPath)) { $UnpinMatchPatterns += [System.Management.Automation.WildcardPattern]::Escape((Get-DirectoryShortcutName $ResolvedUnpinPath)); continue }
                    $UnpinMatchPatterns += [System.Management.Automation.WildcardPattern]::Escape([IO.Path]::GetFileNameWithoutExtension($ResolvedUnpinPath))
                    if ([IO.Path]::GetExtension($ResolvedUnpinPath).ToLower() -eq '.exe') {
                        $UnpinExecutableIdentity = Resolve-ExecutableIdentity $ResolvedUnpinPath
                        if ($UnpinExecutableIdentity) {
                            $UnpinMatchPatterns += [System.Management.Automation.WildcardPattern]::Escape(($UnpinExecutableIdentity.DisplayName -replace '[<>:"/\\|?*]', '_'))
                            $UnpinMatchPatterns += [System.Management.Automation.WildcardPattern]::Escape($UnpinExecutableIdentity.Aumid)
                            Write-Log "  [pattern] '$InputItem' carries application identity '$($UnpinExecutableIdentity.DisplayName)' ($($UnpinExecutableIdentity.Aumid))"
                        }
                    }
                }
            } elseif ($InputItem -notmatch '[/\\]') {
                foreach ($UnpinApplicationMatch in @(Find-ApplicationMatches $InputItem)) {
                    $UnpinMatchPatterns += [System.Management.Automation.WildcardPattern]::Escape(($UnpinApplicationMatch.DisplayName -replace '[<>:"/\\|?*]', '_'))
                    if ($UnpinApplicationMatch.Kind -eq 'Aumid') { $UnpinMatchPatterns += [System.Management.Automation.WildcardPattern]::Escape($UnpinApplicationMatch.Aumid) }
                    Write-Log "  [pattern] '$InputItem' matched installed application '$($UnpinApplicationMatch.DisplayName)'"
                }
            }
        }
    }
    $UnpinMatchPatterns = @($UnpinMatchPatterns | Where-Object { $_ } | Select-Object -Unique)
    # Invalid wildcard syntax (a stray '[') degrades to a literal pattern.
    $UnpinMatchPatterns = @(foreach ($UnpinPattern in $UnpinMatchPatterns) {
        try { $null = ('' -like $UnpinPattern); $UnpinPattern } catch { [System.Management.Automation.WildcardPattern]::Escape($UnpinPattern) }
    })
    $DisplayPatternLabel = $UnpinMatchPatterns -join ', '
    Write-Banner 'UNPIN' 'DarkRed' "$DisplayPatternLabel$(if ($AllUsers) { ' (AllUsers)' })"
    Write-OperationLogHeader 'UNPIN' "patterns : $DisplayPatternLabel"
    Initialize-NativeHelper
    # The pinned shortcuts : the TaskBar directory, or Quick Launch on Vista (elsewhere it holds
    # shortcuts that are not pins).
    $PinnedDirectoriesToScan = @()
    if ($TaskbarUsesQuickLaunch) { if ($QuickLaunchDirectoryExists) { $PinnedDirectoriesToScan += $QuickLaunchDirectory } }
    elseif ($TaskBarDirectoryExists) { $PinnedDirectoriesToScan += $TaskBarPinnedDirectory }
    if ($PinnedDirectoriesToScan.Count -eq 0 -and -not $AllUsers) {
        Write-Console "  [!] No pinned items for this account" -Color Yellow
        Write-Log "No $(if ($TaskbarUsesQuickLaunch) { 'Quick Launch' } else { 'TaskBar' }) directory found -- nothing to unpin" 'Yellow'
        Complete-Run; exit 2
    }
    $MatchedShortcutPaths = @()
    foreach ($DirectoryToScan in $PinnedDirectoriesToScan) { $MatchedShortcutPaths += @(Find-MatchingPins $DirectoryToScan $UnpinMatchPatterns) }
    Write-Log "Total matched shortcuts (current user) : $($MatchedShortcutPaths.Count)"
    $UnpinnedApplicationIds = @()
    if ($TaskBandRegistryKeyExists -and -not $TaskbarUsesQuickLaunch) {
        $UnpinnedApplicationIds = @(Invoke-WithTaskbandKey { param($TaskBandRegistryKey) Invoke-UnpinFromBlob $TaskBandRegistryKey $MatchedShortcutPaths $UnpinMatchPatterns (-not $IsRunningCrossUser) })
    }
    $UnpinFailedDeleteCount = 0
    foreach ($ShortcutPath in $MatchedShortcutPaths) {
        if ([IO.File]::Exists($ShortcutPath)) {
            try   { [IO.File]::Delete($ShortcutPath); Write-Log "  [file] Deleted '$ShortcutPath'" }
            catch { Write-Log "  [file] FAILED to delete '$ShortcutPath' : $_" 'Yellow'; $UnpinFailedDeleteCount++ }
        }
    }
    if ($MatchedShortcutPaths.Count -gt 0 -or $UnpinnedApplicationIds.Count -gt 0) { [TaskbarPin]::SendPinNotify(); Write-Log "[notify] 0x446 posted to the taskbar pinned-items band" }
    $UnpinnedItemCount = $MatchedShortcutPaths.Count + $UnpinnedApplicationIds.Count
    if ($AllUsers) {
        foreach ($UserProfile in @(Get-UserProfiles)) {
            Write-Log "  [profile] $($UserProfile.ProfilePath) (SID : $($UserProfile.SID))"
            $ProfileTaskBarDirectory = [IO.Path]::Combine($UserProfile.ProfilePath, $TaskBarRelativeProfilePath)
            $ProfileMatchedShortcuts = @()
            if ([IO.Directory]::Exists($ProfileTaskBarDirectory)) { $ProfileMatchedShortcuts = @(Find-MatchingPins $ProfileTaskBarDirectory $UnpinMatchPatterns) }
            $script:ProfileUnpinnedApplicationIds = @()
            $null = Invoke-WithOfflineHive $UserProfile.SID $UserProfile.ProfilePath { param($OfflineRegistryKey) $script:ProfileUnpinnedApplicationIds = @(Invoke-UnpinFromBlob $OfflineRegistryKey $ProfileMatchedShortcuts $UnpinMatchPatterns $false) }
            foreach ($ProfileShortcutPath in $ProfileMatchedShortcuts) { if ([IO.File]::Exists($ProfileShortcutPath)) { try { [IO.File]::Delete($ProfileShortcutPath) } catch { } } }
            Write-Log "    [file] Deleted $($ProfileMatchedShortcuts.Count) .lnk file(s)"
            $UnpinnedItemCount += $ProfileMatchedShortcuts.Count + $script:ProfileUnpinnedApplicationIds.Count
        }
    }
    if ($UnpinnedItemCount -eq 0) {
        Write-Console "  [!] No pinned items match" -Color Yellow
        Write-Log "No pinned items matched the given patterns" 'Yellow'
        Write-Console ""; Complete-Run; exit 2
    }
    foreach ($UnpinnedPath in $MatchedShortcutPaths) { Write-Console "  [-] $([IO.Path]::GetFileName($UnpinnedPath))" -Color Cyan }
    foreach ($UnpinnedApplicationId in $UnpinnedApplicationIds) { Write-Console "  [-] $UnpinnedApplicationId" -Color Cyan }
    if ($UnpinFailedDeleteCount -gt 0) {
        Write-Banner 'FAIL' 'DarkRed' "$UnpinFailedDeleteCount item(s) could not be deleted"
        Write-Log "--- UNPIN FAILED : $UnpinFailedDeleteCount deletion(s) failed ---"
        Complete-Run; exit 3
    }
    Write-Banner 'OK' 'DarkGreen' "Unpinned $UnpinnedItemCount item(s)$(if ($AllUsers) { ' (AllUsers)' })"
    Write-Log "--- UNPIN complete : $UnpinnedItemCount item(s) unpinned ---"
    Complete-Run; exit 0
}


#region PIN : RESOLVE INPUT

Write-Banner 'PIN' 'DarkBlue' "$Pin$(if ($AllUsers) { ' (AllUsers)' })"
Write-OperationLogHeader 'PIN' "$Pin ($($ParsedInputItems.Count) parsed item(s))"
$UwpInputItems        = @($ParsedInputItems | Where-Object { $_.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase) })
$FilesystemInputItems = @($ParsedInputItems | Where-Object { -not $_.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase) })
Write-Log "[resolve] UWP inputs : $($UwpInputItems.Count) | filesystem inputs : $($FilesystemInputItems.Count)"
$ResolvedPinTargets               = @()
$AlreadyResolvedApplicationAumids = @{}
$AlreadySeenFilesystemPaths       = @{}

# -- Resolve UWP inputs --
# Exact AUMIDs resolve through ParseName; names and wildcards through the AppsFolder snapshot.
if ($UwpInputItems.Count -gt 0) {
    $ExactAumidInputs = @($UwpInputItems | Where-Object { $_ -notmatch '[*?]' -and $_.Contains('!') })
    $PatternUwpInputs = @($UwpInputItems | Where-Object { $_ -match '[*?]' -or -not $_.Contains('!') })
    if ($ExactAumidInputs.Count -gt 0) {
        $ShellApplicationCom    = New-Object -ComObject Shell.Application
        $AppsFolderNamespaceCom = $ShellApplicationCom.Namespace('shell:AppsFolder')
        foreach ($ExactUwpInput in $ExactAumidInputs) {
            $ResolvedAppItem = $AppsFolderNamespaceCom.ParseName($ExactUwpInput.Substring(17))
            if ($ResolvedAppItem) {
                if (-not $AlreadyResolvedApplicationAumids.ContainsKey($ResolvedAppItem.Path)) {
                    $AlreadyResolvedApplicationAumids[$ResolvedAppItem.Path] = $true
                    $ResolvedPinTargets += @{ PinType = 'UWP'; Aumid = $ResolvedAppItem.Path; DisplayName = $ResolvedAppItem.Name }
                    Write-Log "  [uwp] Resolved : '$($ResolvedAppItem.Name)' ($($ResolvedAppItem.Path))"
                }
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ResolvedAppItem)
            } else {
                Write-Console "  [!] Not found : $ExactUwpInput" -Color Yellow
                Write-Log "  [uwp] AUMID not found in shell:AppsFolder : '$($ExactUwpInput.Substring(17))'" 'Yellow'
            }
        }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($AppsFolderNamespaceCom)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ShellApplicationCom)
    }
    foreach ($PatternUwpInput in $PatternUwpInputs) {
        $UwpMatchPattern = $PatternUwpInput.Substring(17)
        if (-not $UwpMatchPattern) { continue }
        # Invalid wildcard syntax degrades to a literal pattern.
        try { $null = ('' -like $UwpMatchPattern) } catch { $UwpMatchPattern = [System.Management.Automation.WildcardPattern]::Escape($UwpMatchPattern) }
        $MatchedAnyApplication = $false
        foreach ($ApplicationEntry in (Get-AppsFolderSnapshot)) {
            if (($ApplicationEntry.DisplayName -like $UwpMatchPattern -or $ApplicationEntry.Aumid -like $UwpMatchPattern) -and -not $AlreadyResolvedApplicationAumids.ContainsKey($ApplicationEntry.Aumid)) {
                $AlreadyResolvedApplicationAumids[$ApplicationEntry.Aumid] = $true
                $ResolvedPinTargets += @{ PinType = 'UWP'; Aumid = $ApplicationEntry.Aumid; DisplayName = $ApplicationEntry.DisplayName }
                $MatchedAnyApplication = $true
                Write-Log "  [uwp] Pattern '$UwpMatchPattern' matched '$($ApplicationEntry.DisplayName)' ($($ApplicationEntry.Aumid))"
            }
        }
        if (-not $MatchedAnyApplication) {
            Write-Console "  [!] Not found : shell:AppsFolder\$UwpMatchPattern" -Color Yellow
            Write-Log "  [uwp] No installed application matched : '$UwpMatchPattern'" 'Yellow'
        }
    }
}

# -- Resolve filesystem inputs --
foreach ($FilesystemInput in $FilesystemInputItems) {
    Write-Log "  [fs] Resolving : '$FilesystemInput'..."
    $ResolvedFilePaths = @(Resolve-FilesystemInput $FilesystemInput)
    foreach ($ResolvedPath in $ResolvedFilePaths) {
        if (-not $ResolvedPath -or $AlreadySeenFilesystemPaths.ContainsKey($ResolvedPath)) { continue }
        $AlreadySeenFilesystemPaths[$ResolvedPath] = $true
        # An executable registered as an application is pinned through its AUMID.
        $ExecutableIdentity = $null
        if ([IO.Path]::GetExtension($ResolvedPath).ToLower() -eq '.exe') { $ExecutableIdentity = Resolve-ExecutableIdentity $ResolvedPath }
        if ($ExecutableIdentity) {
            if (-not $AlreadyResolvedApplicationAumids.ContainsKey($ExecutableIdentity.Aumid)) {
                $AlreadyResolvedApplicationAumids[$ExecutableIdentity.Aumid] = $true
                $ResolvedPinTargets += @{ PinType = 'UWP'; Aumid = $ExecutableIdentity.Aumid; DisplayName = $ExecutableIdentity.DisplayName }
                Write-Log "  [fs] '$ResolvedPath' has application identity '$($ExecutableIdentity.Aumid)' ('$($ExecutableIdentity.DisplayName)')"
            }
        } else {
            $ResolvedPinTargets += @{ PinType = 'FS'; ResolvedPath = $ResolvedPath }
            Write-Log "  [fs] Resolved : '$ResolvedPath'"
        }
    }
    # Nothing on disk matched : a bare name is searched as an installed application.
    if ($ResolvedFilePaths.Count -eq 0) {
        $ApplicationMatches = @()
        if ($FilesystemInput -notmatch '[/\\]') { $ApplicationMatches = @(Find-ApplicationMatches $FilesystemInput) }
        if ($ApplicationMatches.Count -gt 0) {
            foreach ($ApplicationMatch in $ApplicationMatches) {
                if ($ApplicationMatch.Kind -eq 'Aumid') {
                    if ($AlreadyResolvedApplicationAumids.ContainsKey($ApplicationMatch.Aumid)) { continue }
                    $AlreadyResolvedApplicationAumids[$ApplicationMatch.Aumid] = $true
                    $ResolvedPinTargets += @{ PinType = 'UWP'; Aumid = $ApplicationMatch.Aumid; DisplayName = $ApplicationMatch.DisplayName }
                    Write-Log "  [fs] '$FilesystemInput' matched application '$($ApplicationMatch.DisplayName)' (AUMID '$($ApplicationMatch.Aumid)')"
                } else {
                    if ($AlreadySeenFilesystemPaths.ContainsKey($ApplicationMatch.LnkPath)) { continue }
                    $AlreadySeenFilesystemPaths[$ApplicationMatch.LnkPath] = $true
                    $ResolvedPinTargets += @{ PinType = 'FS'; ResolvedPath = $ApplicationMatch.LnkPath }
                    Write-Log "  [fs] '$FilesystemInput' matched shortcut '$($ApplicationMatch.LnkPath)'"
                }
            }
        } else {
            Write-Console "  [!] Not found : $FilesystemInput" -Color Yellow
            Write-Log "  [fs] No file or installed application found for '$FilesystemInput'" 'Yellow'
        }
    }
}
Write-Log "[resolve] Total resolved pin targets : $($ResolvedPinTargets.Count)"
if ($ResolvedPinTargets.Count -eq 0) {
    Write-Console "  [X] No items found to pin" -Color Red
    Write-Log "No items could be resolved -- aborting" 'Red'
    Write-Console ""
    Complete-Run; exit 2
}


#region PIN : PIN LIST

# Windows 7 and later : place a .lnk in the TaskBar pinned directory, add its Favorites entry
# (PIDL + BEEF001D AppID) and its FavoritesResolve record, then post 0x446. An item already
# pinned is updated in place; one that cannot be pinned is reported as such. An account
# without a pin list of its own (SYSTEM) pins for the other profiles only (-AllUsers), with
# the shortcuts prepared here.
$SuccessfullyPinnedCount = 0
$FailedPinNames          = @()
if (-not $TaskbarUsesQuickLaunch -and -not $PrimaryUserHasPinList) {
    Write-Console "  [!] This account has no taskbar pin list$(if ($AllUsers) { ' : pinning for the other profiles only' })" -Color Yellow
    Write-Log "[pin] No pin list for $EffectivePrimaryUserSID (TaskBar directory : $TaskBarDirectoryExists, Taskband key : $TaskBandRegistryKeyExists)$(if ($AllUsers) { ' : the other profiles only' })" 'Yellow'
}
if (-not $TaskbarUsesQuickLaunch -and ($PrimaryUserHasPinList -or $AllUsers)) {
    Write-Console "  [>] Preparing blob entries ($($ResolvedPinTargets.Count) item(s))..." -Color DarkGray -NoNewline
    Write-Log "[blob-prep] Preparing $($ResolvedPinTargets.Count) item(s)..."
    Initialize-NativeHelper
    $WshShellForPinCreation       = $null
    $BlobEntriesReadyForInjection = @()
    $ItemsAlreadyPinnedByWindows  = @()
    # The pin list as it is before this run, read once, for the applications already pinned.
    $PrimaryPinList = $null
    if ($PrimaryUserHasPinList) { $PrimaryPinList = Read-PrimaryPinList }
    foreach ($PinTarget in $ResolvedPinTargets) {
        $SourceShortcutPath = $null
        $ShortcutWasUpdated = $false
        if ($PinTarget.PinType -eq 'UWP') {
            # UWP : the AUMID is both the shortcut identity and the BEEF001D AppID.
            $PinTargetDisplayName = $PinTarget.DisplayName
            $Beef001dParsingName  = $PinTarget.Aumid
            $ProposedShortcutName = "$($PinTarget.DisplayName -replace '[<>:"/\\|?*]', '_').lnk"
        } else {
            # Filesystem : create (or reuse) a .lnk; its AppID is the one Windows gives it.
            $Beef001dContentReference = [ref]''
            $SourceShortcutPath    = New-TargetShortcut $PinTarget.ResolvedPath $Beef001dContentReference ([ref]$WshShellForPinCreation)
            $Beef001dParsingName   = $Beef001dContentReference.Value
            $PinTargetDisplayName  = [IO.Path]::GetFileName($SourceShortcutPath)
            $ProposedShortcutName  = $PinTargetDisplayName
            $ResolvedApplicationId = [TaskbarPin]::GetShortcutAppId($SourceShortcutPath)
            if ($ResolvedApplicationId) { $Beef001dParsingName = $ResolvedApplicationId }
        }
        if (-not $PrimaryUserHasPinList) {
            # The other profiles only : the shortcut each of them gets a copy of.
            if ($PinTarget.PinType -eq 'UWP') {
                $SourceShortcutPath = Get-TemporaryShortcutPath $ProposedShortcutName
                if (-not [TaskbarPin]::CreateAppShortcut($PinTarget.Aumid, $SourceShortcutPath)) {
                    Write-Log "  [uwp] CreateAppShortcut FAILED for '$($PinTarget.Aumid)' -- not pinned" 'Yellow'
                    $FailedPinNames += $PinTargetDisplayName
                    continue
                }
                $SourceApplicationId = [TaskbarPin]::GetShortcutAppId($SourceShortcutPath)
                if ($SourceApplicationId) { $Beef001dParsingName = $SourceApplicationId }
            }
            $BlobEntriesReadyForInjection += @{ ShortcutPath = $SourceShortcutPath; SerializedBlobEntry = $null; DisplayName = $ProposedShortcutName; Beef001dContent = $Beef001dParsingName }
            Write-Log "  [pin] Target : '$(if ($PinTarget.PinType -eq 'UWP') { $PinTarget.Aumid } else { $PinTarget.ResolvedPath })' | shortcut : '$ProposedShortcutName' | BEEF001D : '$Beef001dParsingName' | other profiles only"
            continue
        }
        # The application already pinned (same AppID, possibly under another name) is updated
        # rather than pinned twice; an item Windows pinned without a shortcut file is left as is.
        $PinnedApplication = Find-PinnedApplication $PrimaryPinList $Beef001dParsingName
        if ($PinnedApplication -and -not $PinnedApplication.ShortcutPath) {
            Write-Log "  [pin] '$PinTargetDisplayName' (AppID '$Beef001dParsingName') is already pinned without a shortcut file -- left as is"
            $ItemsAlreadyPinnedByWindows += $PinTargetDisplayName
            continue
        }
        if ($PinnedApplication) { $DestinationLnkPath = $PinnedApplication.ShortcutPath }
        else { $DestinationLnkPath = Get-AvailablePinnedShortcutPath ([IO.Path]::Combine($TaskBarPinnedDirectory, $ProposedShortcutName)) $Beef001dParsingName }
        $DestinationLnkAlreadyPinned = [IO.File]::Exists($DestinationLnkPath)
        if ($PinTarget.PinType -eq 'UWP') {
            # An existing pinned .lnk is rebuilt in a temporary file, then updated in place.
            $SourceShortcutPath = $DestinationLnkPath
            if ($DestinationLnkAlreadyPinned) { $SourceShortcutPath = Get-TemporaryShortcutPath ([IO.Path]::GetFileName($DestinationLnkPath)) }
            Write-Log "  [uwp] Creating shortcut '$([IO.Path]::GetFileName($SourceShortcutPath))' for AUMID '$($PinTarget.Aumid)'..."
            if (-not [TaskbarPin]::CreateAppShortcut($PinTarget.Aumid, $SourceShortcutPath)) {
                if (-not $DestinationLnkAlreadyPinned) {
                    if ([IO.File]::Exists($DestinationLnkPath)) { try { [IO.File]::Delete($DestinationLnkPath) } catch { } }
                    Write-Log "  [uwp] CreateAppShortcut FAILED for '$($PinTarget.Aumid)' -- not pinned" 'Yellow'
                    $FailedPinNames += $PinTargetDisplayName
                    continue
                }
                Write-Log "  [uwp] CreateAppShortcut FAILED for '$($PinTarget.Aumid)' -- existing pin kept as is" 'Yellow'
                $SourceShortcutPath = $null
            }
        }
        if ($DestinationLnkAlreadyPinned) { $ShortcutWasUpdated = Update-PinnedShortcut $DestinationLnkPath $SourceShortcutPath }
        elseif ($SourceShortcutPath -ne $DestinationLnkPath) { [IO.File]::Copy($SourceShortcutPath, $DestinationLnkPath) }
        if (-not $DestinationLnkAlreadyPinned) { $null = [TaskbarPin]::EmbedStreamIcon($DestinationLnkPath) }
        $PinTargetDisplayName = [IO.Path]::GetFileName($DestinationLnkPath)
        $DestinationApplicationId = [TaskbarPin]::GetShortcutAppId($DestinationLnkPath)
        if ($DestinationApplicationId) { $Beef001dParsingName = $DestinationApplicationId }
        Write-Log "  [pin] Target : '$(if ($PinTarget.PinType -eq 'UWP') { $PinTarget.Aumid } else { $PinTarget.ResolvedPath })' | shortcut : '$PinTargetDisplayName' | BEEF001D : '$Beef001dParsingName'$(if ($DestinationLnkAlreadyPinned) { " | already pinned, updated : $ShortcutWasUpdated" })"
        # Build the blob entry (a filesystem PIDL in cross-user mode).
        $SerializedBlobEntry = $null
        if ($Beef001dParsingName) {
            if ($IsRunningCrossUser) { $SerializedBlobEntry = [TaskbarPin]::GetBlobEntryFs($DestinationLnkPath, $Beef001dParsingName) }
            else                     { $SerializedBlobEntry = [TaskbarPin]::GetBlobEntryEx($DestinationLnkPath, $Beef001dParsingName) }
        }
        if ($SerializedBlobEntry) {
            $BlobEntriesReadyForInjection += @{ ShortcutPath = $DestinationLnkPath; DestinationLnkPath = $DestinationLnkPath; SerializedBlobEntry = $SerializedBlobEntry; DisplayName = $PinTargetDisplayName; Beef001dContent = $Beef001dParsingName; AlreadyPinned = $DestinationLnkAlreadyPinned; ShortcutWasUpdated = $ShortcutWasUpdated; EntryWasRepaired = $false }
            Write-Log "  [blob] Entry ready for '$PinTargetDisplayName' : $($SerializedBlobEntry.Length) bytes"
        } else {
            Write-Log "  [blob] No blob entry for '$PinTargetDisplayName' (no AppID, or no PIDL for its shortcut) -- not pinned" 'Yellow'
            # Only a .lnk created by this run is removed : never a pre-existing live pin.
            if (-not $DestinationLnkAlreadyPinned -and [IO.File]::Exists($DestinationLnkPath)) { try { [IO.File]::Delete($DestinationLnkPath) } catch { } }
            $FailedPinNames += $PinTargetDisplayName
        }
    }
    if ($WshShellForPinCreation) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($WshShellForPinCreation) }
    # Write all prepared entries in one pass, then notify the taskbar.
    if ($PrimaryUserHasPinList -and $BlobEntriesReadyForInjection.Count -gt 0) {
        $BlobEntriesChangedCount = Invoke-WithTaskbandKey { param($TaskBandRegistryKey) Write-BlobToRegistryKey $TaskBandRegistryKey $BlobEntriesReadyForInjection (-not $IsRunningCrossUser) $TaskBarPinnedDirectory }
        if ($BlobEntriesChangedCount -gt 0) { [TaskbarPin]::SendPinNotify(); Write-Log "[notify] 0x446 posted to the taskbar pinned-items band" }
        # A pinned .lnk that changed is reloaded; in cross-user mode every one is, so that the
        # interactive user's taskbar computes its AppID itself.
        foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
            if ($IsRunningCrossUser -or ($ReadyEntry.AlreadyPinned -and ($ReadyEntry.ShortcutWasUpdated -or $ReadyEntry.EntryWasRepaired))) {
                [TaskbarPin]::NotifyShortcutChanged($ReadyEntry.DestinationLnkPath)
                Write-Log "[notify] '$($ReadyEntry.DisplayName)' reloaded by the taskbar"
            }
        }
        Write-Console " done" -Color Green
        foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
            Write-Console "  [+] $($ReadyEntry.DisplayName)" -Color Cyan
            $SuccessfullyPinnedCount++
        }
        Write-Log "[blob-write] $BlobEntriesChangedCount entries added, replaced or repaired, $SuccessfullyPinnedCount items pinned"
    } elseif ($BlobEntriesReadyForInjection.Count -gt 0) {
        Write-Console " done" -Color Green
    } else {
        Write-Console " nothing to inject" -Color Yellow
        Write-Log "[blob-write] No blob entries to write"
    }
    foreach ($ItemAlreadyPinnedByWindows in $ItemsAlreadyPinnedByWindows) {
        Write-Console "  [=] $ItemAlreadyPinnedByWindows (already pinned)" -Color DarkCyan
        $SuccessfullyPinnedCount++
    }
    Write-Console ""
    # AllUsers : copy (or update) each shortcut in every other profile and write its entry into
    # each one's pin list : the entry built above when it is relative to the profile and the
    # shortcut keeps its name (users created later from the Default profile then get their own
    # copy), else a filesystem PIDL to that profile's shortcut.
    if ($AllUsers -and $BlobEntriesReadyForInjection.Count -gt 0) {
        $AllUserProfiles = @(Get-UserProfiles)
        Write-Log "[allUsers] Replicating to $($AllUserProfiles.Count) additional profile(s)..."
        $AllUsersProfilesUpdatedCount = 0
        foreach ($UserProfile in $AllUserProfiles) {
            $ProfileTaskBarDirectory = [IO.Path]::Combine($UserProfile.ProfilePath, $TaskBarRelativeProfilePath)
            Write-Log "  [profile] $($UserProfile.ProfilePath) (SID : $($UserProfile.SID))"
            if (-not [IO.Directory]::Exists($ProfileTaskBarDirectory)) {
                try   { $null = [IO.Directory]::CreateDirectory($ProfileTaskBarDirectory) }
                catch { Write-Log "    [file] FAILED to create TaskBar directory : $_" 'Yellow'; continue }
            }
            $ProfileSpecificBlobEntries = @()
            foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
                $PinnedShortcutName  = [IO.Path]::GetFileName($ReadyEntry.ShortcutPath)
                $ProfileShortcutPath = Get-AvailablePinnedShortcutPath ([IO.Path]::Combine($ProfileTaskBarDirectory, $PinnedShortcutName)) $ReadyEntry.Beef001dContent
                try {
                    if ([IO.File]::Exists($ProfileShortcutPath)) { $null = Update-PinnedShortcut $ProfileShortcutPath $ReadyEntry.ShortcutPath }
                    else { [IO.File]::Copy($ReadyEntry.ShortcutPath, $ProfileShortcutPath); $null = [TaskbarPin]::EmbedStreamIcon($ProfileShortcutPath) }
                } catch { Write-Log "    [file] Copy FAILED for '$([IO.Path]::GetFileName($ProfileShortcutPath))' : $_" 'Yellow'; continue }
                $ProfileBlobEntry = $ReadyEntry.SerializedBlobEntry
                if (-not ($ProfileBlobEntry -and [TaskbarPin]::IsProfileRelativeEntry($ProfileBlobEntry) -and [IO.Path]::GetFileName($ProfileShortcutPath) -eq $PinnedShortcutName)) { $ProfileBlobEntry = [TaskbarPin]::GetBlobEntryFs($ProfileShortcutPath, $ReadyEntry.Beef001dContent) }
                if ($ProfileBlobEntry) { $ProfileSpecificBlobEntries += @{ DestinationLnkPath = $ProfileShortcutPath; SerializedBlobEntry = $ProfileBlobEntry; Beef001dContent = $ReadyEntry.Beef001dContent; EntryWasRepaired = $false } }
            }
            if ($ProfileSpecificBlobEntries.Count -eq 0) { Write-Log "    No blob entries could be built -- skipping"; continue }
            $OfflineHiveResult = Invoke-WithOfflineHive $UserProfile.SID $UserProfile.ProfilePath {
                param($OfflineRegistryKey)
                $OfflineChangedCount = Write-BlobToRegistryKey $OfflineRegistryKey $ProfileSpecificBlobEntries $false $ProfileTaskBarDirectory
                Write-Log "    [blob] $OfflineChangedCount entries added, replaced or repaired in offline profile"
            }
            if ($OfflineHiveResult) { $AllUsersProfilesUpdatedCount++ }
        }
        # Without a pin list of its own, an item is pinned once a profile has it.
        if (-not $PrimaryUserHasPinList -and $AllUsersProfilesUpdatedCount -gt 0) {
            foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
                Write-Console "  [+] $($ReadyEntry.DisplayName)" -Color Cyan
                $SuccessfullyPinnedCount++
            }
        }
        Write-Console "  [*] AllUsers : $AllUsersProfilesUpdatedCount profile(s) updated" -Color DarkCyan
        Write-Log "[allUsers] $AllUsersProfilesUpdatedCount profile(s) updated"
        Write-Console ""
    }
}


#region PIN : QUICK LAUNCH (VISTA)

# Vista's taskbar pins are its Quick Launch shortcuts : the .lnk is copied there. UWP apps do
# not exist there.
if ($TaskbarUsesQuickLaunch) {
    Write-Log "[quicklaunch] Processing $($ResolvedPinTargets.Count) item(s)..."
    if (-not $QuickLaunchDirectoryExists) { Write-Log "  [quicklaunch] Quick Launch directory not found" 'Yellow' }
    $WshShellForQuickLaunch = $null
    foreach ($QuickLaunchTarget in $ResolvedPinTargets) {
        if ($QuickLaunchTarget.PinType -eq 'UWP') { Write-Log "  [quicklaunch] UWP item '$($QuickLaunchTarget.DisplayName)' -- Quick Launch cannot pin UWP apps" 'Yellow'; $FailedPinNames += $QuickLaunchTarget.DisplayName; continue }
        if (-not $QuickLaunchDirectoryExists) { $FailedPinNames += $QuickLaunchTarget.ResolvedPath; continue }
        $Beef001dQuickLaunchRef  = [ref]''
        $QuickLaunchSourcePath   = New-TargetShortcut $QuickLaunchTarget.ResolvedPath $Beef001dQuickLaunchRef ([ref]$WshShellForQuickLaunch)
        $QuickLaunchShortcutName = [IO.Path]::GetFileName($QuickLaunchSourcePath)
        [IO.File]::Copy($QuickLaunchSourcePath, [IO.Path]::Combine($QuickLaunchDirectory, $QuickLaunchShortcutName), $true)
        Write-Console "  [+] $QuickLaunchShortcutName" -Color Cyan
        Write-Log "  [quicklaunch] Copied '$QuickLaunchShortcutName' to Quick Launch directory"
        $SuccessfullyPinnedCount++
    }
    if ($WshShellForQuickLaunch) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($WshShellForQuickLaunch) }
}


#region FINAL STATUS

foreach ($FailedPinName in $FailedPinNames) { Write-Console "  [X] $FailedPinName : not pinned" -Color Red }
if ($FailedPinNames.Count -gt 0) {
    Write-Banner 'FAIL' 'DarkRed' "$($FailedPinNames.Count) item(s) could not be pinned$(if ($SuccessfullyPinnedCount -gt 0) { ", $SuccessfullyPinnedCount pinned" })$(if ($AllUsers) { ' (AllUsers)' })"
    Write-Log "--- PIN FAILED : $($FailedPinNames.Count) item(s) not pinned, $SuccessfullyPinnedCount pinned ---"
    Complete-Run; exit 3
}
if ($SuccessfullyPinnedCount -gt 0) {
    Write-Banner 'OK' 'DarkGreen' "Pinned $SuccessfullyPinnedCount item(s)$(if ($AllUsers) { ' (AllUsers)' })"
    Write-Log "--- PIN complete : $SuccessfullyPinnedCount pinned ---"
    Complete-Run; exit 0
}
Write-Banner 'FAIL' 'DarkRed' "No items could be pinned"
Write-Log "--- PIN FAILED : 0/$($ResolvedPinTargets.Count) items pinned ---"
Complete-Run; exit 3
