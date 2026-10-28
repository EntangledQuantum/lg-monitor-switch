<#
.SYNOPSIS
  LG Monitor Switch for Windows - brightness/contrast sliders and a
  "Switch to Linux" button for an LG UltraGear monitor shared with a Linux PC.

.DESCRIPTION
  Single PowerShell script, no build step. Uses Windows Forms (built into
  Windows) and the Win32 Monitor Configuration API (dxva2.dll) for DDC/CI.

  Only these monitor settings are ever written:
    VCP 0x10 brightness, VCP 0x12 contrast (0-100)
    VCP 0x60 input select - ONLY with the optional "ddc60" switch method
  The normal "Switch to Linux" asks the Linux computer (lg-monitor listener)
  over the LAN to send LG's input-switch packet, because this monitor ignores
  the standard VCP 0x60 command.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File LGMonitor.ps1            # GUI
  powershell -NoProfile -ExecutionPolicy Bypass -File LGMonitor.ps1 -ListMonitors
  powershell -NoProfile -ExecutionPolicy Bypass -File LGMonitor.ps1 -Get
  powershell -NoProfile -ExecutionPolicy Bypass -File LGMonitor.ps1 -SetBrightness 60
  powershell -NoProfile -ExecutionPolicy Bypass -File LGMonitor.ps1 -TestLinux
  powershell -NoProfile -ExecutionPolicy Bypass -File LGMonitor.ps1 -SwitchToLinux
  powershell -NoProfile -ExecutionPolicy Bypass -File LGMonitor.ps1 -Configure -LinuxHost 192.168.1.20 -Token abc...
#>
[CmdletBinding()]
param(
    [switch]$ListMonitors,
    [switch]$Get,
    [int]$SetBrightness = -1,
    [int]$SetContrast = -1,
    [switch]$SwitchToLinux,
    [ValidateSet('', 'linux', 'ddc60')][string]$Method = '',
    [switch]$TestLinux,
    [switch]$Configure,
    [string]$LinuxHost,
    [int]$LinuxPort = 0,
    [string]$Token,
    [int]$MonitorIndex = -2,
    [switch]$Tray,
    [string]$ConfigPath = (Join-Path $env:APPDATA 'LGMonitor\config.json')
)

$ErrorActionPreference = 'Stop'
$AppVersion = '1.0.0'

# --------------------------------------------------------------------------
# Win32 DDC/CI wrapper (C# 5 so it compiles on Windows PowerShell 5.1 too)
# --------------------------------------------------------------------------
if (-not ('LGMonitorSwitch.Ddc' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace LGMonitorSwitch {
    public class MonitorEntry {
        public int Index;
        public string DisplayName;   // \\.\DISPLAY1
        public string DeviceId;      // MONITOR\GSM5BBF\{...}
        public string DeviceString;  // e.g. "LG ULTRAGEAR(DisplayPort)" or "Generic PnP Monitor"
        public string Description;   // physical monitor description from dxva2
        public bool Primary;
        public override string ToString() {
            return String.Format("[{0}] {1}  {2}  {3}{4}", Index, DisplayName, DeviceString, DeviceId, Primary ? "  (primary)" : "");
        }
    }

    public static class Ddc {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct MONITORINFOEX {
            public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DISPLAY_DEVICE {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public uint StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct PHYSICAL_MONITOR {
            public IntPtr hPhysicalMonitor;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szPhysicalMonitorDescription;
        }

        delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);

        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint devNum, ref DISPLAY_DEVICE dd, uint flags);
        [DllImport("dxva2.dll", SetLastError = true)] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);
        [DllImport("dxva2.dll", SetLastError = true)] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint size, [Out] PHYSICAL_MONITOR[] arr);
        [DllImport("dxva2.dll", SetLastError = true)] static extern bool DestroyPhysicalMonitors(uint size, PHYSICAL_MONITOR[] arr);
        [DllImport("dxva2.dll", SetLastError = true)] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, IntPtr type, out uint cur, out uint max);
        [DllImport("dxva2.dll", SetLastError = true)] static extern bool SetVCPFeature(IntPtr h, byte code, uint value);

        static List<IntPtr> HMonitors() {
            List<IntPtr> list = new List<IntPtr>();
            MonitorEnumProc cb = delegate (IntPtr h, IntPtr dc, ref RECT r, IntPtr d) { list.Add(h); return true; };
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
            GC.KeepAlive(cb);
            return list;
        }

        // One entry per physical monitor, in a stable order.
        public static List<MonitorEntry> List() {
            List<MonitorEntry> result = new List<MonitorEntry>();
            foreach (IntPtr hmon in HMonitors()) {
                MONITORINFOEX mi = new MONITORINFOEX();
                mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
                GetMonitorInfo(hmon, ref mi);
                DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
                dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                bool haveDd = EnumDisplayDevices(mi.szDevice, 0, ref dd, 0);
                uint n;
                if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hmon, out n) || n == 0) n = 0;
                PHYSICAL_MONITOR[] pms = new PHYSICAL_MONITOR[n];
                if (n > 0 && GetPhysicalMonitorsFromHMONITOR(hmon, n, pms)) {
                    for (int i = 0; i < n; i++) {
                        MonitorEntry e = new MonitorEntry();
                        e.Index = result.Count;
                        e.DisplayName = mi.szDevice;
                        e.DeviceId = haveDd ? dd.DeviceID : "";
                        e.DeviceString = haveDd ? dd.DeviceString : "";
                        e.Description = pms[i].szPhysicalMonitorDescription;
                        e.Primary = (mi.dwFlags & 1) != 0;
                        result.Add(e);
                    }
                    DestroyPhysicalMonitors(n, pms);
                }
            }
            return result;
        }

        static T WithPhysical<T>(int index, Func<IntPtr, T> fn) {
            int seen = 0;
            foreach (IntPtr hmon in HMonitors()) {
                uint n;
                if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hmon, out n) || n == 0) continue;
                PHYSICAL_MONITOR[] pms = new PHYSICAL_MONITOR[n];
                if (!GetPhysicalMonitorsFromHMONITOR(hmon, n, pms)) continue;
                try {
                    if (index < seen + n) return fn(pms[index - seen].hPhysicalMonitor);
                } finally {
                    DestroyPhysicalMonitors(n, pms);
                }
                seen += (int)n;
            }
            throw new ArgumentException("No monitor with index " + index);
        }

        // Returns { current, maximum }.
        public static uint[] GetVcp(int index, byte code) {
            return WithPhysical<uint[]>(index, delegate (IntPtr h) {
                uint cur, max;
                for (int attempt = 0; attempt < 3; attempt++) {
                    if (GetVCPFeatureAndVCPFeatureReply(h, code, IntPtr.Zero, out cur, out max))
                        return new uint[] { cur, max };
                    System.Threading.Thread.Sleep(60);
                }
                throw new Win32Exception(Marshal.GetLastWin32Error(), String.Format("DDC/CI read of VCP 0x{0:X2} failed", code));
            });
        }

        // Safety net: only brightness, contrast and the standard input select.
        public static void SetVcp(int index, byte code, uint value) {
            if (code == 0x10 || code == 0x12) {
                if (value > 100) throw new ArgumentOutOfRangeException("value", "must be 0-100");
            } else if (code == 0x60) {
                if (value != 0x0F && value != 0x10 && value != 0x11 && value != 0x12)
                    throw new ArgumentOutOfRangeException("value", "input must be 0x0F, 0x10, 0x11 or 0x12");
            } else {
                throw new InvalidOperationException(String.Format("Refusing to write VCP 0x{0:X2}", code));
            }
            WithPhysical<bool>(index, delegate (IntPtr h) {
                for (int attempt = 0; attempt < 3; attempt++) {
                    if (SetVCPFeature(h, code, value)) return true;
                    System.Threading.Thread.Sleep(60);
                }
                throw new Win32Exception(Marshal.GetLastWin32Error(), String.Format("DDC/CI write of VCP 0x{0:X2} failed", code));
            });
        }
    }
}
'@
}

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
$DefaultConfig = [ordered]@{
    linux_host     = ''        # IP or hostname of the Linux PC running "lg-monitor serve"
    linux_port     = 47320
    token          = ''        # from "lg-monitor token" on Linux
    monitor_index  = -1        # -1 = auto (first monitor whose id contains monitor_match)
    monitor_match  = 'GSM'     # LG's EDID manufacturer id
    brightness_via = 'local'   # 'local' (DDC/CI from this PC) or 'linux' (ask the Linux listener)
    switch_method  = 'linux'   # 'linux' (recommended) or 'ddc60' (standard VCP 0x60, ignored by the 32GN650)
    ddc60_value    = 15        # 0x0F = DisplayPort-1 for the ddc60 method
}

function Read-Config {
    $cfg = [ordered]@{}
    foreach ($k in $DefaultConfig.Keys) { $cfg[$k] = $DefaultConfig[$k] }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $json = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) {
                if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
            }
        } catch {
            Write-Warning "Could not read $ConfigPath : $($_.Exception.Message)"
        }
    }
    return $cfg
}

function Save-Config($cfg) {
    $dir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($cfg | ConvertTo-Json) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

$script:Config = Read-Config

# --------------------------------------------------------------------------
# Monitor access
# --------------------------------------------------------------------------
function Get-MonitorList { return [LGMonitorSwitch.Ddc]::List() }

function Resolve-MonitorIndex {
    $list = @(Get-MonitorList)
    if ($list.Count -eq 0) { throw 'No monitors with DDC/CI support were found.' }
    $idx = [int]$script:Config.monitor_index
    if ($idx -ge 0) {
        if ($idx -ge $list.Count) { throw "monitor_index $idx does not exist (found $($list.Count) monitors; run -ListMonitors)." }
        return $idx
    }
    $match = [string]$script:Config.monitor_match
    foreach ($m in $list) {
        if ($match -and (("$($m.DeviceId) $($m.DeviceString) $($m.Description)") -match [regex]::Escape($match))) { return $m.Index }
    }
    if ($list.Count -eq 1) { return 0 }
    foreach ($m in $list) {
        try { [void][LGMonitorSwitch.Ddc]::GetVcp($m.Index, 0x10); return $m.Index } catch { }
    }
    throw 'Could not pick the LG monitor automatically; set monitor_index (see -ListMonitors).'
}

function Invoke-Linux([string]$HttpMethod, [string]$Path, $Body = $null) {
    $c = $script:Config
    if (-not $c.linux_host) { throw 'Linux host is not set. Open Settings (or use -Configure -LinuxHost ...).' }
    if (-not $c.token) { throw 'Token is not set. On Linux run "lg-monitor token" and paste it into Settings.' }
    $params = @{
        Uri         = "http://$($c.linux_host):$($c.linux_port)$Path"
        Method      = $HttpMethod
        Headers     = @{ Authorization = "Bearer $($c.token)" }
        TimeoutSec  = 6
        ContentType = 'application/json'
    }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Compress) }
    try {
        return Invoke-RestMethod @params
    } catch {
        $msg = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try { $msg = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { $msg = $_.ErrorDetails.Message }
        }
        throw "Linux listener at $($c.linux_host):$($c.linux_port): $msg"
    }
}

function Get-Levels {
    if ($script:Config.brightness_via -eq 'linux') {
        $r = Invoke-Linux 'GET' '/v1/status'
        return @{ brightness = [int]$r.brightness; contrast = [int]$r.contrast }
    }
    $i = Resolve-MonitorIndex
    $b = [LGMonitorSwitch.Ddc]::GetVcp($i, 0x10)
    $c = [LGMonitorSwitch.Ddc]::GetVcp($i, 0x12)
    return @{ brightness = [int]$b[0]; contrast = [int]$c[0] }
}

function Set-Level([string]$What, [int]$Value) {
    if ($Value -lt 0 -or $Value -gt 100) { throw "$What must be 0-100" }
    if ($script:Config.brightness_via -eq 'linux') {
        [void](Invoke-Linux 'POST' "/v1/$What" @{ value = $Value })
        return
    }
    $code = if ($What -eq 'brightness') { [byte]0x10 } else { [byte]0x12 }
    [LGMonitorSwitch.Ddc]::SetVcp((Resolve-MonitorIndex), $code, [uint32]$Value)
}

function Switch-ToLinux([string]$Using = '') {
    $m = if ($Using) { $Using } else { [string]$script:Config.switch_method }
    if ($m -eq 'ddc60') {
        # Standard MCCS input select. Accepted but IGNORED by the LG 32GN650;
        # kept for other monitors.
        [LGMonitorSwitch.Ddc]::SetVcp((Resolve-MonitorIndex), [byte]0x60, [uint32]$script:Config.ddc60_value)
        return 'Sent VCP 0x60 (standard input select).'
    }
    $r = Invoke-Linux 'POST' '/v1/switch' @{}
    return "Linux switched the monitor to $($r.input)."
}

# --------------------------------------------------------------------------
# Command-line mode
# --------------------------------------------------------------------------
$cliMode = $ListMonitors -or $Get -or $SetBrightness -ge 0 -or $SetContrast -ge 0 -or $SwitchToLinux -or $TestLinux -or $Configure
if ($cliMode) {
    try {
        if ($Configure) {
            if ($PSBoundParameters.ContainsKey('LinuxHost')) { $script:Config.linux_host = $LinuxHost }
            if ($LinuxPort -gt 0) { $script:Config.linux_port = $LinuxPort }
            if ($PSBoundParameters.ContainsKey('Token')) { $script:Config.token = $Token }
            if ($MonitorIndex -ge -1) { $script:Config.monitor_index = $MonitorIndex }
            Save-Config $script:Config
            Write-Output "Saved $ConfigPath"
        }
        if ($ListMonitors) {
            $list = @(Get-MonitorList)
            if ($list.Count -eq 0) { Write-Output 'No DDC/CI capable monitors found.' }
            $auto = $null; try { $auto = Resolve-MonitorIndex } catch { }
            foreach ($m in $list) {
                $mark = if ($m.Index -eq $auto) { '  <- selected' } else { '' }
                $levels = ''
                try { $b = [LGMonitorSwitch.Ddc]::GetVcp($m.Index, 0x10); $levels = "  brightness=$($b[0])" } catch { $levels = '  (no DDC/CI reply)' }
                Write-Output ("{0}  desc='{1}'{2}{3}" -f $m.ToString(), $m.Description, $levels, $mark)
            }
        }
        if ($Get) { $l = Get-Levels; Write-Output "brightness $($l.brightness)"; Write-Output "contrast $($l.contrast)" }
        if ($SetBrightness -ge 0) { Set-Level 'brightness' $SetBrightness; Write-Output "brightness set to $SetBrightness" }
        if ($SetContrast -ge 0) { Set-Level 'contrast' $SetContrast; Write-Output "contrast set to $SetContrast" }
        if ($TestLinux) {
            $p = Invoke-Linux 'GET' '/v1/ping'
            $s = Invoke-Linux 'GET' '/v1/status'
            Write-Output "Linux listener OK (version $($p.version)); brightness $($s.brightness), contrast $($s.contrast)"
        }
        if ($SwitchToLinux) { Write-Output (Switch-ToLinux $Method) }
        exit 0
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
}

# --------------------------------------------------------------------------
# GUI mode
# --------------------------------------------------------------------------
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    if ($Tray) { $relaunch += '-Tray' }
    Start-Process -FilePath $exe -ArgumentList $relaunch -WindowStyle Hidden
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\LGMonitorSwitch', [ref]$created)
if (-not $created) {
    [System.Windows.Forms.MessageBox]::Show('LG Monitor Switch is already running (see the tray icon).', 'LG Monitor Switch') | Out-Null
    exit 0
}

$iconPath = Join-Path $PSScriptRoot 'LGMonitor.ico'
$appIcon = if (Test-Path -LiteralPath $iconPath) { New-Object System.Drawing.Icon($iconPath) } else { [System.Drawing.SystemIcons]::Application }

$font = New-Object System.Drawing.Font('Segoe UI', 10)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'LG Monitor Switch'
$form.Icon = $appIcon
$form.Font = $font
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(380, 250)
$form.AutoScaleMode = 'Dpi'

function New-Label($text, $x, $y, $w = 100) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($w, 24)
    $l.TextAlign = 'MiddleLeft'
    $form.Controls.Add($l); return $l
}

function New-LevelRow($caption, $y) {
    [void](New-Label $caption 16 $y 90)
    $tb = New-Object System.Windows.Forms.TrackBar
    $tb.Minimum = 0; $tb.Maximum = 100; $tb.TickFrequency = 10; $tb.SmallChange = 1; $tb.LargeChange = 10
    $tb.Location = New-Object System.Drawing.Point(106, ($y - 4)); $tb.Size = New-Object System.Drawing.Size(210, 40)
    $tb.AccessibleName = $caption
    $form.Controls.Add($tb)
    $val = New-Label '–' 320 $y 50
    $val.TextAlign = 'MiddleRight'
    return @{ Bar = $tb; Value = $val }
}

$rowB = New-LevelRow 'Brightness' 20
$rowC = New-LevelRow 'Contrast' 70

$switchBtn = New-Object System.Windows.Forms.Button
$switchBtn.Text = 'Switch to Linux'
$switchBtn.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$switchBtn.Location = New-Object System.Drawing.Point(16, 125)
$switchBtn.Size = New-Object System.Drawing.Size(348, 44)
$form.Controls.Add($switchBtn)

$status = New-Label '' 16 180 348
$status.ForeColor = [System.Drawing.Color]::DimGray
$status.AutoEllipsis = $true

$settingsLink = New-Object System.Windows.Forms.LinkLabel
$settingsLink.Text = 'Settings…'
$settingsLink.Location = New-Object System.Drawing.Point(16, 214)
$settingsLink.Size = New-Object System.Drawing.Size(100, 24)
$form.Controls.Add($settingsLink)
$refreshLink = New-Object System.Windows.Forms.LinkLabel
$refreshLink.Text = 'Refresh'
$refreshLink.Location = New-Object System.Drawing.Point(300, 214)
$refreshLink.Size = New-Object System.Drawing.Size(64, 24)
$refreshLink.TextAlign = 'MiddleRight'
$form.Controls.Add($refreshLink)

$script:Updating = $false
function Set-Status([string]$text) { $status.Text = $text }

function Update-Levels {
    Set-Status 'Reading monitor…'
    $form.Refresh()
    try {
        $l = Get-Levels
        $script:Updating = $true
        $rowB.Bar.Value = [Math]::Min(100, [Math]::Max(0, $l.brightness)); $rowB.Value.Text = "$($l.brightness)%"
        $rowC.Bar.Value = [Math]::Min(100, [Math]::Max(0, $l.contrast)); $rowC.Value.Text = "$($l.contrast)%"
        Set-Status ''
    } catch {
        Set-Status $_.Exception.Message
    } finally {
        $script:Updating = $false
    }
}

# Debounce: DDC/CI is slow, so only send the value once the slider rests.
# (Handlers are defined at script scope on purpose: event script blocks run in
# the scope that is current when they fire, so they must not rely on locals.)
$timerB = New-Object System.Windows.Forms.Timer
$timerB.Interval = 300
$timerB.Add_Tick({
    $timerB.Stop()
    try { Set-Level 'brightness' $rowB.Bar.Value; Set-Status '' } catch { Set-Status $_.Exception.Message }
})
$rowB.Bar.Add_ValueChanged({
    $rowB.Value.Text = "$($rowB.Bar.Value)%"
    if (-not $script:Updating) { $timerB.Stop(); $timerB.Start() }
})
$timerC = New-Object System.Windows.Forms.Timer
$timerC.Interval = 300
$timerC.Add_Tick({
    $timerC.Stop()
    try { Set-Level 'contrast' $rowC.Bar.Value; Set-Status '' } catch { Set-Status $_.Exception.Message }
})
$rowC.Bar.Add_ValueChanged({
    $rowC.Value.Text = "$($rowC.Bar.Value)%"
    if (-not $script:Updating) { $timerC.Stop(); $timerC.Start() }
})

function Invoke-SwitchToLinux {
    $switchBtn.Enabled = $false
    Set-Status 'Asking Linux to switch the monitor…'
    $form.Refresh()
    try { Set-Status (Switch-ToLinux) } catch { Set-Status $_.Exception.Message }
    finally { $switchBtn.Enabled = $true }
}
$switchBtn.Add_Click({ Invoke-SwitchToLinux })
$refreshLink.Add_LinkClicked({ Update-Levels })

# ---- Settings dialog ------------------------------------------------------
function Show-Settings {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'LG Monitor Switch – Settings'; $d.Icon = $appIcon; $d.Font = $font
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterParent'; $d.ClientSize = New-Object System.Drawing.Size(460, 300); $d.AutoScaleMode = 'Dpi'
    $y = 16
    $fields = @{}
    foreach ($f in @(@('linux_host', 'Linux PC address'), @('linux_port', 'Listener port'), @('token', 'Token'))) {
        $l = New-Object System.Windows.Forms.Label; $l.Text = $f[1]; $l.Location = New-Object System.Drawing.Point(16, $y); $l.Size = New-Object System.Drawing.Size(130, 24); $l.TextAlign = 'MiddleLeft'
        $t = New-Object System.Windows.Forms.TextBox; $t.Location = New-Object System.Drawing.Point(150, $y); $t.Size = New-Object System.Drawing.Size(290, 24)
        $t.Text = [string]$script:Config[$f[0]]
        if ($f[0] -eq 'token') { $t.UseSystemPasswordChar = $true }
        $d.Controls.Add($l); $d.Controls.Add($t); $fields[$f[0]] = $t; $y += 36
    }
    $l = New-Object System.Windows.Forms.Label; $l.Text = 'Monitor'; $l.Location = New-Object System.Drawing.Point(16, $y); $l.Size = New-Object System.Drawing.Size(130, 24); $l.TextAlign = 'MiddleLeft'
    $combo = New-Object System.Windows.Forms.ComboBox; $combo.DropDownStyle = 'DropDownList'
    $combo.Location = New-Object System.Drawing.Point(150, $y); $combo.Size = New-Object System.Drawing.Size(290, 24)
    [void]$combo.Items.Add('Automatic (LG monitor)')
    $mons = @(); try { $mons = @(Get-MonitorList) } catch { }
    foreach ($m in $mons) { [void]$combo.Items.Add(("{0}: {1} {2}" -f $m.Index, $m.DisplayName, $m.DeviceString)) }
    $sel = [int]$script:Config.monitor_index + 1
    $combo.SelectedIndex = if ($sel -ge 0 -and $sel -lt $combo.Items.Count) { $sel } else { 0 }
    $d.Controls.Add($l); $d.Controls.Add($combo); $y += 36
    $via = New-Object System.Windows.Forms.CheckBox
    $via.Text = 'Change brightness/contrast through the Linux PC'
    $via.Location = New-Object System.Drawing.Point(150, $y); $via.Size = New-Object System.Drawing.Size(300, 24)
    $via.Checked = ($script:Config.brightness_via -eq 'linux')
    $d.Controls.Add($via); $y += 40
    $result = New-Object System.Windows.Forms.Label; $result.Location = New-Object System.Drawing.Point(16, $y)
    $result.Size = New-Object System.Drawing.Size(430, 24); $result.AutoEllipsis = $true; $d.Controls.Add($result); $y += 34
    $test = New-Object System.Windows.Forms.Button; $test.Text = 'Test connection'; $test.Location = New-Object System.Drawing.Point(16, $y); $test.Size = New-Object System.Drawing.Size(140, 32)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Save'; $ok.Location = New-Object System.Drawing.Point(260, $y); $ok.Size = New-Object System.Drawing.Size(85, 32)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = New-Object System.Drawing.Point(355, $y); $cancel.Size = New-Object System.Drawing.Size(85, 32)
    $cancel.DialogResult = 'Cancel'; $d.CancelButton = $cancel; $d.AcceptButton = $ok
    $d.Controls.AddRange(@($test, $ok, $cancel))
    $apply = {
        $script:Config.linux_host = $fields['linux_host'].Text.Trim()
        $port = 0; if ([int]::TryParse($fields['linux_port'].Text.Trim(), [ref]$port) -and $port -gt 0 -and $port -lt 65536) { $script:Config.linux_port = $port }
        $script:Config.token = $fields['token'].Text.Trim()
        $script:Config.monitor_index = $combo.SelectedIndex - 1
        $script:Config.brightness_via = if ($via.Checked) { 'linux' } else { 'local' }
    }
    $test.Add_Click({
        & $apply
        $result.Text = 'Testing…'; $d.Refresh()
        try { $p = Invoke-Linux 'GET' '/v1/ping'; $result.ForeColor = [System.Drawing.Color]::DarkGreen; $result.Text = "Connected to lg-monitor $($p.version) on Linux." }
        catch { $result.ForeColor = [System.Drawing.Color]::DarkRed; $result.Text = $_.Exception.Message }
    })
    # These handlers only fire while ShowDialog() below is running, i.e. while
    # this function's variables are still in scope.
    $ok.Add_Click({ & $apply; Save-Config $script:Config; $d.DialogResult = 'OK'; $d.Close() })
    $saved = $script:Config | ConvertTo-Json
    if ($d.ShowDialog($form) -ne 'OK') {
        # restore the previous values if the user cancelled after testing
        $old = $saved | ConvertFrom-Json
        foreach ($p in $old.PSObject.Properties) { $script:Config[$p.Name] = $p.Value }
    } else {
        Update-Levels
    }
    $d.Dispose()
}
$settingsLink.Add_LinkClicked({ Show-Settings })

# ---- Tray icon ----------------------------------------------------------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $appIcon
$tray.Text = 'LG Monitor Switch'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Open')
$miSwitch = $menu.Items.Add('Switch to Linux')
$miSettings = $menu.Items.Add('Settings…')
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Exit')
$tray.ContextMenuStrip = $menu
$tray.Visible = $true

$script:Exiting = $false
function Show-Main { $form.Show(); $form.WindowState = 'Normal'; $form.Activate(); Update-Levels }
$miOpen.Add_Click({ Show-Main })
$miSwitch.Add_Click({ try { $tray.ShowBalloonTip(3000, 'LG Monitor Switch', (Switch-ToLinux), 'Info') } catch { $tray.ShowBalloonTip(5000, 'LG Monitor Switch', $_.Exception.Message, 'Error') } })
$miSettings.Add_Click({ Show-Main; Show-Settings })
$miExit.Add_Click({ $script:Exiting = $true; $form.Close(); [System.Windows.Forms.Application]::Exit() })
$tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { if ($form.Visible) { $form.Hide() } else { Show-Main } } })

# Closing the window hides it to the tray; "Exit" in the tray menu quits.
$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:Exiting -and $e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; $form.Hide() }
})
$form.Add_Shown({
    if (-not $script:Config.linux_host -or -not $script:Config.token) {
        Set-Status 'Open Settings… to enter the Linux PC address and token.'
    }
    Update-Levels
})

try {
    if ($Tray) { [System.Windows.Forms.Application]::Run() } else { [System.Windows.Forms.Application]::Run($form) }
} finally {
    $tray.Visible = $false
    $tray.Dispose()
    $mutex.ReleaseMutex()
}
