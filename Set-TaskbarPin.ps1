function Set-TaskbarPin {
    # Version 1.4
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
    $script:SuppressConsoleOutput = $false
    #region ENVIRONMENT
    function Test-RegistrySubKeyExists {
        param($RegistryRootKey, [string]$RegistrySubKeyPath)
        $ProbeHandle = $null
        try { $ProbeHandle = $RegistryRootKey.OpenSubKey($RegistrySubKeyPath, $false) } catch { }
        if ($ProbeHandle) { $ProbeHandle.Close(); return $true }
        return $false
    }
    $RoamingAppDataPath              = [Environment]::GetFolderPath('ApplicationData')
    $TaskBarPinnedDirectory          = [IO.Path]::Combine($RoamingAppDataPath, 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
    $QuickLaunchDirectory            = [IO.Path]::Combine($RoamingAppDataPath, 'Microsoft\Internet Explorer\Quick Launch')
    $TaskBandRegistrySubKey          = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
    $TaskBarRelativeProfilePath      = 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    $QuickLaunchRelativePath         = 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch'
    $DoNotExpandRegistryOption       = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    $BinaryRegistryValueKind         = [Microsoft.Win32.RegistryValueKind]::Binary
    $DwordRegistryValueKind          = [Microsoft.Win32.RegistryValueKind]::DWord
    $CurrentUserSecurityIdentifier   = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    $IsRunningCrossUser         = $false
    $InteractiveUserProfilePath = $null
    $EffectivePrimaryUserSID    = $CurrentUserSecurityIdentifier
    $CurrentProcessSessionId    = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    foreach ($CandidateSidKeyName in [Microsoft.Win32.Registry]::Users.GetSubKeyNames()) {
        if ($CandidateSidKeyName.Length -lt 20 -or $CandidateSidKeyName.EndsWith('_Classes')) { continue }
        if (-not (Test-RegistrySubKeyExists ([Microsoft.Win32.Registry]::Users) "$CandidateSidKeyName\Volatile Environment\$CurrentProcessSessionId")) { continue }
        if ($CandidateSidKeyName -ne $CurrentUserSecurityIdentifier) {
            $IsRunningCrossUser      = $true
            $EffectivePrimaryUserSID = $CandidateSidKeyName
            $ProfileListKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$CandidateSidKeyName")
            if ($ProfileListKey) {
                $InteractiveUserProfilePath = $ProfileListKey.GetValue('ProfileImagePath', ''); $ProfileListKey.Close()
                $TaskBarPinnedDirectory     = [IO.Path]::Combine($InteractiveUserProfilePath, $TaskBarRelativeProfilePath)
                $QuickLaunchDirectory       = [IO.Path]::Combine($InteractiveUserProfilePath, $QuickLaunchRelativePath)
            }
        }
        break
    }
    $TaskBarDirectoryExists     = [IO.Directory]::Exists($TaskBarPinnedDirectory)
    $QuickLaunchDirectoryExists = [IO.Directory]::Exists($QuickLaunchDirectory)
    $TaskBandRegistryKeyExists  = if ($IsRunningCrossUser) { Test-RegistrySubKeyExists ([Microsoft.Win32.Registry]::Users) "$EffectivePrimaryUserSID\$TaskBandRegistrySubKey" } else { Test-RegistrySubKeyExists ([Microsoft.Win32.Registry]::CurrentUser) $TaskBandRegistrySubKey }
    $DirectBlobWriteIsSupported = $TaskBarDirectoryExists -and $TaskBandRegistryKeyExists
    #region CONSOLE
    function Write-Console {
        param([string]$Message, [string]$Color = 'White', [switch]$NoNewline)
        if ($Silent -or $script:SuppressConsoleOutput) { return }
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
    if (-not $Pin) { Write-Console "ERROR : Specify -Pin" -Color Red; return }
    $LiteralSemicolonSentinel = [string][char]1
    $ParsedInputItems = @($Pin.Replace(';;', $LiteralSemicolonSentinel) -split ';' | ForEach-Object { $_.Replace($LiteralSemicolonSentinel, ';').Trim() } | Where-Object { $_ })
    if ($ParsedInputItems.Count -eq 0) { Write-Console "ERROR : Specify -Pin" -Color Red; return }
    $ParsedInputItems = @($ParsedInputItems | ForEach-Object {  if     ($_.StartsWith('uwp:', [StringComparison]::OrdinalIgnoreCase))              { 'shell:AppsFolder\' + $_.Substring(4) }
                                                                elseif ($_.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase)) { 'shell:AppsFolder\' + $_.Substring(17) }
                                                                elseif ($_ -match '!' -and $_ -notmatch '[/\\]')                                   { 'shell:AppsFolder\' + $_ }
                                                                else                                                                               {                       $_ }
    })
    function Test-IsAdmin {
        $CurrentIdentity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)
        return $CurrentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    if ($AllUsers -and -not (Test-IsAdmin)) { Write-Console "ERROR : -AllUsers requires elevation" -Color Red; return }
    #region C# HELPER
    function Initialize-NativeHelper {
        if ('TaskbarPin' -as [Type]) { return }
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public class TaskbarPin {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]static extern IntPtr ILCreateFromPathW(string pszPath);
    [DllImport("shell32.dll")]static extern void ILFree(IntPtr pidl);
    [DllImport("shell32.dll")]static extern IntPtr ILFindLastID(IntPtr pidl);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]static extern int SHParseDisplayName(string pszName, IntPtr pbc, out IntPtr ppidl, uint sfgaoIn, out uint psfgaoOut);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]static extern IntPtr FindWindowEx(IntPtr hWndParent, IntPtr hWndChildAfter, string lpszClass, string lpszWindow);
    [DllImport("user32.dll")]static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("ole32.dll")]static extern int CoCreateInstance(ref Guid rclsid, IntPtr pUnk, uint ctx, ref Guid riid, out IntPtr ppv);
    [DllImport("ole32.dll")]static extern int PropVariantClear(IntPtr pvar);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]static extern IntPtr CreateMutexExW(IntPtr lpMutexAttributes, string lpName, uint dwFlags, uint dwDesiredAccess);
    [DllImport("kernel32.dll", SetLastError = true)]static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]static extern bool ReleaseMutex(IntPtr hMutex);
    [DllImport("kernel32.dll", SetLastError = true)]static extern bool CloseHandle(IntPtr hObject);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint FnRelease(IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnQueryInterface(IntPtr p, ref Guid riid, out IntPtr ppv);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSetIDList(IntPtr p, IntPtr pidl);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSetValue(IntPtr p, IntPtr key, IntPtr propvar);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnCommitStore(IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSaveFile(IntPtr p, IntPtr pszFileName, int fRemember);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnLoadFile(IntPtr p, IntPtr pszFileName, uint dwMode);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnGetValue(IntPtr p, IntPtr key, IntPtr propvar);
    static readonly Guid CLSID_ShellLink = new Guid("00021401-0000-0000-C000-000000000046");
    static readonly Guid IID_IShellLinkW = new Guid("000214F9-0000-0000-C000-000000000046");
    static readonly Guid IID_IPropertyStore = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    static readonly Guid IID_IPersistFile = new Guid("0000010B-0000-0000-C000-000000000046");
    static readonly Guid FMTID_AppUserModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    delegate T StaFunc<T>(); static T RunOnSTA<T>(StaFunc<T> fn) { if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA) return fn(); T r = default(T); Thread t = new Thread(delegate() { r = fn(); }); t.SetApartmentState(ApartmentState.STA); t.Start(); t.Join(); return r; }
    static T Vtbl<T>(IntPtr vtbl, int slot) where T : class { return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vtbl, slot * IntPtr.Size), typeof(T)); }
    static void Release(IntPtr ppv) { Vtbl<FnRelease>(Marshal.ReadIntPtr(ppv), 2)(ppv); }
    static void Release(IntPtr ppv, IntPtr vtbl) { Vtbl<FnRelease>(vtbl, 2)(ppv); }
    static IntPtr ParseDisplayName(string name) { IntPtr pidl; uint sfgao; if (SHParseDisplayName(name, IntPtr.Zero, out pidl, 0, out sfgao) == 0) return pidl; return IntPtr.Zero; }
    static IntPtr AllocPropertyKey() { byte[] pk = new byte[20]; Array.Copy(FMTID_AppUserModel.ToByteArray(), 0, pk, 0, 16); pk[16] = 5; IntPtr ptr = Marshal.AllocCoTaskMem(20); Marshal.Copy(pk, 0, ptr, 20); return ptr; }
    static bool WriteAumidToStore(IntPtr psl, IntPtr vtLink, string aumid) {
        Guid iid = IID_IPropertyStore; IntPtr pps; if (Vtbl<FnQueryInterface>(vtLink, 0)(psl, ref iid, out pps) != 0) return false;
        try {
            IntPtr pkPtr = AllocPropertyKey(); IntPtr pvPtr = Marshal.AllocCoTaskMem(24); for (int i = 0; i < 24; i++) Marshal.WriteByte(pvPtr, i, 0);
            Marshal.WriteInt16(pvPtr, 0, 31); IntPtr strPtr = Marshal.StringToCoTaskMemUni(aumid); Marshal.WriteIntPtr(pvPtr, 8, strPtr);
            try { IntPtr vt = Marshal.ReadIntPtr(pps); Vtbl<FnSetValue>(vt, 6)(pps, pkPtr, pvPtr); Vtbl<FnCommitStore>(vt, 7)(pps); }
            finally { Marshal.FreeCoTaskMem(strPtr); Marshal.FreeCoTaskMem(pvPtr); Marshal.FreeCoTaskMem(pkPtr); }
        } finally { Release(pps); }
        return true;
    }
    static bool PersistSave(IntPtr psl, IntPtr vtLink, string lnkPath) {
        Guid iid = IID_IPersistFile; IntPtr ppf; if (Vtbl<FnQueryInterface>(vtLink, 0)(psl, ref iid, out ppf) != 0) return false;
        try { IntPtr p = Marshal.StringToCoTaskMemUni(lnkPath); try { Vtbl<FnSaveFile>(Marshal.ReadIntPtr(ppf), 6)(ppf, p, 1); } finally { Marshal.FreeCoTaskMem(p); } } finally { Release(ppf); }
        return true;
    }
    static byte[] InjectBeef001D(byte[] item, string displayName) {
        ushort cb = BitConverter.ToUInt16(item, 0); if (cb < 4) return null;
        byte[] nameBytes = System.Text.Encoding.Unicode.GetBytes(displayName + "\0");
        int blockCb = 2 + 2 + 4 + 2 + nameBytes.Length;
        byte[] block = new byte[blockCb];
        Array.Copy(BitConverter.GetBytes((ushort)blockCb), 0, block, 0, 2);
        block[2] = 0; block[3] = 0; block[4] = 0x1D; block[5] = 0x00; block[6] = 0xEF; block[7] = 0xBE; block[8] = 0x02; block[9] = 0x00;
        Array.Copy(nameBytes, 0, block, 10, nameBytes.Length);
        ushort extOffset = BitConverter.ToUInt16(item, cb - 2);
        int insertPos;
        if (extOffset > 4 && extOffset < cb - 4) {
            int epos = extOffset;
            while (epos + 8 <= cb) { ushort ecb = BitConverter.ToUInt16(item, epos); if (ecb < 8 || epos + ecb > cb) break; uint esig = BitConverter.ToUInt32(item, epos + 4); if ((esig & 0xFFFF0000) != 0xBEEF0000) break; epos += ecb; }
            insertPos = epos;
        } else { insertPos = cb - 2; extOffset = (ushort)insertPos; }
        int newCb = insertPos + blockCb + 2;
        byte[] result = new byte[newCb];
        Array.Copy(item, 0, result, 0, insertPos);
        Array.Copy(block, 0, result, insertPos, blockCb);
        Array.Copy(BitConverter.GetBytes(extOffset), 0, result, newCb - 2, 2);
        Array.Copy(BitConverter.GetBytes((ushort)newCb), 0, result, 0, 2);
        return result;
    }
    static byte[] BuildBlobEntry(IntPtr pidl, string beef001dContent) {
        IntPtr lastPtr = ILFindLastID(pidl);
        if (lastPtr == IntPtr.Zero) return null;
        int prefixLen = (int)((long)lastPtr - (long)pidl);
        ushort lastCb = (ushort)Marshal.ReadInt16(lastPtr);
        if (lastCb < 4) return null;
        byte[] lastItem = new byte[lastCb]; Marshal.Copy(lastPtr, lastItem, 0, lastCb);
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
    static byte[] GetBlobEntryInternal(string path, string beef001dContent, bool useFilesystem) {
        IntPtr pidl;
        if (useFilesystem) { pidl = ILCreateFromPathW(path); }
        else { uint sfgao; if (SHParseDisplayName(path, IntPtr.Zero, out pidl, 0, out sfgao) != 0) pidl = IntPtr.Zero; }
        if (pidl == IntPtr.Zero) return null;
        try { return BuildBlobEntry(pidl, beef001dContent); } finally { ILFree(pidl); }
    }
    public static byte[] GetBlobEntryEx(string lnkFullPath, string beef001dContent) { return RunOnSTA<byte[]>(delegate() { return GetBlobEntryInternal(lnkFullPath, beef001dContent, false); }); }
    public static byte[] GetBlobEntryFs(string lnkFullPath, string beef001dContent) { return RunOnSTA<byte[]>(delegate() { return GetBlobEntryInternal(lnkFullPath, beef001dContent, true); }); }
    static bool CreateShortcutFromPidl(IntPtr pidl, string lnkPath, string aumid) {
        Guid cls = CLSID_ShellLink; Guid iid = IID_IShellLinkW; IntPtr psl;
        if (CoCreateInstance(ref cls, IntPtr.Zero, 1, ref iid, out psl) != 0) return false;
        IntPtr vtLink = Marshal.ReadIntPtr(psl);
        try { Vtbl<FnSetIDList>(vtLink, 5)(psl, pidl); if (aumid != null && aumid.Length > 0) WriteAumidToStore(psl, vtLink, aumid); return PersistSave(psl, vtLink, lnkPath); }
        finally { Release(psl, vtLink); }
    }
    public static bool CreatePidlShortcut(string displayName, string lnkPath, string appUserModelId) {
        return RunOnSTA<bool>(delegate() { IntPtr pidl = ParseDisplayName(displayName); if (pidl == IntPtr.Zero) return false; try { return CreateShortcutFromPidl(pidl, lnkPath, appUserModelId); } finally { ILFree(pidl); } });
    }
    public static bool CreateAppShortcut(string aumid, string lnkPath) { return CreatePidlShortcut("shell:AppsFolder\\" + aumid, lnkPath, aumid); }
    public static string GetAumid(string lnkPath) {
        return RunOnSTA<string>(delegate() {
            Guid cls = CLSID_ShellLink; Guid iid = IID_IShellLinkW; IntPtr psl;
            if (CoCreateInstance(ref cls, IntPtr.Zero, 1, ref iid, out psl) != 0) return "";
            IntPtr vtLink = Marshal.ReadIntPtr(psl);
            try {
                FnQueryInterface qi = Vtbl<FnQueryInterface>(vtLink, 0);
                Guid iidFile = IID_IPersistFile; IntPtr ppf;
                if (qi(psl, ref iidFile, out ppf) != 0) return "";
                try { IntPtr p = Marshal.StringToCoTaskMemUni(lnkPath); try { if (Vtbl<FnLoadFile>(Marshal.ReadIntPtr(ppf), 5)(ppf, p, 0) != 0) return ""; } finally { Marshal.FreeCoTaskMem(p); } } finally { Release(ppf); }
                Guid iidStore = IID_IPropertyStore; IntPtr pps;
                if (qi(psl, ref iidStore, out pps) != 0) return "";
                try {
                    IntPtr pkPtr = AllocPropertyKey(); IntPtr pvPtr = Marshal.AllocCoTaskMem(24); for (int i = 0; i < 24; i++) Marshal.WriteByte(pvPtr, i, 0);
                    try { if (Vtbl<FnGetValue>(Marshal.ReadIntPtr(pps), 5)(pps, pkPtr, pvPtr) != 0) return ""; short vt = Marshal.ReadInt16(pvPtr); if (vt != 31) return ""; IntPtr sp = Marshal.ReadIntPtr(pvPtr, 8); if (sp == IntPtr.Zero) return ""; return Marshal.PtrToStringUni(sp) ?? ""; }
                    finally { PropVariantClear(pvPtr); Marshal.FreeCoTaskMem(pvPtr); Marshal.FreeCoTaskMem(pkPtr); }
                } finally { Release(pps); }
            } finally { Release(psl, vtLink); }
        });
    }
    public static void SendPinNotify() {
        IntPtr trayWindow = FindWindow("Shell_TrayWnd", null);
        IntPtr reBarWindow = FindWindowEx(trayWindow, IntPtr.Zero, "ReBarWindow32", null);
        IntPtr pinnedItemsBand = FindWindowEx(reBarWindow, IntPtr.Zero, "MSTaskSwWClass", null);
        if (pinnedItemsBand != IntPtr.Zero) { PostMessage(pinnedItemsBand, 0x446, IntPtr.Zero, IntPtr.Zero); }
    }
    static IntPtr _mutexHandle = IntPtr.Zero;
    public static bool AcquirePinMutex(int timeoutMs) {
        IntPtr h = CreateMutexExW(IntPtr.Zero, "TaskbarPinListMutex", 0, 0x001F0001); if (h == IntPtr.Zero) return false;
        uint r = WaitForSingleObject(h, (uint)timeoutMs);
        if (r == 0 || r == 0x80) { _mutexHandle = h; return true; } CloseHandle(h); return false;
    }
    public static void ReleasePinMutex() { if (_mutexHandle != IntPtr.Zero) { ReleaseMutex(_mutexHandle); CloseHandle(_mutexHandle); _mutexHandle = IntPtr.Zero; } }
    public static int FindBlobEntry(byte[] blob, string filename) {
        byte[] needle = System.Text.Encoding.Unicode.GetBytes(filename); int pos = 0; int idx = 0;
        while (pos < blob.Length && blob[pos] != 0xFF) {
            if (pos + 5 > blob.Length) break; uint pidlSize = BitConverter.ToUInt32(blob, pos + 1);
            int pidlStart = pos + 5; int pidlEnd = pidlStart + (int)pidlSize; if (pidlEnd > blob.Length) break;
            for (int b = pidlStart; b + needle.Length <= pidlEnd; b++) { bool match = true; for (int c = 0; c < needle.Length; c++) { if (blob[b + c] != needle[c]) { match = false; break; } } if (match) return idx; }
            pos = pidlEnd; idx++;
        } return -1;
    }
    public static byte[] RemoveFavEntry(byte[] blob, int removeIdx) {
        System.IO.MemoryStream ms = new System.IO.MemoryStream(); int pos = 0; int idx = 0;
        while (pos < blob.Length && blob[pos] != 0xFF) { if (pos + 5 > blob.Length) break; uint pidlSize = BitConverter.ToUInt32(blob, pos + 1); int total = 1 + 4 + (int)pidlSize; if (pos + total > blob.Length) break; if (idx != removeIdx) ms.Write(blob, pos, total); pos += total; idx++; }
        ms.WriteByte(0xFF); return ms.ToArray();
    }
    public static byte[] RemoveResEntry(byte[] blob, int removeIdx) {
        System.IO.MemoryStream ms = new System.IO.MemoryStream(); int pos = 0; int idx = 0;
        while (pos + 4 <= blob.Length) { uint linkSize = BitConverter.ToUInt32(blob, pos); if (linkSize == 0 || pos + 4 + (int)linkSize > blob.Length) break; int total = 4 + (int)linkSize; if (idx != removeIdx) ms.Write(blob, pos, total); pos += total; idx++; }
        return ms.ToArray();
    }
    static string ReadAnsiZ(byte[] d, int pos) { int end = pos; while (end < d.Length && d[end] != 0) end++; return System.Text.Encoding.Default.GetString(d, pos, end - pos); }
    static string ReadUniZ(byte[] d, int pos) { int end = pos; while (end + 1 < d.Length && (d[end] != 0 || d[end + 1] != 0)) end += 2; return System.Text.Encoding.Unicode.GetString(d, pos, end - pos); }
    static string ReadStoreAumid(byte[] d, int pos, int end) {
        byte[] fmtid = FMTID_AppUserModel.ToByteArray();
        while (pos + 28 <= end) {
            uint storageSize = BitConverter.ToUInt32(d, pos); if (storageSize == 0 || pos + storageSize > end) break;
            bool fmtidMatch = true; for (int i = 0; i < 16; i++) { if (d[pos + 8 + i] != fmtid[i]) { fmtidMatch = false; break; } }
            if (fmtidMatch) {
                int vpos = pos + 24; int vend = pos + (int)storageSize;
                while (vpos + 13 <= vend) {
                    uint valueSize = BitConverter.ToUInt32(d, vpos); if (valueSize == 0 || vpos + valueSize > vend) break;
                    uint propId = BitConverter.ToUInt32(d, vpos + 4); ushort vt = BitConverter.ToUInt16(d, vpos + 9);
                    if (propId == 5 && vt == 0x1F && vpos + 17 <= vend) return ReadUniZ(d, vpos + 17);
                    vpos += (int)valueSize;
                }
            }
            pos += (int)storageSize;
        }
        return "";
    }
    static void ParseLnk(byte[] d, string lnkDirectory, out string target, out string aumid) {
        target = ""; aumid = "";
        if (d.Length < 0x4C || BitConverter.ToInt32(d, 0) != 0x4C) return;
        uint flags = BitConverter.ToUInt32(d, 20);
        int pos = 0x4C;
        if ((flags & 0x01) != 0) { if (pos + 2 > d.Length) return; pos += 2 + BitConverter.ToUInt16(d, pos); }
        if ((flags & 0x02) != 0 && pos + 36 <= d.Length) {
            int li = pos;
            uint liSize = BitConverter.ToUInt32(d, li); uint liHead = BitConverter.ToUInt32(d, li + 4); uint liFlags = BitConverter.ToUInt32(d, li + 8);
            if ((liFlags & 0x01) != 0) {
                if (liHead >= 0x24) { target = ReadUniZ(d, li + (int)BitConverter.ToUInt32(d, li + 28)) + ReadUniZ(d, li + (int)BitConverter.ToUInt32(d, li + 32)); }
                else { target = ReadAnsiZ(d, li + (int)BitConverter.ToUInt32(d, li + 16)) + ReadAnsiZ(d, li + (int)BitConverter.ToUInt32(d, li + 24)); }
            }
            pos = li + (int)liSize;
        }
        bool isUnicode = (flags & 0x80) != 0;
        string relativePath = "";
        uint[] stringDataFlags = new uint[] { 0x04, 0x08, 0x10, 0x20, 0x40 };
        for (int i = 0; i < stringDataFlags.Length; i++) {
            if ((flags & stringDataFlags[i]) == 0) continue;
            if (pos + 2 > d.Length) return;
            int charCount = BitConverter.ToUInt16(d, pos); int byteCount = charCount * (isUnicode ? 2 : 1);
            if (pos + 2 + byteCount > d.Length) return;
            if (stringDataFlags[i] == 0x08) { relativePath = isUnicode ? System.Text.Encoding.Unicode.GetString(d, pos + 2, byteCount) : System.Text.Encoding.Default.GetString(d, pos + 2, byteCount); }
            pos += 2 + byteCount;
        }
        while (pos + 8 <= d.Length) {
            uint blockSize = BitConverter.ToUInt32(d, pos); if (blockSize < 8 || pos + blockSize > d.Length) break;
            uint blockSig = BitConverter.ToUInt32(d, pos + 4);
            if (blockSig == 0xA0000001 && target.Length == 0 && blockSize >= 8 + 260 + 520) {
                string envTarget = ReadUniZ(d, pos + 8 + 260); if (envTarget.Length == 0) envTarget = ReadAnsiZ(d, pos + 8);
                if (envTarget.Length > 0) target = Environment.ExpandEnvironmentVariables(envTarget);
            }
            if (blockSig == 0xA0000009 && aumid.Length == 0) { aumid = ReadStoreAumid(d, pos + 8, pos + (int)blockSize); }
            pos += (int)blockSize;
        }
        if (target.Length == 0 && relativePath.Length > 0 && lnkDirectory.Length > 0) { try { target = System.IO.Path.GetFullPath(System.IO.Path.Combine(lnkDirectory, relativePath)); } catch { } }
    }
    public static LnkEntry[] GetLnkCatalog(string directory, bool recurse, int rank) {
        string[] files;
        try { files = System.IO.Directory.GetFiles(directory, "*.lnk", recurse ? System.IO.SearchOption.AllDirectories : System.IO.SearchOption.TopDirectoryOnly); } catch { return new LnkEntry[0]; }
        LnkEntry[] entries = new LnkEntry[files.Length];
        for (int i = 0; i < files.Length; i++) {
            LnkEntry entry = new LnkEntry(); entry.LnkPath = files[i]; entry.DisplayName = System.IO.Path.GetFileNameWithoutExtension(files[i]); entry.Rank = rank;
            string target = ""; string aumid = "";
            try { byte[] d = System.IO.File.ReadAllBytes(files[i]); ParseLnk(d, System.IO.Path.GetDirectoryName(files[i]), out target, out aumid); } catch { }
            entry.TargetPath = target; entry.Aumid = aumid; entries[i] = entry;
        }
        return entries;
    }
}
public class LnkEntry { public string LnkPath; public string DisplayName; public string TargetPath; public string Aumid; public int Rank; }
'@
    }
    function Open-EffectiveTaskbandKey {
        param([bool]$Writable = $false)
        if ($IsRunningCrossUser) { return [Microsoft.Win32.Registry]::Users.OpenSubKey("$EffectivePrimaryUserSID\$TaskBandRegistrySubKey", $Writable) }
        return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($TaskBandRegistrySubKey, $Writable)
    }
    #region HELPER FUNCTIONS
    function Resolve-CplControlPanelItem {
        param([string]$CplFilePath)
        $CplFileName = [IO.Path]::GetFileName($CplFilePath).ToLower()
        $CplBaseName = [IO.Path]::GetFileNameWithoutExtension($CplFilePath).ToLower()
        $CplShellApp = New-Object -ComObject Shell.Application
        $CplNamespace = $CplShellApp.Namespace('shell:ControlPanelFolder')
        $MatchedResult = $null
        foreach ($ControlPanelItem in $CplNamespace.Items()) {
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
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($CplNamespace)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($CplShellApp)
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
            foreach ($PathEntry in ($env:PATH -split ';')) { if ($PathEntry -and [IO.Directory]::Exists($PathEntry)) { $DirectoriesToSearch += $PathEntry } }
            $PatternsToTry = @($FileNamePattern)
            if (-not $InputContainsWildcard -and -not [IO.Path]::HasExtension($FileNamePattern)) {
                foreach ($ExecutableExtension in ($env:PATHEXT -split ';')) { $PatternsToTry += "$FileNamePattern$ExecutableExtension" }
                $PatternsToTry += "$FileNamePattern.lnk"
            }
            foreach ($SearchDirectory in $DirectoriesToSearch) {
                foreach ($SearchPattern in $PatternsToTry) {
                    try { $FoundFiles = @([IO.Directory]::GetFiles($SearchDirectory, $SearchPattern)); if ($FoundFiles.Count -gt 0) { return $FoundFiles } } catch { }
                }
            }
        }
        return
    }
    $script:AppsFolderSnapshot = $null
    function Get-AppsFolderSnapshot {
        if ($null -ne $script:AppsFolderSnapshot) { return $script:AppsFolderSnapshot }
        $CollectedApplicationEntries = New-Object System.Collections.ArrayList
        try {
            $ShellApplicationForAppsFolder = New-Object -ComObject Shell.Application
            $ApplicationsNamespace         = $ShellApplicationForAppsFolder.Namespace('shell:AppsFolder')
            foreach ($ApplicationItem in $ApplicationsNamespace.Items()) {
                $ApplicationTargetParsingPath = ''
                try { $ApplicationTargetParsingPath = [string]$ApplicationItem.ExtendedProperty('System.Link.TargetParsingPath') } catch { }
                [void]$CollectedApplicationEntries.Add(@{ Aumid = $ApplicationItem.Path; DisplayName = $ApplicationItem.Name; TargetParsingPath = $ApplicationTargetParsingPath })
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ApplicationItem)
            }
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ApplicationsNamespace)
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ShellApplicationForAppsFolder)
        } catch { }
        $script:AppsFolderSnapshot = @($CollectedApplicationEntries.ToArray())
        return $script:AppsFolderSnapshot
    }
    $script:ShortcutCatalog = $null
    function Get-ShortcutCatalog {
        if ($null -ne $script:ShortcutCatalog) { return $script:ShortcutCatalog }
        Initialize-NativeHelper
        $PrimaryUserProgramsDirectory = if ($IsRunningCrossUser -and $InteractiveUserProfilePath) { [IO.Path]::Combine($InteractiveUserProfilePath, 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs') } else { [Environment]::GetFolderPath('Programs') }
        $ShortcutSearchRoots = @(
            @{ Directory = [Environment]::GetFolderPath('CommonPrograms'); Rank = 1; Recurse = $true },
            @{ Directory = $PrimaryUserProgramsDirectory;                  Rank = 1; Recurse = $true },
            @{ Directory = $QuickLaunchDirectory;                          Rank = 2; Recurse = $false }
        )
        if ($AllUsers) {
            foreach ($UserProfile in @(Get-UserProfiles)) {
                $ShortcutSearchRoots += @{ Directory = [IO.Path]::Combine($UserProfile.ProfilePath, 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs'); Rank = 1; Recurse = $true }
                $ShortcutSearchRoots += @{ Directory = [IO.Path]::Combine($UserProfile.ProfilePath, $QuickLaunchRelativePath);                                Rank = 2; Recurse = $false }
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
        $PatternHasWildcard    = $NameOrAumidPattern -match '[*?]'
        $EffectiveMatchPattern = if ($PatternHasWildcard) { $NameOrAumidPattern } else { "*$NameOrAumidPattern*" }
        $MatchedApplications   = @()
        $AlreadyMatchedAumids  = @{}
        $AlreadyMatchedTargets = @{}
        foreach ($ApplicationEntry in (Get-AppsFolderSnapshot)) {
            if ($ApplicationEntry.DisplayName -like $EffectiveMatchPattern -or $ApplicationEntry.Aumid -like $EffectiveMatchPattern) {
                $MatchedApplications += @{ Kind = 'Aumid'; Aumid = $ApplicationEntry.Aumid; DisplayName = $ApplicationEntry.DisplayName }
                $AlreadyMatchedAumids[$ApplicationEntry.Aumid] = $true
                if ($ApplicationEntry.TargetParsingPath) { $AlreadyMatchedTargets[$ApplicationEntry.TargetParsingPath.ToLower()] = $true }
            }
        }
        if (-not $PatternHasWildcard -and $MatchedApplications.Count -gt 0) { return $MatchedApplications }
        foreach ($CatalogRank in 1, 2) {
            foreach ($ShortcutEntry in (Get-ShortcutCatalog)) {
                if ($ShortcutEntry.Rank -ne $CatalogRank -or $ShortcutEntry.DisplayName -notlike $EffectiveMatchPattern) { continue }
                if ($ShortcutEntry.TargetPath -and $AlreadyMatchedTargets.ContainsKey($ShortcutEntry.TargetPath.ToLower())) { continue }
                if ($ShortcutEntry.Aumid -and $AlreadyMatchedAumids.ContainsKey($ShortcutEntry.Aumid)) { continue }
                $MatchedApplications += @{ Kind = 'Lnk'; LnkPath = $ShortcutEntry.LnkPath; DisplayName = $ShortcutEntry.DisplayName }
                if ($ShortcutEntry.Aumid) { $AlreadyMatchedAumids[$ShortcutEntry.Aumid] = $true }
                if ($ShortcutEntry.TargetPath) { $AlreadyMatchedTargets[$ShortcutEntry.TargetPath.ToLower()] = $true }
            }
            if (-not $PatternHasWildcard -and $MatchedApplications.Count -gt 0) { return $MatchedApplications }
        }
        return $MatchedApplications
    }
    function New-TargetShortcut {
        param([string]$ResolvedTargetPath, [ref]$Beef001dContentRef, [ref]$WshShellComObjectRef)
        $TargetFileExtension = [IO.Path]::GetExtension($ResolvedTargetPath).ToLower()
        if ($TargetFileExtension -eq '.lnk') {
            if (-not $WshShellComObjectRef.Value) { $WshShellComObjectRef.Value = New-Object -ComObject WScript.Shell }
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
                $SafeCplDisplayName       = $CplControlPanelMatch.Name -replace '[<>:"/\\|?*]', '_'
                $CplTemporaryLnkPath      = [IO.Path]::Combine($env:TEMP, "$SafeCplDisplayName.lnk")
                if ([TaskbarPin]::CreatePidlShortcut($CplControlPanelMatch.Path, $CplTemporaryLnkPath, $CplControlPanelMatch.Path)) {
                    $Beef001dContentRef.Value = $CplControlPanelMatch.Path
                    return $CplTemporaryLnkPath
                }
            }
            Write-Console "  [!] CPL not found in Control Panel namespace, fallback to filesystem shortcut" -Color Yellow
        }
        $ShortcutDisplayName = [IO.Path]::GetFileNameWithoutExtension($ResolvedTargetPath)
        if ($TargetFileExtension -eq '.exe') {
            try { $FileVersionDescription = [Diagnostics.FileVersionInfo]::GetVersionInfo($ResolvedTargetPath).FileDescription; if ($FileVersionDescription -and $FileVersionDescription.Trim()) { $CandidateDisplayName = ($FileVersionDescription.Trim() -replace '[<>:"/\\|?*]', '_'); if (-not [IO.File]::Exists([IO.Path]::Combine($TaskBarPinnedDirectory, "$CandidateDisplayName.lnk"))) { $ShortcutDisplayName = $CandidateDisplayName } } } catch { }
        }
        $TemporaryLnkPath = [IO.Path]::Combine($env:TEMP, "$ShortcutDisplayName.lnk")
        if (-not $WshShellComObjectRef.Value) { $WshShellComObjectRef.Value = New-Object -ComObject WScript.Shell }
        $NewShortcutObject = $WshShellComObjectRef.Value.CreateShortcut($TemporaryLnkPath)
        if ([IO.Directory]::Exists($ResolvedTargetPath)) {
            $NewShortcutObject.TargetPath        = [IO.Path]::Combine($env:SystemRoot, 'explorer.exe')
            $NewShortcutObject.Arguments         = "`"$ResolvedTargetPath`""
            $NewShortcutObject.IconLocation      = [IO.Path]::Combine($env:SystemRoot, 'System32\shell32.dll') + ',3'
            $NewShortcutObject.WorkingDirectory  = $ResolvedTargetPath
        } elseif ($TargetFileExtension -eq '.cpl') {
            $NewShortcutObject.TargetPath        = [IO.Path]::Combine($env:SystemRoot, 'System32\rundll32.exe')
            $NewShortcutObject.Arguments         = "shell32.dll,Control_RunDLL `"$ResolvedTargetPath`""
            $NewShortcutObject.IconLocation      = "$ResolvedTargetPath,0"
            $NewShortcutObject.WorkingDirectory  = [IO.Path]::GetDirectoryName($ResolvedTargetPath)
        } else {
            $NewShortcutObject.TargetPath        = $ResolvedTargetPath
            $NewShortcutObject.WorkingDirectory  = [IO.Path]::GetDirectoryName($ResolvedTargetPath)
        }
        $Beef001dContentRef.Value = $ResolvedTargetPath
        $NewShortcutObject.Save()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($NewShortcutObject)
        return $TemporaryLnkPath
    }
    function Write-BlobToRegistryKey {
        param($RegistryKeyHandle, [byte[]]$ExistingFavoritesBlob, $NewBlobEntriesToAdd)
        if (-not $ExistingFavoritesBlob -or $ExistingFavoritesBlob.Length -lt 2) { $ExistingFavoritesBlob = [byte[]]@(0xFF) }
        $BlobInsertionOffset = 0
        while ($BlobInsertionOffset -lt $ExistingFavoritesBlob.Length -and $ExistingFavoritesBlob[$BlobInsertionOffset] -ne 0xFF) {
            if ($BlobInsertionOffset + 5 -gt $ExistingFavoritesBlob.Length) { break }
            $CurrentEntryPidlSize = [BitConverter]::ToUInt32($ExistingFavoritesBlob, $BlobInsertionOffset + 1)
            $BlobInsertionOffset += 1 + 4 + $CurrentEntryPidlSize
        }
        $OutputBlobStream = New-Object System.IO.MemoryStream
        if ($BlobInsertionOffset -gt 0) { $OutputBlobStream.Write($ExistingFavoritesBlob, 0, $BlobInsertionOffset) }
        $NumberOfEntriesActuallyAdded = 0
        foreach ($NewEntry in $NewBlobEntriesToAdd) {
            $ShortcutFileName = [IO.Path]::GetFileName($NewEntry.DestinationLnkPath)
            if ([TaskbarPin]::FindBlobEntry($ExistingFavoritesBlob, $ShortcutFileName) -ge 0) { Write-Console "  [skip] '$ShortcutFileName' already in blob" -Color Yellow; continue }
            $OutputBlobStream.Write($NewEntry.SerializedBlobEntry, 0, $NewEntry.SerializedBlobEntry.Length)
            $NumberOfEntriesActuallyAdded++
        }
        $OutputBlobStream.WriteByte(0xFF)
        $FinalBlobBytes = $OutputBlobStream.ToArray(); $OutputBlobStream.Dispose()
        if ($NumberOfEntriesActuallyAdded -eq 0) { return 0 }
        $CurrentFavoritesChangesCounter = [int]$RegistryKeyHandle.GetValue('FavoritesChanges', 0, $DoNotExpandRegistryOption)
        $RegistryKeyHandle.SetValue('Favorites',        $FinalBlobBytes,                       $BinaryRegistryValueKind)
        $RegistryKeyHandle.SetValue('FavoritesVersion',  3,                                    $DwordRegistryValueKind)
        $RegistryKeyHandle.SetValue('FavoritesChanges', ($CurrentFavoritesChangesCounter + 1), $DwordRegistryValueKind)
        return $NumberOfEntriesActuallyAdded
    }
    function Get-UserProfiles {
        $ProfileListRegistryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList')
        if (-not $ProfileListRegistryKey) { return @() }
        $DiscoveredProfiles = @()
        foreach ($ProfileSid in $ProfileListRegistryKey.GetSubKeyNames()) {
            if ($ProfileSid.Length -lt 20 -or $ProfileSid -eq $EffectivePrimaryUserSID) { continue }
            $ProfileSubKey = $ProfileListRegistryKey.OpenSubKey($ProfileSid)
            if (-not $ProfileSubKey) { continue }
            $ProfileImagePath = $ProfileSubKey.GetValue('ProfileImagePath', ''); $ProfileSubKey.Close()
            if (-not $ProfileImagePath -or -not [IO.Directory]::Exists($ProfileImagePath)) { continue }
            $ProfileFolderName = [IO.Path]::GetFileName($ProfileImagePath).ToLower()
            if ($ProfileFolderName -eq 'systemprofile' -or $ProfileFolderName -eq 'localservice' -or $ProfileFolderName -eq 'networkservice') { continue }
            $DiscoveredProfiles += @{ SID = $ProfileSid; ProfilePath = $ProfileImagePath }
        }
        $ProfileListRegistryKey.Close()
        if ([IO.File]::Exists([IO.Path]::Combine($env:SystemDrive, 'Users\Default\NTUSER.DAT'))) {
            $DiscoveredProfiles += @{ SID = 'Default'; ProfilePath = [IO.Path]::Combine($env:SystemDrive, 'Users\Default') }
        }
        return $DiscoveredProfiles
    }
    function Invoke-RegistryExecutable {
        param([string]$ArgumentLine)
        $RegProcessStartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $RegProcessStartInfo.FileName = 'reg.exe'; $RegProcessStartInfo.Arguments = $ArgumentLine
        $RegProcessStartInfo.UseShellExecute = $false; $RegProcessStartInfo.CreateNoWindow = $true; $RegProcessStartInfo.RedirectStandardError = $true
        $RegProcess = [System.Diagnostics.Process]::Start($RegProcessStartInfo); $null = $RegProcess.WaitForExit(10000)
        return $RegProcess.ExitCode
    }
    function Invoke-WithOfflineHive {
        param([string]$ProfileSID, [string]$ProfileDirectoryPath, [scriptblock]$ActionToPerform)
        $NtUserDatFilePath = [IO.Path]::Combine($ProfileDirectoryPath, 'NTUSER.DAT')
        if (-not [IO.File]::Exists($NtUserDatFilePath)) { return $false }
        $LoadedHiveRegistryPath = $null; $HiveRequiresUnload = $false
        if ($ProfileSID -ne 'Default' -and (Test-RegistrySubKeyExists ([Microsoft.Win32.Registry]::Users) "$ProfileSID\$TaskBandRegistrySubKey")) { $LoadedHiveRegistryPath = $ProfileSID }
        if (-not $LoadedHiveRegistryPath) {
            $TemporaryHiveName = "TempPin_$($ProfileSID.Replace('-','').Substring(0, [Math]::Min(12, $ProfileSID.Replace('-','').Length)))"
            if ((Invoke-RegistryExecutable "load `"HKU\$TemporaryHiveName`" `"$NtUserDatFilePath`"") -ne 0) { return $false }
            $LoadedHiveRegistryPath = $TemporaryHiveName; $HiveRequiresUnload = $true
        }
        try {
            $TaskBandKeyHandle = [Microsoft.Win32.Registry]::Users.OpenSubKey("$LoadedHiveRegistryPath\$TaskBandRegistrySubKey", $true)
            if (-not $TaskBandKeyHandle) { $TaskBandKeyHandle = [Microsoft.Win32.Registry]::Users.CreateSubKey("$LoadedHiveRegistryPath\$TaskBandRegistrySubKey") }
            if ($TaskBandKeyHandle) { try { & $ActionToPerform $TaskBandKeyHandle } finally { $TaskBandKeyHandle.Close() } }
        } finally {
            if ($HiveRequiresUnload) {
                [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 200
                $null = Invoke-RegistryExecutable "unload `"HKU\$TemporaryHiveName`""
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
                if ($PatternMatched) { $MatchedShortcutPaths += $PinnedShortcutEntry.LnkPath; break }
            }
        }
        return $MatchedShortcutPaths
    }
    function Invoke-UnpinFromBlob {
        param($RegistryKeyHandle, [string[]]$ShortcutFilenamesToRemove)
        $FavoritesBlob        = $RegistryKeyHandle.GetValue('Favorites', $null, $DoNotExpandRegistryOption)
        $FavoritesResolveBlob = $RegistryKeyHandle.GetValue('FavoritesResolve', $null, $DoNotExpandRegistryOption)
        if (-not $FavoritesBlob -or $FavoritesBlob.Length -lt 6) { return }
        $EntriesToRemove = @()
        foreach ($ShortcutFilename in $ShortcutFilenamesToRemove) {
            $FoundBlobIndex = [TaskbarPin]::FindBlobEntry($FavoritesBlob, $ShortcutFilename)
            if ($FoundBlobIndex -ge 0) { $EntriesToRemove += @{ Name = $ShortcutFilename; Index = $FoundBlobIndex } }
        }
        foreach ($EntryToRemove in @($EntriesToRemove | Sort-Object { $_.Index } -Descending)) {
            $FavoritesBlob = [TaskbarPin]::RemoveFavEntry($FavoritesBlob, $EntryToRemove.Index)
            if ($FavoritesResolveBlob) { $FavoritesResolveBlob = [TaskbarPin]::RemoveResEntry($FavoritesResolveBlob, $EntryToRemove.Index) }
        }
        if ($EntriesToRemove.Count -gt 0) {
            $CurrentFavoritesChanges = [int]$RegistryKeyHandle.GetValue('FavoritesChanges', 0, $DoNotExpandRegistryOption)
            $RegistryKeyHandle.SetValue('Favorites', ([byte[]]$FavoritesBlob), $BinaryRegistryValueKind)
            if ($FavoritesResolveBlob) { $RegistryKeyHandle.SetValue('FavoritesResolve', ([byte[]]$FavoritesResolveBlob), $BinaryRegistryValueKind) }
            $RegistryKeyHandle.SetValue('FavoritesVersion',  3,                                $DwordRegistryValueKind)
            $RegistryKeyHandle.SetValue('FavoritesChanges', ($CurrentFavoritesChanges + 1),    $DwordRegistryValueKind)
        }
        return $EntriesToRemove.Count
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
                        Initialize-NativeHelper
                        $CplMatch = Resolve-CplControlPanelItem $ResolvedCplPath
                        if ($CplMatch) { $CplResolvedPattern = $CplMatch.Name -replace '[<>:"/\\|?*]', '_'; break }
                    }
                }
                if ($CplResolvedPattern) { $UnpinMatchPatterns += $CplResolvedPattern }
                else { $UnpinMatchPatterns += [IO.Path]::GetFileNameWithoutExtension($InputItem) }
            } else {
                # Baseline pattern : same behavior as before so explicit and wildcard patterns keep working.
                if (($InputItem -match '[/\\]' -and -not $InputHasWildcard) -or $InputExtension -eq '.msc' -or $InputExtension -eq '.exe') { $UnpinMatchPatterns += [IO.Path]::GetFileNameWithoutExtension($InputItem) }
                else { $UnpinMatchPatterns += $InputItem }
                # Mirror the pin resolution : a pinned shortcut may carry the basename of a file
                # the input resolved to (wildcard expansion included), or the display name and
                # AUMID of the application identity an executable or a bare name was pinned
                # under. AUMID-based shortcuts have no target path, so without these patterns
                # they can never be matched back from the original input.
                $ResolvedUnpinPaths = @(Resolve-FilesystemInput $InputItem)
                if ($ResolvedUnpinPaths.Count -gt 0) {
                    foreach ($ResolvedUnpinPath in $ResolvedUnpinPaths) {
                        $UnpinMatchPatterns += [IO.Path]::GetFileNameWithoutExtension($ResolvedUnpinPath)
                        if ([IO.Path]::GetExtension($ResolvedUnpinPath).ToLower() -eq '.exe') {
                            $UnpinExecutableIdentity = Resolve-ExecutableIdentity $ResolvedUnpinPath
                            if ($UnpinExecutableIdentity) {
                                $UnpinMatchPatterns += ($UnpinExecutableIdentity.DisplayName -replace '[<>:"/\\|?*]', '_')
                                $UnpinMatchPatterns += $UnpinExecutableIdentity.Aumid
                            }
                        }
                    }
                } elseif ($InputItem -notmatch '[/\\]') {
                    foreach ($UnpinApplicationMatch in @(Find-ApplicationMatches $InputItem)) {
                        $UnpinMatchPatterns += ($UnpinApplicationMatch.DisplayName -replace '[<>:"/\\|?*]', '_')
                        if ($UnpinApplicationMatch.Kind -eq 'Aumid') { $UnpinMatchPatterns += $UnpinApplicationMatch.Aumid }
                    }
                }
            }
        }
        $UnpinMatchPatterns = @($UnpinMatchPatterns | Where-Object { $_ } | Select-Object -Unique)
        $DisplayPatternLabel = $UnpinMatchPatterns -join ', '
        Write-Banner 'UNPIN' 'DarkRed' "$DisplayPatternLabel$(if ($AllUsers) { ' (AllUsers)' })"
        Initialize-NativeHelper
        $PinnedDirectoriesToScan = @()
        if ($TaskBarDirectoryExists)     { $PinnedDirectoriesToScan += $TaskBarPinnedDirectory }
        if ($QuickLaunchDirectoryExists) { $PinnedDirectoriesToScan += $QuickLaunchDirectory }
        if ($PinnedDirectoriesToScan.Count -eq 0 -and -not $AllUsers) { Write-Console "  [!] No pin locations found" -Color Yellow; return }
        $MatchedShortcutPaths = @()
        foreach ($DirectoryToScan in $PinnedDirectoriesToScan) { $MatchedShortcutPaths += @(Find-MatchingPins $DirectoryToScan $UnpinMatchPatterns) }
        if ($MatchedShortcutPaths.Count -eq 0 -and -not $AllUsers) { Write-Console "  [!] No pinned items match" -Color Yellow; Write-Console ""; return }
        if ($MatchedShortcutPaths.Count -gt 0 -and $TaskBandRegistryKeyExists) {
            $MutexWasAcquired = [TaskbarPin]::AcquirePinMutex(5000)
            try {
                $TaskBandRegistryKey = Open-EffectiveTaskbandKey $true
                if ($TaskBandRegistryKey) {
                    try { $null = Invoke-UnpinFromBlob $TaskBandRegistryKey @($MatchedShortcutPaths | ForEach-Object { [IO.Path]::GetFileName($_) }) }
                    finally { $TaskBandRegistryKey.Close() }
                }
            } finally { if ($MutexWasAcquired) { [TaskbarPin]::ReleasePinMutex() } }
        }
        foreach ($ShortcutPath in $MatchedShortcutPaths) { if ([IO.File]::Exists($ShortcutPath)) { try { [IO.File]::Delete($ShortcutPath) } catch { } } }
        if ($MatchedShortcutPaths.Count -gt 0) { [TaskbarPin]::SendPinNotify() }
        if ($AllUsers) {
            foreach ($UserProfile in @(Get-UserProfiles)) {
                $ProfileTaskBarDirectory = [IO.Path]::Combine($UserProfile.ProfilePath, $TaskBarRelativeProfilePath)
                $ProfileMatchedShortcuts = @()
                if ([IO.Directory]::Exists($ProfileTaskBarDirectory)) { $ProfileMatchedShortcuts = @(Find-MatchingPins $ProfileTaskBarDirectory $UnpinMatchPatterns) }
                if ($ProfileMatchedShortcuts.Count -eq 0) { continue }
                $ProfileShortcutFilenames = @($ProfileMatchedShortcuts | ForEach-Object { [IO.Path]::GetFileName($_) })
                $null = Invoke-WithOfflineHive $UserProfile.SID $UserProfile.ProfilePath { param($OfflineRegistryKey); $null = Invoke-UnpinFromBlob $OfflineRegistryKey $ProfileShortcutFilenames }
                foreach ($ProfileShortcutPath in $ProfileMatchedShortcuts) { if ([IO.File]::Exists($ProfileShortcutPath)) { try { [IO.File]::Delete($ProfileShortcutPath) } catch { } } }
            }
        }
        foreach ($UnpinnedPath in $MatchedShortcutPaths) { Write-Console "  [-] $([IO.Path]::GetFileName($UnpinnedPath))" -Color Cyan }
        Write-Banner 'OK' 'DarkGreen' "Unpinned $($MatchedShortcutPaths.Count) item(s)$(if ($AllUsers) { ' (AllUsers)' })"
        return
    }
    #region PIN : RESOLVE INPUT
    Write-Banner 'PIN' 'DarkBlue' "$Pin$(if ($AllUsers) { ' (AllUsers)' })"
    $UwpInputItems        = @($ParsedInputItems | Where-Object {     $_.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase) })
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
    #region PIN : BLOB INJECTION
    $SuccessfullyPinnedCount      = 0
    $BlobEntriesReadyForInjection = @()
    $ItemsDeferredToQuickLaunch   = @()
    if ($DirectBlobWriteIsSupported) {
        Write-Console "  [>] Preparing blob entries ($($ResolvedPinTargets.Count) item(s))..." -Color DarkGray -NoNewline
        $script:SuppressConsoleOutput = $true
        Initialize-NativeHelper
        $WshShellForPinCreation = $null
        foreach ($PinTarget in $ResolvedPinTargets) {
            $SourceShortcutPath = $null; $ShortcutIsTemporary = $false
            if ($PinTarget.PinType -eq 'UWP') {
                $PinTargetDisplayName = $PinTarget.DisplayName
                $Beef001dParsingName  = $PinTarget.Aumid
                $DestinationLnkPath   = [IO.Path]::Combine($TaskBarPinnedDirectory, "$($PinTarget.DisplayName -replace '[<>:"/\\|?*]', '_').lnk")
                if (-not [IO.File]::Exists($DestinationLnkPath)) {
                    if (-not [TaskbarPin]::CreateAppShortcut($PinTarget.Aumid, $DestinationLnkPath)) {
                        if ([IO.File]::Exists($DestinationLnkPath)) { try { [IO.File]::Delete($DestinationLnkPath) } catch { } }
                        $ItemsDeferredToQuickLaunch += $PinTarget; continue
                    }
                }
            } else {
                $Beef001dContentReference = [ref]''
                $SourceShortcutPath   = New-TargetShortcut $PinTarget.ResolvedPath $Beef001dContentReference ([ref]$WshShellForPinCreation)
                $Beef001dParsingName  = $Beef001dContentReference.Value
                $ShortcutIsTemporary  = ($SourceShortcutPath -ne $PinTarget.ResolvedPath)
                $PinTargetDisplayName = [IO.Path]::GetFileName($SourceShortcutPath)
                $DestinationLnkPath   = [IO.Path]::Combine($TaskBarPinnedDirectory, $PinTargetDisplayName)
                if (-not [IO.File]::Exists($DestinationLnkPath)) { [IO.File]::Copy($SourceShortcutPath, $DestinationLnkPath) }
            }
            $SerializedBlobEntry = $null
            if ($Beef001dParsingName) {
                if ($IsRunningCrossUser) { $SerializedBlobEntry = [TaskbarPin]::GetBlobEntryFs($DestinationLnkPath, $Beef001dParsingName) }
                else                     { $SerializedBlobEntry = [TaskbarPin]::GetBlobEntryEx($DestinationLnkPath, $Beef001dParsingName) }
            }
            if ($SerializedBlobEntry) {
                $BlobEntriesReadyForInjection += @{ DestinationLnkPath = $DestinationLnkPath; SerializedBlobEntry = $SerializedBlobEntry; DisplayName = $PinTargetDisplayName; ShortcutIsTemporary = $ShortcutIsTemporary; SourceShortcutPath = $SourceShortcutPath; Beef001dContent = $Beef001dParsingName }
            } else {
                if ($DestinationLnkPath -and [IO.File]::Exists($DestinationLnkPath)) { try { [IO.File]::Delete($DestinationLnkPath) } catch { } }
                $ItemsDeferredToQuickLaunch += $PinTarget
            }
        }
        if ($WshShellForPinCreation) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($WshShellForPinCreation) }
        if ($BlobEntriesReadyForInjection.Count -gt 0) {
            $MutexWasAcquired = [TaskbarPin]::AcquirePinMutex(5000)
            $BlobEntriesAddedCount = 0
            try {
                $TaskBandRegistryKey = Open-EffectiveTaskbandKey $true
                try {
                    $ExistingFavoritesBlob = $TaskBandRegistryKey.GetValue('Favorites', $null, $DoNotExpandRegistryOption)
                    $BlobEntriesAddedCount = Write-BlobToRegistryKey $TaskBandRegistryKey $ExistingFavoritesBlob $BlobEntriesReadyForInjection
                } finally { $TaskBandRegistryKey.Close() }
            } finally { if ($MutexWasAcquired) { [TaskbarPin]::ReleasePinMutex() } }
            if ($BlobEntriesAddedCount -gt 0) { [TaskbarPin]::SendPinNotify() }
            $script:SuppressConsoleOutput = $false
            Write-Console " done" -Color Green
            foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
                Write-Console "  [+] $($ReadyEntry.DisplayName)" -Color Cyan
                $SuccessfullyPinnedCount++
                if ($ReadyEntry.ShortcutIsTemporary -and $ReadyEntry.SourceShortcutPath) { try { [IO.File]::Delete($ReadyEntry.SourceShortcutPath) } catch { } }
            }
            Write-Console ""
        } else { $script:SuppressConsoleOutput = $false; Write-Console " nothing to inject" -Color Yellow; Write-Console "" }
        if ($AllUsers -and $BlobEntriesReadyForInjection.Count -gt 0) {
            $AllUserProfiles = @(Get-UserProfiles); $AllUsersProfilesUpdatedCount = 0
            foreach ($UserProfile in $AllUserProfiles) {
                $ProfileTaskBarDirectory = [IO.Path]::Combine($UserProfile.ProfilePath, $TaskBarRelativeProfilePath)
                if (-not [IO.Directory]::Exists($ProfileTaskBarDirectory)) { try { $null = [IO.Directory]::CreateDirectory($ProfileTaskBarDirectory) } catch { continue } }
                $ProfileSpecificBlobEntries = @()
                foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
                    $ProfileShortcutPath = [IO.Path]::Combine($ProfileTaskBarDirectory, [IO.Path]::GetFileName($ReadyEntry.DestinationLnkPath))
                    if (-not [IO.File]::Exists($ProfileShortcutPath)) { try { [IO.File]::Copy($ReadyEntry.DestinationLnkPath, $ProfileShortcutPath) } catch { continue } }
                    $ProfileBlobEntry = [TaskbarPin]::GetBlobEntryFs($ProfileShortcutPath, $ReadyEntry.Beef001dContent)
                    if ($ProfileBlobEntry) { $ProfileSpecificBlobEntries += @{ DestinationLnkPath = $ProfileShortcutPath; SerializedBlobEntry = $ProfileBlobEntry } }
                }
                if ($ProfileSpecificBlobEntries.Count -eq 0) { continue }
                $OfflineHiveResult = Invoke-WithOfflineHive $UserProfile.SID $UserProfile.ProfilePath {
                    param($OfflineRegistryKey)
                    $null = Write-BlobToRegistryKey $OfflineRegistryKey ($OfflineRegistryKey.GetValue('Favorites', $null, $DoNotExpandRegistryOption)) $ProfileSpecificBlobEntries
                }
                if ($OfflineHiveResult) { $AllUsersProfilesUpdatedCount++ }
            }
            Write-Console "  [*] AllUsers : $AllUsersProfilesUpdatedCount profile(s) updated" -Color DarkCyan; Write-Console ""
        }
        $RemainingPinTargets = @($ItemsDeferredToQuickLaunch)
    } else { $RemainingPinTargets = @($ResolvedPinTargets) }
    #region PIN : QUICK LAUNCH FALLBACK
    if ($RemainingPinTargets.Count -gt 0 -and $QuickLaunchDirectoryExists) {
        $WshShellForFallback = $null
        foreach ($FallbackTarget in $RemainingPinTargets) {
            if ($FallbackTarget.PinType -eq 'UWP') { continue }
            $Beef001dFallbackRef  = [ref]''
            $FallbackShortcutPath = New-TargetShortcut $FallbackTarget.ResolvedPath $Beef001dFallbackRef ([ref]$WshShellForFallback)
            $FallbackIsTemporary  = ($FallbackShortcutPath -ne $FallbackTarget.ResolvedPath)
            $FallbackShortcutName = [IO.Path]::GetFileName($FallbackShortcutPath)
            Write-Console "  [QL] $FallbackShortcutName..." -Color DarkGray -NoNewline
            [IO.File]::Copy($FallbackShortcutPath, [IO.Path]::Combine($QuickLaunchDirectory, $FallbackShortcutName), $true)
            Write-Console " done" -Color Green; Write-Console "  [+] $FallbackShortcutName" -Color Cyan
            $SuccessfullyPinnedCount++
            if ($FallbackIsTemporary -and $FallbackShortcutPath) { try { [IO.File]::Delete($FallbackShortcutPath) } catch { } }
        }
        if ($WshShellForFallback) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($WshShellForFallback) }
    }
    #region RESULT
    if ($SuccessfullyPinnedCount -gt 0) {
        Write-Banner 'OK' 'DarkGreen' "Pinned $SuccessfullyPinnedCount item(s)$(if ($AllUsers) { ' (AllUsers)' })"
        return
    }
    Write-Banner 'FAIL' 'DarkRed' "No items could be pinned"
    return
}
