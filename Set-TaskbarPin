function Set-TaskbarPin {
    # Version 1.0
    <#
    .EXAMPLE
      Set-TaskbarPin "C:\Users\John\Desktop\MyApp.lnk"
      Set-TaskbarPin "C:\Windows\regedit.exe;C:\MyFolder" -AllUsers
      Set-TaskbarPin "shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
      Set-TaskbarPin "uwp:Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
      Set-TaskbarPin "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"
      Set-TaskbarPin "C:\App1.lnk;C:\App2.lnk;C:\App3.exe"
      Set-TaskbarPin "notepad" 
      Set-TaskbarPin "C:\Tools\*.exe"
      Set-TaskbarPin -Unpin "Notepad*" -AllUsers
      Set-TaskbarPin "C:\MyApp.lnk" -Silent
      Set-TaskbarPin "C:\Windows\System32\services.msc;C:\Windows\System32\main.cpl"
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
    $RoamingAppDataPath              = [Environment]::GetFolderPath('ApplicationData')
    $TaskBarPinnedDirectory          = [IO.Path]::Combine($RoamingAppDataPath, 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
    $QuickLaunchDirectory            = [IO.Path]::Combine($RoamingAppDataPath, 'Microsoft\Internet Explorer\Quick Launch')
    $TaskBandRegistrySubKey          = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
    $TaskBarRelativeProfilePath      = 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    $DoNotExpandRegistryOption       = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    $BinaryRegistryValueKind         = [Microsoft.Win32.RegistryValueKind]::Binary
    $DwordRegistryValueKind          = [Microsoft.Win32.RegistryValueKind]::DWord
    $TaskBarDirectoryExists          = [IO.Directory]::Exists($TaskBarPinnedDirectory)
    $QuickLaunchDirectoryExists      = [IO.Directory]::Exists($QuickLaunchDirectory)
    $TaskBandRegistryKeyExists       = $false
    $RegistryProbeHandle             = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($TaskBandRegistrySubKey, $false)
    if ($RegistryProbeHandle) { $TaskBandRegistryKeyExists = $true; $RegistryProbeHandle.Close() }
    $CurrentUserSecurityIdentifier   = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    $DirectBlobWriteIsSupported      = $TaskBarDirectoryExists -and $TaskBandRegistryKeyExists
    # -- Cross-user elevation detection --
    $IsRunningCrossUser         = $false
    $EffectivePrimaryUserSID    = $CurrentUserSecurityIdentifier
    $CurrentProcessSessionId    = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    foreach ($CandidateSidKeyName in [Microsoft.Win32.Registry]::Users.GetSubKeyNames()) {
        if ($CandidateSidKeyName.Length -lt 20 -or $CandidateSidKeyName.EndsWith('_Classes')) { continue }
        $SessionVolatileEnvKey = $null
        try { $SessionVolatileEnvKey = [Microsoft.Win32.Registry]::Users.OpenSubKey("$CandidateSidKeyName\Volatile Environment\$CurrentProcessSessionId") } catch { }
        if ($SessionVolatileEnvKey) {
            $SessionVolatileEnvKey.Close()
            if ($CandidateSidKeyName -ne $CurrentUserSecurityIdentifier) {
                $IsRunningCrossUser      = $true
                $EffectivePrimaryUserSID = $CandidateSidKeyName
                $ProfileListKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$CandidateSidKeyName")
                if ($ProfileListKey) {
                    $InteractiveUserProfilePath = $ProfileListKey.GetValue('ProfileImagePath', ''); $ProfileListKey.Close()
                    $TaskBarPinnedDirectory     = [IO.Path]::Combine($InteractiveUserProfilePath, $TaskBarRelativeProfilePath)
                    $QuickLaunchDirectory       = [IO.Path]::Combine($InteractiveUserProfilePath, 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch')
                    $TaskBarDirectoryExists     = [IO.Directory]::Exists($TaskBarPinnedDirectory)
                    $QuickLaunchDirectoryExists = [IO.Directory]::Exists($QuickLaunchDirectory)
                    $TaskBandRegistryKeyExists  = $false
                    $CrossUserRegistryProbe = [Microsoft.Win32.Registry]::Users.OpenSubKey("$CandidateSidKeyName\$TaskBandRegistrySubKey", $false)
                    if ($CrossUserRegistryProbe) { $TaskBandRegistryKeyExists = $true; $CrossUserRegistryProbe.Close() }
                    $DirectBlobWriteIsSupported = $TaskBarDirectoryExists -and $TaskBandRegistryKeyExists
                }
            }
            break
        }
    }
    #region LOGGING
    function Write-Console {
        param([string]$Message, [string]$Color = 'White', [switch]$NoNewline)
        if ($Silent) { return }
        $WriteHostParams = @{ Object = $Message; ForegroundColor = $Color }
        if ($NoNewline)       { $WriteHostParams['NoNewline']       = $true }
        Write-Host @WriteHostParams
    }
    function Write-Banner {
        param([string]$Label, [string]$LabelBackground, [string]$Detail)
        if ($Silent) { return }
        Write-Host ""; Write-Host "  $Label  " -ForegroundColor White -BackgroundColor $LabelBackground -NoNewline; Write-Host "  $Detail"; Write-Host ""
    }
    #region INPUT VALIDATION
    if (-not $Pin) { Write-Console "ERROR : Specify -Pin" -Color Red; return }
    $ParsedInputItems = @($Pin -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($ParsedInputItems.Count -eq 0) { Write-Console "ERROR : Specify -Pin" -Color Red; return }
    $ParsedInputItems = @($ParsedInputItems | ForEach-Object {  if     ($_.StartsWith('uwp:', [StringComparison]::OrdinalIgnoreCase))              { 'shell:AppsFolder\' + $_.Substring(4) }
                                                                elseif ($_.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase)) { 'shell:AppsFolder\' + $_.Substring(17) }
                                                                elseif ($_ -match '!' -and $_ -notmatch '[/\\]')                                  { 'shell:AppsFolder\' + $_ }
                                                                else                                                                              {                       $_ }
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
    [DllImport("shell32.dll")]static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
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
    static T RunOnSTA<T>(Func<T> fn) { if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA) return fn(); T r = default(T); Thread t = new Thread(delegate() { r = fn(); }); t.SetApartmentState(ApartmentState.STA); t.Start(); t.Join(); return r; }
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
    public static byte[] GetBlobEntryEx(string lnkFullPath, string beef001dContent) { return RunOnSTA(() => GetBlobEntryInternal(lnkFullPath, beef001dContent, false)); }
    public static byte[] GetBlobEntryFs(string lnkFullPath, string beef001dContent) { return RunOnSTA(() => GetBlobEntryInternal(lnkFullPath, beef001dContent, true)); }
    static bool CreateShortcutFromPidl(IntPtr pidl, string lnkPath, string aumid) {
        Guid cls = CLSID_ShellLink; Guid iid = IID_IShellLinkW; IntPtr psl;
        if (CoCreateInstance(ref cls, IntPtr.Zero, 1, ref iid, out psl) != 0) return false;
        IntPtr vtLink = Marshal.ReadIntPtr(psl);
        try { Vtbl<FnSetIDList>(vtLink, 5)(psl, pidl); if (aumid != null && aumid.Length > 0) WriteAumidToStore(psl, vtLink, aumid); return PersistSave(psl, vtLink, lnkPath); }
        finally { Release(psl, vtLink); }
    }
    public static bool CreateAppShortcut(string aumid, string lnkPath) {
        return RunOnSTA(() => { IntPtr pidl = ParseDisplayName("shell:AppsFolder\\" + aumid); if (pidl == IntPtr.Zero) return false; try { return CreateShortcutFromPidl(pidl, lnkPath, aumid); } finally { ILFree(pidl); } });
    }
    public static bool CreatePidlShortcut(string displayName, string lnkPath, string appUserModelId) {
        return RunOnSTA(() => { IntPtr pidl; uint sfgao; if (SHParseDisplayName(displayName, IntPtr.Zero, out pidl, 0, out sfgao) != 0 || pidl == IntPtr.Zero) return false; try { return CreateShortcutFromPidl(pidl, lnkPath, appUserModelId); } finally { ILFree(pidl); } });
    }
    public static string GetAumid(string lnkPath) {
        return RunOnSTA(() => {
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
        byte[] payload = new byte[12]; payload[0] = 0x0A; payload[1] = 0x00; payload[2] = 0x0D; payload[3] = 0x00;
        IntPtr ptr = Marshal.AllocHGlobal(12);
        try { Marshal.Copy(payload, 0, ptr, 12); SHChangeNotify(0x04000000, 0x3000, ptr, IntPtr.Zero); } finally { Marshal.FreeHGlobal(ptr); }
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
            for (int b = pidlStart; b + needle.Length <= pidlEnd; b += 2) { bool match = true; for (int c = 0; c < needle.Length; c++) { if (blob[b + c] != needle[c]) { match = false; break; } } if (match) return idx; }
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
}
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
    function New-TargetShortcut {
        param([string]$ResolvedTargetPath, [ref]$Beef001dContentRef, [ref]$WshShellComObjectRef)
        $TargetFileExtension = [IO.Path]::GetExtension($ResolvedTargetPath).ToLower()
        if ($TargetFileExtension -eq '.lnk') {
            if (-not $WshShellComObjectRef.Value) { $WshShellComObjectRef.Value = New-Object -ComObject WScript.Shell }
            $ShortcutObject = $WshShellComObjectRef.Value.CreateShortcut($ResolvedTargetPath)
            $Beef001dContentRef.Value = $ShortcutObject.TargetPath
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ShortcutObject)
            if (-not $Beef001dContentRef.Value) { $Beef001dContentRef.Value = [TaskbarPin]::GetAumid($ResolvedTargetPath) }
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
            $NewShortcutObject.TargetPath      = [IO.Path]::Combine($env:SystemRoot, 'explorer.exe')
            $NewShortcutObject.Arguments        = "`"$ResolvedTargetPath`""
            $NewShortcutObject.IconLocation     = [IO.Path]::Combine($env:SystemRoot, 'System32\shell32.dll') + ',3'
            $NewShortcutObject.WorkingDirectory = $ResolvedTargetPath
            $Beef001dContentRef.Value           = $ResolvedTargetPath
        } elseif ($TargetFileExtension -eq '.cpl') {
            $NewShortcutObject.TargetPath       = [IO.Path]::Combine($env:SystemRoot, 'System32\rundll32.exe')
            $NewShortcutObject.Arguments         = "shell32.dll,Control_RunDLL `"$ResolvedTargetPath`""
            $NewShortcutObject.IconLocation      = "$ResolvedTargetPath,0"
            $NewShortcutObject.WorkingDirectory  = [IO.Path]::GetDirectoryName($ResolvedTargetPath)
            $Beef001dContentRef.Value            = $ResolvedTargetPath
        } else {
            $NewShortcutObject.TargetPath       = $ResolvedTargetPath
            $NewShortcutObject.WorkingDirectory  = [IO.Path]::GetDirectoryName($ResolvedTargetPath)
            $Beef001dContentRef.Value            = $ResolvedTargetPath
        }
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
        Write-Console "  [blob] $($ExistingFavoritesBlob.Length) -> $($FinalBlobBytes.Length) bytes (+$NumberOfEntriesActuallyAdded) | FavChanges : $CurrentFavoritesChangesCounter -> $($CurrentFavoritesChangesCounter + 1)" -Color DarkGray
        return $NumberOfEntriesActuallyAdded
    }
    function Get-UserProfiles {
        $ProfileListRegistryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList')
        if (-not $ProfileListRegistryKey) { return @() }
        $DiscoveredProfiles = @()
        foreach ($ProfileSid in $ProfileListRegistryKey.GetSubKeyNames()) {
            if ($ProfileSid.Length -lt 20) { continue }
            if ($ProfileSid -eq $EffectivePrimaryUserSID) { continue }
            $ProfileSubKey = $ProfileListRegistryKey.OpenSubKey($ProfileSid)
            if (-not $ProfileSubKey) { continue }
            $ProfileImagePath = $ProfileSubKey.GetValue('ProfileImagePath', ''); $ProfileSubKey.Close()
            if (-not $ProfileImagePath -or -not [IO.Directory]::Exists($ProfileImagePath)) { continue }
            $ProfileFolderName = [IO.Path]::GetFileName($ProfileImagePath).ToLower()
            if ($ProfileFolderName -eq 'systemprofile' -or $ProfileFolderName -eq 'localservice' -or $ProfileFolderName -eq 'networkservice') { continue }
            $DiscoveredProfiles += New-Object PSObject -Property @{ SID = $ProfileSid; ProfilePath = $ProfileImagePath }
        }
        $ProfileListRegistryKey.Close()
        $DefaultUserNtUserDatPath = [IO.Path]::Combine($env:SystemDrive, 'Users\Default\NTUSER.DAT')
        if ([IO.File]::Exists($DefaultUserNtUserDatPath)) {
            $DiscoveredProfiles += New-Object PSObject -Property @{ SID = 'Default'; ProfilePath = [IO.Path]::Combine($env:SystemDrive, 'Users\Default') }
        }
        return $DiscoveredProfiles
    }
    function Invoke-WithOfflineHive {
        param([string]$ProfileSID, [string]$ProfileDirectoryPath, [scriptblock]$ActionToPerform)
        $NtUserDatFilePath = [IO.Path]::Combine($ProfileDirectoryPath, 'NTUSER.DAT')
        if (-not [IO.File]::Exists($NtUserDatFilePath)) { return $false }
        $LoadedHiveRegistryPath = $null; $HiveRequiresUnload = $false
        if ($ProfileSID -ne 'Default') {
            try { $AlreadyLoadedTestKey = [Microsoft.Win32.Registry]::Users.OpenSubKey("$ProfileSID\$TaskBandRegistrySubKey", $false); if ($AlreadyLoadedTestKey) { $LoadedHiveRegistryPath = $ProfileSID; $AlreadyLoadedTestKey.Close() } } catch { }
        }
        if (-not $LoadedHiveRegistryPath) {
            $TemporaryHiveName = "TempPin_$($ProfileSID.Replace('-','').Substring(0, [Math]::Min(12, $ProfileSID.Replace('-','').Length)))"
            $RegLoadProcessInfo = New-Object System.Diagnostics.ProcessStartInfo; $RegLoadProcessInfo.FileName = 'reg.exe'
            $RegLoadProcessInfo.Arguments = "load `"HKU\$TemporaryHiveName`" `"$NtUserDatFilePath`""
            $RegLoadProcessInfo.UseShellExecute = $false; $RegLoadProcessInfo.CreateNoWindow = $true; $RegLoadProcessInfo.RedirectStandardError = $true
            $RegLoadProcess = [System.Diagnostics.Process]::Start($RegLoadProcessInfo); $RegLoadProcess.WaitForExit(10000)
            if ($RegLoadProcess.ExitCode -ne 0) { return $false }
            $LoadedHiveRegistryPath = $TemporaryHiveName; $HiveRequiresUnload = $true
        }
        try {
            $TaskBandKeyHandle = [Microsoft.Win32.Registry]::Users.OpenSubKey("$LoadedHiveRegistryPath\$TaskBandRegistrySubKey", $true)
            if (-not $TaskBandKeyHandle) { $TaskBandKeyHandle = [Microsoft.Win32.Registry]::Users.CreateSubKey("$LoadedHiveRegistryPath\$TaskBandRegistrySubKey") }
            if ($TaskBandKeyHandle) { try { & $ActionToPerform $TaskBandKeyHandle } finally { $TaskBandKeyHandle.Close() } }
        } finally {
            if ($HiveRequiresUnload) {
                [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 200
                $RegUnloadProcessInfo = New-Object System.Diagnostics.ProcessStartInfo; $RegUnloadProcessInfo.FileName = 'reg.exe'
                $RegUnloadProcessInfo.Arguments = "unload `"HKU\$TemporaryHiveName`""
                $RegUnloadProcessInfo.UseShellExecute = $false; $RegUnloadProcessInfo.CreateNoWindow = $true; $RegUnloadProcessInfo.RedirectStandardError = $true
                $RegUnloadProcess = [System.Diagnostics.Process]::Start($RegUnloadProcessInfo); $RegUnloadProcess.WaitForExit(10000)
            }
        }
        return $true
    }
    #region UNPIN FLOW
    if ($Unpin) {
        $UnpinMatchPatterns = @()
        foreach ($InputItem in $ParsedInputItems) {
            if ($InputItem.StartsWith('shell:AppsFolder\', [StringComparison]::OrdinalIgnoreCase)) { $UnpinMatchPatterns += $InputItem.Substring(17) }
            else {
                $InputHasDirectoryPart = $InputItem.Contains('\') -or $InputItem.Contains('/')
                $InputHasWildcard      = $InputItem.Contains('*') -or $InputItem.Contains('?')
                if ($InputHasDirectoryPart -and -not $InputHasWildcard) {
                    $InputExtension = [IO.Path]::GetExtension($InputItem).ToLower()
                    if ($InputExtension -eq '.cpl' -and [IO.File]::Exists($InputItem)) {
                        Initialize-NativeHelper
                        $CplMatch = Resolve-CplControlPanelItem $InputItem
                        if ($CplMatch) { $UnpinMatchPatterns += ($CplMatch.Name -replace '[<>:"/\\|?*]', '_') }
                        else           { $UnpinMatchPatterns += [IO.Path]::GetFileNameWithoutExtension($InputItem) }
                    } else {
                        $UnpinMatchPatterns += [IO.Path]::GetFileNameWithoutExtension($InputItem)
                    }
                }
                else {
                    $InputExtension = [IO.Path]::GetExtension($InputItem).ToLower()
                    if ($InputExtension -eq '.cpl') {
                        $ResolvedCplPaths = @(Resolve-FilesystemInput $InputItem)
                        $CplHandled = $false
                        foreach ($ResolvedCplPath in $ResolvedCplPaths) {
                            if ($ResolvedCplPath -and [IO.File]::Exists($ResolvedCplPath)) {
                                Initialize-NativeHelper
                                $CplMatch = Resolve-CplControlPanelItem $ResolvedCplPath
                                if ($CplMatch) { $UnpinMatchPatterns += ($CplMatch.Name -replace '[<>:"/\\|?*]', '_'); $CplHandled = $true }
                            }
                        }
                        if (-not $CplHandled) { $UnpinMatchPatterns += [IO.Path]::GetFileNameWithoutExtension($InputItem) }
                    }
                    elseif ($InputExtension -in '.msc', '.exe') {
                        $UnpinMatchPatterns += [IO.Path]::GetFileNameWithoutExtension($InputItem)
                    }
                    else { $UnpinMatchPatterns += $InputItem }
                }
            }
        }
        $DisplayPatternLabel = ($UnpinMatchPatterns | ForEach-Object { $_ }) -join ', '
        Write-Banner 'UNPIN' 'DarkRed' "$DisplayPatternLabel$(if ($AllUsers) { ' (AllUsers)' })"
        Initialize-NativeHelper
        function Find-MatchingPins {
            param([string]$PinnedShortcutDirectory, [string[]]$PatternsToMatch)
            $MatchedShortcutPaths = @(); $WshShellInstance = $null
            try { $ShortcutFilesInDirectory = @([IO.Directory]::GetFiles($PinnedShortcutDirectory, '*.lnk')) } catch { return @() }
            foreach ($ShortcutFilePath in $ShortcutFilesInDirectory) {
                $ShortcutFileName = [IO.Path]::GetFileName($ShortcutFilePath); $PatternMatched = $false
                foreach ($Pattern in $PatternsToMatch) {
                    $PatternIsFullPath = $Pattern.Contains('\') -or $Pattern.Contains('/')
                    if (-not $PatternIsFullPath -and [IO.Path]::GetFileNameWithoutExtension($ShortcutFileName) -like $Pattern) { $PatternMatched = $true; break }
                }
                if (-not $PatternMatched) {
                    if (-not $WshShellInstance) { $WshShellInstance = New-Object -ComObject WScript.Shell }
                    $ShortcutComObject = $WshShellInstance.CreateShortcut($ShortcutFilePath); $ShortcutTargetPath = $ShortcutComObject.TargetPath
                    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ShortcutComObject)
                    foreach ($Pattern in $PatternsToMatch) {
                        $PatternIsFullPath = $Pattern.Contains('\') -or $Pattern.Contains('/')
                        if (-not $PatternIsFullPath) { if ($ShortcutTargetPath -and ([IO.Path]::GetFileNameWithoutExtension($ShortcutTargetPath) -like $Pattern -or [IO.Path]::GetFileName($ShortcutTargetPath) -like $Pattern)) { $PatternMatched = $true; break } }
                        else { if ($ShortcutTargetPath -like $Pattern) { $PatternMatched = $true; break } }
                    }
                    if (-not $PatternMatched) {
                        $ShortcutAumid = [TaskbarPin]::GetAumid($ShortcutFilePath)
                        if ($ShortcutAumid) { foreach ($Pattern in $PatternsToMatch) { if ($ShortcutAumid -like $Pattern) { $PatternMatched = $true; break } } }
                    }
                }
                if ($PatternMatched) { $MatchedShortcutPaths += $ShortcutFilePath }
            }
            if ($WshShellInstance) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($WshShellInstance) }
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
                if ($FoundBlobIndex -ge 0) { $EntriesToRemove += New-Object PSObject -Property @{ Name = $ShortcutFilename; Index = $FoundBlobIndex } }
            }
            $EntriesToRemove = @($EntriesToRemove | Sort-Object -Property Index -Descending)
            foreach ($EntryToRemove in $EntriesToRemove) {
                $FavoritesBlob = [TaskbarPin]::RemoveFavEntry($FavoritesBlob, $EntryToRemove.Index)
                if ($FavoritesResolveBlob) { $FavoritesResolveBlob = [TaskbarPin]::RemoveResEntry($FavoritesResolveBlob, $EntryToRemove.Index) }
            }
            if ($EntriesToRemove.Count -gt 0) {
                $CurrentFavoritesChanges = [int]$RegistryKeyHandle.GetValue('FavoritesChanges', 0, $DoNotExpandRegistryOption)
                $RegistryKeyHandle.SetValue('Favorites', ([byte[]]$FavoritesBlob), $BinaryRegistryValueKind)
                if ($FavoritesResolveBlob) { $RegistryKeyHandle.SetValue('FavoritesResolve', ([byte[]]$FavoritesResolveBlob), $BinaryRegistryValueKind) }
                $RegistryKeyHandle.SetValue('FavoritesVersion',  3,                                $DwordRegistryValueKind)
                $RegistryKeyHandle.SetValue('FavoritesChanges', ($CurrentFavoritesChanges + 1),    $DwordRegistryValueKind)
                Write-Console "  [blob] Removed $($EntriesToRemove.Count) entries | FavChanges : $CurrentFavoritesChanges -> $($CurrentFavoritesChanges + 1)" -Color DarkGray
            }
            return $EntriesToRemove.Count
        }
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
    $ResolvedPinTargets     = @()
    $ShellApplicationCom    = $null
    $AppsFolderNamespaceCom = $null
    if ($UwpInputItems.Count -gt 0) {
        $ShellApplicationCom    = New-Object -ComObject Shell.Application
        $AppsFolderNamespaceCom = $ShellApplicationCom.Namespace('shell:AppsFolder')
        $AlreadySeenAumids = @{}
        $ExactAumidInputs  = @($UwpInputItems | Where-Object { $_ -notmatch '[*?]' -and $_.Contains('!') })
        $WildcardUwpInputs = @($UwpInputItems | Where-Object { $_    -match '[*?]' -or -not $_.Contains('!') })
        foreach ($ExactUwpInput in $ExactAumidInputs) {
            $AumidSuffix = $ExactUwpInput.Substring(17); if (-not $AumidSuffix) { continue }
            $DirectlyResolvedAppItem = $AppsFolderNamespaceCom.ParseName($AumidSuffix)
            if ($DirectlyResolvedAppItem) {
                if (-not $AlreadySeenAumids.ContainsKey($DirectlyResolvedAppItem.Path)) {
                    $AlreadySeenAumids[$DirectlyResolvedAppItem.Path] = $true
                    $ResolvedPinTargets += New-Object PSObject -Property @{ PinType = 'UWP'; Aumid = $DirectlyResolvedAppItem.Path; DisplayName = $DirectlyResolvedAppItem.Name }
                }
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($DirectlyResolvedAppItem)
            } else { Write-Console "  [!] Not found : $ExactUwpInput" -Color Yellow }
        }
        if ($WildcardUwpInputs.Count -gt 0) {
            $WildcardSuffixes = @($WildcardUwpInputs | ForEach-Object { $_.Substring(17) } | Where-Object { $_ })
            $AllInstalledAppItems = @($AppsFolderNamespaceCom.Items()); $MatchedWildcardSuffixes = @{}
            foreach ($AppItem in $AllInstalledAppItems) {
                foreach ($WildcardPattern in $WildcardSuffixes) {
                    if (($AppItem.Name -like $WildcardPattern -or $AppItem.Path -like $WildcardPattern) -and -not $AlreadySeenAumids.ContainsKey($AppItem.Path)) {
                        $AlreadySeenAumids[$AppItem.Path] = $true
                        $ResolvedPinTargets += New-Object PSObject -Property @{ PinType = 'UWP'; Aumid = $AppItem.Path; DisplayName = $AppItem.Name }
                        $MatchedWildcardSuffixes[$WildcardPattern] = $true
                    }
                }
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($AppItem)
            }
            foreach ($WildcardPattern in $WildcardSuffixes) { if (-not $MatchedWildcardSuffixes.ContainsKey($WildcardPattern)) { Write-Console "  [!] Not found : shell:AppsFolder\$WildcardPattern" -Color Yellow } }
        }
    }
    if ($FilesystemInputItems.Count -gt 0) {
        $AlreadySeenFilesystemPaths = @{}
        foreach ($FilesystemInput in $FilesystemInputItems) {
            $ResolvedFilePaths = @(Resolve-FilesystemInput $FilesystemInput)
            foreach ($ResolvedPath in $ResolvedFilePaths) {
                if ($ResolvedPath -and -not $AlreadySeenFilesystemPaths.ContainsKey($ResolvedPath)) {
                    $AlreadySeenFilesystemPaths[$ResolvedPath] = $true
                    $ResolvedPinTargets += New-Object PSObject -Property @{ PinType = 'FS'; ResolvedPath = $ResolvedPath }
                }
            }
            if ($ResolvedFilePaths.Count -eq 0) { Write-Console "  [!] Not found : $FilesystemInput" -Color Yellow }
        }
    }
    if ($ResolvedPinTargets.Count -eq 0) {
        Write-Console "  [X] No items found to pin" -Color Red; Write-Console ""
        if ($AppsFolderNamespaceCom) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($AppsFolderNamespaceCom) }
        if ($ShellApplicationCom)   { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ShellApplicationCom) }
        return
    }
    #region PIN : BLOB INJECTION
    $SuccessfullyPinnedCount      = 0
    $BlobEntriesReadyForInjection = @()
    $ItemsDeferredToQuickLaunch   = @()
    if ($DirectBlobWriteIsSupported) {
        Write-Console "  [>] Preparing blob entries ($($ResolvedPinTargets.Count) item(s))..." -Color DarkGray -NoNewline
        Initialize-NativeHelper
        $WshShellForPinCreation = $null
        foreach ($PinTarget in $ResolvedPinTargets) {
            $DestinationLnkPath = $null; $Beef001dParsingName = $null; $SourceShortcutPath = $null; $ShortcutIsTemporary = $false; $PinTargetDisplayName = $null
            if ($PinTarget.PinType -eq 'UWP') {
                $TargetAumid          = $PinTarget.Aumid; $PinTargetDisplayName = $PinTarget.DisplayName
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
                if (-not [TaskbarPin]::CreateAppShortcut($TargetAumid, $DestinationLnkPath)) {
                    if ($DestinationLnkPath -and [IO.File]::Exists($DestinationLnkPath)) { try { [IO.File]::Delete($DestinationLnkPath) } catch { } }
                    $ItemsDeferredToQuickLaunch += $PinTarget; continue
                }
            } else {
                $Beef001dContentReference = [ref]''
                $SourceShortcutPath       = New-TargetShortcut $PinTarget.ResolvedPath $Beef001dContentReference ([ref]$WshShellForPinCreation)
                $Beef001dParsingName      = $Beef001dContentReference.Value
                $ShortcutIsTemporary      = ($SourceShortcutPath -ne $PinTarget.ResolvedPath)
                $ShortcutFileName         = [IO.Path]::GetFileName($SourceShortcutPath)
                $DestinationLnkPath       = [IO.Path]::Combine($TaskBarPinnedDirectory, $ShortcutFileName)
                $PinTargetDisplayName     = $ShortcutFileName
                if (-not [IO.File]::Exists($DestinationLnkPath)) { [IO.File]::Copy($SourceShortcutPath, $DestinationLnkPath) }
            }
            $SerializedBlobEntry = $null
            if ($Beef001dParsingName) {
                if ($IsRunningCrossUser) { $SerializedBlobEntry = [TaskbarPin]::GetBlobEntryFs($DestinationLnkPath, $Beef001dParsingName) }
                else                     { $SerializedBlobEntry = [TaskbarPin]::GetBlobEntryEx($DestinationLnkPath, $Beef001dParsingName) }
            }
            if ($SerializedBlobEntry) {
                $BlobEntriesReadyForInjection += New-Object PSObject -Property @{
                    DestinationLnkPath  = $DestinationLnkPath;  SerializedBlobEntry = $SerializedBlobEntry; DisplayName    = $PinTargetDisplayName
                    ShortcutIsTemporary = $ShortcutIsTemporary;  SourceShortcutPath  = $SourceShortcutPath;  PinType        = $PinTarget.PinType
                    Aumid               = $(if ($PinTarget.PinType -eq 'UWP') { $PinTarget.Aumid } else { $null })
                    Beef001dContent     = $Beef001dParsingName
                }
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
            Write-Console " done" -Color Green
            foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
                Write-Console "  [+] $($ReadyEntry.DisplayName)" -Color Cyan
                $SuccessfullyPinnedCount++
                if ($ReadyEntry.ShortcutIsTemporary -and $ReadyEntry.SourceShortcutPath) { try { [IO.File]::Delete($ReadyEntry.SourceShortcutPath) } catch { } }
            }
            Write-Console ""
        } else { Write-Console " nothing to inject" -Color Yellow; Write-Console "" }
        if ($AllUsers -and $BlobEntriesReadyForInjection.Count -gt 0) {
            $AllUserProfiles = @(Get-UserProfiles); $AllUsersProfilesUpdatedCount = 0
            foreach ($UserProfile in $AllUserProfiles) {
                $ProfileTaskBarDirectory = [IO.Path]::Combine($UserProfile.ProfilePath, $TaskBarRelativeProfilePath)
                if (-not [IO.Directory]::Exists($ProfileTaskBarDirectory)) { try { $null = [IO.Directory]::CreateDirectory($ProfileTaskBarDirectory) } catch { continue } }
                foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
                    $SourceLnkPath      = $ReadyEntry.DestinationLnkPath
                    $DestinationLnkPath = [IO.Path]::Combine($ProfileTaskBarDirectory, [IO.Path]::GetFileName($SourceLnkPath))
                    if (-not [IO.File]::Exists($DestinationLnkPath)) { try { [IO.File]::Copy($SourceLnkPath, $DestinationLnkPath) } catch { } }
                }
                $ProfileSpecificBlobEntries = @()
                foreach ($ReadyEntry in $BlobEntriesReadyForInjection) {
                    $ProfileShortcutPath = [IO.Path]::Combine($ProfileTaskBarDirectory, [IO.Path]::GetFileName($ReadyEntry.DestinationLnkPath))
                    if (-not [IO.File]::Exists($ProfileShortcutPath)) { continue }
                    $ProfileBlobEntry = [TaskbarPin]::GetBlobEntryFs($ProfileShortcutPath, $ReadyEntry.Beef001dContent)
                    if ($ProfileBlobEntry) { $ProfileSpecificBlobEntries += New-Object PSObject -Property @{ DestinationLnkPath = $ProfileShortcutPath; SerializedBlobEntry = $ProfileBlobEntry } }
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
    #region CLEANUP AND RESULT
    if ($AppsFolderNamespaceCom) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($AppsFolderNamespaceCom) }
    if ($ShellApplicationCom)    { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ShellApplicationCom) }
    if ($SuccessfullyPinnedCount -gt 0) {
        Write-Banner 'OK' 'DarkGreen' "Pinned $SuccessfullyPinnedCount item(s)$(if ($AllUsers) { ' (AllUsers)' })"
        return
    }
    Write-Banner 'FAIL' 'DarkRed' "No items could be pinned"
    return
}
