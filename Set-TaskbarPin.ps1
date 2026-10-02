function Set-TaskbarPin {
    # Version 1.6
    <#
        .EXAMPLE
        Set-TaskbarPin firefox
        Set-TaskbarPin "C:\App1.lnk;C:\Windows\regedit.exe;C:\MyFolder;C:\Tools\*.exe" -AllUsers
        Set-TaskbarPin "shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
        Set-TaskbarPin "uwp:Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
        Set-TaskbarPin -Unpin * -AllUsers
        Set-TaskbarPin "C:\MyApp.lnk;C:\Windows\System32\services.msc;C:\Windows\System32\main.cpl" -Silent
    #>
    param(
        [Parameter(Position = 0)]
        [Alias('Path', 'File', 'Files')][string]$Pin,
        [Alias('Remove')]               [switch]$Unpin,
        [Alias('S')]                    [switch]$Silent,
        [Alias('Everyone', 'All')]      [switch]$AllUsers
    )
    $ErrorActionPreference = 'Stop'
    #region ENVIRONMENT
    function Test-RegistrySubKeyExists {
        param($RegistryRootKey, [string]$RegistrySubKeyPath)
        $ProbeHandle = $null
        try { $ProbeHandle = $RegistryRootKey.OpenSubKey($RegistrySubKeyPath, $false) } catch { }
        if ($ProbeHandle) { $ProbeHandle.Close(); return $true }
        return $false
    }
    $UserAccountSidPattern           = '^S-1-(5-21|12-1)(-\d+)+$'
    $TaskBarRelativeAppDataPath      = 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    $QuickLaunchRelativeAppDataPath  = 'Microsoft\Internet Explorer\Quick Launch'
    $TaskBarRelativeProfilePath      = "AppData\Roaming\$TaskBarRelativeAppDataPath"
    $QuickLaunchRelativePath         = "AppData\Roaming\$QuickLaunchRelativeAppDataPath"
    $TaskBandRegistrySubKey          = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
    $DoNotExpandRegistryOption       = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    $BinaryRegistryValueKind         = [Microsoft.Win32.RegistryValueKind]::Binary
    $DwordRegistryValueKind          = [Microsoft.Win32.RegistryValueKind]::DWord
    $WindowsBuildNumber              = [Environment]::OSVersion.Version.Build
    $CurrentVersionRegistryKey       = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion')
    if ($CurrentVersionRegistryKey) {
        $RegistryBuildNumber = 0
        if ([int]::TryParse([string]$CurrentVersionRegistryKey.GetValue('CurrentBuildNumber', ''), [ref]$RegistryBuildNumber)) { $WindowsBuildNumber = $RegistryBuildNumber }
        $CurrentVersionRegistryKey.Close()
    }
    $TaskbarUsesQuickLaunch          = $WindowsBuildNumber -lt 7600
    $CurrentWindowsIdentity          = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $CurrentUserSecurityIdentifier   = $CurrentWindowsIdentity.User.Value
    $IsRunningCrossUser              = $false
    $EffectivePrimaryUserSID         = $CurrentUserSecurityIdentifier
    $PrimaryRoamingAppDataDirectory  = [Environment]::GetFolderPath('ApplicationData')
    $CurrentProcessSessionId         = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    foreach ($CandidateSidKeyName in [Microsoft.Win32.Registry]::Users.GetSubKeyNames()) {
        if ($CandidateSidKeyName -notmatch $UserAccountSidPattern) { continue }
        if (-not (Test-RegistrySubKeyExists ([Microsoft.Win32.Registry]::Users) "$CandidateSidKeyName\Volatile Environment\$CurrentProcessSessionId")) { continue }
        if ($CandidateSidKeyName -ne $CurrentUserSecurityIdentifier) {
            $IsRunningCrossUser             = $true
            $EffectivePrimaryUserSID        = $CandidateSidKeyName
            $PrimaryRoamingAppDataDirectory = ''
            $VolatileEnvironmentKey = [Microsoft.Win32.Registry]::Users.OpenSubKey("$CandidateSidKeyName\Volatile Environment")
            if ($VolatileEnvironmentKey) { $PrimaryRoamingAppDataDirectory = [string]$VolatileEnvironmentKey.GetValue('APPDATA', ''); $VolatileEnvironmentKey.Close() }
            if (-not $PrimaryRoamingAppDataDirectory) {
                $ProfileListKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$CandidateSidKeyName")
                if ($ProfileListKey) {
                    $InteractiveUserProfilePath = [string]$ProfileListKey.GetValue('ProfileImagePath', ''); $ProfileListKey.Close()
                    if ($InteractiveUserProfilePath) { $PrimaryRoamingAppDataDirectory = [IO.Path]::Combine($InteractiveUserProfilePath, 'AppData\Roaming') }
                }
            }
        }
        break
    }
    $TaskBarPinnedDirectory = ''
    $QuickLaunchDirectory   = ''
    if ($PrimaryRoamingAppDataDirectory) {
        $TaskBarPinnedDirectory = [IO.Path]::Combine($PrimaryRoamingAppDataDirectory, $TaskBarRelativeAppDataPath)
        $QuickLaunchDirectory   = [IO.Path]::Combine($PrimaryRoamingAppDataDirectory, $QuickLaunchRelativeAppDataPath)
    }
    $TaskBarDirectoryExists     = [IO.Directory]::Exists($TaskBarPinnedDirectory)
    $QuickLaunchDirectoryExists = [IO.Directory]::Exists($QuickLaunchDirectory)
    $TaskBandRegistryKeyExists  = if ($IsRunningCrossUser) { Test-RegistrySubKeyExists ([Microsoft.Win32.Registry]::Users) "$EffectivePrimaryUserSID\$TaskBandRegistrySubKey" } else { Test-RegistrySubKeyExists ([Microsoft.Win32.Registry]::CurrentUser) $TaskBandRegistrySubKey }
    $PrimaryUserHasPinList      = -not $TaskbarUsesQuickLaunch -and $TaskBarDirectoryExists -and $TaskBandRegistryKeyExists
    #region CONSOLE
    function Write-Console {
        param([string]$Message, [string]$Color = 'White', [switch]$NoNewline)
        if ($Silent) { return }
        $WriteHostParams = @{ Object = $Message; ForegroundColor = $Color }
        if ($NoNewline) { $WriteHostParams['NoNewline'] = $true }
        Write-Host @WriteHostParams
    }
    function Write-Banner {
        param([string]$Label, [string]$LabelBackground, [string]$Detail)
        if ($Silent) { return }
        Write-Host ""; Write-Host "  $Label  " -ForegroundColor White -BackgroundColor $LabelBackground -NoNewline; Write-Host "  $Detail"; Write-Host ""
    }
    #region INPUT VALIDATION
    $LiteralSemicolonSentinel = [string][char]1
    $ParsedInputItems = @($Pin.Replace(';;', $LiteralSemicolonSentinel) -split ';' | ForEach-Object { $_.Replace($LiteralSemicolonSentinel, ';').Trim() } | Where-Object { $_ })
    if ($ParsedInputItems.Count -eq 0) { Write-Console "ERROR : Specify -Pin" -Color Red; return }
    $ParsedInputItems = @($ParsedInputItems | ForEach-Object {  if     ($_.StartsWith('uwp:', [StringComparison]::OrdinalIgnoreCase))              { 'shell:AppsFolder\' + $_.Substring(4) }
                                                                elseif ($_.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase)) { 'shell:AppsFolder\' + $_.Substring(17) }
                                                                elseif ($_ -match '!' -and $_ -notmatch '[/\\]')                                   { 'shell:AppsFolder\' + $_ }
                                                                else                                                                               {                       $_ }
    })
    function Test-IsAdmin {
        $CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal($CurrentWindowsIdentity)
        return $CurrentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    if ($AllUsers -and -not (Test-IsAdmin)) { Write-Console "ERROR : -AllUsers requires elevation" -Color Red; return }
    #region C# HELPER
    function Initialize-NativeHelper {
        $NativeHelperType = 'TaskbarPin' -as [Type]
        if ($NativeHelperType) {
            $HelperVersionField = $NativeHelperType.GetField('HelperVersion')
            if (-not $HelperVersionField -or $HelperVersionField.GetValue($null) -ne '1.6') { throw 'This PowerShell session holds the helper of another Pin-Taskbar version : run the script in a new PowerShell session.' }
            return
        }
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
public class TaskbarPin {
    public const string HelperVersion = "1.6";
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
    static T Vtbl<T>(IntPtr vtbl, int slot) where T : class {
        return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vtbl, slot * IntPtr.Size), typeof(T));
    }
    static T Slot<T>(IntPtr comObject, int slot) where T : class { return Vtbl<T>(Marshal.ReadIntPtr(comObject), slot); }
    static void Release(IntPtr ppv) { Vtbl<FnRelease>(Marshal.ReadIntPtr(ppv), 2)(ppv); }
    static void Release(IntPtr ppv, IntPtr vtbl) { Vtbl<FnRelease>(vtbl, 2)(ppv); }
    static IntPtr ParseDisplayName(string name) {
        IntPtr pidl; uint sfgao;
        if (SHParseDisplayName(name, IntPtr.Zero, out pidl, 0, out sfgao) == 0) return pidl;
        return IntPtr.Zero;
    }
    static IntPtr AllocPropertyKey() {
        byte[] propertyKeyBytes = new byte[20];
        Array.Copy(FMTID_AppUserModel.ToByteArray(), 0, propertyKeyBytes, 0, 16);
        propertyKeyBytes[16] = 5;
        IntPtr propertyKeyPtr = Marshal.AllocCoTaskMem(20);
        Marshal.Copy(propertyKeyBytes, 0, propertyKeyPtr, 20);
        return propertyKeyPtr;
    }
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
    static bool IsBlock(byte[] item, int pos, int cb) {
        if (pos + 8 > cb) return false;
        int size = BitConverter.ToUInt16(item, pos);
        return size >= 8 && pos + size <= cb && BitConverter.ToUInt16(item, pos + 6) == 0xBEEF;
    }
    static int FirstBlock(byte[] item, int cb) {
        if (cb < 12) return 0;
        int first = BitConverter.ToUInt16(item, cb - 2);
        if (first < 4 || first >= cb) return 0;
        int pos = first;
        while (pos < cb && IsBlock(item, pos, cb)) pos += BitConverter.ToUInt16(item, pos);
        return pos == cb ? first : 0;
    }
    static void Put16(byte[] data, int pos, int value) { data[pos] = (byte)value; data[pos + 1] = (byte)(value >> 8); }
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
    public static bool IsRetiredEntry(byte[] entry) {
        int last = LastItemOffset(entry);
        bool repaired;
        return last != 0 && FindBlock(LastItem(entry, last, out repaired), 0xBEEF002C) >= 0;
    }
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
    public static bool IsProfileRelativeEntry(byte[] entry) {
        if (entry == null || entry.Length < 25 || entry[0] != 0 || BitConverter.ToUInt16(entry, 5) < 20 || entry[7] != 0x1F) return false;
        byte[] rootGuid = new byte[16];
        Array.Copy(entry, 9, rootGuid, 0, 16);
        Guid root = new Guid(rootGuid);
        return root == CLSID_UsersFilesFolder || root == CLSID_UserPinnedFolder;
    }
    public static string GetEntryPath(byte[] entry) {
        IntPtr pidl = EntryPidl(entry);
        if (pidl == IntPtr.Zero) return "";
        try {
            System.Text.StringBuilder path = new System.Text.StringBuilder(1024);
            return SHGetPathFromIDListW(pidl, path) ? path.ToString() : "";
        } finally { ILFree(pidl); }
    }
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
    public static bool WriteInPlace(string path, byte[] content) {
        byte[] current = System.IO.File.ReadAllBytes(path);
        if (BytesEqual(current, WithAccessTimeOf(content, current))) return false;
        using (System.IO.FileStream fs = new System.IO.FileStream(path, System.IO.FileMode.Open, System.IO.FileAccess.Write, System.IO.FileShare.Read)) {
            fs.Write(content, 0, content.Length);
            fs.SetLength(content.Length);
        }
        return true;
    }
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
    public static void NotifyShortcutChanged(string lnkPath) {
        IntPtr pathPtr = Marshal.StringToHGlobalUni(lnkPath);
        try {
            SHChangeNotify(0x00000001, 0x1005, pathPtr, pathPtr);
            SHChangeNotify(0x00002000, 0x1005, pathPtr, IntPtr.Zero);
        } finally { Marshal.FreeHGlobal(pathPtr); }
    }
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
    public static void SendPinNotify() {
        IntPtr reBarWindow = FindWindowEx(FindWindow("Shell_TrayWnd", null), IntPtr.Zero, "ReBarWindow32", null);
        IntPtr pinnedItemsBand = FindWindowEx(reBarWindow, IntPtr.Zero, "MSTaskSwWClass", null);
        if (pinnedItemsBand != IntPtr.Zero) PostMessage(pinnedItemsBand, 0x446, IntPtr.Zero, IntPtr.Zero);
    }
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
    public static int LoadUserHive(string name, string file) { return CallWithHivePrivileges(name, file); }
    public static int UnloadUserHive(string name) { return CallWithHivePrivileges(name, null); }
    static int CallWithHivePrivileges(string name, string file) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0028, out token)) return Marshal.GetLastWin32Error();
        try {
            TokenPrivilegePair wanted = new TokenPrivilegePair(), previous = new TokenPrivilegePair();
            wanted.Count = 2;
            wanted.FirstAttributes = wanted.SecondAttributes = 2;
            if (!LookupPrivilegeValueW(null, "SeBackupPrivilege", out wanted.FirstLuid) || !LookupPrivilegeValueW(null, "SeRestorePrivilege", out wanted.SecondLuid)) return Marshal.GetLastWin32Error();
            int previousSize;
            if (!AdjustTokenPrivileges(token, false, ref wanted, Marshal.SizeOf(typeof(TokenPrivilegePair)), ref previous, out previousSize)) return Marshal.GetLastWin32Error();
            int error = Marshal.GetLastWin32Error();
            try {
                if (error != 0) return error;
                return file != null ? RegLoadKeyW(HKEY_USERS, name, file) : RegUnLoadKeyW(HKEY_USERS, name);
            } finally { RestoreTokenPrivileges(token, false, ref previous, 0, IntPtr.Zero, IntPtr.Zero); }
        } finally { CloseHandle(token); }
    }
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
    public static byte[] BuildResolveRecord(byte[] entry) {
        return RunOnSTA<byte[]>(delegate() {
            IntPtr pidl = EntryPidl(entry);
            if (pidl == IntPtr.Zero) throw new InvalidOperationException("Malformed Favorites entry.");
            try { return BuildRecordFromPidl(pidl); } finally { ILFree(pidl); }
        });
    }
    public static byte[] BuildResolveRecordForPath(string lnkPath) {
        return RunOnSTA<byte[]>(delegate() {
            IntPtr pidl = ILCreateFromPathW(lnkPath);
            if (pidl == IntPtr.Zero) throw new System.IO.FileNotFoundException("Shortcut not found.", lnkPath);
            try { return BuildRecordFromPidl(pidl); } finally { ILFree(pidl); }
        });
    }
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
    static string ItemDisplayName(IntPtr item, uint form) {
        IntPtr name;
        if (Slot<FnGetDisplayName>(item, 5)(item, form, out name) != 0 || name == IntPtr.Zero) return "";
        try { return Marshal.PtrToStringUni(name) ?? ""; } finally { Marshal.FreeCoTaskMem(name); }
    }
    static string ItemString(IntPtr item, PropertyKey key) {
        Guid iid = IID_IShellItem2; IntPtr item2;
        if (Slot<FnQueryInterface>(item, 0)(item, ref iid, out item2) != 0) return "";
        try {
            IntPtr value;
            if (Slot<FnGetString>(item2, 17)(item2, ref key, out value) != 0 || value == IntPtr.Zero) return "";
            try { return Marshal.PtrToStringUni(value) ?? ""; } finally { Marshal.FreeCoTaskMem(value); }
        } finally { Release(item2); }
    }
    public static string GetShellDisplayName(string path) {
        return RunOnSTA<string>(delegate() {
            Guid iid = IID_IShellItem; IntPtr item;
            if (SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out item) != 0) return "";
            try { return ItemDisplayName(item, 0); } finally { Release(item); }
        });
    }
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
                            entry.Aumid             = ItemDisplayName(item, 0x80018001);
                            entry.DisplayName       = ItemDisplayName(item, 0x80080001);
                            entry.TargetParsingPath = ItemString(item, PKEY_Link_TargetParsingPath);
                            entries.Add(entry);
                        } finally { Release(item); }
                    }
                } finally { Release(items); }
            } finally { Release(folder); }
            return entries.ToArray();
        });
    }
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
    static string ReadAnsiZ(byte[] d, int pos) {
        int end = pos;
        while (end < d.Length && d[end] != 0) end++;
        return System.Text.Encoding.Default.GetString(d, pos, end - pos);
    }
    static string ReadUniZ(byte[] d, int pos) {
        int end = pos;
        while (end + 1 < d.Length && (d[end] != 0 || d[end + 1] != 0)) end += 2;
        return System.Text.Encoding.Unicode.GetString(d, pos, end - pos);
    }
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
    static void ParseLnk(byte[] d, string lnkDirectory, out string target, out string aumid, out string iconPath) {
        target = ""; aumid = ""; iconPath = "";
        if (d.Length < 0x4C || BitConverter.ToInt32(d, 0) != 0x4C) return;
        uint flags = BitConverter.ToUInt32(d, 20);
        int pos = 0x4C;
        if ((flags & 0x01) != 0) {
            if (pos + 2 > d.Length) return;
            pos += 2 + BitConverter.ToUInt16(d, pos);
        }
        if ((flags & 0x02) != 0 && pos + 36 <= d.Length) {
            int li = pos;
            uint liSize  = BitConverter.ToUInt32(d, li);
            uint liHead  = BitConverter.ToUInt32(d, li + 4);
            uint liFlags = BitConverter.ToUInt32(d, li + 8);
            if ((liFlags & 0x01) != 0) {
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
        bool isUnicode = (flags & 0x80) != 0;
        string relativePath = "";
        uint[] stringDataFlags = new uint[] { 0x04, 0x08, 0x10, 0x20, 0x40 };
        for (int i = 0; i < stringDataFlags.Length; i++) {
            if ((flags & stringDataFlags[i]) == 0) continue;
            if (pos + 2 > d.Length) return;
            int charCount = BitConverter.ToUInt16(d, pos);
            int byteCount = charCount * (isUnicode ? 2 : 1);
            if (pos + 2 + byteCount > d.Length) return;
            if (stringDataFlags[i] == 0x08) {
                relativePath = isUnicode ? System.Text.Encoding.Unicode.GetString(d, pos + 2, byteCount)
                                         : System.Text.Encoding.Default.GetString(d, pos + 2, byteCount);
            }
            else if (stringDataFlags[i] == 0x40) {
                iconPath = isUnicode ? System.Text.Encoding.Unicode.GetString(d, pos + 2, byteCount)
                                     : System.Text.Encoding.Default.GetString(d, pos + 2, byteCount);
            }
            pos += 2 + byteCount;
        }
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
        if (target.Length == 0 && relativePath.Length > 0 && lnkDirectory.Length > 0) {
            try { target = System.IO.Path.GetFullPath(System.IO.Path.Combine(lnkDirectory, relativePath)); } catch { }
        }
    }
    public static int GetIconResourceCount(string filePath) {
        if (!System.IO.File.Exists(filePath)) return 0;
        uint iconResourceCount = ExtractIconExW(filePath, -1, IntPtr.Zero, IntPtr.Zero, 0);
        if (iconResourceCount == 0xFFFFFFFF) return 0;
        return (int)iconResourceCount;
    }
    static void AddLnkFiles(string directory, List<string> lnkPaths) {
        string[] matchedFiles;
        try { matchedFiles = System.IO.Directory.GetFiles(directory, "*.lnk"); } catch { return; }
        for (int i = 0; i < matchedFiles.Length; i++) {
            if (matchedFiles[i].EndsWith(".lnk", StringComparison.OrdinalIgnoreCase)) lnkPaths.Add(matchedFiles[i]);
        }
    }
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
public class LnkEntry {
    public string LnkPath;
    public string DisplayName;
    public string TargetPath;
    public string Aumid;
    public string IconPath;
    public int Rank;
}
public class AppEntry {
    public string Aumid;
    public string DisplayName;
    public string TargetParsingPath;
}
public class TaskbandPinList {
    readonly List<byte[]> entries = new List<byte[]>();
    readonly List<byte[]> records = new List<byte[]>();
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
    public void SetEntry(int index, byte[] entry, bool resetRecord) { entries[index] = entry; if (resetRecord) records[index] = new byte[4]; }
    public void SetRecord(int index, byte[] record) { records[index] = record; }
    public int Add(byte[] entry) { entries.Add(entry); records.Add(new byte[4]); return entries.Count - 1; }
    public void RemoveAt(int index) { entries.RemoveAt(index); records.RemoveAt(index); }
    public bool NeedsRecord(int index, bool replaceForeign) {
        if (TaskbarPin.IsRetiredEntry(entries[index])) return false;
        return records[index].Length == 4 || (replaceForeign && !TaskbarPin.IsWindowsRecord(records[index]));
    }
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
    }
    #region HELPER FUNCTIONS
    $script:AppsFolderSnapshot     = $null
    $script:ShortcutCatalog        = $null
    $script:UserProfiles           = $null
    $script:TemporaryShortcutRoot  = [IO.Path]::Combine([IO.Path]::GetTempPath(), "Pin-Taskbar-$PID")
    $script:TemporaryShortcutCount = 0
    function Get-TemporaryShortcutPath {
        param([string]$ShortcutFileName)
        $script:TemporaryShortcutCount++
        $TemporaryShortcutDirectory = [IO.Path]::Combine($script:TemporaryShortcutRoot, [string]$script:TemporaryShortcutCount)
        $null = [IO.Directory]::CreateDirectory($TemporaryShortcutDirectory)
        return [IO.Path]::Combine($TemporaryShortcutDirectory, $ShortcutFileName)
    }
    function Remove-TemporaryShortcuts {
        if ($script:TemporaryShortcutCount -gt 0) { try { [IO.Directory]::Delete($script:TemporaryShortcutRoot, $true) } catch { } }
        $script:TemporaryShortcutCount = 0
    }
    function Open-EffectiveTaskbandKey {
        param([bool]$Writable = $false)
        if ($IsRunningCrossUser) { return [Microsoft.Win32.Registry]::Users.OpenSubKey("$EffectivePrimaryUserSID\$TaskBandRegistrySubKey", $Writable) }
        return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($TaskBandRegistrySubKey, $Writable)
    }
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
    function Get-AppsFolderSnapshot {
        if ($null -ne $script:AppsFolderSnapshot) { return $script:AppsFolderSnapshot }
        Initialize-NativeHelper
        try { $script:AppsFolderSnapshot = [TaskbarPin]::GetAppsFolderEntries() } catch { $script:AppsFolderSnapshot = @() }
        return $script:AppsFolderSnapshot
    }
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
        $script:ShortcutCatalog = @($CollectedShortcutEntries.ToArray())
        return $script:ShortcutCatalog
    }
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
    function Find-ApplicationMatches {
        param([string]$NameOrAumidPattern)
        if ($NameOrAumidPattern -match '[*?]') {
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
        $SubstringMatchPattern = '*' + [System.Management.Automation.WildcardPattern]::Escape($NameOrAumidPattern) + '*'
        $ExactNameMatches      = @()
        $SubstringNameMatches  = @()
        foreach ($ApplicationEntry in (Get-AppsFolderSnapshot)) {
            if ($ApplicationEntry.DisplayName -notlike $SubstringMatchPattern) { continue }
            $CandidateMatch = @{ Kind = 'Aumid'; Aumid = $ApplicationEntry.Aumid; DisplayName = $ApplicationEntry.DisplayName; CandidateTargetPath = [string]$ApplicationEntry.TargetParsingPath; CandidateIconPath = '' }
            if ([string]::Equals($ApplicationEntry.DisplayName, $NameOrAumidPattern, [StringComparison]::OrdinalIgnoreCase)) { $ExactNameMatches += $CandidateMatch } else { $SubstringNameMatches += $CandidateMatch }
        }
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
    function Select-SingleApplicationMatch {
        param($CandidateMatches, [string]$BareNameInput)
        Initialize-NativeHelper
        $RemainingCandidates = @($CandidateMatches)
        foreach ($Candidate in $RemainingCandidates) {
            $CandidateAumid = [string]$Candidate.Aumid
            $Candidate.IsUwpApplication = ($CandidateAumid.IndexOf('!') -ge 0 -and $CandidateAumid.IndexOf('\') -lt 0)
        }
        if ($RemainingCandidates.Count -gt 1) {
            $ExecutableBackedCandidates = @()
            foreach ($Candidate in $RemainingCandidates) {
                if ($Candidate.IsUwpApplication -or $Candidate.CandidateTargetPath.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { $ExecutableBackedCandidates += $Candidate }
            }
            if ($ExecutableBackedCandidates.Count -gt 0 -and $ExecutableBackedCandidates.Count -lt $RemainingCandidates.Count) {
                $RemainingCandidates = $ExecutableBackedCandidates
            }
        }
        if ($RemainingCandidates.Count -gt 1) {
            $OwnIconCandidates = @()
            foreach ($Candidate in $RemainingCandidates) {
                if (Test-CandidateOwnsIcon $Candidate) { $OwnIconCandidates += $Candidate }
            }
            if ($OwnIconCandidates.Count -gt 0 -and $OwnIconCandidates.Count -lt $RemainingCandidates.Count) {
                $RemainingCandidates = $OwnIconCandidates
            }
        }
        if ($RemainingCandidates.Count -gt 1) {
            foreach ($Candidate in $RemainingCandidates) { $Candidate.EliminationMetric = $Candidate.DisplayName.Length }
            $RemainingCandidates = @(Select-MinimumMetricCandidates $RemainingCandidates)
        }
        if ($RemainingCandidates.Count -gt 1) {
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
        return $SelectedApplicationMatch
    }
    function Get-DirectoryShortcutName {
        param([string]$DirectoryPath)
        $DirectoryName = [IO.Path]::GetFileName($DirectoryPath.TrimEnd('\', '/'))
        if (-not $DirectoryName) { Initialize-NativeHelper; $DirectoryName = ([TaskbarPin]::GetShellDisplayName($DirectoryPath) -replace '[<>:"/\\|?*]', '').Trim() }
        if (-not $DirectoryName) { $DirectoryName = $DirectoryPath -replace '[<>:"/\\|?*]', '' }
        return $DirectoryName
    }
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
            $NewShortcutObject.TargetPath       = [IO.Path]::Combine($env:SystemRoot, 'explorer.exe')
            $NewShortcutObject.Arguments        = "`"$ResolvedTargetPath`""
            $NewShortcutObject.IconLocation     = [IO.Path]::Combine($env:SystemRoot, 'System32\shell32.dll') + ',3'
            $NewShortcutObject.WorkingDirectory = $ResolvedTargetPath
        } elseif ($TargetFileExtension -eq '.cpl') {
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
    function Invoke-WithTaskbandKey {
        param([scriptblock]$ActionToPerform)
        if (-not [TaskbarPin]::AcquirePinMutex(5000)) { throw 'The taskbar pin list is busy (TaskbarPinListMutex held for 5 s) : nothing was written.' }
        try {
            $TaskBandRegistryKey = Open-EffectiveTaskbandKey $true
            if (-not $TaskBandRegistryKey) { throw 'The Taskband registry key cannot be opened for writing.' }
            try { & $ActionToPerform $TaskBandRegistryKey } finally { $TaskBandRegistryKey.Close() }
        } finally {
            [TaskbarPin]::ReleasePinMutex()
        }
    }
    function Read-TaskbandPinList {
        param($RegistryKeyHandle)
        $FavoritesBlob = $RegistryKeyHandle.GetValue('Favorites', $null, $DoNotExpandRegistryOption)
        $ResolveBlob   = $RegistryKeyHandle.GetValue('FavoritesResolve', $null, $DoNotExpandRegistryOption)
        return @{ FavoritesBlob = $FavoritesBlob; ResolveBlob = $ResolveBlob; PinList = [TaskbandPinList]::Parse($FavoritesBlob, $ResolveBlob) }
    }
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
        return $true
    }
    function Get-EntryShortcutPath {
        param([byte[]]$PinnedEntry, [bool]$IsOwnerSession, [string]$OwnerTaskBarDirectory)
        $EntryPath = [TaskbarPin]::GetEntryPath($PinnedEntry)
        if ($IsOwnerSession -or -not $EntryPath) { return $EntryPath }
        if (-not ([string][IO.Path]::GetDirectoryName($EntryPath)).EndsWith('\User Pinned\TaskBar', [StringComparison]::OrdinalIgnoreCase)) { return '' }
        return [IO.Path]::Combine($OwnerTaskBarDirectory, [IO.Path]::GetFileName($EntryPath))
    }
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
        } catch { return $false }
    }
    function Write-BlobToRegistryKey {
        param($RegistryKeyHandle, $PreparedBlobEntries, [bool]$IsOwnerSession, [string]$OwnerTaskBarDirectory)
        $PinListState = Read-TaskbandPinList $RegistryKeyHandle
        $PinList = $PinListState.PinList
        $ChangedEntryCount = 0
        foreach ($PreparedEntry in $PreparedBlobEntries) {
            $EntryIndex = $PinList.IndexOfPath($PreparedEntry.DestinationLnkPath, -not $IsOwnerSession)
            if ($EntryIndex -lt 0) { $EntryIndex = $PinList.IndexOfAppId($PreparedEntry.Beef001dContent) }
            if ($EntryIndex -lt 0) {
                $EntryIndex = $PinList.Add($PreparedEntry.SerializedBlobEntry)
                $ChangedEntryCount++
            } elseif ([TaskbarPin]::IsRetiredEntry($PinList.GetEntry($EntryIndex))) {
                $PinList.SetEntry($EntryIndex, $PreparedEntry.SerializedBlobEntry, $true)
                $PreparedEntry.EntryWasRepaired = $true
                $ChangedEntryCount++
            } else {
                $RepairedEntry = [TaskbarPin]::FixEntry($PinList.GetEntry($EntryIndex), $PreparedEntry.Beef001dContent)
                if ($RepairedEntry) {
                    $PinList.SetEntry($EntryIndex, $RepairedEntry, $false)
                    $PreparedEntry.EntryWasRepaired = $true
                    $ChangedEntryCount++
                }
            }
            $null = Set-EntryResolveRecord $PinList $EntryIndex $IsOwnerSession $OwnerTaskBarDirectory $true
        }
        for ($EntryIndex = 0; $EntryIndex -lt $PinList.Count; $EntryIndex++) { $null = Set-EntryResolveRecord $PinList $EntryIndex $IsOwnerSession $OwnerTaskBarDirectory $false }
        $null = Save-TaskbandPinList $RegistryKeyHandle $PinListState
        return $ChangedEntryCount
    }
    function Read-PrimaryPinList {
        $TaskBandRegistryKey = Open-EffectiveTaskbandKey $false
        if (-not $TaskBandRegistryKey) { return $null }
        try { return (Read-TaskbandPinList $TaskBandRegistryKey).PinList } finally { $TaskBandRegistryKey.Close() }
    }
    function Find-PinnedApplication {
        param($PinList, [string]$ApplicationId)
        if (-not $ApplicationId -or -not $PinList) { return $null }
        $EntryIndex = $PinList.IndexOfAppId($ApplicationId)
        if ($EntryIndex -lt 0 -or [TaskbarPin]::IsRetiredEntry($PinList.GetEntry($EntryIndex))) { return $null }
        $PinnedShortcutPath = Get-EntryShortcutPath $PinList.GetEntry($EntryIndex) (-not $IsRunningCrossUser) $TaskBarPinnedDirectory
        if (-not ($PinnedShortcutPath.EndsWith('.lnk', [StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([IO.Path]::GetDirectoryName($PinnedShortcutPath), $TaskBarPinnedDirectory, [StringComparison]::OrdinalIgnoreCase))) { $PinnedShortcutPath = '' }
        return @{ ShortcutPath = $PinnedShortcutPath }
    }
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
    function Invoke-WithOfflineHive {
        param([string]$ProfileSID, [string]$ProfileDirectoryPath, [scriptblock]$ActionToPerform)
        $NtUserDatFilePath      = [IO.Path]::Combine($ProfileDirectoryPath, 'NTUSER.DAT')
        $LoadedHiveRegistryPath = $ProfileSID
        $HiveRequiresUnload     = $false
        if (-not ($ProfileSID -ne 'Default' -and (Test-RegistrySubKeyExists ([Microsoft.Win32.Registry]::Users) $ProfileSID))) {
            if (-not [IO.File]::Exists($NtUserDatFilePath)) { return $false }
            $LoadedHiveRegistryPath = "TempPin_$ProfileSID"
            if ([TaskbarPin]::LoadUserHive($LoadedHiveRegistryPath, $NtUserDatFilePath) -ne 0) { return $false }
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
                $null = [TaskbarPin]::UnloadUserHive($LoadedHiveRegistryPath)
            }
        }
        return $true
    }
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
                    $MatchedShortcutPaths += $PinnedShortcutEntry.LnkPath
                    break
                }
            }
        }
        return $MatchedShortcutPaths
    }
    function Invoke-UnpinFromBlob {
        param($RegistryKeyHandle, [string[]]$ShortcutPathsToRemove, [string[]]$ApplicationIdPatterns, [bool]$IsOwnerSession)
        $PinListState = Read-TaskbandPinList $RegistryKeyHandle
        $PinList = $PinListState.PinList
        $RemovedEntryCount = 0
        foreach ($ShortcutPath in $ShortcutPathsToRemove) {
            $EntryIndex = $PinList.IndexOfPath($ShortcutPath, -not $IsOwnerSession)
            while ($EntryIndex -ge 0) {
                $PinList.RemoveAt($EntryIndex)
                $RemovedEntryCount++
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
        }
        if ($RemovedEntryCount -gt 0) { $null = Save-TaskbandPinList $RegistryKeyHandle $PinListState }
        return $RemovedApplicationIds
    }
    #region UNPIN FLOW
    if ($Unpin) {
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
                if ($CplResolvedPattern) { $UnpinMatchPatterns += [System.Management.Automation.WildcardPattern]::Escape($CplResolvedPattern) }
                else { $UnpinMatchPatterns += [System.Management.Automation.WildcardPattern]::Escape([IO.Path]::GetFileNameWithoutExtension($InputItem)) }
            } else {
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
                            }
                        }
                    }
                } elseif ($InputItem -notmatch '[/\\]') {
                    foreach ($UnpinApplicationMatch in @(Find-ApplicationMatches $InputItem)) {
                        $UnpinMatchPatterns += [System.Management.Automation.WildcardPattern]::Escape(($UnpinApplicationMatch.DisplayName -replace '[<>:"/\\|?*]', '_'))
                        if ($UnpinApplicationMatch.Kind -eq 'Aumid') { $UnpinMatchPatterns += [System.Management.Automation.WildcardPattern]::Escape($UnpinApplicationMatch.Aumid) }
                    }
                }
            }
        }
        $UnpinMatchPatterns = @($UnpinMatchPatterns | Where-Object { $_ } | Select-Object -Unique)
        $UnpinMatchPatterns = @(foreach ($UnpinPattern in $UnpinMatchPatterns) {
            try { $null = ('' -like $UnpinPattern); $UnpinPattern } catch { [System.Management.Automation.WildcardPattern]::Escape($UnpinPattern) }
        })
        $DisplayPatternLabel = $UnpinMatchPatterns -join ', '
        Write-Banner 'UNPIN' 'DarkRed' "$DisplayPatternLabel$(if ($AllUsers) { ' (AllUsers)' })"
        Initialize-NativeHelper
        $PinnedDirectoriesToScan = @()
        if ($TaskbarUsesQuickLaunch) { if ($QuickLaunchDirectoryExists) { $PinnedDirectoriesToScan += $QuickLaunchDirectory } }
        elseif ($TaskBarDirectoryExists) { $PinnedDirectoriesToScan += $TaskBarPinnedDirectory }
        if ($PinnedDirectoriesToScan.Count -eq 0 -and -not $AllUsers) { Write-Console "  [!] No pinned items for this account" -Color Yellow; return }
        $MatchedShortcutPaths = @()
        foreach ($DirectoryToScan in $PinnedDirectoriesToScan) { $MatchedShortcutPaths += @(Find-MatchingPins $DirectoryToScan $UnpinMatchPatterns) }
        $UnpinnedApplicationIds = @()
        if ($TaskBandRegistryKeyExists -and -not $TaskbarUsesQuickLaunch) {
            $UnpinnedApplicationIds = @(Invoke-WithTaskbandKey { param($TaskBandRegistryKey) Invoke-UnpinFromBlob $TaskBandRegistryKey $MatchedShortcutPaths $UnpinMatchPatterns (-not $IsRunningCrossUser) })
        }
        $UnpinFailedDeleteCount = 0
        foreach ($ShortcutPath in $MatchedShortcutPaths) {
            if ([IO.File]::Exists($ShortcutPath)) { try { [IO.File]::Delete($ShortcutPath) } catch { $UnpinFailedDeleteCount++ } }
        }
        if ($MatchedShortcutPaths.Count -gt 0 -or $UnpinnedApplicationIds.Count -gt 0) { [TaskbarPin]::SendPinNotify() }
        $UnpinnedItemCount = $MatchedShortcutPaths.Count + $UnpinnedApplicationIds.Count
        if ($AllUsers) {
            foreach ($UserProfile in @(Get-UserProfiles)) {
                $ProfileTaskBarDirectory = [IO.Path]::Combine($UserProfile.ProfilePath, $TaskBarRelativeProfilePath)
                $ProfileMatchedShortcuts = @()
                if ([IO.Directory]::Exists($ProfileTaskBarDirectory)) { $ProfileMatchedShortcuts = @(Find-MatchingPins $ProfileTaskBarDirectory $UnpinMatchPatterns) }
                $script:ProfileUnpinnedApplicationIds = @()
                $null = Invoke-WithOfflineHive $UserProfile.SID $UserProfile.ProfilePath { param($OfflineRegistryKey) $script:ProfileUnpinnedApplicationIds = @(Invoke-UnpinFromBlob $OfflineRegistryKey $ProfileMatchedShortcuts $UnpinMatchPatterns $false) }
                foreach ($ProfileShortcutPath in $ProfileMatchedShortcuts) { if ([IO.File]::Exists($ProfileShortcutPath)) { try { [IO.File]::Delete($ProfileShortcutPath) } catch { } } }
                $UnpinnedItemCount += $ProfileMatchedShortcuts.Count + $script:ProfileUnpinnedApplicationIds.Count
            }
        }
        if ($UnpinnedItemCount -eq 0) { Write-Console "  [!] No pinned items match" -Color Yellow; Write-Console ""; return }
        foreach ($UnpinnedPath in $MatchedShortcutPaths) { Write-Console "  [-] $([IO.Path]::GetFileName($UnpinnedPath))" -Color Cyan }
        foreach ($UnpinnedApplicationId in $UnpinnedApplicationIds) { Write-Console "  [-] $UnpinnedApplicationId" -Color Cyan }
        if ($UnpinFailedDeleteCount -gt 0) { Write-Banner 'FAIL' 'DarkRed' "$UnpinFailedDeleteCount item(s) could not be deleted"; return }
        Write-Banner 'OK' 'DarkGreen' "Unpinned $UnpinnedItemCount item(s)$(if ($AllUsers) { ' (AllUsers)' })"
        return
    }
    #region PIN : RESOLVE INPUT
    Write-Banner 'PIN' 'DarkBlue' "$Pin$(if ($AllUsers) { ' (AllUsers)' })"
    $UwpInputItems        = @($ParsedInputItems | Where-Object { $_.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase) })
    $FilesystemInputItems = @($ParsedInputItems | Where-Object { -not $_.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase) })
    $ResolvedPinTargets               = @()
    $AlreadyResolvedApplicationAumids = @{}
    $AlreadySeenFilesystemPaths       = @{}
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
                    }
                    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ResolvedAppItem)
                } else { Write-Console "  [!] Not found : $ExactUwpInput" -Color Yellow }
            }
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($AppsFolderNamespaceCom)
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ShellApplicationCom)
        }
        foreach ($PatternUwpInput in $PatternUwpInputs) {
            $UwpMatchPattern = $PatternUwpInput.Substring(17); if (-not $UwpMatchPattern) { continue }
            try { $null = ('' -like $UwpMatchPattern) } catch { $UwpMatchPattern = [System.Management.Automation.WildcardPattern]::Escape($UwpMatchPattern) }
            $MatchedAnyApplication = $false
            foreach ($ApplicationEntry in (Get-AppsFolderSnapshot)) {
                if (($ApplicationEntry.DisplayName -like $UwpMatchPattern -or $ApplicationEntry.Aumid -like $UwpMatchPattern) -and -not $AlreadyResolvedApplicationAumids.ContainsKey($ApplicationEntry.Aumid)) {
                    $AlreadyResolvedApplicationAumids[$ApplicationEntry.Aumid] = $true
                    $ResolvedPinTargets += @{ PinType = 'UWP'; Aumid = $ApplicationEntry.Aumid; DisplayName = $ApplicationEntry.DisplayName }
                    $MatchedAnyApplication = $true
                }
            }
            if (-not $MatchedAnyApplication) { Write-Console "  [!] Not found : shell:AppsFolder\$UwpMatchPattern" -Color Yellow }
        }
    }
    foreach ($FilesystemInput in $FilesystemInputItems) {
        $ResolvedFilePaths = @(Resolve-FilesystemInput $FilesystemInput)
        foreach ($ResolvedPath in $ResolvedFilePaths) {
            if (-not $ResolvedPath -or $AlreadySeenFilesystemPaths.ContainsKey($ResolvedPath)) { continue }
            $AlreadySeenFilesystemPaths[$ResolvedPath] = $true
            $ExecutableIdentity = $null
            if ([IO.Path]::GetExtension($ResolvedPath).ToLower() -eq '.exe') { $ExecutableIdentity = Resolve-ExecutableIdentity $ResolvedPath }
            if ($ExecutableIdentity) {
                if (-not $AlreadyResolvedApplicationAumids.ContainsKey($ExecutableIdentity.Aumid)) {
                    $AlreadyResolvedApplicationAumids[$ExecutableIdentity.Aumid] = $true
                    $ResolvedPinTargets += @{ PinType = 'UWP'; Aumid = $ExecutableIdentity.Aumid; DisplayName = $ExecutableIdentity.DisplayName }
                }
            } else {
                $ResolvedPinTargets += @{ PinType = 'FS'; ResolvedPath = $ResolvedPath }
            }
        }
        if ($ResolvedFilePaths.Count -eq 0) {
            $ApplicationMatches = @()
            if ($FilesystemInput -notmatch '[/\\]') { $ApplicationMatches = @(Find-ApplicationMatches $FilesystemInput) }
            if ($ApplicationMatches.Count -gt 0) {
                foreach ($ApplicationMatch in $ApplicationMatches) {
                    if ($ApplicationMatch.Kind -eq 'Aumid') {
                        if ($AlreadyResolvedApplicationAumids.ContainsKey($ApplicationMatch.Aumid)) { continue }
                        $AlreadyResolvedApplicationAumids[$ApplicationMatch.Aumid] = $true
                        $ResolvedPinTargets += @{ PinType = 'UWP'; Aumid = $ApplicationMatch.Aumid; DisplayName = $ApplicationMatch.DisplayName }
                    } else {
                        if ($AlreadySeenFilesystemPaths.ContainsKey($ApplicationMatch.LnkPath)) { continue }
                        $AlreadySeenFilesystemPaths[$ApplicationMatch.LnkPath] = $true
                        $ResolvedPinTargets += @{ PinType = 'FS'; ResolvedPath = $ApplicationMatch.LnkPath }
                    }
                }
            } else { Write-Console "  [!] Not found : $FilesystemInput" -Color Yellow }
        }
    }
    if ($ResolvedPinTargets.Count -eq 0) { Write-Console "  [X] No items found to pin" -Color Red; Write-Console ""; return }
    #region PIN : PIN LIST
    $SuccessfullyPinnedCount = 0
    $FailedPinNames          = @()
    try {
        if (-not $TaskbarUsesQuickLaunch -and -not $PrimaryUserHasPinList) { Write-Console "  [!] This account has no taskbar pin list$(if ($AllUsers) { ' : pinning for the other profiles only' })" -Color Yellow }
        if (-not $TaskbarUsesQuickLaunch -and ($PrimaryUserHasPinList -or $AllUsers)) {
            Write-Console "  [>] Preparing blob entries ($($ResolvedPinTargets.Count) item(s))..." -Color DarkGray -NoNewline
            Initialize-NativeHelper
            $WshShellForPinCreation       = $null
            $BlobEntriesReadyForInjection = @()
            $ItemsAlreadyPinnedByWindows  = @()
            $PrimaryPinList               = $null
            if ($PrimaryUserHasPinList) { $PrimaryPinList = Read-PrimaryPinList }
            foreach ($PinTarget in $ResolvedPinTargets) {
                $SourceShortcutPath = $null; $ShortcutWasUpdated = $false
                if ($PinTarget.PinType -eq 'UWP') {
                    $PinTargetDisplayName = $PinTarget.DisplayName
                    $Beef001dParsingName  = $PinTarget.Aumid
                    $ProposedShortcutName = "$($PinTarget.DisplayName -replace '[<>:"/\\|?*]', '_').lnk"
                } else {
                    $Beef001dContentReference = [ref]''
                    $SourceShortcutPath    = New-TargetShortcut $PinTarget.ResolvedPath $Beef001dContentReference ([ref]$WshShellForPinCreation)
                    $Beef001dParsingName   = $Beef001dContentReference.Value
                    $PinTargetDisplayName  = [IO.Path]::GetFileName($SourceShortcutPath)
                    $ProposedShortcutName  = $PinTargetDisplayName
                    $ResolvedApplicationId = [TaskbarPin]::GetShortcutAppId($SourceShortcutPath)
                    if ($ResolvedApplicationId) { $Beef001dParsingName = $ResolvedApplicationId }
                }
                if (-not $PrimaryUserHasPinList) {
                    if ($PinTarget.PinType -eq 'UWP') {
                        $SourceShortcutPath = Get-TemporaryShortcutPath $ProposedShortcutName
                        if (-not [TaskbarPin]::CreateAppShortcut($PinTarget.Aumid, $SourceShortcutPath)) { $FailedPinNames += $PinTargetDisplayName; continue }
                        $SourceApplicationId = [TaskbarPin]::GetShortcutAppId($SourceShortcutPath)
                        if ($SourceApplicationId) { $Beef001dParsingName = $SourceApplicationId }
                    }
                    $BlobEntriesReadyForInjection += @{ ShortcutPath = $SourceShortcutPath; SerializedBlobEntry = $null; DisplayName = $ProposedShortcutName; Beef001dContent = $Beef001dParsingName }
                    continue
                }
                $PinnedApplication = Find-PinnedApplication $PrimaryPinList $Beef001dParsingName
                if ($PinnedApplication -and -not $PinnedApplication.ShortcutPath) { $ItemsAlreadyPinnedByWindows += $PinTargetDisplayName; continue }
                if ($PinnedApplication) { $DestinationLnkPath = $PinnedApplication.ShortcutPath }
                else { $DestinationLnkPath = Get-AvailablePinnedShortcutPath ([IO.Path]::Combine($TaskBarPinnedDirectory, $ProposedShortcutName)) $Beef001dParsingName }
                $DestinationLnkAlreadyPinned = [IO.File]::Exists($DestinationLnkPath)
                if ($PinTarget.PinType -eq 'UWP') {
                    $SourceShortcutPath = $DestinationLnkPath
                    if ($DestinationLnkAlreadyPinned) { $SourceShortcutPath = Get-TemporaryShortcutPath ([IO.Path]::GetFileName($DestinationLnkPath)) }
                    if (-not [TaskbarPin]::CreateAppShortcut($PinTarget.Aumid, $SourceShortcutPath)) {
                        if (-not $DestinationLnkAlreadyPinned) {
                            if ([IO.File]::Exists($DestinationLnkPath)) { try { [IO.File]::Delete($DestinationLnkPath) } catch { } }
                            $FailedPinNames += $PinTargetDisplayName; continue
                        }
                        $SourceShortcutPath = $null
                    }
                }
                if ($DestinationLnkAlreadyPinned) { $ShortcutWasUpdated = Update-PinnedShortcut $DestinationLnkPath $SourceShortcutPath }
                elseif ($SourceShortcutPath -ne $DestinationLnkPath) { [IO.File]::Copy($SourceShortcutPath, $DestinationLnkPath) }
                if (-not $DestinationLnkAlreadyPinned) { $null = [TaskbarPin]::EmbedStreamIcon($DestinationLnkPath) }
                $PinTargetDisplayName = [IO.Path]::GetFileName($DestinationLnkPath)
                $DestinationApplicationId = [TaskbarPin]::GetShortcutAppId($DestinationLnkPath)
                if ($DestinationApplicationId) { $Beef001dParsingName = $DestinationApplicationId }
                $SerializedBlobEntry = $null
                if ($Beef001dParsingName) {
                    if ($IsRunningCrossUser) { $SerializedBlobEntry = [TaskbarPin]::GetBlobEntryFs($DestinationLnkPath, $Beef001dParsingName) }
                    else                     { $SerializedBlobEntry = [TaskbarPin]::GetBlobEntryEx($DestinationLnkPath, $Beef001dParsingName) }
                }
                if ($SerializedBlobEntry) {
                    $BlobEntriesReadyForInjection += @{ ShortcutPath = $DestinationLnkPath; DestinationLnkPath = $DestinationLnkPath; SerializedBlobEntry = $SerializedBlobEntry; DisplayName = $PinTargetDisplayName; Beef001dContent = $Beef001dParsingName; AlreadyPinned = $DestinationLnkAlreadyPinned; ShortcutWasUpdated = $ShortcutWasUpdated; EntryWasRepaired = $false }
                } else {
                    if (-not $DestinationLnkAlreadyPinned -and [IO.File]::Exists($DestinationLnkPath)) { try { [IO.File]::Delete($DestinationLnkPath) } catch { } }
                    $FailedPinNames += $PinTargetDisplayName
                }
            }
            if ($WshShellForPinCreation) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($WshShellForPinCreation) }
            if ($PrimaryUserHasPinList -and $BlobEntriesReadyForInjection.Count -gt 0) {
                $BlobEntriesChangedCount = Invoke-WithTaskbandKey { param($TaskBandRegistryKey) Write-BlobToRegistryKey $TaskBandRegistryKey $BlobEntriesReadyForInjection (-not $IsRunningCrossUser) $TaskBarPinnedDirectory }
                if ($BlobEntriesChangedCount -gt 0) { [TaskbarPin]::SendPinNotify() }
                foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
                    if ($IsRunningCrossUser -or ($ReadyEntry.AlreadyPinned -and ($ReadyEntry.ShortcutWasUpdated -or $ReadyEntry.EntryWasRepaired))) { [TaskbarPin]::NotifyShortcutChanged($ReadyEntry.DestinationLnkPath) }
                }
                Write-Console " done" -Color Green
                foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
                    Write-Console "  [+] $($ReadyEntry.DisplayName)" -Color Cyan
                    $SuccessfullyPinnedCount++
                }
            } elseif ($BlobEntriesReadyForInjection.Count -gt 0) { Write-Console " done" -Color Green }
            else { Write-Console " nothing to inject" -Color Yellow }
            foreach ($ItemAlreadyPinnedByWindows in $ItemsAlreadyPinnedByWindows) {
                Write-Console "  [=] $ItemAlreadyPinnedByWindows (already pinned)" -Color DarkCyan
                $SuccessfullyPinnedCount++
            }
            Write-Console ""
            if ($AllUsers -and $BlobEntriesReadyForInjection.Count -gt 0) {
                $AllUsersProfilesUpdatedCount = 0
                foreach ($UserProfile in @(Get-UserProfiles)) {
                    $ProfileTaskBarDirectory = [IO.Path]::Combine($UserProfile.ProfilePath, $TaskBarRelativeProfilePath)
                    if (-not [IO.Directory]::Exists($ProfileTaskBarDirectory)) { try { $null = [IO.Directory]::CreateDirectory($ProfileTaskBarDirectory) } catch { continue } }
                    $ProfileSpecificBlobEntries = @()
                    foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
                        $PinnedShortcutName  = [IO.Path]::GetFileName($ReadyEntry.ShortcutPath)
                        $ProfileShortcutPath = Get-AvailablePinnedShortcutPath ([IO.Path]::Combine($ProfileTaskBarDirectory, $PinnedShortcutName)) $ReadyEntry.Beef001dContent
                        try {
                            if ([IO.File]::Exists($ProfileShortcutPath)) { $null = Update-PinnedShortcut $ProfileShortcutPath $ReadyEntry.ShortcutPath }
                            else { [IO.File]::Copy($ReadyEntry.ShortcutPath, $ProfileShortcutPath); $null = [TaskbarPin]::EmbedStreamIcon($ProfileShortcutPath) }
                        } catch { continue }
                        $ProfileBlobEntry = $ReadyEntry.SerializedBlobEntry
                        if (-not ($ProfileBlobEntry -and [TaskbarPin]::IsProfileRelativeEntry($ProfileBlobEntry) -and [IO.Path]::GetFileName($ProfileShortcutPath) -eq $PinnedShortcutName)) { $ProfileBlobEntry = [TaskbarPin]::GetBlobEntryFs($ProfileShortcutPath, $ReadyEntry.Beef001dContent) }
                        if ($ProfileBlobEntry) { $ProfileSpecificBlobEntries += @{ DestinationLnkPath = $ProfileShortcutPath; SerializedBlobEntry = $ProfileBlobEntry; Beef001dContent = $ReadyEntry.Beef001dContent; EntryWasRepaired = $false } }
                    }
                    if ($ProfileSpecificBlobEntries.Count -eq 0) { continue }
                    if (Invoke-WithOfflineHive $UserProfile.SID $UserProfile.ProfilePath { param($OfflineRegistryKey) $null = Write-BlobToRegistryKey $OfflineRegistryKey $ProfileSpecificBlobEntries $false $ProfileTaskBarDirectory }) { $AllUsersProfilesUpdatedCount++ }
                }
                if (-not $PrimaryUserHasPinList -and $AllUsersProfilesUpdatedCount -gt 0) {
                    foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
                        Write-Console "  [+] $($ReadyEntry.DisplayName)" -Color Cyan
                        $SuccessfullyPinnedCount++
                    }
                }
                Write-Console "  [*] AllUsers : $AllUsersProfilesUpdatedCount profile(s) updated" -Color DarkCyan; Write-Console ""
            }
        }
        #region PIN : QUICK LAUNCH (VISTA)
        if ($TaskbarUsesQuickLaunch) {
            $WshShellForQuickLaunch = $null
            foreach ($QuickLaunchTarget in $ResolvedPinTargets) {
                if ($QuickLaunchTarget.PinType -eq 'UWP') { $FailedPinNames += $QuickLaunchTarget.DisplayName; continue }
                if (-not $QuickLaunchDirectoryExists) { $FailedPinNames += $QuickLaunchTarget.ResolvedPath; continue }
                $Beef001dQuickLaunchRef  = [ref]''
                $QuickLaunchSourcePath   = New-TargetShortcut $QuickLaunchTarget.ResolvedPath $Beef001dQuickLaunchRef ([ref]$WshShellForQuickLaunch)
                $QuickLaunchShortcutName = [IO.Path]::GetFileName($QuickLaunchSourcePath)
                [IO.File]::Copy($QuickLaunchSourcePath, [IO.Path]::Combine($QuickLaunchDirectory, $QuickLaunchShortcutName), $true)
                Write-Console "  [+] $QuickLaunchShortcutName" -Color Cyan
                $SuccessfullyPinnedCount++
            }
            if ($WshShellForQuickLaunch) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($WshShellForQuickLaunch) }
        }
    } finally { Remove-TemporaryShortcuts }
    #region RESULT
    foreach ($FailedPinName in $FailedPinNames) { Write-Console "  [X] $FailedPinName : not pinned" -Color Red }
    if ($FailedPinNames.Count -gt 0) { Write-Banner 'FAIL' 'DarkRed' "$($FailedPinNames.Count) item(s) could not be pinned$(if ($SuccessfullyPinnedCount -gt 0) { ", $SuccessfullyPinnedCount pinned" })$(if ($AllUsers) { ' (AllUsers)' })"; return }
    if ($SuccessfullyPinnedCount -gt 0) { Write-Banner 'OK' 'DarkGreen' "Pinned $SuccessfullyPinnedCount item(s)$(if ($AllUsers) { ' (AllUsers)' })"; return }
    Write-Banner 'FAIL' 'DarkRed' "No items could be pinned"
}
