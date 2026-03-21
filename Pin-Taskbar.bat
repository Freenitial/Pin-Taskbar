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
        %powershell% -NoLogo -NoProfile -Command "$n=[IO.Path]::GetFileName('%~f0');$sb=[ScriptBlock]::Create([IO.File]::ReadAllText('%~f0'));Set-Item function:$n $sb;Get-Help $n -Full" 
        pause & endlocal & exit /b
    )
    %powershell% -NoLogo -NoProfile -Command "Set-Location $([IO.Path]::GetDirectoryName('%~f0'));$sb=[ScriptBlock]::Create([IO.File]::ReadAllText('%~f0'));& $sb @args" %args%
    endlocal & exit /b %errorlevel%
#>

<#
.SYNOPSIS
    Pin or unpin shortcuts from the Windows taskbar programmatically.
    Version 1.0
.DESCRIPTION
    Pins or unpins items to/from the Windows taskbar across all windows versions.

    PIN strategy :
      - Modern (Win7+) : writes a binary blob entry with a BEEF001D extension block
        directly into the Taskband registry, then notifies the taskbar via SHChangeNotify.
        This is the only reliable method on Windows 11 where COM pin APIs are stubbed out.
      - Legacy (Vista)  : copies a .lnk shortcut into the Quick Launch directory.

    UNPIN strategy :
      - Removes matching entries from the Taskband registry blob, deletes the .lnk files,
        and notifies the taskbar.
      - Falls back to Quick Launch deletion on Vista.

    When -AllUsers is specified, the script loads each user's offline registry hive
    (NTUSER.DAT) and replicates the operation across all profiles.

.PARAMETER Pin
    Path to .lnk/.exe/.msc or shell:AppsFolder identifier. Supports semicolons and wildcards.
.PARAMETER Unpin
    Triggers unpin mode. -Pin becomes a match pattern.
.PARAMETER Silent
    Suppresses all console output. Log file output is not affected.
.PARAMETER LogFile
    Path to a log file. Must end with .txt or .log.
.PARAMETER AllUsers
    Applies pin/unpin to all user profiles (requires elevation).
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
.NOTES
    Exit codes : 0 = Success, 2 = Nothing found to pin/unpin, 3 = Fail to pin/unpin.
    Compatible with PowerShell 2.0+ (.NET 2.0+).
#>
param(
    [Parameter(Position = 0)]
    [Alias('Path', 'File', 'Files')][string]$Pin,
    [Alias('Remove')]               [switch]$Unpin,
    [Alias('S')]                    [switch]$Silent,
    [Alias('Log')]                  [string]$LogFile,
    [Alias('Everyone', 'All')]      [switch]$AllUsers
)
$ErrorActionPreference = 'Stop'
if ($LogFile) {
    if (-not ($LogFile.EndsWith('.txt') -or $LogFile.EndsWith('.log'))) {
        if (-not $Silent) { Write-Host "ERROR : -LogFile must end with .txt or .log" -ForegroundColor Red }
        exit 3
    }
}


#region ENVIRONMENT

# -- Filesystem paths where Windows stores pinned taskbar shortcuts --
$RoamingAppDataPath      = [Environment]::GetFolderPath('ApplicationData')
$TaskBarPinnedDirectory  = [IO.Path]::Combine($RoamingAppDataPath, 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
$QuickLaunchDirectory    = [IO.Path]::Combine($RoamingAppDataPath, 'Microsoft\Internet Explorer\Quick Launch')

# -- Registry location where the taskbar stores its pin state (the "blob") --
# The Favorites binary value inside this key contains the serialized PIDL list
# of all pinned items. Modifying this blob + notifying the shell is how we pin.
$TaskBandRegistrySubKey  = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'

# -- Relative path from a user profile root to the TaskBar shortcuts directory --
# Used in AllUsers mode to locate each profile's pin storage.
$TaskBarRelativeProfilePath = 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'

# -- Registry value type constants used throughout blob read/write operations --
$DoNotExpandRegistryOption  = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
$BinaryRegistryValueKind    = [Microsoft.Win32.RegistryValueKind]::Binary
$DwordRegistryValueKind     = [Microsoft.Win32.RegistryValueKind]::DWord

# -- Probe the current system to determine which pin strategies are available --
$TaskBarDirectoryExists     = [IO.Directory]::Exists($TaskBarPinnedDirectory)
$QuickLaunchDirectoryExists = [IO.Directory]::Exists($QuickLaunchDirectory)
$TaskBandRegistryKeyExists  = $false
$RegistryProbeHandle        = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($TaskBandRegistrySubKey, $false)
if ($RegistryProbeHandle) { $TaskBandRegistryKeyExists = $true; $RegistryProbeHandle.Close() }

# -- Windows build number drives feature availability and logging --
$WindowsBuildNumber = 0
try { $WindowsBuildNumber = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber } catch { }

# -- SID of the currently logged-in user, used to skip ourselves in AllUsers mode --
$CurrentUserSecurityIdentifier = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value

# -- Whether blob injection (the modern strategy) can be used --
# Requires both the TaskBar shortcut directory (to place .lnk files)
# and the Taskband registry key (to write the Favorites blob).
$DirectBlobWriteIsSupported = $TaskBarDirectoryExists -and $TaskBandRegistryKeyExists

# -- Cross-user elevation detection --
# When the script is launched via RunAs under a different account, HKCU and %APPDATA%
# resolve to the elevated identity rather than the interactive session user.
# Detect this by matching the current session ID against Volatile Environment subkeys
# in HKU, which are created per-session by userinit.exe at interactive logon.
$IsRunningCrossUser         = $false
$InteractiveSessionUserSID  = $null
$InteractiveUserProfilePath = $null
$EffectivePrimaryUserSID    = $CurrentUserSecurityIdentifier
$CurrentProcessSessionId    = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
foreach ($CandidateSidKeyName in [Microsoft.Win32.Registry]::Users.GetSubKeyNames()) {
    if ($CandidateSidKeyName.Length -lt 20 -or $CandidateSidKeyName.EndsWith('_Classes')) { continue }
    $SessionVolatileEnvKey = $null
    try { $SessionVolatileEnvKey = [Microsoft.Win32.Registry]::Users.OpenSubKey("$CandidateSidKeyName\Volatile Environment\$CurrentProcessSessionId") } catch { }
    if ($SessionVolatileEnvKey) {
        $SessionVolatileEnvKey.Close()
        $InteractiveSessionUserSID = $CandidateSidKeyName
        break
    }
}
if ($InteractiveSessionUserSID -and $InteractiveSessionUserSID -ne $CurrentUserSecurityIdentifier) {
    $IsRunningCrossUser      = $true
    $EffectivePrimaryUserSID = $InteractiveSessionUserSID
    $ProfileListKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$InteractiveSessionUserSID")
    if ($ProfileListKey) {
        $InteractiveUserProfilePath = $ProfileListKey.GetValue('ProfileImagePath', '')
        $ProfileListKey.Close()
    }
    $TaskBarPinnedDirectory     = [IO.Path]::Combine($InteractiveUserProfilePath, $TaskBarRelativeProfilePath)
    $QuickLaunchDirectory       = [IO.Path]::Combine($InteractiveUserProfilePath, 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch')
    $TaskBarDirectoryExists     = [IO.Directory]::Exists($TaskBarPinnedDirectory)
    $QuickLaunchDirectoryExists = [IO.Directory]::Exists($QuickLaunchDirectory)
    $TaskBandRegistryKeyExists  = $false
    $CrossUserRegistryProbe = [Microsoft.Win32.Registry]::Users.OpenSubKey("$InteractiveSessionUserSID\$TaskBandRegistrySubKey", $false)
    if ($CrossUserRegistryProbe) { $TaskBandRegistryKeyExists = $true; $CrossUserRegistryProbe.Close() }
    $DirectBlobWriteIsSupported = $TaskBarDirectoryExists -and $TaskBandRegistryKeyExists
}


#region LOGGING

# The logging system has three output channels :
#   1. Write-Log     : always writes to the log file (if open), and to the console unless -Silent
#   2. Write-Console  : writes to the console only (never to the log file), respects -Silent
#   3. Write-Banner   : colored status banners (PIN/UNPIN/OK/FAIL) to both console and log file

$LogFileStreamWriter = $null
if ($LogFile) {
    $LogFileParentDirectory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([IO.Path]::Combine($PWD.ProviderPath, $LogFile)))
    if ($LogFileParentDirectory -and -not [IO.Directory]::Exists($LogFileParentDirectory)) {
        $null = [IO.Directory]::CreateDirectory($LogFileParentDirectory)
    }
    $LogFileStreamWriter = New-Object System.IO.StreamWriter($LogFile, $false, [System.Text.Encoding]::UTF8)
    $LogFileStreamWriter.AutoFlush = $true
}

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $FormattedTimestamp = [DateTime]::Now.ToString('HH:mm:ss.fff')
    $FormattedLogLine  = "[$FormattedTimestamp] $Message"
    if (-not $Silent) { Write-Host $FormattedLogLine -ForegroundColor $Color }
    if ($LogFileStreamWriter) { $LogFileStreamWriter.WriteLine($FormattedLogLine) }
}

function Write-Console {
    param([string]$Message, [string]$Color = 'White', [switch]$NoNewline, [string]$BackgroundColor)
    if ($Silent) { return }
    $WriteHostParams = @{ Object = $Message; ForegroundColor = $Color }
    if ($NoNewline)       { $WriteHostParams['NoNewline']       = $true }
    if ($BackgroundColor) { $WriteHostParams['BackgroundColor'] = $BackgroundColor }
    Write-Host @WriteHostParams
}

function Write-Banner {
    param([string]$Label, [string]$LabelBackground, [string]$Detail)
    if (-not $Silent) {
        Write-Host ""
        Write-Host "  $Label  " -ForegroundColor White -BackgroundColor $LabelBackground -NoNewline
        Write-Host "  $Detail"
        Write-Host ""
    }
    if ($LogFileStreamWriter) {
        $FormattedTimestamp = [DateTime]::Now.ToString('HH:mm:ss.fff')
        $LogFileStreamWriter.WriteLine("[$FormattedTimestamp] === $Label : $Detail ===")
    }
}

function Close-Log { if ($LogFileStreamWriter) { $LogFileStreamWriter.Close() } }
trap { Close-Log; break }


#region INPUT VALIDATION

if (-not $Pin) {
    Write-Log "ERROR : Specify -Pin" -Color Red
    Close-Log; exit 3
}

# Split semicolon-delimited input into individual items, trim whitespace, discard empties
$ParsedInputItems = @($Pin -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($ParsedInputItems.Count -eq 0) {
    Write-Log "ERROR : Specify -Pin" -Color Red
    Close-Log; exit 3
}

# Normalize UWP inputs : accept uwp: prefix and bare AUMIDs (containing !)
# "uwp:Microsoft.Calculator_8wekyb3d8bbwe!App" -> "shell:AppsFolder\Microsoft.Calculator_8wekyb3d8bbwe!App"
# "Microsoft.Calculator_8wekyb3d8bbwe!App"      -> "shell:AppsFolder\Microsoft.Calculator_8wekyb3d8bbwe!App"
$ParsedInputItems = @($ParsedInputItems | ForEach-Object {  if     ($_.StartsWith('uwp:', [StringComparison]::OrdinalIgnoreCase))              { 'shell:AppsFolder\' + $_.Substring(4) }
                                                            elseif ($_.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase)) { 'shell:AppsFolder\' + $_.Substring(17) }
                                                            elseif ($_ -match '!' -and $_ -notmatch '[/\\]')                                  { 'shell:AppsFolder\' + $_ }
                                                            else                                                                              {                       $_ }
})


#region ELEVATION CHECK

function Test-IsAdmin {
    $CurrentIdentity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)
    return $CurrentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($AllUsers -and -not (Test-IsAdmin)) {
    Write-Log "ERROR : -AllUsers requires elevation (run as Administrator)" -Color Red
    Close-Log; exit 3
}


#region C# COMPILATION

# This compiles a C# class that provides low-level Win32 interop functions that
# cannot be done (or done efficiently) in pure PowerShell :
#
#   PIDL manipulation :
#     - GetBlobEntryEx()  : takes an .lnk path, calls SHParseDisplayName to obtain
#                           its namespace PIDL, then injects a BEEF001D extension block
#                           into the last SHITEMID so the taskbar handler can resolve it.
#     - GetBlobEntryFs()  : same but uses ILCreateFromPathW (filesystem PIDL). Used for
#                           AllUsers mode where SHParseDisplayName targets a foreign profile.
#
#   Blob parsing :
#     - FindBlobEntry()   : searches the Favorites blob for a Unicode filename match.
#     - RemoveFavEntry()  : removes an entry from the Favorites blob by index.
#     - RemoveResEntry()  : removes an entry from the FavoritesResolve blob by index.
#
#   Taskbar notification :
#     - SendPinNotify()   : fires SHChangeNotify(SHCNE_EXTENDED_EVENT, type=0x0D) which
#                           tells the Taskbar.dll handler to re-read the blob.
#
#   Mutex :
#     - AcquirePinMutex() : acquires the "TaskbarPinListMutex" named kernel mutex to
#                           serialize with concurrent blob writes from explorer.exe.
#     - ReleasePinMutex() : releases and closes the mutex handle.
#
#   UWP shortcut creation :
#     - CreateAppShortcut() : creates a .lnk for a UWP/MSIX app by resolving its AUMID
#                             through shell:AppsFolder, setting PKEY_AppUserModel_ID, and
#                             saving via IPersistFile.
#     - GetAumid()          : reads the AUMID from an existing .lnk via IPropertyStore.

function Initialize-NativeHelper {
    # Skip compilation if the type is already loaded (idempotent)
    if ('TaskbarPin' -as [Type]) { return }
    Write-Log "[init] Compiling C# native helper (COM interop, PIDL manipulation, mutex, blob parsing)..."
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public class TaskbarPin {

    //===========================================================
    //  Win32 P/Invoke declarations
    //===========================================================

    // Creates a filesystem PIDL from a path string.
    // Returns IntPtr.Zero on failure. Caller must ILFree the result.
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr ILCreateFromPathW(string pszPath);

    // Frees a PIDL allocated by the shell.
    [DllImport("shell32.dll")]
    static extern void ILFree(IntPtr pidl);

    // Returns a pointer to the last SHITEMID in a PIDL chain.
    // This is where we inject the BEEF001D extension block.
    [DllImport("shell32.dll")]
    static extern IntPtr ILFindLastID(IntPtr pidl);

    // Parses a display name string into a namespace PIDL.
    // Namespace PIDLs (rooted at {59031A47}) are what the taskbar handler expects.
    // Returns HRESULT 0 on success.
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHParseDisplayName(string pszName, IntPtr pbc, out IntPtr ppidl, uint sfgaoIn, out uint psfgaoOut);

    // Notifies the shell of a change. We use SHCNE_EXTENDED_EVENT (0x04000000)
    // with a custom payload to tell the taskbar handler to re-read its blob.
    [DllImport("shell32.dll")]
    static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

    // Creates a COM object instance. Used for IShellLink creation.
    [DllImport("ole32.dll")]
    static extern int CoCreateInstance(ref Guid rclsid, IntPtr pUnk, uint ctx, ref Guid riid, out IntPtr ppv);

    // Clears a PROPVARIANT and frees its associated memory.
    [DllImport("ole32.dll")]
    static extern int PropVariantClear(IntPtr pvar);

    // Creates or opens a named kernel mutex. Used for TaskbarPinListMutex serialization.
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateMutexExW(IntPtr lpMutexAttributes, string lpName, uint dwFlags, uint dwDesiredAccess);

    // Waits for a kernel object to become signaled. Returns 0 (WAIT_OBJECT_0) on success.
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    // Releases ownership of a mutex.
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReleaseMutex(IntPtr hMutex);

    // Closes a kernel handle.
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    //===========================================================
    //  COM vtable delegate signatures
    //===========================================================
    // These delegates map to specific vtable slots on COM interfaces
    // (IShellLink, IPropertyStore, IPersistFile) that we call via
    // raw vtable pointer arithmetic, because PowerShell 2.0 cannot
    // use .NET 4+ COM interop wrappers.

    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint FnRelease(IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnQueryInterface(IntPtr p, ref Guid riid, out IntPtr ppv);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSetIDList(IntPtr p, IntPtr pidl);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSetValue(IntPtr p, IntPtr key, IntPtr propvar);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnCommitStore(IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSaveFile(IntPtr p, IntPtr pszFileName, int fRemember);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnLoadFile(IntPtr p, IntPtr pszFileName, uint dwMode);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnGetValue(IntPtr p, IntPtr key, IntPtr propvar);

    //===========================================================
    //  Class-level constants
    //===========================================================

    static readonly Guid CLSID_ShellLink    = new Guid("00021401-0000-0000-C000-000000000046");
    static readonly Guid IID_IShellLinkW    = new Guid("000214F9-0000-0000-C000-000000000046");
    static readonly Guid IID_IPropertyStore = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    static readonly Guid IID_IPersistFile   = new Guid("0000010B-0000-0000-C000-000000000046");
    static readonly Guid FMTID_AppUserModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    //===========================================================
    //  STA thread helper
    //===========================================================

    // Many shell COM operations require an STA (Single-Threaded Apartment) thread.
    // PowerShell runs in MTA by default. This generic wrapper spawns a dedicated
    // STA thread when needed, runs the operation there, and joins back.
    static T RunOnSTA<T>(Func<T> fn) {
        if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA) return fn();
        T r = default(T);
        Thread t = new Thread(delegate() { r = fn(); });
        t.SetApartmentState(ApartmentState.STA);
        t.Start(); t.Join();
        return r;
    }

    //===========================================================
    //  COM vtable and Release helpers
    //===========================================================

    // Reads a delegate of type T from a COM vtable at the given slot index.
    static T Vtbl<T>(IntPtr vtbl, int slot) where T : class {
        return (T)(object)Marshal.GetDelegateForFunctionPointer(
            Marshal.ReadIntPtr(vtbl, slot * IntPtr.Size), typeof(T));
    }

    // Release a COM object by reading its vtable and calling slot[2] (IUnknown::Release).
    static void Release(IntPtr ppv) {
        Vtbl<FnRelease>(Marshal.ReadIntPtr(ppv), 2)(ppv);
    }

    // Release when we already have the vtable pointer cached.
    static void Release(IntPtr ppv, IntPtr vtbl) {
        Vtbl<FnRelease>(vtbl, 2)(ppv);
    }

    //===========================================================
    //  PIDL resolution
    //===========================================================

    // Wrapper around SHParseDisplayName that returns IntPtr.Zero on failure
    // instead of requiring HRESULT checking at every call site.
    static IntPtr ParseDisplayName(string name) {
        IntPtr pidl; uint sfgao;
        if (SHParseDisplayName(name, IntPtr.Zero, out pidl, 0, out sfgao) == 0) return pidl;
        return IntPtr.Zero;
    }

    //===========================================================
    //  Property store helpers (PKEY_AppUserModel_ID)
    //===========================================================

    // Allocates a PROPERTYKEY structure for PKEY_AppUserModel_ID (PID 5).
    static IntPtr AllocPropertyKey() {
        byte[] pk = new byte[20];
        Array.Copy(FMTID_AppUserModel.ToByteArray(), 0, pk, 0, 16);
        pk[16] = 5; // PID = 5 (AppUserModel_ID)
        IntPtr ptr = Marshal.AllocCoTaskMem(20);
        Marshal.Copy(pk, 0, ptr, 20);
        return ptr;
    }

    // Writes an AUMID string to an IShellLink's IPropertyStore.
    // Sets PKEY_AppUserModel_ID as VT_LPWSTR and commits the store.
    static bool WriteAumidToStore(IntPtr psl, IntPtr vtLink, string aumid) {
        Guid iid = IID_IPropertyStore; IntPtr pps;
        if (Vtbl<FnQueryInterface>(vtLink, 0)(psl, ref iid, out pps) != 0) return false;
        try {
            IntPtr pkPtr = AllocPropertyKey();
            IntPtr pvPtr = Marshal.AllocCoTaskMem(24);
            for (int i = 0; i < 24; i++) Marshal.WriteByte(pvPtr, i, 0);
            Marshal.WriteInt16(pvPtr, 0, 31); // VT_LPWSTR
            IntPtr strPtr = Marshal.StringToCoTaskMemUni(aumid);
            Marshal.WriteIntPtr(pvPtr, 8, strPtr);
            try {
                IntPtr vt = Marshal.ReadIntPtr(pps);
                Vtbl<FnSetValue>(vt, 6)(pps, pkPtr, pvPtr);   // IPropertyStore::SetValue
                Vtbl<FnCommitStore>(vt, 7)(pps);              // IPropertyStore::Commit
            } finally {
                Marshal.FreeCoTaskMem(strPtr);
                Marshal.FreeCoTaskMem(pvPtr);
                Marshal.FreeCoTaskMem(pkPtr);
            }
        } finally { Release(pps); }
        return true;
    }

    // Saves an IShellLink to disk via IPersistFile::Save.
    static bool PersistSave(IntPtr psl, IntPtr vtLink, string lnkPath) {
        Guid iid = IID_IPersistFile; IntPtr ppf;
        if (Vtbl<FnQueryInterface>(vtLink, 0)(psl, ref iid, out ppf) != 0) return false;
        try {
            IntPtr p = Marshal.StringToCoTaskMemUni(lnkPath);
            try { Vtbl<FnSaveFile>(Marshal.ReadIntPtr(ppf), 6)(ppf, p, 1); }
            finally { Marshal.FreeCoTaskMem(p); }
        } finally { Release(ppf); }
        return true;
    }

    //===========================================================
    //  BEEF001D extension block injection
    //===========================================================

    // Injects a BEEF001D extension block into a SHITEMID's extension chain.
    //
    // SHITEMID extension blocks are chained after the primary data. Each block
    // has an 8-byte header : [uint16 cb][uint16 version][uint32 signature].
    // The last 2 bytes of the SHITEMID store the offset to the first extension block.
    //
    // BEEF001D format :
    //   [uint16 cb]                -- total block size
    //   [uint16 version = 0x0000]
    //   [uint32 sig = 0xBEEF001D]
    //   [uint16 type = 0x0002]
    //   [wchar[] parsingName + null terminator]
    static byte[] InjectBeef001D(byte[] item, string displayName) {
        ushort cb = BitConverter.ToUInt16(item, 0);
        if (cb < 4) return null;
        byte[] nameBytes = System.Text.Encoding.Unicode.GetBytes(displayName + "\0");
        int blockCb = 2 + 2 + 4 + 2 + nameBytes.Length;
        byte[] block = new byte[blockCb];
        Array.Copy(BitConverter.GetBytes((ushort)blockCb), 0, block, 0, 2);
        block[2] = 0; block[3] = 0;
        block[4] = 0x1D; block[5] = 0x00; block[6] = 0xEF; block[7] = 0xBE;
        block[8] = 0x02; block[9] = 0x00;
        Array.Copy(nameBytes, 0, block, 10, nameBytes.Length);
        ushort extOffset = BitConverter.ToUInt16(item, cb - 2);
        int insertPos;
        if (extOffset > 4 && extOffset < cb - 4) {
            int epos = extOffset;
            while (epos + 8 <= cb) {
                ushort ecb = BitConverter.ToUInt16(item, epos);
                if (ecb < 8 || epos + ecb > cb) break;
                uint esig = BitConverter.ToUInt32(item, epos + 4);
                if ((esig & 0xFFFF0000) != 0xBEEF0000) break;
                epos += ecb;
            }
            insertPos = epos;
        } else {
            insertPos = cb - 2;
            extOffset = (ushort)insertPos;
        }
        int newCb = insertPos + blockCb + 2;
        byte[] result = new byte[newCb];
        Array.Copy(item, 0, result, 0, insertPos);
        Array.Copy(block, 0, result, insertPos, blockCb);
        Array.Copy(BitConverter.GetBytes(extOffset), 0, result, newCb - 2, 2);
        Array.Copy(BitConverter.GetBytes((ushort)newCb), 0, result, 0, 2);
        return result;
    }

    // Builds a complete Favorites blob entry from a PIDL and a BEEF001D content string.
    //
    // The Favorites blob format for each entry is :
    //   [1 byte]  category (0x00 = Desktop root)
    //   [4 bytes] pidlSize (uint32 LE)
    //   [N bytes] PIDL data with BEEF001D injected into the last SHITEMID
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
        result[0] = 0x00;
        Array.Copy(BitConverter.GetBytes((uint)newPidlLen), 0, result, 1, 4);
        Marshal.Copy(pidl, result, 5, prefixLen);
        Array.Copy(patched, 0, result, 5 + prefixLen, patched.Length);
        return result;
    }

    // Public entry point using SHParseDisplayName (namespace PIDLs).
    // Produces PIDLs natively accepted by the taskbar handler.
    public static byte[] GetBlobEntryEx(string lnkFullPath, string beef001dContent) {
        return RunOnSTA(() => {
            IntPtr pidl; uint sfgao;
            if (SHParseDisplayName(lnkFullPath, IntPtr.Zero, out pidl, 0, out sfgao) != 0 || pidl == IntPtr.Zero) return null;
            try { return BuildBlobEntry(pidl, beef001dContent); } finally { ILFree(pidl); }
        });
    }

    // Public entry point using ILCreateFromPathW (filesystem PIDLs).
    // Used in AllUsers mode where SHParseDisplayName cannot resolve
    // paths under another user's profile.
    public static byte[] GetBlobEntryFs(string lnkFullPath, string beef001dContent) {
        return RunOnSTA(() => {
            IntPtr pidl = ILCreateFromPathW(lnkFullPath);
            if (pidl == IntPtr.Zero) return null;
            try { return BuildBlobEntry(pidl, beef001dContent); } finally { ILFree(pidl); }
        });
    }

    //===========================================================
    //  SHChangeNotify -- taskbar refresh notification
    //===========================================================

    // Sends SHCNE_EXTENDED_EVENT with type=0x0D payload.
    // The Taskbar.dll handler picks this up and re-reads the Favorites blob.
    public static void SendPinNotify() {
        byte[] payload = new byte[12];
        payload[0] = 0x0A; payload[1] = 0x00;
        payload[2] = 0x0D; payload[3] = 0x00;
        IntPtr ptr = Marshal.AllocHGlobal(12);
        try {
            Marshal.Copy(payload, 0, ptr, 12);
            SHChangeNotify(0x04000000, 0x3000, ptr, IntPtr.Zero);
        } finally { Marshal.FreeHGlobal(ptr); }
    }

    //===========================================================
    //  TaskbarPinListMutex -- serialization with explorer.exe
    //===========================================================

    static IntPtr _mutexHandle = IntPtr.Zero;

    public static bool AcquirePinMutex(int timeoutMs) {
        IntPtr h = CreateMutexExW(IntPtr.Zero, "TaskbarPinListMutex", 0, 0x001F0001);
        if (h == IntPtr.Zero) return false;
        uint r = WaitForSingleObject(h, (uint)timeoutMs);
        if (r == 0 || r == 0x80) { _mutexHandle = h; return true; }
        CloseHandle(h);
        return false;
    }

    public static void ReleasePinMutex() {
        if (_mutexHandle != IntPtr.Zero) {
            ReleaseMutex(_mutexHandle);
            CloseHandle(_mutexHandle);
            _mutexHandle = IntPtr.Zero;
        }
    }

    //===========================================================
    //  Blob parsing -- search and removal
    //===========================================================

    // Searches the Favorites blob for an entry whose PIDL data contains
    // the given filename as a Unicode substring. Returns the 0-based entry
    // index, or -1 if not found.
    public static int FindBlobEntry(byte[] blob, string filename) {
        byte[] needle = System.Text.Encoding.Unicode.GetBytes(filename);
        int pos = 0; int idx = 0;
        while (pos < blob.Length && blob[pos] != 0xFF) {
            if (pos + 5 > blob.Length) break;
            uint pidlSize = BitConverter.ToUInt32(blob, pos + 1);
            int pidlStart = pos + 5;
            int pidlEnd   = pidlStart + (int)pidlSize;
            if (pidlEnd > blob.Length) break;
            for (int b = pidlStart; b + needle.Length <= pidlEnd; b++) {
                bool match = true;
                for (int c = 0; c < needle.Length; c++) { if (blob[b + c] != needle[c]) { match = false; break; } }
                if (match) return idx;
            }
            pos = pidlEnd; idx++;
        }
        return -1;
    }

    // Removes the entry at removeIdx from the Favorites blob.
    public static byte[] RemoveFavEntry(byte[] blob, int removeIdx) {
        System.IO.MemoryStream ms = new System.IO.MemoryStream();
        int pos = 0; int idx = 0;
        while (pos < blob.Length && blob[pos] != 0xFF) {
            if (pos + 5 > blob.Length) break;
            uint pidlSize = BitConverter.ToUInt32(blob, pos + 1);
            int total = 1 + 4 + (int)pidlSize;
            if (pos + total > blob.Length) break;
            if (idx != removeIdx) ms.Write(blob, pos, total);
            pos += total; idx++;
        }
        ms.WriteByte(0xFF);
        return ms.ToArray();
    }

    // Removes the entry at removeIdx from the FavoritesResolve blob.
    // Different format : [uint32 linkSize][linkData] repeated, no terminator.
    public static byte[] RemoveResEntry(byte[] blob, int removeIdx) {
        System.IO.MemoryStream ms = new System.IO.MemoryStream();
        int pos = 0; int idx = 0;
        while (pos + 4 <= blob.Length) {
            uint linkSize = BitConverter.ToUInt32(blob, pos);
            if (linkSize == 0 || pos + 4 + (int)linkSize > blob.Length) break;
            int total = 4 + (int)linkSize;
            if (idx != removeIdx) ms.Write(blob, pos, total);
            pos += total; idx++;
        }
        return ms.ToArray();
    }

    //===========================================================
    //  Shortcut creation (shared logic)
    //===========================================================

    // Creates an IShellLink from a PIDL, optionally sets the AUMID property,
    // and saves the .lnk to disk. Used by both CreateAppShortcut and CreatePidlShortcut.
    static bool CreateShortcutFromPidl(IntPtr pidl, string lnkPath, string aumid) {
        Guid cls = CLSID_ShellLink; Guid iid = IID_IShellLinkW; IntPtr psl;
        if (CoCreateInstance(ref cls, IntPtr.Zero, 1, ref iid, out psl) != 0) return false;
        IntPtr vtLink = Marshal.ReadIntPtr(psl);
        try {
            Vtbl<FnSetIDList>(vtLink, 5)(psl, pidl);
            if (aumid != null && aumid.Length > 0) WriteAumidToStore(psl, vtLink, aumid);
            return PersistSave(psl, vtLink, lnkPath);
        } finally { Release(psl, vtLink); }
    }

    //===========================================================
    //  UWP shortcut creation
    //===========================================================

    // Creates a .lnk shortcut file for a UWP/MSIX application identified by AUMID.
    // Resolves the AUMID to a PIDL via shell:AppsFolder, sets PKEY_AppUserModel_ID,
    // and saves the .lnk via IPersistFile.
    public static bool CreateAppShortcut(string aumid, string lnkPath) {
        return RunOnSTA(() => {
            IntPtr pidl = ParseDisplayName("shell:AppsFolder\\" + aumid);
            if (pidl == IntPtr.Zero) return false;
            try { return CreateShortcutFromPidl(pidl, lnkPath, aumid); }
            finally { ILFree(pidl); }
        });
    }

    // Creates a .lnk shortcut from a shell display name (e.g. a Control Panel item path).
    // The appUserModelId parameter is stored as the AUMID property on the shortcut.
    public static bool CreatePidlShortcut(string displayName, string lnkPath, string appUserModelId) {
        return RunOnSTA(() => {
            IntPtr pidl; uint sfgao;
            if (SHParseDisplayName(displayName, IntPtr.Zero, out pidl, 0, out sfgao) != 0 || pidl == IntPtr.Zero) return false;
            try { return CreateShortcutFromPidl(pidl, lnkPath, appUserModelId); }
            finally { ILFree(pidl); }
        });
    }

    //===========================================================
    //  AUMID extraction from existing shortcuts
    //===========================================================

    // Reads the PKEY_AppUserModel_ID (AUMID) from an existing .lnk file.
    // Returns empty string if the property is not set.
    public static string GetAumid(string lnkPath) {
        return RunOnSTA(() => {
            Guid cls = CLSID_ShellLink; Guid iid = IID_IShellLinkW; IntPtr psl;
            if (CoCreateInstance(ref cls, IntPtr.Zero, 1, ref iid, out psl) != 0) return "";
            IntPtr vtLink = Marshal.ReadIntPtr(psl);
            try {
                FnQueryInterface qi = Vtbl<FnQueryInterface>(vtLink, 0);
                // Load the .lnk file via IPersistFile
                Guid iidFile = IID_IPersistFile; IntPtr ppf;
                if (qi(psl, ref iidFile, out ppf) != 0) return "";
                try {
                    IntPtr p = Marshal.StringToCoTaskMemUni(lnkPath);
                    try { if (Vtbl<FnLoadFile>(Marshal.ReadIntPtr(ppf), 5)(ppf, p, 0) != 0) return ""; }
                    finally { Marshal.FreeCoTaskMem(p); }
                } finally { Release(ppf); }
                // Read AUMID from IPropertyStore
                Guid iidStore = IID_IPropertyStore; IntPtr pps;
                if (qi(psl, ref iidStore, out pps) != 0) return "";
                try {
                    IntPtr pkPtr = AllocPropertyKey();
                    IntPtr pvPtr = Marshal.AllocCoTaskMem(24);
                    for (int i = 0; i < 24; i++) Marshal.WriteByte(pvPtr, i, 0);
                    try {
                        if (Vtbl<FnGetValue>(Marshal.ReadIntPtr(pps), 5)(pps, pkPtr, pvPtr) != 0) return "";
                        short vt = Marshal.ReadInt16(pvPtr);
                        if (vt != 31) return "";
                        IntPtr sp = Marshal.ReadIntPtr(pvPtr, 8);
                        if (sp == IntPtr.Zero) return "";
                        return Marshal.PtrToStringUni(sp) ?? "";
                    } finally {
                        PropVariantClear(pvPtr);
                        Marshal.FreeCoTaskMem(pvPtr);
                        Marshal.FreeCoTaskMem(pkPtr);
                    }
                } finally { Release(pps); }
            } finally { Release(psl, vtLink); }
        });
    }
}
'@
    Write-Log "[init] C# native helper compiled successfully"
}


# Opens the Taskband registry key for the effective primary user.
# In cross-user mode, targets HKU\{InteractiveSessionSID} instead of HKCU.
function Open-EffectiveTaskbandKey {
    param([bool]$Writable = $false)
    if ($IsRunningCrossUser) {
        return [Microsoft.Win32.Registry]::Users.OpenSubKey("$InteractiveSessionUserSID\$TaskBandRegistrySubKey", $Writable)
    }
    return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($TaskBandRegistrySubKey, $Writable)
}


#region FILES HELPERS

# Resolve a .cpl file to its matching Control Panel namespace item.
# Enumerates shell:ControlPanelFolder, matches each item's CLSID InprocServer32
# module path or DefaultIcon value against the .cpl filename.
# Returns a hashtable with Name and Path properties, or $null if not found.
function Resolve-CplControlPanelItem {
    param([string]$CplFilePath)
    $CplFileName = [IO.Path]::GetFileName($CplFilePath).ToLower()
    $CplBaseName = [IO.Path]::GetFileNameWithoutExtension($CplFilePath).ToLower()
    $CplShellApp = New-Object -ComObject Shell.Application
    $CplNamespace = $CplShellApp.Namespace('shell:ControlPanelFolder')
    $MatchedResult = $null
    foreach ($ControlPanelItem in $CplNamespace.Items()) {
        $ControlPanelItemPath = $ControlPanelItem.Path
        $AllGuidsInPath = [regex]::Matches($ControlPanelItemPath, '\{[0-9A-Fa-f\-]+\}')
        foreach ($GuidMatch in $AllGuidsInPath) {
            $CandidateGuid = $GuidMatch.Value
            $InprocRegistryKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("CLSID\$CandidateGuid\InprocServer32")
            if ($InprocRegistryKey) {
                $ModulePath = $InprocRegistryKey.GetValue($null, ''); $InprocRegistryKey.Close()
                if ($ModulePath -and [IO.Path]::GetFileName($ModulePath).ToLower() -eq $CplFileName) {
                    $MatchedResult = @{ Name = $ControlPanelItem.Name; Path = $ControlPanelItemPath }; break
                }
            }
            $DefaultIconKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("CLSID\$CandidateGuid\DefaultIcon")
            if ($DefaultIconKey) {
                $IconValue = $DefaultIconKey.GetValue($null, ''); $DefaultIconKey.Close()
                if ($IconValue -and $IconValue.ToLower().Contains($CplBaseName)) {
                    $MatchedResult = @{ Name = $ControlPanelItem.Name; Path = $ControlPanelItemPath }; break
                }
            }
        }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ControlPanelItem)
        if ($MatchedResult) { break }
    }
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($CplNamespace)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($CplShellApp)
    return $MatchedResult
}

# Resolve a filesystem input string to one or more absolute paths.
# Supports direct paths, wildcards, bare filenames (searched via PATH/PATHEXT),
# and extensionless names that get .exe/.lnk appended automatically.
function Resolve-FilesystemInput {
    param([string]$InputPath)
    $InputContainsWildcard      = $InputPath.Contains('*') -or $InputPath.Contains('?')
    $InputContainsDirectoryPart = $InputPath.Contains('\') -or $InputPath.Contains('/')
    # Direct path resolution (no wildcards) -- try exact path first
    if (-not $InputContainsWildcard) {
        try {
            $AbsoluteDirectPath = [IO.Path]::GetFullPath([IO.Path]::Combine($PWD.ProviderPath, $InputPath))
            if ([IO.File]::Exists($AbsoluteDirectPath))      { return $AbsoluteDirectPath }
            if ([IO.Directory]::Exists($AbsoluteDirectPath)) { return $AbsoluteDirectPath }
        } catch { }
    }
    # Wildcard or fallback : search by filename pattern in a directory
    $FileNamePattern = [IO.Path]::GetFileName($InputPath)
    if ($InputContainsDirectoryPart) {
        # User specified a directory -- search only there
        try {
            $ExplicitSearchDirectory = [IO.Path]::GetFullPath([IO.Path]::Combine($PWD.ProviderPath, [IO.Path]::GetDirectoryName($InputPath)))
            if ([IO.Directory]::Exists($ExplicitSearchDirectory)) {
                $FoundFilesInDirectory = @([IO.Directory]::GetFiles($ExplicitSearchDirectory, $FileNamePattern))
                if ($FoundFilesInDirectory.Count -gt 0) { return $FoundFilesInDirectory }
            }
        } catch { }
    } else {
        # No directory specified : search current directory, then every PATH entry
        $DirectoriesToSearch = @($PWD.ProviderPath)
        foreach ($PathEntry in ($env:PATH -split ';')) {
            if ($PathEntry -and [IO.Directory]::Exists($PathEntry)) { $DirectoriesToSearch += $PathEntry }
        }
        # If no extension and no wildcard, try appending PATHEXT extensions and .lnk
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

# Creates a .lnk shortcut suitable for taskbar pinning from a resolved filesystem path.
# For .lnk inputs   : returns the same path and extracts its target for BEEF001D.
# For .exe inputs   : creates a temp .lnk in %TEMP% named after the FileDescription.
# For .cpl inputs   : resolves via Control Panel namespace with CreatePidlShortcut,
#                     falls back to a rundll32 shortcut if the namespace match fails.
# For directories   : creates a temp .lnk targeting explorer.exe with the dir as argument.
# For other types   : creates a temp .lnk pointing directly at the target file.
# The BEEF001D parsing name (set via $Beef001dContentRef) tells the taskbar handler
# what the shortcut actually points to. This MUST be unique per item -- if two shortcuts
# share the same BEEF001D content, the handler treats them as duplicates.
function New-TargetShortcut {
    param([string]$ResolvedTargetPath, [ref]$Beef001dContentRef, [ref]$WshShellComObjectRef)
    $TargetFileExtension = [IO.Path]::GetExtension($ResolvedTargetPath).ToLower()
    # .lnk inputs : read their target path as BEEF001D content, return as-is
    if ($TargetFileExtension -eq '.lnk') {
        if (-not $WshShellComObjectRef.Value) { $WshShellComObjectRef.Value = New-Object -ComObject WScript.Shell }
        $ShortcutObject = $WshShellComObjectRef.Value.CreateShortcut($ResolvedTargetPath)
        $Beef001dContentRef.Value = $ShortcutObject.TargetPath
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ShortcutObject)
        # If TargetPath is empty, this is likely a UWP shortcut -- try reading the AUMID
        if (-not $Beef001dContentRef.Value) { $Beef001dContentRef.Value = [TaskbarPin]::GetAumid($ResolvedTargetPath) }
        return $ResolvedTargetPath
    }
    # .cpl inputs : resolve through Control Panel namespace for proper icon and display name.
    # Falls back to a rundll32-based shortcut if the namespace match fails.
    if ($TargetFileExtension -eq '.cpl') {
        Initialize-NativeHelper
        $CplControlPanelMatch = Resolve-CplControlPanelItem $ResolvedTargetPath
        if ($CplControlPanelMatch) {
            $SafeCplDisplayName       = $CplControlPanelMatch.Name -replace '[<>:"/\\|?*]', '_'
            $CplTemporaryLnkPath      = [IO.Path]::Combine($env:TEMP, "$SafeCplDisplayName.lnk")
            if ([TaskbarPin]::CreatePidlShortcut($CplControlPanelMatch.Path, $CplTemporaryLnkPath, $CplControlPanelMatch.Path)) {
                $Beef001dContentRef.Value = $CplControlPanelMatch.Path
                return $CplTemporaryLnkPath
            }
        }
        Write-Log "  [!] CPL not found in Control Panel namespace, fallback to filesystem shortcut" -Color Yellow
    }
    # Non-.lnk inputs : create a temporary shortcut in %TEMP%
    $ShortcutDisplayName = [IO.Path]::GetFileNameWithoutExtension($ResolvedTargetPath)
    # For .exe files, try to get a friendlier name from the FileDescription PE metadata
    if ($TargetFileExtension -eq '.exe') {
        try {
            $FileVersionDescription = [Diagnostics.FileVersionInfo]::GetVersionInfo($ResolvedTargetPath).FileDescription
            if ($FileVersionDescription -and $FileVersionDescription.Trim()) {
                $CandidateDisplayName = ($FileVersionDescription.Trim() -replace '[<>:"/\\|?*]', '_')
                if (-not [IO.File]::Exists([IO.Path]::Combine($TaskBarPinnedDirectory, "$CandidateDisplayName.lnk"))) {
                    $ShortcutDisplayName = $CandidateDisplayName
                }
            }
        } catch { }
    }
    $TemporaryLnkPath = [IO.Path]::Combine($env:TEMP, "$ShortcutDisplayName.lnk")
    if (-not $WshShellComObjectRef.Value) { $WshShellComObjectRef.Value = New-Object -ComObject WScript.Shell }
    $NewShortcutObject = $WshShellComObjectRef.Value.CreateShortcut($TemporaryLnkPath)
    # Configure shortcut properties based on the target file type.
    # BEEF001D content must be the ARGUMENT file (not the host executable)
    # for .cpl fallback, because the host exe is shared across many items
    # and BEEF001D must be unique per pinned item.
    if ($TargetFileExtension -eq '.cpl') {
        $NewShortcutObject.TargetPath       = [IO.Path]::Combine($env:SystemRoot, 'System32\rundll32.exe')
        $NewShortcutObject.Arguments         = "shell32.dll,Control_RunDLL `"$ResolvedTargetPath`""
        $NewShortcutObject.IconLocation      = "$ResolvedTargetPath,0"
        $NewShortcutObject.WorkingDirectory  = [IO.Path]::GetDirectoryName($ResolvedTargetPath)
        $Beef001dContentRef.Value            = $ResolvedTargetPath
    } elseif ([IO.Directory]::Exists($ResolvedTargetPath)) {
        $NewShortcutObject.TargetPath      = [IO.Path]::Combine($env:SystemRoot, 'explorer.exe')
        $NewShortcutObject.Arguments        = "`"$ResolvedTargetPath`""
        $NewShortcutObject.IconLocation     = [IO.Path]::Combine($env:SystemRoot, 'System32\shell32.dll') + ',3'
        $NewShortcutObject.WorkingDirectory = $ResolvedTargetPath
        $Beef001dContentRef.Value           = $ResolvedTargetPath
    } else {
        $NewShortcutObject.TargetPath      = $ResolvedTargetPath
        $NewShortcutObject.WorkingDirectory = [IO.Path]::GetDirectoryName($ResolvedTargetPath)
        $Beef001dContentRef.Value           = $ResolvedTargetPath
    }
    $NewShortcutObject.Save()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($NewShortcutObject)
    return $TemporaryLnkPath
}


#region REGISTRY BLOB WRITE

# Appends new entries to the Favorites blob in the Taskband registry key.
# The Favorites blob is the binary value that tells the taskbar which items are pinned.
# Its format is a sequence of [category][pidlSize][pidlData] entries terminated by 0xFF.
# This function :
#   1. Finds the 0xFF terminator in the existing blob (insertion point)
#   2. Checks each new entry against the blob for duplicates (by .lnk filename)
#   3. Appends non-duplicate entries before the terminator
#   4. Writes the new blob, FavoritesVersion=3, and increments FavoritesChanges
# The write order is critical : blob first, then version, then changes counter.
# The taskbar handler checks FavoritesChanges as a guard -- writing it LAST ensures
# the blob is fully committed before the handler reads it.
# Returns the number of entries actually added (0 if all were duplicates).
function Write-BlobToRegistryKey {
    param($RegistryKeyHandle, [byte[]]$ExistingFavoritesBlob, $NewBlobEntriesToAdd)
    # Start with a minimal valid blob if none exists
    if (-not $ExistingFavoritesBlob -or $ExistingFavoritesBlob.Length -lt 2) { $ExistingFavoritesBlob = [byte[]]@(0xFF) }
    # Walk the blob to find the insertion point (just before 0xFF terminator)
    $BlobInsertionOffset = 0
    while ($BlobInsertionOffset -lt $ExistingFavoritesBlob.Length -and $ExistingFavoritesBlob[$BlobInsertionOffset] -ne 0xFF) {
        if ($BlobInsertionOffset + 5 -gt $ExistingFavoritesBlob.Length) { break }
        $CurrentEntryPidlSize = [BitConverter]::ToUInt32($ExistingFavoritesBlob, $BlobInsertionOffset + 1)
        $BlobInsertionOffset += 1 + 4 + $CurrentEntryPidlSize
    }
    # Build the new blob by copying existing entries, then appending new ones
    $OutputBlobStream = New-Object System.IO.MemoryStream
    if ($BlobInsertionOffset -gt 0) { $OutputBlobStream.Write($ExistingFavoritesBlob, 0, $BlobInsertionOffset) }
    $NumberOfEntriesActuallyAdded = 0
    foreach ($NewEntry in $NewBlobEntriesToAdd) {
        $ShortcutFileName = [IO.Path]::GetFileName($NewEntry.DestinationLnkPath)
        # Deduplication : skip if this .lnk filename is already in the blob
        if ([TaskbarPin]::FindBlobEntry($ExistingFavoritesBlob, $ShortcutFileName) -ge 0) {
            Write-Log "    [blob] '$ShortcutFileName' already present in Favorites blob -- skipping duplicate" 'Yellow'
            continue
        }
        $OutputBlobStream.Write($NewEntry.SerializedBlobEntry, 0, $NewEntry.SerializedBlobEntry.Length)
        $NumberOfEntriesActuallyAdded++
        Write-Log "    [blob] Appended '$ShortcutFileName' to blob ($($NewEntry.SerializedBlobEntry.Length) bytes)"
    }
    $OutputBlobStream.WriteByte(0xFF) # terminator
    $FinalBlobBytes = $OutputBlobStream.ToArray()
    $OutputBlobStream.Dispose()
    if ($NumberOfEntriesActuallyAdded -eq 0) {
        Write-Log "    [blob] No new entries to add -- Favorites blob unchanged"
        return 0
    }
    # Write atomically : blob -> version -> changes counter (order matters, see header comment)
    $CurrentFavoritesChangesCounter = [int]$RegistryKeyHandle.GetValue('FavoritesChanges', 0, $DoNotExpandRegistryOption)
    $RegistryKeyHandle.SetValue('Favorites',        $FinalBlobBytes,                       $BinaryRegistryValueKind)
    $RegistryKeyHandle.SetValue('FavoritesVersion',  3,                                    $DwordRegistryValueKind)
    $RegistryKeyHandle.SetValue('FavoritesChanges', ($CurrentFavoritesChangesCounter + 1), $DwordRegistryValueKind)
    Write-Log "    [blob] Favorites : $($ExistingFavoritesBlob.Length) -> $($FinalBlobBytes.Length) bytes (+$NumberOfEntriesActuallyAdded entries)"
    Write-Log "    [blob] FavoritesChanges : $CurrentFavoritesChangesCounter -> $($CurrentFavoritesChangesCounter + 1)"
    return $NumberOfEntriesActuallyAdded
}


#region PIN : ALLUSERS

# Returns a list of user profiles suitable for AllUsers mode.
# Each profile has a SID and a ProfilePath property.
# Excludes : the current user (already handled), system accounts, service accounts.
# Includes : the Default profile (so new users get the pins on first logon).
function Get-UserProfiles {
    $ProfileListRegistryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList')
    if (-not $ProfileListRegistryKey) { return @() }
    $DiscoveredProfiles = @()
    foreach ($ProfileSid in $ProfileListRegistryKey.GetSubKeyNames()) {
        # Short SIDs are built-in accounts (S-1-5-18 = SYSTEM, etc.)
        if ($ProfileSid.Length -lt 20) { continue }
        # Skip the effective primary user -- already handled in the main flow
        if ($ProfileSid -eq $EffectivePrimaryUserSID) { continue }
        $ProfileSubKey = $ProfileListRegistryKey.OpenSubKey($ProfileSid)
        if (-not $ProfileSubKey) { continue }
        $ProfileImagePath = $ProfileSubKey.GetValue('ProfileImagePath', '')
        $ProfileSubKey.Close()
        if (-not $ProfileImagePath -or -not [IO.Directory]::Exists($ProfileImagePath)) { continue }
        # Exclude well-known system profile directories
        $ProfileFolderName = [IO.Path]::GetFileName($ProfileImagePath).ToLower()
        if ($ProfileFolderName -eq 'systemprofile' -or $ProfileFolderName -eq 'localservice' -or $ProfileFolderName -eq 'networkservice') { continue }
        $DiscoveredProfiles += New-Object PSObject -Property @{ SID = $ProfileSid; ProfilePath = $ProfileImagePath }
    }
    $ProfileListRegistryKey.Close()
    # Include the Default user template profile (applies to newly created users)
    $DefaultUserNtUserDatPath = [IO.Path]::Combine($env:SystemDrive, 'Users\Default\NTUSER.DAT')
    if ([IO.File]::Exists($DefaultUserNtUserDatPath)) {
        $DiscoveredProfiles += New-Object PSObject -Property @{ SID = 'Default'; ProfilePath = [IO.Path]::Combine($env:SystemDrive, 'Users\Default') }
    }
    return $DiscoveredProfiles
}

# Loads an offline user's NTUSER.DAT registry hive, opens the Taskband key,
# executes a scriptblock with that key, then unloads the hive.
# If the user is currently logged in, their hive is already under HKU\{SID}
# and we can open it directly without loading/unloading.
# Returns $true if the action was executed, $false on failure.
function Invoke-WithOfflineHive {
    param([string]$ProfileSID, [string]$ProfileDirectoryPath, [scriptblock]$ActionToPerform)
    $NtUserDatFilePath = [IO.Path]::Combine($ProfileDirectoryPath, 'NTUSER.DAT')
    if (-not [IO.File]::Exists($NtUserDatFilePath)) {
        Write-Log "    [hive] NTUSER.DAT not found at '$NtUserDatFilePath'" 'Yellow'
        return $false
    }
    $LoadedHiveRegistryPath = $null
    $HiveRequiresUnload     = $false
    # Check if the hive is already loaded (user is logged in concurrently)
    if ($ProfileSID -ne 'Default') {
        try {
            $AlreadyLoadedTestKey = [Microsoft.Win32.Registry]::Users.OpenSubKey("$ProfileSID\$TaskBandRegistrySubKey", $false)
            if ($AlreadyLoadedTestKey) {
                $LoadedHiveRegistryPath = $ProfileSID
                $AlreadyLoadedTestKey.Close()
                Write-Log "    [hive] Hive for SID $ProfileSID is already loaded (user is logged in)"
            }
        } catch { }
    }
    # If not already loaded, load it temporarily via reg.exe
    if (-not $LoadedHiveRegistryPath) {
        $TemporaryHiveName = "TempPin_$($ProfileSID.Replace('-','').Substring(0, [Math]::Min(12, $ProfileSID.Replace('-','').Length)))"
        Write-Log "    [hive] Loading NTUSER.DAT from '$NtUserDatFilePath' as HKU\$TemporaryHiveName..."
        $RegLoadProcessInfo                        = New-Object System.Diagnostics.ProcessStartInfo
        $RegLoadProcessInfo.FileName               = 'reg.exe'
        $RegLoadProcessInfo.Arguments              = "load `"HKU\$TemporaryHiveName`" `"$NtUserDatFilePath`""
        $RegLoadProcessInfo.UseShellExecute        = $false
        $RegLoadProcessInfo.CreateNoWindow         = $true
        $RegLoadProcessInfo.RedirectStandardError  = $true
        $RegLoadProcess = [System.Diagnostics.Process]::Start($RegLoadProcessInfo)
        $RegLoadProcess.WaitForExit(10000)
        if ($RegLoadProcess.ExitCode -ne 0) {
            Write-Log "    [hive] reg.exe load FAILED (exit $($RegLoadProcess.ExitCode)) -- profile may be locked by another process" 'Yellow'
            return $false
        }
        $LoadedHiveRegistryPath = $TemporaryHiveName
        $HiveRequiresUnload     = $true
        Write-Log "    [hive] Hive loaded successfully as HKU\$TemporaryHiveName"
    }
    try {
        # Open the Taskband key with write access, create it if missing
        $TaskBandKeyHandle = [Microsoft.Win32.Registry]::Users.OpenSubKey("$LoadedHiveRegistryPath\$TaskBandRegistrySubKey", $true)
        if (-not $TaskBandKeyHandle) {
            $TaskBandKeyHandle = [Microsoft.Win32.Registry]::Users.CreateSubKey("$LoadedHiveRegistryPath\$TaskBandRegistrySubKey")
            Write-Log "    [hive] Created missing Taskband registry key"
        }
        if ($TaskBandKeyHandle) {
            try { & $ActionToPerform $TaskBandKeyHandle }
            finally { $TaskBandKeyHandle.Close(); $TaskBandKeyHandle = $null }
        }
    } finally {
        # Unload the temporarily loaded hive
        if ($HiveRequiresUnload) {
            # Force GC to release all .NET RegistryKey handles referencing this hive,
            # otherwise reg.exe unload will fail with "access denied"
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds 200
            $RegUnloadProcessInfo                       = New-Object System.Diagnostics.ProcessStartInfo
            $RegUnloadProcessInfo.FileName              = 'reg.exe'
            $RegUnloadProcessInfo.Arguments             = "unload `"HKU\$TemporaryHiveName`""
            $RegUnloadProcessInfo.UseShellExecute       = $false
            $RegUnloadProcessInfo.CreateNoWindow        = $true
            $RegUnloadProcessInfo.RedirectStandardError = $true
            $RegUnloadProcess = [System.Diagnostics.Process]::Start($RegUnloadProcessInfo)
            $RegUnloadProcess.WaitForExit(10000)
            if ($RegUnloadProcess.ExitCode -ne 0) { Write-Log "    [hive] WARNING : reg.exe unload FAILED for HKU\$TemporaryHiveName -- handle may be leaked" 'Yellow' }
            else                                  { Write-Log "    [hive] Unloaded HKU\$TemporaryHiveName" }
        }
    }
    return $true
}


#region UNPIN FLOW

if ($Unpin) {

    # -- Build match patterns from input items --
    # For shell:AppsFolder inputs, match by AUMID suffix.
    # For filesystem paths, match by filename without extension.
    # For wildcards, pass through as-is for -like matching.
    $UnpinMatchPatterns = @()
    foreach ($InputItem in $ParsedInputItems) {
        if ($InputItem.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase)) {
            $UnpinMatchPatterns += $InputItem.Substring(17)
        } else {
            $InputHasDirectoryPart = $InputItem.Contains('\') -or $InputItem.Contains('/')
            $InputHasWildcard      = $InputItem.Contains('*') -or $InputItem.Contains('?')
            if ($InputHasDirectoryPart -and -not $InputHasWildcard) {
                $InputExtension = [IO.Path]::GetExtension($InputItem).ToLower()
                if ($InputExtension -eq '.cpl' -and [IO.File]::Exists($InputItem)) {
                    # .cpl files are pinned under their Control Panel display name, not their filename.
                    # Resolve the display name so the unpin pattern matches the actual .lnk filename.
                    Initialize-NativeHelper
                    $CplMatch = Resolve-CplControlPanelItem $InputItem
                    if ($CplMatch) { $UnpinMatchPatterns += ($CplMatch.Name -replace '[<>:"/\\|?*]', '_') }
                    else           { $UnpinMatchPatterns += [IO.Path]::GetFileNameWithoutExtension($InputItem) }
                } else {
                    $UnpinMatchPatterns += [IO.Path]::GetFileNameWithoutExtension($InputItem)
                }
            }
            else {
                # Bare input without directory separator (e.g. "joy.cpl", "services.msc", "notepad", "Notepad*")
                $InputExtension = [IO.Path]::GetExtension($InputItem).ToLower()
                if ($InputExtension -eq '.cpl') {
                    # .cpl files are pinned under their Control Panel display name, not their filename.
                    # Resolve the full path via PATH/PATHEXT, then look up the namespace display name
                    # so the unpin pattern matches the actual .lnk filename in the TaskBar directory.
                    $ResolvedCplPaths = @(Resolve-FilesystemInput $InputItem)
                    $CplPatternResolved = $false
                    foreach ($ResolvedCplPath in $ResolvedCplPaths) {
                        if ($ResolvedCplPath -and [IO.File]::Exists($ResolvedCplPath)) {
                            Initialize-NativeHelper
                            $CplMatch = Resolve-CplControlPanelItem $ResolvedCplPath
                            if ($CplMatch) {
                                $CplDisplayPattern = $CplMatch.Name -replace '[<>:"/\\|?*]', '_'
                                $UnpinMatchPatterns += $CplDisplayPattern
                                $CplPatternResolved = $true
                                Write-Log "  [pattern] CPL '$InputItem' resolved to display name pattern '$CplDisplayPattern' via '$ResolvedCplPath'"
                            }
                        }
                    }
                    if (-not $CplPatternResolved) {
                        # Namespace resolution failed -- fall back to filename without extension
                        $FallbackPattern = [IO.Path]::GetFileNameWithoutExtension($InputItem)
                        $UnpinMatchPatterns += $FallbackPattern
                        Write-Log "  [pattern] CPL '$InputItem' could not be resolved via namespace -- falling back to '$FallbackPattern'" 'Yellow'
                    }
                }
                elseif ($InputExtension -in '.msc', '.exe') {
                    # .msc and .exe items are pinned under their filename without extension
                    # (e.g. "services.msc" becomes "services.lnk" in the TaskBar directory)
                    $StrippedPattern = [IO.Path]::GetFileNameWithoutExtension($InputItem)
                    $UnpinMatchPatterns += $StrippedPattern
                    Write-Log "  [pattern] Stripped extension from '$InputItem' -> pattern '$StrippedPattern'"
                }
                else {
                    # Bare name or wildcard without known extension -- use as-is for -like matching
                    $UnpinMatchPatterns += $InputItem
                    Write-Log "  [pattern] Using raw input as pattern : '$InputItem'"
                }
            }
        }
    }
    $DisplayPatternLabel = ($UnpinMatchPatterns | ForEach-Object { $_ }) -join ', '

    Write-Banner 'UNPIN' 'DarkRed' "$DisplayPatternLabel$(if ($AllUsers) { ' (AllUsers)' })"
    Write-Log "--- UNPIN operation starting ---"
    Write-Log "Match patterns           : $DisplayPatternLabel"
    Write-Log "AllUsers mode            : $AllUsers"
    Write-Log "Windows build            : $WindowsBuildNumber"
    Write-Log "TaskBar directory         : $TaskBarPinnedDirectory (exists : $TaskBarDirectoryExists)"
    Write-Log "QuickLaunch directory     : $QuickLaunchDirectory (exists : $QuickLaunchDirectoryExists)"
    Write-Log "TaskBand registry key     : $TaskBandRegistrySubKey (exists : $TaskBandRegistryKeyExists)"
    if ($IsRunningCrossUser) {
        Write-Log "Cross-user elevation     : True (interactive SID : $InteractiveSessionUserSID)"
        Write-Log "Interactive profile      : $InteractiveUserProfilePath"
    }
    Initialize-NativeHelper

    # -------------------------------------------------------------------
    # Scan a directory of pinned shortcuts and return those that match
    # the unpin patterns. Matching is done by shortcut filename, target
    # path, or AUMID (in that order of increasing cost).
    # -------------------------------------------------------------------
    function Find-MatchingPins {
        param([string]$PinnedShortcutDirectory, [string[]]$PatternsToMatch)
        $MatchedShortcutPaths = @()
        $WshShellInstance     = $null
        try { $ShortcutFilesInDirectory = @([IO.Directory]::GetFiles($PinnedShortcutDirectory, '*.lnk')) } catch { return @() }
        Write-Log "  [scan] Directory '$PinnedShortcutDirectory' : $($ShortcutFilesInDirectory.Count) .lnk file(s)"
        foreach ($ShortcutFilePath in $ShortcutFilesInDirectory) {
            $ShortcutFileName = [IO.Path]::GetFileName($ShortcutFilePath)
            $PatternMatched   = $false
            # Pass 1 : match by shortcut filename (fast, no COM)
            foreach ($Pattern in $PatternsToMatch) {
                $PatternIsFullPath = $Pattern.Contains('\') -or $Pattern.Contains('/')
                if (-not $PatternIsFullPath) {
                    if ([IO.Path]::GetFileNameWithoutExtension($ShortcutFileName) -like $Pattern) {
                        Write-Log "    [match] '$ShortcutFileName' matched by filename against pattern '$Pattern'"
                        $PatternMatched = $true; break
                    }
                }
            }
            # Pass 2 : match by shortcut target path (requires COM to read .lnk)
            if (-not $PatternMatched) {
                if (-not $WshShellInstance) { $WshShellInstance = New-Object -ComObject WScript.Shell }
                $ShortcutComObject  = $WshShellInstance.CreateShortcut($ShortcutFilePath)
                $ShortcutTargetPath = $ShortcutComObject.TargetPath
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ShortcutComObject)
                foreach ($Pattern in $PatternsToMatch) {
                    $PatternIsFullPath = $Pattern.Contains('\') -or $Pattern.Contains('/')
                    if (-not $PatternIsFullPath) {
                        if ($ShortcutTargetPath -and ([IO.Path]::GetFileNameWithoutExtension($ShortcutTargetPath) -like $Pattern -or [IO.Path]::GetFileName($ShortcutTargetPath) -like $Pattern)) {
                            Write-Log "    [match] '$ShortcutFileName' matched by target path '$ShortcutTargetPath' against pattern '$Pattern'"
                            $PatternMatched = $true; break
                        }
                    } else {
                        if ($ShortcutTargetPath -like $Pattern) {
                            Write-Log "    [match] '$ShortcutFileName' matched by full target path against pattern '$Pattern'"
                            $PatternMatched = $true; break
                        }
                    }
                }
                # Pass 3 : match by AUMID (for UWP shortcuts that have no filesystem target)
                if (-not $PatternMatched) {
                    $ShortcutAumid = [TaskbarPin]::GetAumid($ShortcutFilePath)
                    if ($ShortcutAumid) {
                        foreach ($Pattern in $PatternsToMatch) {
                            if ($ShortcutAumid -like $Pattern) {
                                Write-Log "    [match] '$ShortcutFileName' matched by AUMID '$ShortcutAumid' against pattern '$Pattern'"
                                $PatternMatched = $true; break
                            }
                        }
                    }
                }
            }
            if ($PatternMatched) { $MatchedShortcutPaths += $ShortcutFilePath }
        }
        if ($WshShellInstance) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($WshShellInstance) }
        Write-Log "  [scan] $($MatchedShortcutPaths.Count) shortcut(s) matched in this directory"
        return $MatchedShortcutPaths
    }

    # -------------------------------------------------------------------
    # Remove matching entries from the Favorites and FavoritesResolve blobs.
    # Entries are identified by searching for the Unicode .lnk filename inside
    # each blob entry's PIDL data. Removal indices are processed in descending
    # order so that earlier indices remain valid as we remove later ones.
    # -------------------------------------------------------------------
    function Invoke-UnpinFromBlob {
        param($RegistryKeyHandle, [string[]]$ShortcutFilenamesToRemove)
        $FavoritesBlob        = $RegistryKeyHandle.GetValue('Favorites', $null, $DoNotExpandRegistryOption)
        $FavoritesResolveBlob = $RegistryKeyHandle.GetValue('FavoritesResolve', $null, $DoNotExpandRegistryOption)
        if (-not $FavoritesBlob -or $FavoritesBlob.Length -lt 6) {
            Write-Log "    [blob] Favorites blob is empty or absent ($( if ($FavoritesBlob) { "$($FavoritesBlob.Length) bytes" } else { 'null' } )) -- nothing to unpin"
            return 0
        }
        Write-Log "    [blob] Existing Favorites blob : $($FavoritesBlob.Length) bytes"
        # Locate each filename in the blob and collect their indices
        $EntriesToRemove = @()
        foreach ($ShortcutFilename in $ShortcutFilenamesToRemove) {
            $FoundBlobIndex = [TaskbarPin]::FindBlobEntry($FavoritesBlob, $ShortcutFilename)
            if ($FoundBlobIndex -ge 0) {
                $EntriesToRemove += New-Object PSObject -Property @{ Name = $ShortcutFilename; Index = $FoundBlobIndex }
                Write-Log "    [blob] Found '$ShortcutFilename' at blob index $FoundBlobIndex"
            } else {
                Write-Log "    [blob] '$ShortcutFilename' not found in blob -- already absent or never pinned"
            }
        }
        # Sort by descending index so removals don't shift earlier indices
        $EntriesToRemove = @($EntriesToRemove | Sort-Object -Property Index -Descending)
        foreach ($EntryToRemove in $EntriesToRemove) {
            $FavoritesBlob = [TaskbarPin]::RemoveFavEntry($FavoritesBlob, $EntryToRemove.Index)
            if ($FavoritesResolveBlob) { $FavoritesResolveBlob = [TaskbarPin]::RemoveResEntry($FavoritesResolveBlob, $EntryToRemove.Index) }
            Write-Log "    [blob] Removed '$($EntryToRemove.Name)' (was at index $($EntryToRemove.Index))"
        }
        if ($EntriesToRemove.Count -gt 0) {
            $CurrentFavoritesChanges = [int]$RegistryKeyHandle.GetValue('FavoritesChanges', 0, $DoNotExpandRegistryOption)
            $RegistryKeyHandle.SetValue('Favorites',        ([byte[]]$FavoritesBlob),          $BinaryRegistryValueKind)
            if ($FavoritesResolveBlob) { $RegistryKeyHandle.SetValue('FavoritesResolve', ([byte[]]$FavoritesResolveBlob), $BinaryRegistryValueKind) }
            $RegistryKeyHandle.SetValue('FavoritesVersion',  3,                                $DwordRegistryValueKind)
            $RegistryKeyHandle.SetValue('FavoritesChanges', ($CurrentFavoritesChanges + 1),    $DwordRegistryValueKind)
            Write-Log "    [blob] Blob cleaned : $($EntriesToRemove.Count) entries removed. FavoritesChanges : $CurrentFavoritesChanges -> $($CurrentFavoritesChanges + 1)"
        }
        return $EntriesToRemove.Count
    }

    # -- Main unpin flow for the current user --
    $PinnedDirectoriesToScan = @()
    if ($TaskBarDirectoryExists)     { $PinnedDirectoriesToScan += $TaskBarPinnedDirectory }
    if ($QuickLaunchDirectoryExists) { $PinnedDirectoriesToScan += $QuickLaunchDirectory }
    if ($PinnedDirectoriesToScan.Count -eq 0 -and -not $AllUsers) {
        Write-Console "  [!] No pin locations found on this system" -Color Yellow
        Write-Log "No TaskBar or QuickLaunch directory found -- nothing to unpin" 'Yellow'
        Close-Log; exit 2
    }
    # Find all matching shortcuts across pin directories
    $MatchedShortcutPaths = @()
    foreach ($DirectoryToScan in $PinnedDirectoriesToScan) {
        $MatchedShortcutPaths += @(Find-MatchingPins $DirectoryToScan $UnpinMatchPatterns)
    }
    Write-Log "Total matched shortcuts (current user) : $($MatchedShortcutPaths.Count)"
    if ($MatchedShortcutPaths.Count -eq 0 -and -not $AllUsers) {
        Write-Console "  [!] No pinned items match" -Color Yellow
        Write-Log "No pinned items matched the given patterns" 'Yellow'
        Write-Console ""; Close-Log; exit 2
    }
    # Remove matching entries from the Taskband registry blob
    if ($MatchedShortcutPaths.Count -gt 0 -and $TaskBandRegistryKeyExists) {
        Write-Log "[mutex] Acquiring TaskbarPinListMutex before modifying the Favorites blob..."
        $MutexWasAcquired = [TaskbarPin]::AcquirePinMutex(5000)
        Write-Log "[mutex] TaskbarPinListMutex acquired : $MutexWasAcquired"
        try {
            $TaskBandRegistryKey = Open-EffectiveTaskbandKey $true
            if ($TaskBandRegistryKey) {
                try {
                    $ShortcutFilenamesToRemove  = @($MatchedShortcutPaths | ForEach-Object { [IO.Path]::GetFileName($_) })
                    $NumberOfBlobEntriesRemoved = Invoke-UnpinFromBlob $TaskBandRegistryKey $ShortcutFilenamesToRemove
                    Write-Log "[unpin] Blob cleanup for current user : $NumberOfBlobEntriesRemoved entries removed"
                } finally { $TaskBandRegistryKey.Close() }
            }
        } finally {
            if ($MutexWasAcquired) { [TaskbarPin]::ReleasePinMutex(); Write-Log "[mutex] TaskbarPinListMutex released" }
        }
    }
    # Delete the .lnk files from disk
    $UnpinFailedDeleteCount = 0
    Write-Log "[unpin] Deleting $($MatchedShortcutPaths.Count) .lnk file(s) from disk..."
    foreach ($ShortcutPath in $MatchedShortcutPaths) {
        if ([IO.File]::Exists($ShortcutPath)) {
            try   { [IO.File]::Delete($ShortcutPath); Write-Log "  [file] Deleted '$ShortcutPath'" }
            catch { Write-Log "  [file] FAILED to delete '$ShortcutPath' : $_" 'Yellow'; $UnpinFailedDeleteCount++ }
        }
    }
    # Notify the taskbar to refresh its UI
    if ($MatchedShortcutPaths.Count -gt 0) {
        [TaskbarPin]::SendPinNotify()
        Write-Log "[notify] SHChangeNotify(SHCNE_EXTENDED_EVENT, type=0x0D) sent -- taskbar will re-read blob"
    }
    # -- AllUsers unpin --
    if ($AllUsers) {
        $AllUserProfiles = @(Get-UserProfiles)
        Write-Log "[allUsers] Found $($AllUserProfiles.Count) additional profile(s) to process"
        foreach ($UserProfile in $AllUserProfiles) {
            Write-Log "  [profile] $($UserProfile.ProfilePath) (SID : $($UserProfile.SID))"
            $ProfileTaskBarDirectory = [IO.Path]::Combine($UserProfile.ProfilePath, $TaskBarRelativeProfilePath)
            $ProfileMatchedShortcuts = @()
            if ([IO.Directory]::Exists($ProfileTaskBarDirectory)) {
                $ProfileMatchedShortcuts = @(Find-MatchingPins $ProfileTaskBarDirectory $UnpinMatchPatterns)
            }
            if ($ProfileMatchedShortcuts.Count -eq 0) { Write-Log "    No matching pins in this profile -- skipping"; continue }
            $ProfileShortcutFilenames = @($ProfileMatchedShortcuts | ForEach-Object { [IO.Path]::GetFileName($_) })
            $null = Invoke-WithOfflineHive $UserProfile.SID $UserProfile.ProfilePath {
                param($OfflineRegistryKey)
                $OfflineRemovedCount = Invoke-UnpinFromBlob $OfflineRegistryKey $ProfileShortcutFilenames
                Write-Log "    [blob] Removed $OfflineRemovedCount entries from offline blob"
            }
            foreach ($ProfileShortcutPath in $ProfileMatchedShortcuts) {
                if ([IO.File]::Exists($ProfileShortcutPath)) { try { [IO.File]::Delete($ProfileShortcutPath) } catch { } }
            }
            Write-Log "    [file] Deleted $($ProfileMatchedShortcuts.Count) .lnk file(s)"
        }
    }
    # -- Summary --
    $TotalItemsUnpinned = $MatchedShortcutPaths.Count
    foreach ($UnpinnedPath in $MatchedShortcutPaths) {
        Write-Console "  [-] $([IO.Path]::GetFileName($UnpinnedPath))" -Color Cyan
    }
    if ($UnpinFailedDeleteCount -gt 0) {
        Write-Banner 'FAIL' 'DarkRed' "$UnpinFailedDeleteCount item(s) could not be deleted"
        Write-Log "--- UNPIN FAILED : $UnpinFailedDeleteCount deletion(s) failed ---"
        Close-Log; exit 3
    }
    Write-Banner 'OK' 'DarkGreen' "Unpinned $TotalItemsUnpinned item(s)$(if ($AllUsers) { ' (AllUsers)' })"
    Write-Log "--- UNPIN complete : $TotalItemsUnpinned item(s) unpinned ---"
    Close-Log; exit 0
}


#region PIN : RESOLVE INPUT

Write-Banner 'PIN' 'DarkBlue' "$Pin$(if ($AllUsers) { ' (AllUsers)' })"
Write-Log "--- PIN operation starting ---"
Write-Log "Raw input                : $Pin"
Write-Log "Parsed items             : $($ParsedInputItems.Count)"
Write-Log "AllUsers mode            : $AllUsers"
Write-Log "Windows build            : $WindowsBuildNumber"
Write-Log "TaskBar directory         : $TaskBarPinnedDirectory (exists : $TaskBarDirectoryExists)"
Write-Log "QuickLaunch directory     : $QuickLaunchDirectory (exists : $QuickLaunchDirectoryExists)"
Write-Log "TaskBand registry key     : $TaskBandRegistrySubKey (exists : $TaskBandRegistryKeyExists)"
Write-Log "Blob injection available  : $DirectBlobWriteIsSupported"
if ($IsRunningCrossUser) {
    Write-Log "Cross-user elevation     : True (interactive SID : $InteractiveSessionUserSID)"
    Write-Log "Interactive profile      : $InteractiveUserProfilePath"
}

# Separate UWP (shell:AppsFolder) inputs from filesystem inputs
$UwpInputItems        = @($ParsedInputItems | Where-Object {     $_.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase) })
$FilesystemInputItems = @($ParsedInputItems | Where-Object { -not $_.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase) })
Write-Log "UWP inputs               : $($UwpInputItems.Count)"
Write-Log "Filesystem inputs        : $($FilesystemInputItems.Count)"

# Accumulate resolved pin targets from both input types
$ResolvedPinTargets     = @()
$ShellApplicationCom    = $null
$AppsFolderNamespaceCom = $null

# -- Resolve UWP inputs via Shell.Application COM --
if ($UwpInputItems.Count -gt 0) {
    Write-Log "[resolve] Resolving $($UwpInputItems.Count) UWP input(s) via Shell.Application COM..."
    $ShellApplicationCom    = New-Object -ComObject Shell.Application
    $AppsFolderNamespaceCom = $ShellApplicationCom.Namespace('shell:AppsFolder')
    $AlreadySeenAumids = @{}
    # Separate exact AUMIDs (containing !) from wildcard/display-name patterns.
    # Exact AUMIDs can be resolved instantly via ParseName (O(1)).
    # Wildcards require enumerating all installed apps (O(n)).
    $ExactAumidInputs  = @($UwpInputItems | Where-Object { $_ -notmatch '[*?]' -and $_.Contains('!') })
    $WildcardUwpInputs = @($UwpInputItems | Where-Object { $_    -match '[*?]' -or -not $_.Contains('!') })
    Write-Log "  Exact AUMID inputs     : $($ExactAumidInputs.Count)"
    Write-Log "  Wildcard UWP inputs    : $($WildcardUwpInputs.Count)"
    # Exact AUMIDs : O(1) lookup via ParseName
    foreach ($ExactUwpInput in $ExactAumidInputs) {
        $AumidSuffix = $ExactUwpInput.Substring(17)
        if (-not $AumidSuffix) { continue }
        Write-Log "  [uwp] Looking up AUMID : '$AumidSuffix'..."
        $DirectlyResolvedAppItem = $AppsFolderNamespaceCom.ParseName($AumidSuffix)
        if ($DirectlyResolvedAppItem) {
            if (-not $AlreadySeenAumids.ContainsKey($DirectlyResolvedAppItem.Path)) {
                $AlreadySeenAumids[$DirectlyResolvedAppItem.Path] = $true
                $ResolvedPinTargets += New-Object PSObject -Property @{ PinType = 'UWP'; Aumid = $DirectlyResolvedAppItem.Path; DisplayName = $DirectlyResolvedAppItem.Name }
                Write-Log "  [uwp] Resolved : '$($DirectlyResolvedAppItem.Name)' ($($DirectlyResolvedAppItem.Path))"
            } else {
                Write-Log "  [uwp] Skipping duplicate AUMID : $($DirectlyResolvedAppItem.Path)"
            }
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($DirectlyResolvedAppItem)
        } else {
            Write-Console "  [!] Not found : $ExactUwpInput" -Color Yellow
            Write-Log "  [uwp] AUMID not found in shell:AppsFolder namespace : '$AumidSuffix'" 'Yellow'
        }
    }
    # Wildcard patterns : enumerate all installed apps and match in a single pass
    if ($WildcardUwpInputs.Count -gt 0) {
        $WildcardSuffixes     = @($WildcardUwpInputs | ForEach-Object { $_.Substring(17) } | Where-Object { $_ })
        $AllInstalledAppItems = @($AppsFolderNamespaceCom.Items())
        Write-Log "  [uwp] Enumerating $($AllInstalledAppItems.Count) installed apps for $($WildcardSuffixes.Count) wildcard pattern(s)..."
        $MatchedWildcardSuffixes = @{}
        foreach ($AppItem in $AllInstalledAppItems) {
            foreach ($WildcardPattern in $WildcardSuffixes) {
                if (($AppItem.Name -like $WildcardPattern -or $AppItem.Path -like $WildcardPattern) -and -not $AlreadySeenAumids.ContainsKey($AppItem.Path)) {
                    $AlreadySeenAumids[$AppItem.Path] = $true
                    $ResolvedPinTargets += New-Object PSObject -Property @{ PinType = 'UWP'; Aumid = $AppItem.Path; DisplayName = $AppItem.Name }
                    $MatchedWildcardSuffixes[$WildcardPattern] = $true
                    Write-Log "  [uwp] Wildcard match : '$WildcardPattern' -> '$($AppItem.Name)' ($($AppItem.Path))"
                }
            }
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($AppItem)
        }
        foreach ($WildcardPattern in $WildcardSuffixes) {
            if (-not $MatchedWildcardSuffixes.ContainsKey($WildcardPattern)) {
                Write-Console "  [!] Not found : shell:AppsFolder\$WildcardPattern" -Color Yellow
                Write-Log "  [uwp] No installed app matched wildcard : '$WildcardPattern'" 'Yellow'
            }
        }
    }
}

# -- Resolve filesystem inputs --
if ($FilesystemInputItems.Count -gt 0) {
    Write-Log "[resolve] Resolving $($FilesystemInputItems.Count) filesystem input(s)..."
    $AlreadySeenFilesystemPaths = @{}
    foreach ($FilesystemInput in $FilesystemInputItems) {
        Write-Log "  [fs] Resolving : '$FilesystemInput'..."
        $ResolvedFilePaths = @(Resolve-FilesystemInput $FilesystemInput)
        foreach ($ResolvedPath in $ResolvedFilePaths) {
            if ($ResolvedPath -and -not $AlreadySeenFilesystemPaths.ContainsKey($ResolvedPath)) {
                $AlreadySeenFilesystemPaths[$ResolvedPath] = $true
                $ResolvedPinTargets += New-Object PSObject -Property @{ PinType = 'FS'; ResolvedPath = $ResolvedPath }
                Write-Log "  [fs] Resolved : '$ResolvedPath'"
            }
        }
        if ($ResolvedFilePaths.Count -eq 0) {
            Write-Console "  [!] Not found : $FilesystemInput" -Color Yellow
            Write-Log "  [fs] No file found for '$FilesystemInput'" 'Yellow'
        }
    }
}

Write-Log "[resolve] Total resolved pin targets : $($ResolvedPinTargets.Count)"

if ($ResolvedPinTargets.Count -eq 0) {
    Write-Console "  [X] No items found to pin" -Color Red
    Write-Log "No items could be resolved to valid paths -- aborting" 'Red'
    Write-Console ""
    if ($AppsFolderNamespaceCom) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($AppsFolderNamespaceCom) }
    if ($ShellApplicationCom)   { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ShellApplicationCom) }
    Close-Log; exit 2
}


#region PIN : BLOB INJECTION

# The modern pin strategy works by :
#   1. Placing a .lnk shortcut in the TaskBar pinned directory
#   2. Building a binary blob entry (PIDL + BEEF001D extension block)
#   3. Appending that entry to the Favorites blob in the registry
#   4. Sending SHChangeNotify so the taskbar handler re-reads the blob
# The BEEF001D extension block is the critical piece -- it contains a parsing name
# string (e.g. "C:\Windows\notepad.exe") that the handler uses to resolve the item
# when its ILIsEqual primary match fails (which it always does for externally-written PIDLs
# because the SHITEMID timestamps differ from the handler's cached copy).
# This strategy requires both the TaskBar directory and the Taskband registry key.
# If either is missing (e.g. on Vista), we fall back to the Quick Launch strategy.

$SuccessfullyPinnedCount       = 0
$BlobEntriesReadyForInjection  = @()  # Entries with valid PIDL + BEEF001D, ready to write
$ItemsDeferredToQuickLaunch    = @()  # Entries that failed blob preparation, will try Quick Launch

if ($DirectBlobWriteIsSupported) {
    Write-Console "  [>] Preparing blob entries ($($ResolvedPinTargets.Count) item(s))..." -Color DarkGray -NoNewline
    Write-Log "[blob-prep] Direct blob injection is supported -- preparing $($ResolvedPinTargets.Count) item(s)..."
    Initialize-NativeHelper
    $WshShellForPinCreation = $null

    foreach ($PinTarget in $ResolvedPinTargets) {
        $DestinationLnkPath   = $null  # Path where the .lnk will live in the TaskBar directory
        $Beef001dParsingName  = $null  # The parsing name that goes into the BEEF001D block
        $SourceShortcutPath   = $null  # Path to the .lnk we created (may be in %TEMP%)
        $ShortcutIsTemporary  = $false # True if we created a temp .lnk that needs cleanup
        $PinTargetDisplayName = $null  # Readable name for logging

        if ($PinTarget.PinType -eq 'UWP') {
            # -- UWP apps : create a special shortcut with the AUMID as BEEF001D content --
            $TargetAumid          = $PinTarget.Aumid
            $PinTargetDisplayName = $PinTarget.DisplayName
            $SafeShortcutName     = $PinTargetDisplayName -replace '[<>:"/\\|?*]', '_'
            $DestinationLnkPath   = [IO.Path]::Combine($TaskBarPinnedDirectory, "$SafeShortcutName.lnk")
            $Beef001dParsingName  = $TargetAumid
            if ([IO.File]::Exists($DestinationLnkPath)) {
                $SerializedBlobEntry = [TaskbarPin]::GetBlobEntryEx($DestinationLnkPath, $Beef001dParsingName)
                if ($SerializedBlobEntry) {
                    $BlobEntriesReadyForInjection += New-Object PSObject -Property @{
                        DestinationLnkPath  = $DestinationLnkPath;  SerializedBlobEntry = $SerializedBlobEntry; DisplayName    = $PinTargetDisplayName
                        ShortcutIsTemporary = $false;                SourceShortcutPath  = $null;                PinType        = 'UWP'
                        Aumid               = $TargetAumid;          Beef001dContent     = $Beef001dParsingName
                    }
                    continue
                }
            }
            Write-Log "  [uwp] Creating shortcut '$SafeShortcutName.lnk' for AUMID '$TargetAumid'..."
            # CreateAppShortcut sets up IShellLink with the AppsFolder PIDL and PKEY_AppUserModel_ID
            if (-not [TaskbarPin]::CreateAppShortcut($TargetAumid, $DestinationLnkPath)) {
                Write-Log "  [uwp] CreateAppShortcut FAILED for '$TargetAumid' -- deferring to Quick Launch fallback" 'Yellow'
                if ($DestinationLnkPath -and [IO.File]::Exists($DestinationLnkPath)) { try { [IO.File]::Delete($DestinationLnkPath) } catch { } }
                $ItemsDeferredToQuickLaunch += $PinTarget
                continue
            }
            Write-Log "  [uwp] Shortcut created successfully"
        } else {
            # -- Filesystem targets : create a .lnk and extract the BEEF001D content --
            $Beef001dContentReference = [ref]''
            $SourceShortcutPath       = New-TargetShortcut $PinTarget.ResolvedPath $Beef001dContentReference ([ref]$WshShellForPinCreation)
            $Beef001dParsingName      = $Beef001dContentReference.Value
            $ShortcutIsTemporary      = ($SourceShortcutPath -ne $PinTarget.ResolvedPath)
            $ShortcutFileName         = [IO.Path]::GetFileName($SourceShortcutPath)
            $DestinationLnkPath       = [IO.Path]::Combine($TaskBarPinnedDirectory, $ShortcutFileName)
            $PinTargetDisplayName     = $ShortcutFileName
            Write-Log "  [fs] Target : '$($PinTarget.ResolvedPath)'"
            Write-Log "  [fs] Shortcut : '$ShortcutFileName' | BEEF001D content : '$Beef001dParsingName'"
            # Copy the shortcut to the TaskBar directory (skip if already present to avoid
            # icon cache corruption from SHCNE_UPDATEITEM during the delete/recreate window)
            if (-not [IO.File]::Exists($DestinationLnkPath)) {
                [IO.File]::Copy($SourceShortcutPath, $DestinationLnkPath)
                Write-Log "  [fs] Copied .lnk to TaskBar directory"
            } else {
                Write-Log "  [fs] .lnk already exists in TaskBar directory -- reusing existing file"
            }
        }

        # -- Build the binary blob entry --
        # GetBlobEntryEx calls SHParseDisplayName on the .lnk path (which MUST be under %APPDATA%
        # to produce namespace PIDLs rooted at {59031A47}), then injects the BEEF001D block
        # into the last SHITEMID.
        $SerializedBlobEntry = $null
        if ($Beef001dParsingName) {
            if ($IsRunningCrossUser) {
                Write-Log "  [blob] Calling GetBlobEntryFs('$DestinationLnkPath', '$Beef001dParsingName') [cross-user mode]..."
                $SerializedBlobEntry = [TaskbarPin]::GetBlobEntryFs($DestinationLnkPath, $Beef001dParsingName)
            } else {
                Write-Log "  [blob] Calling GetBlobEntryEx('$DestinationLnkPath', '$Beef001dParsingName')..."
                $SerializedBlobEntry = [TaskbarPin]::GetBlobEntryEx($DestinationLnkPath, $Beef001dParsingName)
            }
        }

        if ($SerializedBlobEntry) {
            $BlobEntriesReadyForInjection += New-Object PSObject -Property @{
                DestinationLnkPath  = $DestinationLnkPath
                SerializedBlobEntry = $SerializedBlobEntry
                DisplayName         = $PinTargetDisplayName
                ShortcutIsTemporary = $ShortcutIsTemporary
                SourceShortcutPath  = $SourceShortcutPath
                PinType             = $PinTarget.PinType
                Aumid               = $(if ($PinTarget.PinType -eq 'UWP') { $PinTarget.Aumid } else { $null })
                Beef001dContent     = $Beef001dParsingName
            }
            Write-Log "  [blob] Entry ready : $($SerializedBlobEntry.Length) bytes"
        } else {
            # SHParseDisplayName failed -- the .lnk path could not be resolved to a namespace PIDL.
            # This can happen if the file was just created and the shell hasn't indexed it yet,
            # or if the path is too long / contains unusual characters.
            Write-Log "  [blob] GetBlobEntryEx returned null -- SHParseDisplayName failed for the .lnk path. Deferring to Quick Launch." 'Yellow'
            if ($DestinationLnkPath -and [IO.File]::Exists($DestinationLnkPath)) { try { [IO.File]::Delete($DestinationLnkPath) } catch { } }
            $ItemsDeferredToQuickLaunch += $PinTarget
        }
    }
    if ($WshShellForPinCreation) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($WshShellForPinCreation); $WshShellForPinCreation = $null }

    # -- Write all prepared blob entries to the registry in a single atomic operation --
    if ($BlobEntriesReadyForInjection.Count -gt 0) {
        Write-Log "[blob-write] Writing $($BlobEntriesReadyForInjection.Count) blob entries to Taskband registry..."
        # Acquire the TaskbarPinListMutex to serialize with any concurrent blob writes
        # from explorer.exe (e.g. if the user is pinning something via the GUI right now).
        Write-Log "[mutex] Acquiring TaskbarPinListMutex (5s timeout)..."
        $MutexWasAcquired = [TaskbarPin]::AcquirePinMutex(5000)
        Write-Log "[mutex] Acquired : $MutexWasAcquired"
        $BlobEntriesAddedCount = 0
        try {
            $TaskBandRegistryKey = Open-EffectiveTaskbandKey $true
            try {
                $ExistingFavoritesBlob = $TaskBandRegistryKey.GetValue('Favorites', $null, $DoNotExpandRegistryOption)
                Write-Log "  [blob] Current Favorites blob : $(if ($ExistingFavoritesBlob) { "$($ExistingFavoritesBlob.Length) bytes" } else { 'null (first pin on this profile)' })"
                $BlobEntriesAddedCount = Write-BlobToRegistryKey $TaskBandRegistryKey $ExistingFavoritesBlob $BlobEntriesReadyForInjection
            } finally { $TaskBandRegistryKey.Close() }
        } finally {
            if ($MutexWasAcquired) { [TaskbarPin]::ReleasePinMutex(); Write-Log "[mutex] TaskbarPinListMutex released" }
        }
        # Notify the taskbar to re-read the blob and update the UI
        if ($BlobEntriesAddedCount -gt 0) {
            [TaskbarPin]::SendPinNotify()
            Write-Log "[notify] SHChangeNotify(SHCNE_EXTENDED_EVENT, type=0x0D) sent -- taskbar will pick up new pins"
        }
        Write-Console " done" -Color Green
        # Report each pinned item and clean up temporary shortcuts
        foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
            Write-Console "  [+] $($ReadyEntry.DisplayName)" -Color Cyan
            $SuccessfullyPinnedCount++
            if ($ReadyEntry.ShortcutIsTemporary -and $ReadyEntry.SourceShortcutPath) {
                try { [IO.File]::Delete($ReadyEntry.SourceShortcutPath) } catch { }
            }
        }
        Write-Console ""
        Write-Log "[blob-write] $BlobEntriesAddedCount new entries written to blob, $SuccessfullyPinnedCount items pinned"
    } else {
        Write-Console " nothing to inject" -Color Yellow
        Write-Log "[blob-write] No blob entries to write (all items were duplicates or failed preparation)"
        Write-Console ""
    }

    # -- AllUsers : replicate shortcuts and blob entries to other profiles --
    if ($AllUsers -and $BlobEntriesReadyForInjection.Count -gt 0) {
        $AllUserProfiles = @(Get-UserProfiles)
        Write-Log "[allUsers] Found $($AllUserProfiles.Count) additional profile(s)"
        $AllUsersProfilesUpdatedCount = 0
        foreach ($UserProfile in $AllUserProfiles) {
            $ProfileTaskBarDirectory = [IO.Path]::Combine($UserProfile.ProfilePath, $TaskBarRelativeProfilePath)
            Write-Log "  [profile] Processing : $($UserProfile.ProfilePath) (SID : $($UserProfile.SID))"
            # Create the TaskBar directory if it doesn't exist yet
            if (-not [IO.Directory]::Exists($ProfileTaskBarDirectory)) {
                try   { $null = [IO.Directory]::CreateDirectory($ProfileTaskBarDirectory); Write-Log "    [file] Created TaskBar directory" }
                catch { Write-Log "    [file] FAILED to create TaskBar directory : $_" 'Yellow'; continue }
            }
            # Copy shortcut files into the profile's TaskBar directory
            foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
                $SourceLnkPath      = $ReadyEntry.DestinationLnkPath
                $DestinationLnkPath = [IO.Path]::Combine($ProfileTaskBarDirectory, [IO.Path]::GetFileName($SourceLnkPath))
                if (-not [IO.File]::Exists($DestinationLnkPath)) {
                    try   { [IO.File]::Copy($SourceLnkPath, $DestinationLnkPath); Write-Log "    [file] Copied '$([IO.Path]::GetFileName($SourceLnkPath))'" }
                    catch { Write-Log "    [file] Copy FAILED for '$([IO.Path]::GetFileName($SourceLnkPath))' : $_" 'Yellow' }
                }
            }
            # Build blob entries specific to this profile's filesystem paths.
            # We use GetBlobEntryFs (ILCreateFromPathW) because SHParseDisplayName
            # cannot resolve paths under another user's %APPDATA%.
            $ProfileSpecificBlobEntries = @()
            foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
                $ProfileShortcutPath = [IO.Path]::Combine($ProfileTaskBarDirectory, [IO.Path]::GetFileName($ReadyEntry.DestinationLnkPath))
                if (-not [IO.File]::Exists($ProfileShortcutPath)) { continue }
                $ProfileBlobEntry = [TaskbarPin]::GetBlobEntryFs($ProfileShortcutPath, $ReadyEntry.Beef001dContent)
                if ($ProfileBlobEntry) {
                    $ProfileSpecificBlobEntries += New-Object PSObject -Property @{
                        DestinationLnkPath  = $ProfileShortcutPath
                        SerializedBlobEntry = $ProfileBlobEntry
                    }
                }
            }
            if ($ProfileSpecificBlobEntries.Count -eq 0) { Write-Log "    No blob entries could be built -- skipping"; continue }
            # Load the profile's offline hive and write the blob entries
            $OfflineHiveResult = Invoke-WithOfflineHive $UserProfile.SID $UserProfile.ProfilePath {
                param($OfflineRegistryKey)
                $OfflineFavoritesBlob = $OfflineRegistryKey.GetValue('Favorites', $null, $DoNotExpandRegistryOption)
                $OfflineAddedCount    = Write-BlobToRegistryKey $OfflineRegistryKey $OfflineFavoritesBlob $ProfileSpecificBlobEntries
                Write-Log "    [blob] $OfflineAddedCount entries written to offline profile"
            }
            if ($OfflineHiveResult) { $AllUsersProfilesUpdatedCount++ }
        }
        Write-Console "  [*] AllUsers : $AllUsersProfilesUpdatedCount profile(s) updated" -Color DarkCyan
        Write-Log "[allUsers] $AllUsersProfilesUpdatedCount profile(s) updated"
        Write-Console ""
    }

    $RemainingPinTargets = @($ItemsDeferredToQuickLaunch)
} else {
    # Blob injection is not possible (no TaskBar directory or no Taskband registry key).
    # All items will be attempted via the Quick Launch fallback.
    Write-Log "[blob-prep] Direct blob injection NOT available (TaskBar dir : $TaskBarDirectoryExists, Taskband key : $TaskBandRegistryKeyExists)"
    Write-Log "[blob-prep] All $($ResolvedPinTargets.Count) item(s) will be attempted via Quick Launch fallback"
    $RemainingPinTargets = @($ResolvedPinTargets)
}


#region PIN : QUICK LAUNCH FALLBACK

# The Quick Launch fallback is for systems where the TaskBar pinned directory
# or the Taskband registry key doesn't exist (primarily Windows Vista).
# It simply copies the .lnk shortcut into the Quick Launch directory.
# UWP apps are not supported by this method.
if ($RemainingPinTargets.Count -gt 0 -and $QuickLaunchDirectoryExists) {
    Write-Log "[quicklaunch] Falling back to Quick Launch for $($RemainingPinTargets.Count) remaining item(s)..."
    $WshShellForFallback = $null
    foreach ($FallbackTarget in $RemainingPinTargets) {
        if ($FallbackTarget.PinType -eq 'UWP') {
            Write-Log "  [quicklaunch] Skipping UWP item '$($FallbackTarget.DisplayName)' -- Quick Launch cannot pin UWP apps" 'Yellow'
            continue
        }
        $Beef001dFallbackRef    = [ref]''
        $FallbackShortcutPath   = New-TargetShortcut $FallbackTarget.ResolvedPath $Beef001dFallbackRef ([ref]$WshShellForFallback)
        $FallbackIsTemporary    = ($FallbackShortcutPath -ne $FallbackTarget.ResolvedPath)
        $FallbackShortcutName   = [IO.Path]::GetFileName($FallbackShortcutPath)
        Write-Console "  [QL] $FallbackShortcutName..." -Color DarkGray -NoNewline
        $QuickLaunchDestination = [IO.Path]::Combine($QuickLaunchDirectory, $FallbackShortcutName)
        [IO.File]::Copy($FallbackShortcutPath, $QuickLaunchDestination, $true)
        Write-Console " done" -Color Green
        Write-Console "  [+] $FallbackShortcutName" -Color Cyan
        Write-Log "  [quicklaunch] Copied '$FallbackShortcutName' to Quick Launch directory"
        $SuccessfullyPinnedCount++
        if ($FallbackIsTemporary -and $FallbackShortcutPath) { try { [IO.File]::Delete($FallbackShortcutPath) } catch { } }
    }
    if ($WshShellForFallback) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($WshShellForFallback) }
}


#region CLEANUP

# Release COM objects
if ($AppsFolderNamespaceCom) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($AppsFolderNamespaceCom) }
if ($ShellApplicationCom)   { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ShellApplicationCom) }

# Report final status
if ($SuccessfullyPinnedCount -gt 0) {
    Write-Banner 'OK' 'DarkGreen' "Pinned $SuccessfullyPinnedCount item(s)$(if ($AllUsers) { ' (AllUsers)' })"
    Write-Log "--- PIN complete : $SuccessfullyPinnedCount pinned"
    Close-Log; exit 0
}
Write-Banner 'FAIL' 'DarkRed' "No items could be pinned"
Write-Log "--- PIN FAILED : 0/$($ResolvedPinTargets.Count) items pinned ---"
Close-Log; exit 3
