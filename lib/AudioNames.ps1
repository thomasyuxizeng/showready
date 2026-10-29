# ShowReady - lib\AudioNames.ps1
# Audio device names in English. Windows names each audio endpoint (the "Speakers" part of
# "Speakers (Realtek(R) Audio)") in the display language active when the device was installed,
# and keeps that name after the language changes. These helpers list the endpoints and rename
# them the same way Sound settings > Rename does (IPropertyStore, PKEY_Device_DeviceDesc).
# Renaming needs administrator rights. Windows PowerShell 5.1 compatible. Pure ASCII source:
# Korean text is built from \u escapes. Dot-sourcing prints nothing.

if (-not ('SRAudio.Api' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace SRAudio {
    [StructLayout(LayoutKind.Sequential)]
    public struct PropKey {
        public Guid fmtid;
        public int pid;
        public PropKey(string g, int p) { fmtid = new Guid(g); pid = p; }
    }

    // PROPVARIANT is 16 bytes on x86 and 24 on x64; 24 covers both.
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    public struct PropVar {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr p;
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PropKey key);
        [PreserveSig] int GetValue(ref PropKey key, out PropVar value);
        [PreserveSig] int SetValue(ref PropKey key, ref PropVar value);
        [PreserveSig] int Commit();
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorCom { }

    public class Endpoint {
        public string Id;
        public string Flow;      // "output" or "input"
        public int State;        // 1 active, 2 disabled, 4 not present, 8 unplugged
        public string Name;      // PKEY_Device_DeviceDesc, e.g. "Speakers"
        public string FullName;  // PKEY_Device_FriendlyName, e.g. "Speakers (Realtek(R) Audio)"
    }

    public static class Api {
        const int STGM_READ = 0;
        const int STGM_READWRITE = 2;
        const ushort VT_LPWSTR = 31;
        static PropKey DeviceDesc = new PropKey("a45c254e-df1c-4efd-8020-67d146a850e0", 2);
        static PropKey FriendlyName = new PropKey("a45c254e-df1c-4efd-8020-67d146a850e0", 14);

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PropVar pv);

        static void Check(int hr) { if (hr < 0) Marshal.ThrowExceptionForHR(hr); }

        static IMMDeviceEnumerator NewEnumerator() {
            return (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom());
        }

        static string GetString(IPropertyStore store, PropKey key) {
            PropVar v;
            if (store.GetValue(ref key, out v) < 0) return null;
            string s = null;
            if (v.vt == VT_LPWSTR && v.p != IntPtr.Zero) s = Marshal.PtrToStringUni(v.p);
            PropVariantClear(ref v);
            return s;
        }

        // stateMask: 1 active | 2 disabled | 4 not present | 8 unplugged
        public static Endpoint[] List(int stateMask) {
            List<Endpoint> list = new List<Endpoint>();
            IMMDeviceEnumerator en = NewEnumerator();
            for (int flow = 0; flow <= 1; flow++) {
                IMMDeviceCollection col;
                Check(en.EnumAudioEndpoints(flow, stateMask, out col));
                int n;
                Check(col.GetCount(out n));
                for (int i = 0; i < n; i++) {
                    IMMDevice dev;
                    if (col.Item(i, out dev) < 0) continue;
                    Endpoint e = new Endpoint();
                    e.Flow = (flow == 0) ? "output" : "input";
                    dev.GetId(out e.Id);
                    dev.GetState(out e.State);
                    IPropertyStore store;
                    if (dev.OpenPropertyStore(STGM_READ, out store) >= 0) {
                        e.Name = GetString(store, DeviceDesc);
                        e.FullName = GetString(store, FriendlyName);
                        Marshal.ReleaseComObject(store);
                    }
                    Marshal.ReleaseComObject(dev);
                    list.Add(e);
                }
                Marshal.ReleaseComObject(col);
            }
            Marshal.ReleaseComObject(en);
            return list.ToArray();
        }

        // Same as Sound settings > Rename: sets the device part of the name. Needs admin.
        public static void Rename(string id, string name) {
            IMMDeviceEnumerator en = NewEnumerator();
            IMMDevice dev;
            Check(en.GetDevice(id, out dev));
            IPropertyStore store;
            Check(dev.OpenPropertyStore(STGM_READWRITE, out store));
            PropVar v = new PropVar();
            v.vt = VT_LPWSTR;
            v.p = Marshal.StringToCoTaskMemUni(name);
            try {
                PropKey k = DeviceDesc;
                Check(store.SetValue(ref k, ref v));
                Check(store.Commit());
            }
            finally {
                PropVariantClear(ref v);
                Marshal.ReleaseComObject(store);
                Marshal.ReleaseComObject(dev);
                Marshal.ReleaseComObject(en);
            }
        }
    }
}
'@
}

function ConvertFrom-SRUnicodeEscape {
    param([string]$s)
    return [System.Text.RegularExpressions.Regex]::Unescape($s)
}

# Korean device-name words Windows uses -> English. Longest first, so phrases win over words.
function Get-SRAudioNameMap {
    $pairs = @(
        @('\uD5E4\uB4DC\uC14B \uB9C8\uC774\uD06C', 'Headset Microphone'),
        @('\uB9C8\uC774\uD06C \uBC30\uC5F4', 'Microphone Array'),
        @('\uC2A4\uD14C\uB808\uC624 \uBBF9\uC2A4', 'Stereo Mix'),
        @('\uB514\uC9C0\uD138 \uC624\uB514\uC624', 'Digital Audio'),
        @('\uB514\uC9C0\uD138 \uCD9C\uB825', 'Digital Output'),
        @('\uB514\uC9C0\uD138 \uC785\uB825', 'Digital Input'),
        @('\uB77C\uC778 \uC785\uB825', 'Line In'),
        @('\uB77C\uC778 \uCD9C\uB825', 'Line Out'),
        @('\uC678\uBD80 \uB9C8\uC774\uD06C', 'External Microphone'),
        @('\uB0B4\uBD80 \uB9C8\uC774\uD06C', 'Internal Microphone'),
        @('\uC2A4\uD53C\uCEE4', 'Speakers'),
        @('\uD5E4\uB4DC\uD3F0', 'Headphones'),
        @('\uD5E4\uB4DC\uC14B', 'Headset'),
        @('\uC774\uC5B4\uD3F0', 'Earphones'),
        @('\uB9C8\uC774\uD06C', 'Microphone'),
        @('\uB514\uC9C0\uD138', 'Digital'),
        @('\uC624\uB514\uC624', 'Audio'),
        @('\uB77C\uC778', 'Line'),
        @('\uCD9C\uB825', 'Output'),
        @('\uC785\uB825', 'Input'),
        @('\uC678\uBD80', 'External'),
        @('\uB0B4\uBD80', 'Internal')
    )
    $out = New-Object System.Collections.ArrayList
    foreach ($p in $pairs) {
        [void]$out.Add([pscustomobject]@{ ko = (ConvertFrom-SRUnicodeEscape $p[0]); en = $p[1] })
    }
    return , $out
}

function Test-SRHangul {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return $false }
    return [System.Text.RegularExpressions.Regex]::IsMatch($s, '[\u1100-\u11FF\u3130-\u318F\uAC00-\uD7A3]')
}

# English name for a Korean device name. '' when the name has no Korean (nothing to do);
# $null when some Korean words are not in the map (left alone, shown as "unknown").
function ConvertTo-SREnglishAudioName {
    param([string]$Name, $Map)
    if (-not (Test-SRHangul $Name)) { return '' }
    if ($null -eq $Map) { $Map = Get-SRAudioNameMap }
    $s = $Name
    foreach ($m in $Map) { $s = $s.Replace([string]$m.ko, [string]$m.en) }
    if (Test-SRHangul $s) { return $null }
    $s = [System.Text.RegularExpressions.Regex]::Replace($s, '\s{2,}', ' ').Trim()
    return $s
}

# "Speakers (Realtek(R) Audio)" once the device part is renamed
function Get-SRNewFullName {
    param([string]$FullName, [string]$OldName, [string]$NewName)
    if ([string]::IsNullOrEmpty($FullName)) { return $NewName }
    if ($FullName.StartsWith($OldName)) { return $NewName + $FullName.Substring($OldName.Length) }
    return $FullName
}

function Get-SRAudioEndpoints {
    # active, disabled and unplugged; not the ghosts of removed devices
    return , @([SRAudio.Api]::List(11))
}

function Set-SRAudioEndpointName {
    param([string]$Id, [string]$Name)
    [SRAudio.Api]::Rename($Id, $Name)
}
