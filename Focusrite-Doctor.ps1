<#
    FOCUSRITE DOCTOR  v1.0
    ======================
    Finds out why music apps (TONEX, AmpliTube, DAWs...) say
        "Cannot open Focusrite USB ASIO. (Error code: 0x54f)"
    and helps fix it.

    HOW TO RUN
      Double-click  Run-Focusrite-Doctor.bat  (keep it in the same folder as this file).

    WHAT IT DOES
      1. Checks the PC: is the Focusrite connected, which driver Windows uses for it,
         is the ASIO driver installed properly, are other apps holding it, Windows
         sound settings, USB power settings and recent errors.
      2. Live test: opens "Focusrite USB ASIO" the same way TONEX does and runs
         1.5 seconds of silent audio through it.
      3. Offers fixes one at a time and re-tests after each one.
         NOTHING on the PC is changed unless you answer Y.
      4. Saves a report on the Desktop and copies it to the clipboard.

    Needs Windows 10/11 (64-bit) and Windows PowerShell 5.1 (built into Windows).
    Options:  -ReportOnly  (check + test only, never offers fixes)   -NoElevate
#>
[CmdletBinding()]
param(
    [switch]$ReportOnly,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# =============================================================================
#  Settings and shared state
# =============================================================================
$Script:ToolVersion        = '1.0'
# Newest Focusrite Windows driver known when this was written: 4.150.0 (17 Aug 2026)
$Script:LatestKnownDriver  = [version]'4.150.0'
$Script:FromBat            = ($env:FOCUSRITE_DOCTOR_BAT -eq '1')
$Script:SelfPath           = $PSCommandPath
$Script:SelfDir            = $PSScriptRoot
$Script:IsAdmin            = $false
$Script:Build              = 0
$Script:IsAmd              = $false
$Script:LogLines           = New-Object 'System.Collections.Generic.List[string]'
$Script:Findings           = New-Object 'System.Collections.Generic.List[object]'
$Script:ModScanReady       = $false
$Script:WatchDlls          = @()
$Script:AsioList           = @()
$Script:MainAsio           = $null
$Script:TopId              = $null
$Script:ModelName          = 'your Focusrite'
$Script:ModelPid           = ''
$Script:ModelGen           = 0
$Script:Binding            = $null
$Script:FocusritePackages  = @()
$Script:MsdOn              = $false
$Script:RateMismatch       = $false
$Script:MicBlocked         = $false
$Script:SelectiveSuspendOn = $false
$Script:DriverOld          = $false
$Script:MsdOffered         = $false
$Script:LastProbeResult    = ''
$Script:EventsUnreadable   = $false
$Script:ReinstallShown     = $false
$Script:Asio4AllApps       = @()
$Script:ProbeWorks         = $null

# USB product IDs (vendor 0x1235 = Focusrite-Novation), taken from the Linux kernel's Focusrite support.
$Script:Models = @{
    '8002' = 'Scarlett 8i6 (1st Gen)';   '8004' = 'Scarlett 18i6 (1st Gen)';  '8006' = 'Scarlett 2i2 (1st Gen)'
    '8008' = 'Saffire 6 USB';            '800A' = 'Scarlett 2i4 (1st Gen)';   '800C' = 'Scarlett 18i20 (1st Gen)'
    '800E' = 'iTrack Solo';              '8010' = 'Forte';                    '8012' = 'Scarlett 6i6 (1st Gen)'
    '8014' = 'Scarlett 18i8 (1st Gen)';  '8016' = 'Scarlett 2i2 (1st Gen)'
    '8201' = 'Scarlett 18i20 (2nd Gen)'; '8202' = 'Scarlett 2i2 (2nd Gen)';   '8203' = 'Scarlett 6i6 (2nd Gen)'
    '8204' = 'Scarlett 18i8 (2nd Gen)'
    '8206' = 'Clarett 2Pre USB';         '8207' = 'Clarett 4Pre USB';         '8208' = 'Clarett 8Pre USB'
    '820A' = 'Clarett+ 2Pre';            '820B' = 'Clarett+ 4Pre';            '820C' = 'Clarett+ 8Pre'
    '8210' = 'Scarlett 2i2 (3rd Gen)';   '8211' = 'Scarlett Solo (3rd Gen)';  '8212' = 'Scarlett 4i4 (3rd Gen)'
    '8213' = 'Scarlett 8i6 (3rd Gen)';   '8214' = 'Scarlett 18i8 (3rd Gen)';  '8215' = 'Scarlett 18i20 (3rd Gen)'
    '8216' = 'Vocaster One';             '8217' = 'Vocaster Two'
    '8218' = 'Scarlett Solo (4th Gen)';  '8219' = 'Scarlett 2i2 (4th Gen)';   '821A' = 'Scarlett 4i4 (4th Gen)'
    '821B' = 'Scarlett 16i16 (4th Gen)'; '821C' = 'Scarlett 18i16 (4th Gen)'; '821D' = 'Scarlett 18i20 (4th Gen)'
    '821E' = 'ISA C8X'
}

# Device Manager problem codes, in plain English.
$Script:ProblemText = @{
    1  = 'not set up correctly';               3  = 'driver damaged or the PC is low on memory'
    10 = 'device cannot start';                12 = 'not enough free resources'
    14 = 'needs a PC restart';                 18 = 'driver needs reinstalling'
    19 = 'registry problem';                   21 = 'being removed'
    22 = 'device is DISABLED';                 24 = 'not present or not working'
    28 = 'NO DRIVER installed';                29 = 'disabled by the firmware'
    31 = 'driver could not load';              32 = 'driver service is disabled'
    37 = 'driver failed to start';             38 = 'old copy of the driver still loaded - restart the PC'
    39 = 'driver file missing or damaged';     41 = 'driver loaded but cannot find the hardware'
    43 = 'device reported a problem and Windows stopped it'
    45 = 'not connected';                      47 = 'prepared for safe removal'
    48 = 'blocked by Windows (incompatible driver)'
    52 = 'driver signature problem'
}

# Music / audio programs that can hold the Focusrite (matched against process names).
$Script:AudioAppRegex = '^(tonex.*|amplitube.*|ableton.*|fl|fl64|fl studio.*|reaper.*|cubase.*|nuendo.*|' +
    'studio one.*|protools.*|cakewalk.*|bitwig.*|reason\d*|audacity.*|waveform.*|mixcraft.*|lmms.*|' +
    'ardour.*|renoise.*|guitar rig.*|bias ?fx.*|th-u.*|archetype.*|neural.*|tonelib.*|obs32|obs64|' +
    'voicemeeter.*|ocenaudio.*|maschine.*|kontakt.*|melodyne.*|samplitude.*|traktor.*|serato.*|' +
    'rekordbox.*|virtualdj.*|ezdrummer.*|superior drummer.*|amp locker.*|s-gear.*|helix native.*)$'

# =============================================================================
#  Output helpers - everything printed is also kept for the report
# =============================================================================
function Log  { param([string]$Text) [void]$Script:LogLines.Add($Text) }
function Say  {
    param([string]$Text = '', [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host $Text -ForegroundColor $Color
    Log $Text
}
function Head { param([string]$Text) Say ''; Say ('=== ' + $Text + ' ' + ('=' * [Math]::Max(3, 66 - $Text.Length))) Cyan }
function Good { param([string]$Text) Say ('  [ OK ] ' + $Text) Green }
function Warn { param([string]$Text) Say ('  [ !! ] ' + $Text) Yellow }
function Bad  { param([string]$Text) Say ('  [FAIL] ' + $Text) Red }
function Info { param([string]$Text) Say ('         ' + $Text) Gray }
function Step { param([string]$Text) Say ('  ' + $Text) White }

function Add-Finding {
    param([ValidateSet('PROBLEM', 'WARN', 'INFO')][string]$Level, [string]$Text)
    $Script:Findings.Add([pscustomobject]@{ Level = $Level; Text = $Text })
}

# Yes/No question. Enter = the suggested answer. Also accepts the Arabic-keyboard Y/N keys.
# -Changes: the answer changes something on the PC, so Enter alone is not enough - Y must be typed.
function Ask {
    param([string]$Question, [bool]$Default = $true, [switch]$Changes)
    $hint = '[Y/n]'
    if (-not $Default) { $hint = '[y/N]' }
    if ($Changes) { $hint = '[y/n]' }
    for ($try = 1; $try -le 5; $try++) {
        Write-Host ''
        $answer = [string](Read-Host ('  >> ' + $Question + ' ' + $hint))
        $t = $answer.Trim().ToLowerInvariant()
        Log ('  >> ' + $Question + ' ' + $hint + ' ' + $answer)
        if ($t -eq '' -and -not $Changes) { return $Default }
        if ($t -eq 'y' -or $t -eq 'yes' -or $t -eq [string][char]0x063A) { return $true }
        if ($t -eq 'n' -or $t -eq 'no' -or $t -eq [string][char]0x0649) { return $false }
        if ($t -eq '') { Write-Host '     This changes something on your PC, so please type Y (yes) or N (no), then press Enter.' -ForegroundColor DarkGray }
        else { Write-Host '     Please type Y (yes) or N (no), then press Enter.' -ForegroundColor DarkGray }
    }
    # No usable answer after 5 tries (or no keyboard at all): never take that as a yes to a change.
    Log '     (no usable answer)'
    return ($Default -and -not $Changes)
}

function Wait-Enter {
    param([string]$Message = 'Press Enter to continue')
    [void](Read-Host ('  >> ' + $Message))
    Log ('  >> ' + $Message)
}

# Returns $true when a key "S" was pressed (used to skip a waiting step).
function Test-SkipKey {
    try {
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq [ConsoleKey]::S) { return $true }
        }
    } catch { }
    return $false
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# =============================================================================
#  Registry helpers (always read the 64-bit view unless told otherwise)
# =============================================================================
function Open-RegKey {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$Path,
        [Microsoft.Win32.RegistryView]$View = [Microsoft.Win32.RegistryView]::Registry64
    )
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
        return $base.OpenSubKey($Path)
    } catch { return $null }
}

function Get-RegValue {
    param(
        [Microsoft.Win32.RegistryHive]$Hive,
        [string]$Path,
        [string]$Name,
        [Microsoft.Win32.RegistryView]$View = [Microsoft.Win32.RegistryView]::Registry64
    )
    $k = Open-RegKey -Hive $Hive -Path $Path -View $View
    if ($null -eq $k) { return $null }
    try { return $k.GetValue($Name) } catch { return $null } finally { $k.Close() }
}

# Programs from "Apps & features" whose name matches a pattern.
function Get-InstalledApps {
    param([string]$Pattern)
    $found = @{}
    $roots = @(
        @([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64),
        @([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32),
        @([Microsoft.Win32.RegistryHive]::CurrentUser,  [Microsoft.Win32.RegistryView]::Registry64)
    )
    foreach ($r in $roots) {
        $k = Open-RegKey -Hive $r[0] -Path 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -View $r[1]
        if ($null -eq $k) { continue }
        foreach ($sub in $k.GetSubKeyNames()) {
            $sk = $null
            try {
                $sk = $k.OpenSubKey($sub)
                if ($null -eq $sk) { continue }
                $name = [string]$sk.GetValue('DisplayName')
                if ($name -and $name -match $Pattern) {
                    $ver = [string]$sk.GetValue('DisplayVersion')
                    $key = $name + '|' + $ver
                    if (-not $found.ContainsKey($key)) {
                        $found[$key] = [pscustomobject]@{
                            Name      = $name
                            Version   = $ver
                            Publisher = [string]$sk.GetValue('Publisher')
                            Uninstall = [string]$sk.GetValue('UninstallString')
                        }
                    }
                }
            } catch {
            } finally {
                if ($sk) { $sk.Close() }
            }
        }
        $k.Close()
    }
    @($found.Values | Sort-Object Name)
}

# =============================================================================
#  The Focusrite as a USB device
# =============================================================================
function Format-ShortId {
    param([string]$Id)
    $parts = $Id -split '\\'
    if ($parts.Count -ge 2) { return ($parts[0] + '\' + $parts[1]) }
    return $Id
}

function Get-ModelInfo {
    param([string]$InstanceId)
    $pidHex = ''
    if ($InstanceId -match 'PID_([0-9A-Fa-f]{4})') { $pidHex = $Matches[1].ToUpper() }
    $name = $Script:Models[$pidHex]
    if (-not $name) { $name = 'Focusrite/Novation device (USB product id ' + $pidHex + ')' }
    $gen = 0
    if     ($pidHex -match '^821[0-5]$')   { $gen = 3 }
    elseif ($pidHex -match '^821[89A-D]$') { $gen = 4 }
    elseif ($pidHex -match '^820[1-4]$')   { $gen = 2 }
    elseif ($pidHex -match '^80')          { $gen = 1 }
    [pscustomobject]@{ Pid = $pidHex; Name = $name; Gen = $gen }
}

# All Focusrite device nodes Windows knows (not the speaker/mic entries).
function Get-FocusriteNodes {
    param([switch]$IncludeNotPresent)
    $raw = @()
    $fromPnp = $false
    try {
        if ($IncludeNotPresent) { $raw = @(Get-PnpDevice -ErrorAction Stop) }
        else                    { $raw = @(Get-PnpDevice -PresentOnly -ErrorAction Stop) }
        $fromPnp = $true
    } catch {
        try { $raw = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop) } catch { $raw = @() }
    }
    foreach ($d in $raw) {
        $id = [string]$d.InstanceId
        if (-not $id) { $id = [string]$d.PNPDeviceID }
        $name = [string]$d.FriendlyName
        if (-not $name) { $name = [string]$d.Name }
        $cls = [string]$d.Class
        if (-not $cls) { $cls = [string]$d.PNPClass }
        if ($cls -eq 'AudioEndpoint') { continue }
        if (($id -match 'VID_1235') -or ($name -match 'Focusrite|Scarlett|Clarett|Vocaster') -or ([string]$d.Manufacturer -match 'Focusrite')) {
            $present = $true
            if ($fromPnp) { $present = [bool]$d.Present }
            [pscustomobject]@{
                InstanceId   = $id
                Name         = $name
                Class        = $cls
                Status       = [string]$d.Status
                Code         = [int]$d.ConfigManagerErrorCode
                Service      = [string]$d.Service
                Manufacturer = [string]$d.Manufacturer
                Present      = $present
            }
        }
    }
}

# Instance IDs of connected Focusrite USB devices (fast - used while waiting for re-plugs).
function Get-FocusriteTopIds {
    $list = @()
    try {
        $list = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPDeviceID LIKE 'USB\\VID[_]1235%'" -ErrorAction Stop)
    } catch {
        try { $list = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Where-Object { [string]$_.PNPDeviceID -like 'USB\VID_1235*' }) } catch { $list = @() }
    }
    @($list | ForEach-Object { [string]$_.PNPDeviceID } | Where-Object { $_ -match '^USB\\VID_1235&PID_[0-9A-Fa-f]{4}\\' })
}

function Wait-ForFocusrite {
    param([bool]$Present, [int]$TimeoutSec = 60, [switch]$AllowSkip)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $now = (@(Get-FocusriteTopIds).Count -gt 0)
        if ($now -eq $Present) { return $true }
        if ($AllowSkip -and (Test-SkipKey)) { return $false }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

function Get-DevProp {
    param([string]$InstanceId, [string]$Key)
    try { return (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $Key -ErrorAction Stop).Data } catch { return $null }
}

# What the Focusrite is plugged into (a root hub = a port on the PC itself).
function Get-ParentInfo {
    param([string]$InstanceId)
    $parentId = [string](Get-DevProp -InstanceId $InstanceId -Key 'DEVPKEY_Device_Parent')
    if (-not $parentId) { return $null }
    $name = ''
    try { $name = [string](Get-PnpDevice -InstanceId $parentId -ErrorAction Stop).FriendlyName } catch { }
    [pscustomobject]@{ Id = $parentId; Name = $name; IsRootHub = ($parentId -match '^USB\\ROOT_HUB') }
}

# 3rd/4th Gen Scarletts start in "MSD" / "Easy Start" mode, where they also act as a small USB disk.
function Test-MsdMode {
    param($Nodes)
    if ($null -eq $Nodes) { $Nodes = @(Get-FocusriteNodes) }
    foreach ($n in @($Nodes)) {
        if ($n.InstanceId -match 'VID_1235' -and ($n.Service -eq 'USBSTOR' -or $n.Class -eq 'DiskDrive')) { return $true }
        if ($n.Class -eq 'DiskDrive' -and $n.Name -match 'Scarlett|Focusrite') { return $true }
    }
    try {
        $disks = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop | Where-Object {
            ([string]$_.Model -match 'Scarlett|Focusrite|Welcome Disk|Easy Start') -or ([string]$_.PNPDeviceID -match 'SCARLETT|FOCUSRIT')
        })
        if ($disks.Count -gt 0) { return $true }
    } catch { }
    return $false
}

# Which driver Windows has attached to the Focusrite: Focusrite's own, or Microsoft's generic one?
function Get-DriverBinding {
    param($Nodes)
    $signed = @()
    try { $signed = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter "DeviceID LIKE '%VID_1235%'" -ErrorAction Stop) } catch { }
    $focusrite = $false
    $generic = $false
    $version = $null
    foreach ($s in $signed) {
        if ([string]$s.DriverProviderName -match 'Focusrite') {
            $focusrite = $true
            $v = $null
            if ([version]::TryParse([string]$s.DriverVersion, [ref]$v)) {
                if ($null -eq $version -or $v -gt $version) { $version = $v }
            }
        }
        if ([string]$s.InfName -match '^(wdma_usb|usbaudio2?)\.inf$') { $generic = $true }
    }
    foreach ($n in @($Nodes)) {
        if ($null -eq $n) { continue }
        if ([string]$n.Service -match '^usbaudio2?$') { $generic = $true }
        if ([string]$n.Service -match 'focusrite')    { $focusrite = $true }
    }
    [pscustomobject]@{ Signed = $signed; Focusrite = $focusrite; Generic = $generic; Version = $version }
}

# Focusrite driver packages stored in Windows (used to re-attach the right driver).
function Get-FocusriteDriverPackages {
    $res = @()
    try {
        $lines = @(& pnputil.exe /enum-drivers 2>$null)
        if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { $lines = @(& pnputil.exe -e 2>$null) }
        $text = ($lines -join "`n")
        foreach ($block in ($text -split "`n\s*`n")) {
            if ($block -match 'Focusrite') {
                $inf = ''
                $ver = ''
                if ($block -match '(oem\d+\.inf)') { $inf = $Matches[1] }
                if ($block -match '(\d+\.\d+\.\d+\.\d+)') { $ver = $Matches[1] }
                $res += [pscustomobject]@{ Inf = $inf; Version = $ver }
            }
        }
    } catch { }
    $res
}

# =============================================================================
#  ASIO drivers (the list TONEX / AmpliTube show)
# =============================================================================
function Get-AsioDrivers {
    $out = @()
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $bits = 64
        if ($view -eq [Microsoft.Win32.RegistryView]::Registry32) { $bits = 32 }
        if ($bits -eq 32 -and -not [Environment]::Is64BitOperatingSystem) { continue }
        $k = Open-RegKey -Hive LocalMachine -Path 'SOFTWARE\ASIO' -View $view
        if ($null -eq $k) { continue }
        foreach ($name in $k.GetSubKeyNames()) {
            $clsid = ''
            $sk = $k.OpenSubKey($name)
            if ($sk) { $clsid = ([string]$sk.GetValue('CLSID')).Trim(); $sk.Close() }
            $dll = ''
            if ($clsid) {
                $ck = Open-RegKey -Hive LocalMachine -Path ('SOFTWARE\Classes\CLSID\' + $clsid + '\InprocServer32') -View $view
                if ($ck) { $dll = [string]$ck.GetValue(''); $ck.Close() }
            }
            $path = ''
            $exists = $false
            $fileVer = ''
            if ($dll) {
                $path = [Environment]::ExpandEnvironmentVariables($dll.Trim().Trim('"'))
                if ($bits -eq 32) { $path = $path -replace '(?i)\\System32\\', '\SysWOW64\' }
                $exists = Test-Path -LiteralPath $path
                if ($exists) { try { $fileVer = [string](Get-Item -LiteralPath $path).VersionInfo.FileVersion } catch { } }
            }
            $out += [pscustomobject]@{
                Name = $name; Bits = $bits; Clsid = $clsid; Dll = $path; DllExists = $exists; DllVersion = $fileVer
            }
        }
        $k.Close()
    }
    $out
}

# =============================================================================
#  Which processes have a given DLL (e.g. the Focusrite ASIO driver) loaded?
#  Small C# helper so it also sees 32-bit programs.
# =============================================================================
$Script:ModScanCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class FrModScan
{
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int processId);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("psapi.dll")] static extern bool EnumProcessModulesEx(IntPtr process, [Out] IntPtr[] modules, int size, out int needed, int filter);
    [DllImport("psapi.dll", CharSet = CharSet.Unicode)] static extern int GetModuleFileNameExW(IntPtr process, IntPtr module, StringBuilder name, int size);

    // Returns "processId|full path" for every loaded module whose file name is in fileNames.
    public static string[] Find(int[] processIds, string[] fileNames)
    {
        Dictionary<string, bool> wanted = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        foreach (string f in fileNames) { if (!String.IsNullOrEmpty(f)) wanted[f] = true; }
        List<string> hits = new List<string>();
        foreach (int id in processIds)
        {
            IntPtr h = OpenProcess(0x0410, false, id); // QUERY_INFORMATION | VM_READ
            if (h == IntPtr.Zero) continue;
            try
            {
                IntPtr[] mods = new IntPtr[1024];
                int needed;
                if (!EnumProcessModulesEx(h, mods, mods.Length * IntPtr.Size, out needed, 3)) continue;
                int count = needed / IntPtr.Size;
                if (count > mods.Length)
                {
                    mods = new IntPtr[count + 128];
                    if (!EnumProcessModulesEx(h, mods, mods.Length * IntPtr.Size, out needed, 3)) continue;
                    count = Math.Min(needed / IntPtr.Size, mods.Length);
                }
                StringBuilder sb = new StringBuilder(1024);
                for (int i = 0; i < count; i++)
                {
                    sb.Length = 0;
                    if (GetModuleFileNameExW(h, mods[i], sb, sb.Capacity) <= 0) continue;
                    string path = sb.ToString();
                    string file = System.IO.Path.GetFileName(path);
                    if (wanted.ContainsKey(file)) hits.Add(id.ToString() + "|" + path);
                }
            }
            catch { }
            finally { CloseHandle(h); }
        }
        return hits.ToArray();
    }
}
'@

function Initialize-ModScan {
    if ($Script:ModScanReady) { return }
    try {
        if (-not ('FrModScan' -as [type])) {
            Add-Type -TypeDefinition $Script:ModScanCode -Language CSharp -IgnoreWarnings -ErrorAction Stop
        }
        $Script:ModScanReady = $true
    } catch {
        Log ('(process scanner unavailable: ' + $_.Exception.Message + ')')
    }
}

function Find-ProcessesUsingDll {
    param([string[]]$FileNames)
    $names = @($FileNames | Where-Object { $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) { return @() }
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.Id -gt 4 })
    $result = @()
    $done = $false
    if ($Script:ModScanReady) {
        try {
            $ids = [int[]]@($procs | ForEach-Object { $_.Id })
            $hits = [FrModScan]::Find($ids, [string[]]$names)
            foreach ($h in $hits) {
                $parts = $h -split '\|', 2
                $procId = [int]$parts[0]
                $pp = $procs | Where-Object { $_.Id -eq $procId } | Select-Object -First 1
                $result += [pscustomobject]@{ Id = $procId; Name = [string]$pp.ProcessName; Module = $parts[1] }
            }
            $done = $true
        } catch { }
    }
    if (-not $done) {
        foreach ($p in $procs) {
            try {
                foreach ($m in $p.Modules) {
                    if ($names -contains $m.ModuleName) { $result += [pscustomobject]@{ Id = $p.Id; Name = $p.ProcessName; Module = $m.FileName } }
                }
            } catch { }
        }
    }
    $result
}

# Programs that are (or may be) using the Focusrite right now.
function Get-BusyApps {
    $busy = @{}
    foreach ($h in @(Find-ProcessesUsingDll -FileNames $Script:WatchDlls)) {
        if ($h.Name -match 'focusrite') { continue }
        $why = 'has the Focusrite ASIO driver open'
        if ($h.Module -match 'asio4all') { $why = 'has ASIO4ALL open (ASIO4ALL can lock the Focusrite)' }
        $busy[$h.Id] = [pscustomobject]@{ Id = $h.Id; Name = $h.Name; Reason = $why }
    }
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.Id -eq $PID -or $busy.ContainsKey($p.Id)) { continue }
        if ($p.ProcessName -match 'focusrite') { continue }
        if ($p.ProcessName -match $Script:AudioAppRegex) {
            $why = 'music/audio app (it may be using the Focusrite)'
            if ($p.ProcessName -match 'voicemeeter') { $why = 'Voicemeeter (it can lock the Focusrite)' }
            $busy[$p.Id] = [pscustomobject]@{ Id = $p.Id; Name = $p.ProcessName; Reason = $why }
        }
    }
    @($busy.Values)
}

# =============================================================================
#  Windows sound settings for the Focusrite
# =============================================================================
# Decodes the "Default Format" Windows stores for a sound device (a WAVEFORMATEX blob).
function ConvertFrom-WaveFormat {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 16) { return $null }
    $o = 0
    if ($Bytes.Length -ge 26 -and $Bytes[0] -eq 0x41 -and $Bytes[1] -eq 0) { $o = 8 }   # skip the PROPVARIANT header
    if ($Bytes.Length -lt ($o + 16)) { return $null }
    $tag  = [BitConverter]::ToUInt16($Bytes, $o)
    $ch   = [BitConverter]::ToUInt16($Bytes, $o + 2)
    $rate = [BitConverter]::ToUInt32($Bytes, $o + 4)
    $bits = [BitConverter]::ToUInt16($Bytes, $o + 14)
    if ($tag -eq 0xFFFE -and $Bytes.Length -ge ($o + 20)) {
        $valid = [BitConverter]::ToUInt16($Bytes, $o + 18)
        if ($valid -gt 0) { $bits = $valid }
    }
    if ($rate -lt 4000 -or $rate -gt 768000) { return $null }
    [pscustomobject]@{ Rate = [int]$rate; Bits = [int]$bits; Channels = [int]$ch }
}

function Get-FocusriteEndpoints {
    $res = @()
    foreach ($flow in @('Render', 'Capture')) {
        $k = Open-RegKey -Hive LocalMachine -Path ('SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\' + $flow)
        if ($null -eq $k) { continue }
        foreach ($g in $k.GetSubKeyNames()) {
            $dk = $null
            $pk = $null
            try {
                $dk = $k.OpenSubKey($g)
                if ($null -eq $dk) { continue }
                $pk = $dk.OpenSubKey('Properties')
                if ($null -eq $pk) { continue }
                $ep  = [string]$pk.GetValue('{a45c254e-df1c-4efd-8020-67d146a850e0},2')   # e.g. "Speakers"
                $dev = [string]$pk.GetValue('{b3f8fa53-0004-438e-9003-51a46e139bfc},6')   # e.g. "Focusrite USB Audio"
                if (($ep + ' ' + $dev) -notmatch 'Focusrite|Scarlett|Clarett|Vocaster') { continue }
                $state = 0
                try { $state = ([int]$dk.GetValue('DeviceState')) -band 0xF } catch { }
                $fmt = ConvertFrom-WaveFormat ([byte[]]$pk.GetValue('{f19f064d-082c-4e27-bc73-6882a1bb8e4c},0'))
                # "Allow exclusive control": normally a DWORD (0 = off). Anything else is treated as "not set".
                $excl = $null
                $exRaw = $pk.GetValue('{b3f8fa53-0004-438e-9003-51a46e139bfc},3')
                if ($exRaw -is [int]) { $excl = $exRaw }
                $stateText = 'state ' + $state
                switch ($state) { 1 { $stateText = 'active' } 2 { $stateText = 'DISABLED' } 4 { $stateText = 'not present' } 8 { $stateText = 'unplugged' } }
                $flowName = 'Playback'
                if ($flow -eq 'Capture') { $flowName = 'Recording' }
                $rate = $null; $bits = $null; $chans = $null
                if ($fmt) { $rate = $fmt.Rate; $bits = $fmt.Bits; $chans = $fmt.Channels }
                $res += [pscustomobject]@{
                    Flow = $flowName; Name = ($ep + ' (' + $dev + ')'); State = $state; StateText = $stateText
                    Rate = $rate; Bits = $bits; Channels = $chans; Exclusive = $excl
                }
            } catch {
            } finally {
                if ($pk) { $pk.Close() }
                if ($dk) { $dk.Close() }
            }
        }
        $k.Close()
    }
    $res
}

# USB selective suspend (Windows powering down idle USB devices) for the active power plan.
function Get-UsbSelectiveSuspend {
    try {
        $sub = '2a737441-1930-4402-8d77-b2bebba308a3'
        $set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
        $txt = (@(& powercfg.exe /q SCHEME_CURRENT $sub $set 2>$null) -join "`n")
        $m = [regex]::Matches($txt, '0x([0-9a-fA-F]{8})')
        if ($m.Count -ge 2) {
            return [pscustomobject]@{
                AC = [Convert]::ToInt32($m[$m.Count - 2].Groups[1].Value, 16)
                DC = [Convert]::ToInt32($m[$m.Count - 1].Groups[1].Value, 16)
            }
        }
    } catch { }
    return $null
}

# =============================================================================
#  Event logs
# =============================================================================
function Get-PnpConfigEvents {
    $res = @()
    $evs = @()
    try {
        $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Kernel-PnP/Configuration'; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 4000 -ErrorAction Stop)
    } catch {
        if ([string]$_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') { $Script:EventsUnreadable = $true }
        return $res
    }
    foreach ($e in $evs) {
        $hit = $false
        foreach ($p in $e.Properties) { if ([string]$p.Value -match 'VID_1235') { $hit = $true; break } }
        if (-not $hit) { continue }
        $data = @{}
        try {
            $x = [xml]$e.ToXml()
            foreach ($d in @($x.Event.EventData.Data)) { $data[$d.GetAttribute('Name')] = [string]$d.InnerText }
        } catch { }
        $res += [pscustomobject]@{
            Time = $e.TimeCreated; Id = $e.Id; Inf = $data['DriverName']; Provider = $data['DriverProvider']
            Service = $data['ServiceName']; Problem = $data['Problem']
        }
        if ($res.Count -ge 10) { break }
    }
    $res
}

function Get-AppCrashEvents {
    $res = @()
    try {
        $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 300 -ErrorAction Stop)
        foreach ($e in $evs) {
            if ($e.Properties.Count -lt 4) { continue }
            $app = [string]$e.Properties[0].Value
            if ($app -match 'tonex|amplitube') {
                $res += [pscustomobject]@{ Time = $e.TimeCreated; App = $app; Module = [string]$e.Properties[3].Value }
                if ($res.Count -ge 5) { break }
            }
        }
    } catch { }
    $res
}

# =============================================================================
#  LIVE TEST - opens the ASIO driver exactly like TONEX does.
#  It runs in a separate, hidden PowerShell so that a crashing or frozen driver
#  can't take this window down with it.
# =============================================================================
$Script:ProbeScriptText = @'
param([string]$Clsid, [switch]$NoStream)
$ErrorActionPreference = 'Stop'
try {
    if (-not ('FrAsioProbe' -as [type])) {
        Add-Type -Language CSharp -IgnoreWarnings -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class FrAsioProbe
{
    [DllImport("ole32.dll")] static extern int CoInitializeEx(IntPtr reserved, int coInit);
    [DllImport("ole32.dll")] static extern void CoUninitialize();
    [DllImport("ole32.dll")] static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, int context, ref Guid iid, out IntPtr obj);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] static extern bool PeekMessage(out NativeMsg msg, IntPtr hwnd, uint filterMin, uint filterMax, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref NativeMsg msg);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref NativeMsg msg);

    [StructLayout(LayoutKind.Sequential)]
    struct NativeMsg
    {
        public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam;
        public uint time; public int x; public int y;
    }

    // IASIO methods. On 64-bit Windows the calling convention is ignored;
    // on 32-bit, IASIO uses thiscall (unlike normal COM).
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]  delegate uint ReleaseFn(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.ThisCall)] delegate int InitFn(IntPtr self, IntPtr sysHandle);
    [UnmanagedFunctionPointer(CallingConvention.ThisCall)] delegate void TextFn(IntPtr self, IntPtr text);
    [UnmanagedFunctionPointer(CallingConvention.ThisCall)] delegate int PlainFn(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.ThisCall)] delegate int TwoIntFn(IntPtr self, out int a, out int b);
    [UnmanagedFunctionPointer(CallingConvention.ThisCall)] delegate int FourIntFn(IntPtr self, out int a, out int b, out int c, out int d);
    [UnmanagedFunctionPointer(CallingConvention.ThisCall)] delegate int RateFn(IntPtr self, double rate);
    [UnmanagedFunctionPointer(CallingConvention.ThisCall)] delegate int GetRateFn(IntPtr self, out double rate);
    [UnmanagedFunctionPointer(CallingConvention.ThisCall)] delegate int PtrFn(IntPtr self, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.ThisCall)] delegate int CreateBuffersFn(IntPtr self, IntPtr infos, int count, int frames, IntPtr callbacks);

    // Callbacks the driver calls while audio runs (plain C functions).
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void BufferSwitchCb(int index, int direct);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void RateChangedCb(double rate);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int MessageCb(int selector, int value, IntPtr message, IntPtr opt);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr TimeInfoCb(IntPtr timeInfo, int index, int direct);

    // Positions of the IASIO methods in the driver's function table.
    const int SlotRelease = 2, SlotInit = 3, SlotName = 4, SlotVersion = 5, SlotError = 6, SlotStart = 7, SlotStop = 8,
              SlotChannels = 9, SlotLatencies = 10, SlotBufferSize = 11, SlotCanRate = 12, SlotGetRate = 13,
              SlotChannelInfo = 18, SlotCreateBuffers = 19, SlotDisposeBuffers = 20;

    static IntPtr asio = IntPtr.Zero;
    static IntPtr vtable = IntPtr.Zero;
    static List<string> output = new List<string>();
    static int blockCount;
    static int resetRequested;
    static IntPtr[] outA;
    static IntPtr[] outB;
    static byte[] silence;
    static BufferSwitchCb keepSwitch;
    static RateChangedCb keepRate;
    static MessageCb keepMessage;
    static TimeInfoCb keepTime;

    public static string[] Run(string clsid, bool streamTest, int timeoutMs)
    {
        output = new List<string>();
        bool finished = RunOn(ApartmentState.STA, clsid, streamTest, timeoutMs);
        if (finished && Has("CREATE_HR=0x80004002"))
        {
            // Driver registered as free-threaded: try again from a multi-threaded apartment.
            output = new List<string>();
            finished = RunOn(ApartmentState.MTA, clsid, streamTest, timeoutMs);
        }
        List<string> o = output;
        lock (o)
        {
            if (!finished) o.Add("RESULT=HANG");
            return o.ToArray();
        }
    }

    static bool Has(string line)
    {
        List<string> o = output;
        lock (o) { return o.Contains(line); }
    }

    static bool RunOn(ApartmentState apartment, string clsid, bool streamTest, int timeoutMs)
    {
        bool sta = apartment == ApartmentState.STA;
        Thread worker = new Thread(delegate() { Work(clsid, streamTest, sta); });
        worker.IsBackground = true;
        worker.SetApartmentState(apartment);
        worker.Start();
        return worker.Join(timeoutMs);
    }

    static void Put(string key, object value)
    {
        string v = value == null ? "" : value.ToString();
        v = v.Replace("\r", " ").Replace("\n", " ").Trim();
        List<string> o = output;
        lock (o) { o.Add(key + "=" + v); }
    }

    static T Fn<T>(int slot) where T : class
    {
        IntPtr p = Marshal.ReadIntPtr(vtable, slot * IntPtr.Size);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(p, typeof(T));
    }

    static string ReadText(int slot)
    {
        IntPtr buf = Marshal.AllocHGlobal(512);
        try
        {
            for (int i = 0; i < 512; i++) Marshal.WriteByte(buf, i, 0);
            Fn<TextFn>(slot)(asio, buf);
            Marshal.WriteByte(buf, 511, 0);
            string s = Marshal.PtrToStringAnsi(buf);
            return s == null ? "" : s.Trim();
        }
        finally { Marshal.FreeHGlobal(buf); }
    }

    static void Work(string clsidText, bool streamTest, bool sta)
    {
        int coHr = -1;
        try
        {
            coHr = CoInitializeEx(IntPtr.Zero, sta ? 2 : 0);
            Put("ARCH", IntPtr.Size == 8 ? "64-bit" : "32-bit");
            Put("APARTMENT", sta ? "STA" : "MTA");
            Guid clsid = new Guid(clsidText);
            Put("STAGE", "create");
            IntPtr obj;
            int hr = CoCreateInstance(ref clsid, IntPtr.Zero, 1, ref clsid, out obj);
            if (hr != 0 || obj == IntPtr.Zero)
            {
                Put("CREATE_HR", "0x" + hr.ToString("X8"));
                Put("RESULT", "CREATE_FAILED");
                return;
            }
            asio = obj;
            vtable = Marshal.ReadIntPtr(obj);
            try
            {
                Put("STAGE", "init");
                IntPtr hwnd = GetConsoleWindow();
                if (hwnd == IntPtr.Zero) hwnd = GetDesktopWindow();
                int ok = Fn<InitFn>(SlotInit)(asio, hwnd);
                if (ok == 0)
                {
                    Put("ERROR", ReadText(SlotError));
                    Put("RESULT", "INIT_FAILED");
                    return;
                }
                Put("STAGE", "info");
                Put("NAME", ReadText(SlotName));
                Put("DRIVER_VERSION", Fn<PlainFn>(SlotVersion)(asio));
                int ins, outs;
                int e = Fn<TwoIntFn>(SlotChannels)(asio, out ins, out outs);
                Put("CHANNELS_ERR", e);
                Put("INPUTS", ins);
                Put("OUTPUTS", outs);
                double rate;
                e = Fn<GetRateFn>(SlotGetRate)(asio, out rate);
                Put("RATE_ERR", e);
                Put("RATE", ((long)Math.Round(rate)).ToString());
                RateFn canRate = Fn<RateFn>(SlotCanRate);
                StringBuilder rates = new StringBuilder();
                double[] candidates = new double[] { 44100, 48000, 88200, 96000, 176400, 192000 };
                foreach (double r in candidates)
                {
                    if (canRate(asio, r) == 0)
                    {
                        if (rates.Length > 0) rates.Append(",");
                        rates.Append((long)r);
                    }
                }
                Put("RATES_OK", rates.ToString());
                int bMin, bMax, bPref, bGran;
                e = Fn<FourIntFn>(SlotBufferSize)(asio, out bMin, out bMax, out bPref, out bGran);
                Put("BUFFER_ERR", e);
                Put("BUFFER", bMin + "/" + bMax + "/" + bPref + "/" + bGran);
                Put("BUFFER_PREF", bPref);
                if (!streamTest) Put("STREAM", "SKIPPED");
                else if (e != 0 || bPref <= 0) Put("STREAM", "SKIPPED_NO_BUFFER");
                else if (ins + outs <= 0) Put("STREAM", "SKIPPED_NO_CHANNELS");
                else { Put("STAGE", "stream"); StreamTest(ins, outs, bPref, rate); }
                Put("STAGE", "done");
                Put("RESULT", "OK");
            }
            finally
            {
                try { Fn<ReleaseFn>(SlotRelease)(asio); } catch { }
                asio = IntPtr.Zero;
            }
        }
        catch (Exception ex)
        {
            Put("EXCEPTION", ex.GetType().Name + ": " + ex.Message);
            Put("RESULT", "EXCEPTION");
        }
        finally
        {
            if (coHr >= 0) CoUninitialize();
        }
    }

    // Starts audio for 1.5 seconds (inputs + outputs, outputs filled with silence) and counts the blocks.
    static void StreamTest(int ins, int outs, int frames, double rate)
    {
        int nIn = Math.Min(ins, 2);
        int nOut = Math.Min(outs, 2);
        int n = nIn + nOut;
        int bytesPerSample = 4;
        if (nOut > 0)
        {
            IntPtr ci = Marshal.AllocHGlobal(64);
            try
            {
                for (int i = 0; i < 64; i++) Marshal.WriteByte(ci, i, 0);
                if (Fn<PtrFn>(SlotChannelInfo)(asio, ci) == 0)
                {
                    int type = Marshal.ReadInt32(ci, 16);
                    Put("SAMPLE_TYPE", type);
                    bytesPerSample = BytesPerSample(type);
                }
            }
            finally { Marshal.FreeHGlobal(ci); }
        }
        int infoSize = 8 + 2 * IntPtr.Size;
        IntPtr infos = Marshal.AllocHGlobal(infoSize * n);
        IntPtr callbacks = Marshal.AllocHGlobal(4 * IntPtr.Size);
        bool created = false;
        bool started = false;
        try
        {
            for (int i = 0; i < infoSize * n; i++) Marshal.WriteByte(infos, i, 0);
            for (int i = 0; i < n; i++)
            {
                bool isInput = i < nIn;
                Marshal.WriteInt32(infos, i * infoSize, isInput ? 1 : 0);
                Marshal.WriteInt32(infos, i * infoSize + 4, isInput ? i : i - nIn);
            }
            keepSwitch = OnBufferSwitch;
            keepRate = OnRateChanged;
            keepMessage = OnMessage;
            keepTime = OnTimeInfo;
            Marshal.WriteIntPtr(callbacks, 0, Marshal.GetFunctionPointerForDelegate(keepSwitch));
            Marshal.WriteIntPtr(callbacks, IntPtr.Size, Marshal.GetFunctionPointerForDelegate(keepRate));
            Marshal.WriteIntPtr(callbacks, 2 * IntPtr.Size, Marshal.GetFunctionPointerForDelegate(keepMessage));
            Marshal.WriteIntPtr(callbacks, 3 * IntPtr.Size, Marshal.GetFunctionPointerForDelegate(keepTime));
            outA = null;
            outB = null;
            silence = new byte[frames * bytesPerSample];
            Interlocked.Exchange(ref blockCount, 0);
            Interlocked.Exchange(ref resetRequested, 0);

            int e = Fn<CreateBuffersFn>(SlotCreateBuffers)(asio, infos, n, frames, callbacks);
            if (e != 0)
            {
                Put("STREAM", "CREATEBUFFERS_FAILED");
                Put("STREAM_ERR", e);
                Put("STREAM_TEXT", ReadText(SlotError));
                return;
            }
            created = true;
            IntPtr[] a = new IntPtr[nOut];
            IntPtr[] b = new IntPtr[nOut];
            for (int i = 0; i < nOut; i++)
            {
                int off = (nIn + i) * infoSize;
                a[i] = Marshal.ReadIntPtr(infos, off + 8);
                b[i] = Marshal.ReadIntPtr(infos, off + 8 + IntPtr.Size);
            }
            outA = a;
            outB = b;
            WriteSilence(0);
            WriteSilence(1);
            int inLat, outLat;
            if (Fn<TwoIntFn>(SlotLatencies)(asio, out inLat, out outLat) == 0) Put("LATENCY", inLat + "/" + outLat);
            e = Fn<PlainFn>(SlotStart)(asio);
            if (e != 0)
            {
                Put("STREAM", "START_FAILED");
                Put("STREAM_ERR", e);
                return;
            }
            started = true;
            Pump(1500);
            int count = Interlocked.CompareExchange(ref blockCount, 0, 0);
            Put("BLOCKS", count);
            if (rate > 0 && frames > 0) Put("BLOCKS_EXPECTED", (int)(rate / frames * 1.5));
            Put("STREAM", count > 0 ? "OK" : "NO_AUDIO");
            if (Interlocked.CompareExchange(ref resetRequested, 0, 0) != 0) Put("RESET_REQUESTED", 1);
        }
        finally
        {
            if (started) { try { Fn<PlainFn>(SlotStop)(asio); } catch { } }
            if (created) { try { Fn<PlainFn>(SlotDisposeBuffers)(asio); } catch { } }
            outA = null;
            outB = null;
            Marshal.FreeHGlobal(infos);
            Marshal.FreeHGlobal(callbacks);
        }
    }

    static int BytesPerSample(int type)
    {
        switch (type)
        {
            case 0: case 16: return 2;
            case 1: case 17: return 3;
            case 4: case 20: return 8;
            case 32: case 33: case 40: return 1;
            default: return 4;
        }
    }

    static void WriteSilence(int index)
    {
        IntPtr[] bufs = index == 0 ? outA : outB;
        byte[] zeros = silence;
        if (bufs == null || zeros == null) return;
        for (int i = 0; i < bufs.Length; i++)
        {
            if (bufs[i] != IntPtr.Zero) Marshal.Copy(zeros, 0, bufs[i], zeros.Length);
        }
    }

    static void OnBufferSwitch(int index, int direct)
    {
        try
        {
            Interlocked.Increment(ref blockCount);
            WriteSilence(index);
        }
        catch { }
    }

    static IntPtr OnTimeInfo(IntPtr timeInfo, int index, int direct)
    {
        OnBufferSwitch(index, direct);
        return timeInfo;
    }

    static void OnRateChanged(double rate) { }

    static int OnMessage(int selector, int value, IntPtr message, IntPtr opt)
    {
        switch (selector)
        {
            case 1: return (value == 2 || value == 3 || value == 5 || value == 6) ? 1 : 0; // selector supported?
            case 2: return 2;                                                             // engine version
            case 3: Interlocked.Exchange(ref resetRequested, 1); return 1;                // reset request
            case 5: return 1;                                                             // resync request
            case 6: return 1;                                                             // latencies changed
            default: return 0;
        }
    }

    static void Pump(int milliseconds)
    {
        DateTime end = DateTime.UtcNow.AddMilliseconds(milliseconds);
        NativeMsg msg;
        while (DateTime.UtcNow < end)
        {
            while (PeekMessage(out msg, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref msg); DispatchMessage(ref msg); }
            Thread.Sleep(10);
        }
    }
}
"@
    }
} catch {
    Write-Output 'PROBE:RESULT=TEST_UNAVAILABLE'
    Write-Output ('PROBE:ERROR=' + ($_.Exception.Message -replace '[\r\n]+', ' '))
    exit 3
}
$lines = [FrAsioProbe]::Run($Clsid, (-not $NoStream), 25000)
foreach ($l in $lines) { Write-Output ('PROBE:' + $l) }
exit 0
'@

function ConvertFrom-ProbeOutput {
    param([string]$Text)
    $r = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^PROBE:([A-Z_]+)=(.*)$') { $r[$Matches[1]] = $Matches[2].Trim() }
    }
    $r
}

function Invoke-AsioProbe {
    param([string]$Clsid, [switch]$NoStream)
    $r = @{}
    $probeFile = ''
    try {
        $probeFile = Join-Path $env:TEMP 'FocusriteDoctor-AsioTest.ps1'
        [System.IO.File]::WriteAllText($probeFile, $Script:ProbeScriptText, [System.Text.Encoding]::ASCII)
        $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File "' + $probeFile + '" -Clsid "' + $Clsid + '"'
        if ($NoStream) { $argLine += ' -NoStream' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = $argLine
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $hung = $false
        if (-not $proc.WaitForExit(60000)) {
            $hung = $true
            try { $proc.Kill() } catch { }
            [void]$proc.WaitForExit(5000)
        }
        $out = ''
        $err = ''
        try { if ($outTask.Wait(5000)) { $out = [string]$outTask.Result } } catch { }
        try { if ($errTask.Wait(2000)) { $err = [string]$errTask.Result } } catch { }
        $r = ConvertFrom-ProbeOutput -Text $out
        if ($hung) { $r['RESULT'] = 'HANG' }
        if (-not $r.ContainsKey('RESULT')) {
            $code = 0
            try { $code = [int]$proc.ExitCode } catch { }
            $r['EXITCODE'] = ('0x{0:X8}' -f $code)
            $errText = ($err -replace '[\r\n]+', ' ').Trim()
            if ($errText) { $r['STDERR'] = $errText }
            if ($code -lt 0 -or $code -gt 255) {
                $r['RESULT'] = 'CRASH'          # Windows crash code (e.g. 0xC0000005) - the driver crashed
            } else {
                $r['RESULT'] = 'TEST_UNAVAILABLE' # PowerShell itself stopped (blocked by antivirus/policy?)
                if ($errText.Length -gt 200) { $errText = $errText.Substring(0, 200) + '...' }
                if (-not $errText) { $errText = 'the test helper stopped unexpectedly (exit code ' + $code + ')' }
                $r['ERROR'] = $errText
            }
        }
    } catch {
        $r['RESULT'] = 'TEST_UNAVAILABLE'
        $r['ERROR'] = $_.Exception.Message
    } finally {
        if ($probeFile) { Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue }
    }
    return $r
}

# Prints the test result in plain English. Returns $true (works), $false (fails) or $null (test couldn't run).
function Show-ProbeResult {
    param([hashtable]$R, [string]$Name)
    $res = [string]$R['RESULT']
    if ($res -eq 'OK') {
        Good ('"{0}" opened: {1} inputs / {2} outputs, {3} Hz, buffer {4} samples.' -f $Name, $R['INPUTS'], $R['OUTPUTS'], $R['RATE'], $R['BUFFER_PREF'])
        $stream = [string]$R['STREAM']
        if ($stream -eq 'OK') {
            Good ('Audio runs: {0} audio blocks in 1.5 seconds (expected about {1}).' -f $R['BLOCKS'], $R['BLOCKS_EXPECTED'])
            return $true
        }
        if ($stream -eq 'NO_AUDIO') { Bad 'It opened, but no audio came through - the interface is not running.'; return $false }
        if ($stream -eq 'CREATEBUFFERS_FAILED') { Bad ('It opened, but could not set up audio buffers (code {0}). {1}' -f $R['STREAM_ERR'], $R['STREAM_TEXT']); return $false }
        if ($stream -eq 'START_FAILED') { Bad ('It opened, but audio would not start (code {0}).' -f $R['STREAM_ERR']); return $false }
        return $true
    }
    if ($res -eq 'INIT_FAILED') {
        $err = [string]$R['ERROR']
        if (-not $err) { $err = '(the driver gave no reason)' }
        Bad ('"{0}" could NOT open: {1}' -f $Name, $err)
        if ($err -match '0x54f') { Info 'Same error TONEX shows - so it happens outside TONEX too (driver/connection, not TONEX).' }
        return $false
    }
    if ($res -eq 'CREATE_FAILED') {
        $hr = [string]$R['CREATE_HR']
        $why = 'unknown reason'
        switch ($hr) {
            '0x80040154' { $why = 'the driver is not registered properly' }
            '0x8007007E' { $why = 'a file the driver needs is missing' }
            '0x800700C1' { $why = 'the driver file is damaged or the wrong type' }
            '0x80070005' { $why = 'access was denied' }
            '0x80004002' { $why = 'the driver does not answer like an ASIO driver' }
        }
        Bad ('Windows could not load the "{0}" driver file ({1}, {2}). Reinstalling the driver fixes this.' -f $Name, $hr, $why)
        return $false
    }
    if ($res -eq 'HANG') { Bad 'The driver froze while opening (no answer in 25 seconds).'; return $false }
    if ($res -eq 'TEST_UNAVAILABLE') { Warn ('The live test could not run on this PC: {0}' -f $R['ERROR']); return $null }
    if ($res -eq 'EXCEPTION') { Bad ('The test hit an error: {0}' -f $R['EXCEPTION']); return $false }
    Bad ('The driver crashed during the test (exit code {0}).' -f $R['EXITCODE'])
    return $false
}

# Runs the live test on the main Focusrite ASIO driver. $true = works, $false = fails.
function Test-Driver {
    param([string]$Label = 'Testing')
    if (-not $Script:MainAsio) { return $null }
    Say ''
    Say ('  {0}: opening "{1}" (takes about 10 seconds)...' -f $Label, $Script:MainAsio.Name) White
    $r = Invoke-AsioProbe -Clsid $Script:MainAsio.Clsid
    $Script:LastProbeResult = [string]$r['RESULT']
    foreach ($key in @($r.Keys | Sort-Object)) { Log ('           test.' + $key + ' = ' + $r[$key]) }
    $ok = Show-ProbeResult -R $r -Name $Script:MainAsio.Name
    if ($null -eq $ok) {
        return (Ask 'Please open TONEX, pick Focusrite USB ASIO, then close TONEX again. Did it work without the error?' $false)
    }
    return $ok
}

function Show-Fixed {
    Say ''
    Say '  FIXED - the Focusrite driver opens and runs now!' Green
}

# =============================================================================
#  FIXES  (each one is only run after you answer Y)
# =============================================================================
function Fix-CloseApps {
    param($Apps)
    $closedAny = $false
    foreach ($a in @($Apps)) {
        $p = $null
        try { $p = Get-Process -Id $a.Id -ErrorAction Stop } catch { continue }
        Info ('Closing ' + $p.ProcessName + ' ...')
        $gone = $false
        try { if ($p.CloseMainWindow()) { $gone = $p.WaitForExit(15000) } } catch { }
        if (-not $gone) {
            try { $p.Refresh(); $gone = $p.HasExited } catch { $gone = $true }
        }
        if (-not $gone) {
            if (Ask ($p.ProcessName + ' is still open (it may be asking to save, or sitting in the system tray). Force it to close? Unsaved work in it will be lost.') $false -Changes) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $gone = $true } catch { Warn ('Could not close it: ' + $_.Exception.Message) }
            }
        }
        if ($gone) { Good ($a.Name + ' closed.'); $closedAny = $true }
    }
    if ($closedAny) { Start-Sleep -Seconds 2 }
    return $closedAny
}

function Fix-RestartAudioServices {
    if (-not $Script:IsAdmin) { Warn 'Skipped - this needs Administrator (run the tool again and click Yes).'; return $false }
    try {
        Info 'Restarting the Windows Audio services (sound stops for a few seconds)...'
        Restart-Service -Name 'AudioEndpointBuilder' -Force -ErrorAction Stop
        Start-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue
        foreach ($s in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { ($_.Name -match 'focusrite' -or $_.DisplayName -match 'focusrite') -and $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' })) {
            try { Start-Service -Name $s.Name -ErrorAction Stop; Info ('Started ' + $s.DisplayName) } catch { }
        }
        Start-Sleep -Seconds 3
        Good 'Windows Audio restarted.'
        return $true
    } catch {
        Warn ('Could not restart the audio services: ' + $_.Exception.Message)
        return $false
    }
}

function Fix-RestartDevice {
    if (-not $Script:IsAdmin) { Warn 'Skipped - this needs Administrator (run the tool again and click Yes).'; return $false }
    if (-not $Script:TopId) { return $false }
    Info 'Restarting the Focusrite inside Windows (the same as unplugging and re-plugging it)...'
    $done = $false
    if ($Script:Build -ge 19041) {
        try {
            $o = @(& pnputil.exe /restart-device $Script:TopId 2>&1)
            $code = $LASTEXITCODE
            Log ('           pnputil /restart-device -> ' + $code + ' ' + (($o | Out-String).Trim()))
            if ($code -eq 0) { $done = $true }
            elseif ($code -eq 3010) { Warn 'Windows says the PC needs a restart to finish this.'; $done = $true }
        } catch { }
    }
    if (-not $done) {
        try {
            Disable-PnpDevice -InstanceId $Script:TopId -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds 2
            Enable-PnpDevice -InstanceId $Script:TopId -Confirm:$false -ErrorAction Stop
            $done = $true
        } catch { Warn ('Could not restart the device: ' + $_.Exception.Message) }
    }
    if ($done) {
        Info 'Waiting for it to come back...'
        [void](Wait-ForFocusrite -Present $true -TimeoutSec 30)
        Start-Sleep -Seconds 5
        Good 'Focusrite restarted.'
    }
    return $done
}

function Fix-Replug {
    param([switch]$FirstTime)
    Say ''
    if (-not $FirstTime) {
        Step 'Re-plugging. Loose cables and tired USB ports cause this error a lot.'
        Info '1) Unplug the Focusrite''s USB cable from the COMPUTER now.'
        Info '   (I am watching for it. Press S to skip.)'
        if (-not (Wait-ForFocusrite -Present $false -TimeoutSec 120 -AllowSkip)) { Warn 'I did not see it being unplugged - skipping this step.'; return $false }
        Good 'Unplugged.'
        Start-Sleep -Seconds 3
        Info '2) Now plug it into a DIFFERENT USB port, straight into the computer'
    } else {
        Step 'Let''s get Windows to see the Focusrite:'
        Info '- Check the Focusrite lights up. If it does not, the cable or port is not giving it power.'
        Info '- Use the USB cable that came with the Focusrite (some cables only charge and carry no data).'
        Info '1) Plug it into a USB port straight on the computer'
    }
    Info '   (back of a desktop PC is best - not a hub, keyboard, monitor or front-panel port).'
    Info '   If you have another USB cable, try that one. (Press S to skip.)'
    if (-not (Wait-ForFocusrite -Present $true -TimeoutSec 180 -AllowSkip)) { Warn 'I did not see the Focusrite appear.'; return $false }
    Good 'Focusrite detected. Giving Windows a few seconds to load the driver...'
    Start-Sleep -Seconds 8
    $ids = @(Get-FocusriteTopIds)
    if ($ids.Count -gt 0) { $Script:TopId = $ids[0] }
    return $true
}

function Fix-GenericDriver {
    if (-not $Script:IsAdmin) { Warn 'Skipped - this needs Administrator (run the tool again and click Yes).'; return $false }
    if (@($Script:FocusritePackages).Count -eq 0) {
        Warn 'The Focusrite driver is not stored in Windows, so it has to be installed first (see the steps below).'
        return $false
    }
    if ($Script:Build -lt 19041) {
        Warn 'This Windows version is too old for the automatic fix. Do it by hand:'
        Info 'Device Manager > right-click the Focusrite > Uninstall device > OK, then unplug and re-plug it.'
        return $false
    }
    Info 'Removing the Focusrite from Device Manager so Windows sets it up again with the Focusrite driver...'
    $o = @(& pnputil.exe /remove-device $Script:TopId 2>&1)
    Log ('           pnputil /remove-device -> ' + $LASTEXITCODE + ' ' + (($o | Out-String).Trim()))
    Start-Sleep -Seconds 2
    $o = @(& pnputil.exe /scan-devices 2>&1)
    Log ('           pnputil /scan-devices -> ' + $LASTEXITCODE + ' ' + (($o | Out-String).Trim()))
    [void](Wait-ForFocusrite -Present $true -TimeoutSec 40)
    Start-Sleep -Seconds 6
    $ids = @(Get-FocusriteTopIds)
    if ($ids.Count -gt 0) { $Script:TopId = $ids[0] }
    $Script:Binding = Get-DriverBinding -Nodes @(Get-FocusriteNodes)
    if ($Script:Binding.Focusrite) { Good 'Windows is now using the Focusrite driver.' }
    else { Warn 'Windows is still not using the Focusrite driver - a clean reinstall is needed (steps below).' }
    return $true
}

function Fix-MsdMode {
    Step 'How to switch MSD / Easy Start mode off:'
    if ($Script:ModelPid -eq '8214') {
        Info 'Hold the 48V button for inputs 1-2, unplug and re-plug the USB cable while still holding it,'
        Info 'then keep holding 48V for 5 more seconds and let go.'
    } elseif ($Script:ModelGen -eq 4) {
        Info '1) Unplug the USB cable from the Focusrite.'
        Info '2) Press and HOLD the 48V button.'
        Info '3) While still holding 48V, plug the USB cable back in.'
        Info '4) When the front panel lights up, let go of 48V.'
        Info '5) Unplug the USB cable once more and plug it back in.'
    } else {
        Info 'With the Focusrite plugged in, press and HOLD the 48V button for 5 seconds, then let go.'
    }
    Info 'If the 48V light stays on afterwards, press 48V once to turn it off (a guitar does not need it).'
    Info 'I am watching for the change... (press S to skip)'
    $deadline = (Get-Date).AddSeconds(150)
    $okCount = 0
    while ((Get-Date) -lt $deadline) {
        $present = (@(Get-FocusriteTopIds).Count -gt 0)
        if ($present -and -not (Test-MsdMode)) { $okCount++ } else { $okCount = 0 }
        if ($okCount -ge 2) {
            Good 'MSD / Easy Start mode is off now.'
            $ids = @(Get-FocusriteTopIds)
            if ($ids.Count -gt 0) { $Script:TopId = $ids[0] }
            Start-Sleep -Seconds 4
            return $true
        }
        if (Test-SkipKey) { break }
        Start-Sleep -Seconds 3
    }
    Warn 'It still looks like MSD mode (or I could not tell). Installing + opening Focusrite Control 2 also switches it off.'
    return $false
}

function Fix-SelectiveSuspend {
    $sub = '2a737441-1930-4402-8d77-b2bebba308a3'
    $set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    & powercfg.exe /setacvalueindex SCHEME_CURRENT $sub $set 0 | Out-Null
    $c1 = $LASTEXITCODE
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT $sub $set 0 | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
    if ($c1 -eq 0) { Good 'USB selective suspend is now off.' } else { Warn 'Could not change that power setting.' }
}

# Splits an uninstall command into program + arguments.
function Split-CommandLine {
    param([string]$Cmd)
    $Cmd = $Cmd.Trim()
    if ($Cmd.StartsWith('"')) {
        $end = $Cmd.IndexOf('"', 1)
        if ($end -gt 0) { return @($Cmd.Substring(1, $end - 1), $Cmd.Substring($end + 1).Trim()) }
    }
    if ($Cmd -match '^(.+?\.exe)\s*(.*)$') { return @($Matches[1], $Matches[2].Trim()) }
    return @($Cmd, '')
}

function Fix-RemoveAsio4All {
    $started = $false
    foreach ($a in @($Script:Asio4AllApps)) {
        if (-not $a.Uninstall) { continue }
        $parts = @(Split-CommandLine $a.Uninstall)
        Info ('Starting the uninstaller for ' + $a.Name + ' - follow its window.')
        try {
            if ($parts[1]) { Start-Process -FilePath $parts[0] -ArgumentList $parts[1] -Wait -ErrorAction Stop }
            else { Start-Process -FilePath $parts[0] -Wait -ErrorAction Stop }
            $started = $true
        } catch { Warn ('Could not start it: ' + $_.Exception.Message) }
    }
    if (-not $started) {
        Info 'Opening Apps & features - find ASIO4ALL in the list and click Uninstall.'
        try { Start-Process 'ms-settings:appsfeatures' } catch { }
    }
}

function Open-SoundSettings {
    Step 'In the Sound window that opens:'
    Info '1) Playback tab: right-click the Focusrite > Properties > Advanced tab.'
    Info '   Default Format: choose "24 bit, 48000 Hz".'
    Info '   Untick "Allow applications to take exclusive control of this device". Click OK.'
    Info '2) Recording tab: do the same for the Focusrite input (48000 Hz too, untick exclusive control).'
    Info '3) If a Focusrite entry is greyed out / disabled: right-click it > Enable.'
    try { Start-Process -FilePath 'control.exe' -ArgumentList 'mmsys.cpl' } catch { }
    Wait-Enter 'Press Enter here when you have done that'
}

function Show-ReinstallSteps {
    param([string]$Title = 'Clean reinstall of the Focusrite driver:')
    $Script:ReinstallShown = $true
    Say ''
    Step $Title
    Info '1) Close TONEX / AmpliTube and unplug the Focusrite.'
    Info '2) Settings > Apps: uninstall "Focusrite Control", "Focusrite Control 2" and "Focusrite USB Driver"'
    Info '   (whichever of them are installed).'
    Info '3) RESTART the PC (Start > Power > Restart - not Shut down).'
    Info ('4) Go to downloads.focusrite.com, choose ' + $Script:ModelName + ' and install the newest software for it')
    Info '   (for 3rd/4th Gen Scarletts that is Focusrite Control 2, which includes the driver).'
    Info '5) Plug the Focusrite straight into the PC, open Focusrite Control 2 once, then run this tool again.'
}

# =============================================================================
#  Report
# =============================================================================
function Save-Report {
    $name = 'Focusrite-Doctor-Report_' + (Get-Date -Format 'yyyy-MM-dd_HHmm') + '.txt'
    $text = ($Script:LogLines -join "`r`n")
    $dirs = @()
    try { $dirs += [Environment]::GetFolderPath('Desktop') } catch { }
    if ($Script:SelfDir) { $dirs += $Script:SelfDir }
    if ($env:TEMP) { $dirs += $env:TEMP }
    foreach ($dir in $dirs) {
        if (-not $dir) { continue }
        try {
            $path = Join-Path $dir $name
            [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($true)))
            return $path
        } catch { }
    }
    return $null
}

# =============================================================================
#  MAIN
# =============================================================================
function Invoke-Main {
    # --- 64-bit PowerShell is needed: TONEX loads the 64-bit Focusrite ASIO driver ---
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and $Script:SelfPath) {
        $ps64 = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path $ps64) {
            $extra = @()
            if ($ReportOnly) { $extra += '-ReportOnly' }
            if ($NoElevate)  { $extra += '-NoElevate' }
            & $ps64 -NoProfile -ExecutionPolicy Bypass -File $Script:SelfPath @extra
            exit $LASTEXITCODE
        }
    }

    # --- Administrator (the .bat launcher already asks; this is for "Run with PowerShell") ---
    $Script:IsAdmin = Test-IsAdmin
    if (-not $Script:IsAdmin -and -not $NoElevate -and -not $Script:FromBat -and $Script:SelfPath) {
        Write-Host 'Some fixes need Administrator rights.' -ForegroundColor Yellow
        $a = Read-Host '  >> Restart this tool as Administrator? [Y/n]'
        if ($a -notmatch '^\s*(n|no)\s*$') {
            try {
                $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script:SelfPath + '"'
                if ($ReportOnly) { $argLine += ' -ReportOnly' }
                Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $argLine -Verb RunAs -ErrorAction Stop
                Write-Host 'Continuing in the new window...'
                exit 0
            } catch {
                Write-Host 'No Administrator permission - continuing with limited fixes.' -ForegroundColor Yellow
            }
        }
    }

    try { $Host.UI.RawUI.WindowTitle = 'Focusrite Doctor' } catch { }
    Say ''
    Say '  FOCUSRITE DOCTOR' Cyan
    Say '  Finds out why music apps say "Cannot open Focusrite USB ASIO" and helps fix it.'
    Say '  Nothing on this PC is changed unless you answer Y.'
    Log ('  Version ' + $Script:ToolVersion + '  -  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + $(if ($ReportOnly) { '  (report only)' } else { '' }))
    if (-not $Script:IsAdmin) { Warn 'Not running as Administrator: all checks run, but some fixes will be skipped.' }

    try {
        # ---------------------------------------------------------------- 1
        Head '1/9  This PC'
        $os = $null
        try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }
        if ($os) {
            $Script:Build = [int]$os.BuildNumber
            $disp = Get-RegValue LocalMachine 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion'
            if (-not $disp) { $disp = Get-RegValue LocalMachine 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'ReleaseId' }
            $arch = '32-bit'
            if ([Environment]::Is64BitOperatingSystem) { $arch = '64-bit' }
            Info ('Windows: ' + $os.Caption + ' ' + $disp + ' (build ' + $os.BuildNumber + '), ' + $arch)
            try { Info ('Last full restart: {0:N1} days ago' -f ((Get-Date) - $os.LastBootUpTime).TotalDays) } catch { }
        }
        if (-not [Environment]::Is64BitOperatingSystem) {
            Bad '32-bit Windows: TONEX and current Focusrite drivers need 64-bit Windows.'
            Add-Finding PROBLEM 'Windows is 32-bit - TONEX and the current Focusrite driver need 64-bit Windows.'
        }
        if ((Get-RegValue LocalMachine 'SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled') -eq 1) {
            Info 'Fast Startup is on: "Shut down" does not fully reset drivers - "Restart" does.'
        }
        try {
            $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
            Info ('CPU: ' + ([string]$cpu.Name).Trim())
            $Script:IsAmd = ([string]$cpu.Manufacturer -match 'AMD')
        } catch { }
        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            Info ('Computer: ' + $cs.Manufacturer + ' ' + $cs.Model)
        } catch { }
        Info ('PowerShell ' + $PSVersionTable.PSVersion + ', Administrator: ' + $(if ($Script:IsAdmin) { 'yes' } else { 'no' }))
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $pw = [System.Windows.Forms.SystemInformation]::PowerStatus
            if (-not $pw.BatteryChargeStatus.HasFlag([System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery)) {
                if ($pw.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Offline) {
                    Warn 'This laptop is running on battery. USB audio is more reliable with the charger plugged in.'
                    Add-Finding WARN 'Laptop on battery - plug the charger in (USB ports can get less power on battery).'
                } else { Info 'Laptop: charger connected.' }
            }
        } catch { }

        # ---------------------------------------------------------------- 2
        Head '2/9  Is the Focusrite connected?'
        $nodes = @(Get-FocusriteNodes)
        $tops = @($nodes | Where-Object { $_.InstanceId -match '^USB\\VID_1235&PID_[0-9A-Fa-f]{4}\\' })
        if ($tops.Count -eq 0) {
            Bad 'Windows cannot see a Focusrite on USB right now.'
            $ghosts = @(Get-FocusriteNodes -IncludeNotPresent | Where-Object { $_.InstanceId -match '^USB\\VID_1235&PID_[0-9A-Fa-f]{4}\\' -and -not $_.Present })
            if ($ghosts.Count -gt 0) {
                $seen = @($ghosts | ForEach-Object { (Get-ModelInfo $_.InstanceId).Name } | Select-Object -Unique)
                Info ('Windows has seen this before (' + ($seen -join ', ') + ') but it is not connected now.')
                $mi = Get-ModelInfo $ghosts[0].InstanceId
                $Script:ModelName = $mi.Name; $Script:ModelPid = $mi.Pid; $Script:ModelGen = $mi.Gen
            }
            Add-Finding PROBLEM 'The Focusrite is not detected on USB. Check it lights up, use the cable that came with it, and try another USB port.'
        } else {
            $Script:TopId = $tops[0].InstanceId
            $mi = Get-ModelInfo $Script:TopId
            $Script:ModelName = $mi.Name; $Script:ModelPid = $mi.Pid; $Script:ModelGen = $mi.Gen
            $bus = [string](Get-DevProp -InstanceId $Script:TopId -Key 'DEVPKEY_Device_BusReportedDeviceDesc')
            if ($bus) { Good ('Found: ' + $mi.Name + '  (it calls itself "' + $bus + '")') } else { Good ('Found: ' + $mi.Name) }
            if ($tops.Count -gt 1) { Info ('Note: ' + $tops.Count + ' Focusrite/Novation USB devices are connected.') }
            foreach ($n in $nodes) {
                $svc = $n.Service
                if (-not $svc) { $svc = 'none' }
                $line = $n.Name + '  [' + $n.Class + ', driver service: ' + $svc + ']  ' + (Format-ShortId $n.InstanceId)
                if ($n.Code -ne 0) {
                    $why = $Script:ProblemText[$n.Code]
                    if (-not $why) { $why = 'problem' }
                    Bad ($line + '  -> Code ' + $n.Code + ': ' + $why)
                    Add-Finding PROBLEM ('Windows reports a problem with "' + $n.Name + '": Code ' + $n.Code + ' (' + $why + ').')
                } else { Info $line }
            }
            $par = Get-ParentInfo -InstanceId $Script:TopId
            if ($par) {
                if ($par.IsRootHub) { Good 'Plugged straight into a USB port of the computer.' }
                else {
                    Warn ('It is connected through a USB hub ("' + $par.Name + '").')
                    Info 'If that is an external hub, dock, keyboard or monitor port, plug the Focusrite straight into the PC.'
                    Add-Finding WARN 'The Focusrite goes through a USB hub - plug it straight into the computer.'
                }
            }
            $Script:MsdOn = Test-MsdMode -Nodes $nodes
            if ($Script:MsdOn) {
                Warn 'The Focusrite is in "MSD / Easy Start" mode (it also shows up as a small USB disk).'
                Add-Finding WARN 'The Focusrite is still in MSD / Easy Start mode - this limits it and should be switched off.'
            }
        }

        # ---------------------------------------------------------------- 3
        Head '3/9  Which driver is Windows using for it?'
        $Script:Binding = Get-DriverBinding -Nodes $nodes
        foreach ($s in @($Script:Binding.Signed)) {
            $date = ''
            try { if ($s.DriverDate) { $date = ([datetime]$s.DriverDate).ToString('yyyy-MM-dd') } } catch { }
            Info ([string]$s.DeviceName + ': ' + $s.DriverProviderName + ' driver ' + $s.DriverVersion + ' ' + $date + ' (' + $s.InfName + ')')
        }
        if ($tops.Count -gt 0) {
            if ($Script:Binding.Focusrite) {
                $v = 'unknown version'
                if ($Script:Binding.Version) { $v = 'version ' + $Script:Binding.Version }
                Good ('The Focusrite driver is in charge (' + $v + ').')
            } elseif ($Script:Binding.Generic) {
                Bad 'Windows is using its own basic USB audio driver, NOT the Focusrite driver.'
                Info 'Sound in Windows can still work like that, but "Focusrite USB ASIO" cannot reach the interface.'
                Add-Finding PROBLEM 'Windows is using its generic USB audio driver instead of the Focusrite driver, so Focusrite USB ASIO cannot open the interface.'
            } else {
                Bad 'No working audio driver is attached to the Focusrite.'
                Add-Finding PROBLEM 'No audio driver is attached to the Focusrite - the Focusrite driver needs installing.'
            }
        }
        $apps = @(Get-InstalledApps 'Focusrite|ASIO4ALL|Voicemeeter|FlexASIO|ASIO2WASAPI|TONEX|AmpliTube')
        foreach ($a in $apps) { Info ('Installed: ' + $a.Name + ' ' + $a.Version) }
        if (@($apps | Where-Object { $_.Name -match 'Focusrite' }).Count -eq 0) { Warn 'No Focusrite software shows up in the installed apps list.' }
        $Script:Asio4AllApps = @($apps | Where-Object { $_.Name -match 'ASIO4ALL' })
        $Script:FocusritePackages = @(Get-FocusriteDriverPackages)
        if ($Script:FocusritePackages.Count -gt 0) {
            Info ('Focusrite driver packages stored in Windows: ' + (($Script:FocusritePackages | ForEach-Object { $_.Inf + ' ' + $_.Version }) -join ', '))
        }
        $bv = $Script:Binding.Version
        if ($bv -and $bv.Major -eq 4) {
            $short = New-Object Version ($bv.Major, $bv.Minor, [Math]::Max(0, $bv.Build))
            if ($short -lt $Script:LatestKnownDriver) {
                Warn ('Driver ' + $bv + ' is older than ' + $Script:LatestKnownDriver + ' (the newest one when this tool was made).')
                Add-Finding INFO ('The Focusrite driver is older than ' + $Script:LatestKnownDriver + ' - worth updating if the problem stays.')
                $Script:DriverOld = $true
            }
        }

        # ---------------------------------------------------------------- 4
        Head '4/9  ASIO drivers (the list TONEX / AmpliTube show)'
        $Script:AsioList = @(Get-AsioDrivers)
        if ($Script:AsioList.Count -eq 0) { Bad 'No ASIO drivers are registered at all.' }
        foreach ($d in $Script:AsioList) {
            $state = 'ok'
            if (-not $d.Clsid) { $state = 'BROKEN: no CLSID' }
            elseif (-not $d.Dll) { $state = 'BROKEN: not registered' }
            elseif (-not $d.DllExists) { $state = 'BROKEN: driver file missing' }
            $line = $d.Name + '  (' + $d.Bits + '-bit)  ' + $state
            if ($state -ne 'ok') { Warn $line } else { Info $line }
        }
        $focAsio = @($Script:AsioList | Where-Object { $_.Name -match 'Focusrite|Scarlett|Clarett|Vocaster' })
        $foc64 = @($focAsio | Where-Object { $_.Bits -eq 64 })
        if ($foc64.Count -eq 0) {
            Bad 'There is no 64-bit Focusrite ASIO driver registered.'
            Add-Finding PROBLEM 'The Focusrite ASIO driver is not installed/registered for 64-bit apps - reinstall the Focusrite driver.'
        } else {
            $Script:MainAsio = @(@($foc64 | Where-Object { $_.Name -match 'USB' }) + $foc64)[0]
            $m = $Script:MainAsio
            if (-not $m.DllExists) {
                Bad ('"' + $m.Name + '" points to a file that is missing: ' + $m.Dll)
                Add-Finding PROBLEM 'The Focusrite ASIO driver file is missing - reinstall the Focusrite driver.'
            } else {
                $fv = ''
                if ($m.DllVersion) { $fv = '  (file version ' + $m.DllVersion + ')' }
                Good ('"' + $m.Name + '" -> ' + $m.Dll + $fv)
                if ($Script:Binding.Version -and $m.DllVersion -match '^(\d+)[.,]') {
                    if ([int]$Matches[1] -ne $Script:Binding.Version.Major) {
                        Warn 'The ASIO part and the driver part are from different driver versions.'
                        Add-Finding WARN 'Focusrite ASIO file and Focusrite driver are different versions - a clean reinstall fixes this.'
                    }
                }
            }
        }
        if (@($Script:AsioList | Where-Object { $_.Name -match 'ASIO4ALL' }).Count -gt 0 -or $Script:Asio4AllApps.Count -gt 0) {
            Warn 'ASIO4ALL is installed. Focusrite says not to use it with their interfaces: it can grab the'
            Info 'Focusrite and block the real driver.'
            Add-Finding WARN 'ASIO4ALL is installed - Focusrite recommends removing it (it can lock the interface).'
        }

        # ---------------------------------------------------------------- 5
        Head '5/9  Is another program using the Focusrite?'
        Initialize-ModScan
        $dlls = @($Script:AsioList | Where-Object { $_.Dll -and $_.Name -match 'Focusrite|Scarlett|Clarett|Vocaster|ASIO4ALL' } | ForEach-Object { ($_.Dll -split '\\')[-1] })
        $Script:WatchDlls = @($dlls + @('asio4all.dll', 'asio4all64.dll') | Select-Object -Unique)
        $busy = @(Get-BusyApps)
        if ($busy.Count -eq 0) { Good 'No other music/audio programs are running.' }
        else {
            foreach ($b in $busy) { Warn ($b.Name + ' (process ' + $b.Id + ') - ' + $b.Reason) }
            Info 'Two programs using Focusrite USB ASIO at the same time usually fails - only one can have it.'
            Add-Finding WARN ('Other audio programs were open (' + (($busy | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', ') + ') - only one program can use the Focusrite at a time.')
        }

        # ---------------------------------------------------------------- 6
        Head '6/9  Windows sound settings for the Focusrite'
        $eps = @(Get-FocusriteEndpoints)
        $shown = @($eps | Where-Object { $_.State -eq 1 -or $_.State -eq 2 })
        if ($shown.Count -eq 0) { Info 'No active Focusrite playback/recording devices in Windows Sound settings.' }
        foreach ($e in $shown) {
            $fmt = 'format unknown'
            if ($e.Rate) { $fmt = '' + $e.Rate + ' Hz, ' + $e.Bits + '-bit' }
            $ex = 'exclusive mode allowed'
            if ($null -ne $e.Exclusive -and $e.Exclusive -eq 0) { $ex = 'exclusive mode off' }
            $line = $e.Flow + ': ' + $e.Name + ' - ' + $e.StateText + ' - ' + $fmt + ' - ' + $ex
            if ($e.State -eq 2) { Warn $line } else { Info $line }
        }
        $rates = @($eps | Where-Object { $_.State -eq 1 -and $_.Rate } | ForEach-Object { $_.Rate } | Select-Object -Unique)
        if ($rates.Count -gt 1) {
            Warn ('Playback and recording use DIFFERENT sample rates (' + ($rates -join ' / ') + ' Hz). They should match.')
            Add-Finding WARN 'Windows has the Focusrite playback and recording at different sample rates - set both to 48000 Hz.'
            $Script:RateMismatch = $true
        } elseif ($rates.Count -eq 1) { Good ('Windows uses ' + $rates[0] + ' Hz for the Focusrite.') }
        if (@($eps | Where-Object { $_.State -eq 2 }).Count -gt 0) {
            Add-Finding INFO 'Some Focusrite sound devices are disabled in Windows Sound settings.'
        }
        $micDev  = Get-RegValue LocalMachine 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone' 'Value'
        $micUser = Get-RegValue CurrentUser 'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone' 'Value'
        $micDesk = Get-RegValue CurrentUser 'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged' 'Value'
        $micPol  = Get-RegValue LocalMachine 'SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessMicrophone'
        if ($micDev -eq 'Deny' -or $micUser -eq 'Deny' -or $micDesk -eq 'Deny' -or $micPol -eq 2) {
            Warn 'Windows microphone privacy is blocking apps from audio inputs.'
            Info '(This stops Discord, browsers and most Windows apps hearing the Focusrite. ASIO apps are usually not affected.)'
            Add-Finding INFO 'Windows microphone access for apps is turned off (Settings > Privacy > Microphone).'
            $Script:MicBlocked = $true
        } else { Good 'Microphone access for apps is allowed.' }

        # ---------------------------------------------------------------- 7
        Head '7/9  Windows audio services and USB power'
        foreach ($svcName in @('AudioEndpointBuilder', 'Audiosrv')) {
            $s = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if (-not $s) { Bad ('Service ' + $svcName + ' not found.'); continue }
            if ([string]$s.Status -eq 'Running') { Good ($s.DisplayName + ' is running.') }
            else {
                Bad ($s.DisplayName + ' is ' + $s.Status + '.')
                Add-Finding PROBLEM ('The Windows service "' + $s.DisplayName + '" is not running.')
            }
        }
        foreach ($s in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'focusrite' -or $_.DisplayName -match 'focusrite' })) {
            Info ($s.DisplayName + ': ' + $s.Status + ' (starts: ' + $s.StartType + ')')
        }
        $ss = Get-UsbSelectiveSuspend
        if ($ss) {
            if ($ss.AC -ne 0 -or $ss.DC -ne 0) {
                Warn 'USB selective suspend is ON (Windows may power down USB devices to save energy).'
                Add-Finding INFO 'USB selective suspend is on - turning it off is recommended for audio interfaces.'
                $Script:SelectiveSuspendOn = $true
            } else { Good 'USB selective suspend is off.' }
        }

        # ---------------------------------------------------------------- 8
        Head '8/9  Recent Windows events about the Focusrite'
        $pe = @(Get-PnpConfigEvents)
        if ($Script:EventsUnreadable) { Info 'Could not read the device-setup log (it may need Administrator).' }
        elseif ($pe.Count -eq 0) { Info 'No Focusrite device-setup events in the last 30 days.' }
        foreach ($e in $pe) {
            $what = 'event ' + $e.Id
            switch ($e.Id) {
                400 { $what = 'driver set up' }
                410 { $what = 'started' }
                411 { $what = 'PROBLEM starting' }
                420 { $what = 'removed' }
                430 { $what = 'needs more setup' }
            }
            $extra = @()
            if ($e.Inf)      { $extra += $e.Inf }
            if ($e.Provider) { $extra += $e.Provider }
            if ($e.Service)  { $extra += ('service ' + $e.Service) }
            if ($e.Id -eq 411 -and $e.Problem) { $extra += ('problem ' + $e.Problem) }
            $line = ('{0:yyyy-MM-dd HH:mm}  ' -f $e.Time) + $what + '  ' + ($extra -join ', ')
            if ($e.Id -eq 411) { Warn $line } else { Info $line }
        }
        foreach ($c in @(Get-AppCrashEvents)) {
            Warn (('{0:yyyy-MM-dd HH:mm}  ' -f $c.Time) + $c.App + ' crashed (in ' + $c.Module + ')')
        }

        # ---------------------------------------------------------------- 9
        Head '9/9  Live test: opening Focusrite USB ASIO like TONEX does'
        if (-not $Script:MainAsio) {
            Warn 'Skipped - there is no Focusrite ASIO driver to test.'
        } else {
            $busy = @(Get-BusyApps)
            if ($busy.Count -gt 0 -and -not $ReportOnly) {
                Warn ('Open right now: ' + (($busy | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', '))
                if (Ask 'Close them before the test? (Save your work in them first!)' $true -Changes) { [void](Fix-CloseApps $busy) }
            }
            $Script:ProbeWorks = Test-Driver 'Live test'
        }

        # ---------------------------------------------------------------- summary
        Head 'Summary'
        $probs = @($Script:Findings | Where-Object { $_.Level -eq 'PROBLEM' })
        $warns = @($Script:Findings | Where-Object { $_.Level -eq 'WARN' })
        $infos = @($Script:Findings | Where-Object { $_.Level -eq 'INFO' })
        if (($probs.Count + $warns.Count + $infos.Count) -eq 0) { Good 'The checks found nothing wrong.' }
        foreach ($f in $probs) { Bad $f.Text }
        foreach ($f in $warns) { Warn $f.Text }
        foreach ($f in $infos) { Info ('- ' + $f.Text) }
        if ($Script:LastProbeResult -eq 'TEST_UNAVAILABLE') {
            if ($Script:ProbeWorks -eq $true) { Good 'You said TONEX works now (the automatic test could not run on this PC).' }
            elseif ($Script:ProbeWorks -eq $false) { Bad 'You said TONEX still shows the error (the automatic test could not run on this PC).' }
        } elseif ($Script:ProbeWorks -eq $true) {
            Good 'LIVE TEST PASSED: the Focusrite driver opens and runs audio right now.'
        } elseif ($Script:ProbeWorks -eq $false) {
            Bad 'LIVE TEST FAILED: the driver cannot open the Focusrite, outside TONEX too.'
        }

        # ---------------------------------------------------------------- fixes
        $fixed = ($Script:ProbeWorks -eq $true)
        if ($ReportOnly) {
            Say ''
            Info 'Report-only mode: no fixes offered.'
        } else {
            Head 'Fixes'
            if ($fixed) {
                Good 'The Focusrite and its driver work in the test right now.'
                Info 'So TONEX most likely failed because something else had the Focusrite busy at that moment'
                Info '(another music app, or a stuck Windows audio state). Try TONEX now with other music apps closed.'
            }

            # Not connected at all: get it connected first.
            if (-not $Script:TopId -and -not $fixed) {
                if (Ask 'The Focusrite is not connected. Shall I walk you through plugging it in and watch for it?' $true) {
                    if (Fix-Replug -FirstTime) {
                        $nodes = @(Get-FocusriteNodes)
                        $Script:Binding = Get-DriverBinding -Nodes $nodes
                        $Script:MsdOn = Test-MsdMode -Nodes $nodes
                        $mi = Get-ModelInfo $Script:TopId
                        $Script:ModelName = $mi.Name; $Script:ModelPid = $mi.Pid; $Script:ModelGen = $mi.Gen
                        if ($Script:MainAsio) {
                            $Script:ProbeWorks = Test-Driver 'Testing'
                            $fixed = ($Script:ProbeWorks -eq $true)
                            if ($fixed) { Show-Fixed }
                        }
                    }
                }
            }

            # Repair ladder: gentlest first, re-test after each step, stop as soon as it works.
            if (-not $fixed -and $Script:TopId -and $Script:MainAsio) {
                $ladder = New-Object 'System.Collections.Generic.List[string]'
                if (-not $Script:Binding.Focusrite) {
                    # Re-detecting the device makes Windows pick the Focusrite driver, if it is stored in Windows.
                    if (@($Script:FocusritePackages).Count -eq 0) { $ladder.Add('reinstall') }
                    elseif ($Script:IsAdmin) { $ladder.Add('driver') }
                }
                if (@(Get-BusyApps).Count -gt 0) { $ladder.Add('close') }
                if ($Script:MsdOn) { $ladder.Add('msd') }
                if ($Script:IsAdmin) {
                    $ladder.Add('services')
                    $ladder.Add('device')
                } else {
                    Warn 'The strongest fixes (switching the driver, restarting Windows Audio and the Focusrite) need'
                    Info 'Administrator. Run the tool again and click "Yes" when Windows asks, to get them.'
                }
                $ladder.Add('replug')
                $stop = $false
                foreach ($stepName in $ladder) {
                    $acted = $false
                    switch ($stepName) {
                        'driver' {
                            if (Ask 'Switch the Focusrite over to the Focusrite driver? (Windows re-detects it - takes ~30 seconds)' $true -Changes) { $acted = [bool](Fix-GenericDriver) }
                        }
                        'reinstall' {
                            Bad 'The Focusrite driver is not attached, so it needs a clean (re)install first.'
                            Show-ReinstallSteps 'Clean reinstall of the Focusrite driver:'
                            if (Ask 'Open the Focusrite downloads page now?' $true) { try { Start-Process 'https://downloads.focusrite.com/' } catch { } }
                            $stop = $true
                        }
                        'close' {
                            $b = @(Get-BusyApps)
                            if ($b.Count -gt 0 -and (Ask ('Close ' + (($b | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', ') + '? (save your work first)') $true -Changes)) { $acted = [bool](Fix-CloseApps $b) }
                        }
                        'msd' {
                            $Script:MsdOffered = $true
                            if (Ask 'Switch MSD / Easy Start mode off now? (I will show you how)' $true) { $acted = [bool](Fix-MsdMode) }
                        }
                        'services' {
                            if (Ask 'Restart the Windows Audio services? (all sound stops for a few seconds)' $true -Changes) { $acted = [bool](Fix-RestartAudioServices) }
                        }
                        'device' {
                            if (Ask 'Restart the Focusrite inside Windows? (like unplugging it, done by software)' $true -Changes) { $acted = [bool](Fix-RestartDevice) }
                        }
                        'replug' {
                            if (Ask 'Re-plug the Focusrite into a different USB port? (I will walk you through it)' $true) { $acted = [bool](Fix-Replug) }
                        }
                    }
                    if ($stop) { break }
                    if ($acted) {
                        $res = Test-Driver 'Testing again'
                        if ($res -eq $true) {
                            $fixed = $true
                            $Script:ProbeWorks = $true
                            Show-Fixed
                            break
                        }
                    }
                }
            }

            # Settings worth changing even when it works.
            Head 'Other settings worth fixing'
            $offered = $false
            if ($Script:MsdOn -and -not $Script:MsdOffered -and $Script:TopId -and (Test-MsdMode)) {
                $offered = $true
                if (Ask 'The Focusrite is still in MSD / Easy Start mode. Switch it off now? (I will show you how)' $true) { [void](Fix-MsdMode) }
            }
            if ($Script:Asio4AllApps.Count -gt 0) {
                $offered = $true
                if (Ask 'Uninstall ASIO4ALL? (Focusrite recommends it)' $true -Changes) { Fix-RemoveAsio4All }
            }
            if ($Script:SelectiveSuspendOn) {
                $offered = $true
                if ($Script:IsAdmin) {
                    if (Ask 'Turn off USB selective suspend? (stops Windows powering down USB audio)' $true -Changes) { Fix-SelectiveSuspend }
                } else { Info 'USB selective suspend: needs Administrator to change - run the tool again and click Yes.' }
            }
            if ($Script:TopId -and ($Script:RateMismatch -or -not $fixed)) {
                $offered = $true
                if (Ask 'Open Windows Sound settings and set the Focusrite to 48000 Hz / exclusive mode off? (I will tell you what to click)' $true) {
                    Open-SoundSettings
                    if (-not $fixed -and $Script:MainAsio) {
                        $res = Test-Driver 'Testing again'
                        if ($res -eq $true) { $fixed = $true; $Script:ProbeWorks = $true; Show-Fixed }
                    }
                }
            }
            if ($Script:MicBlocked) {
                $offered = $true
                if (Ask 'Open the microphone privacy settings? (lets Windows apps like Discord use the Focusrite input)' $false) {
                    try { Start-Process 'ms-settings:privacy-microphone' } catch { }
                }
            }
            if ($Script:DriverOld) {
                $offered = $true
                if (Ask 'Open the Focusrite downloads page to get the newest driver?' (-not $fixed)) {
                    try { Start-Process 'https://downloads.focusrite.com/' } catch { }
                }
            }
            if (-not $offered) { Good 'Nothing else to change.' }

            if (-not $fixed) {
                Head 'Still not working? Do these, in order'
                Step 'A) RESTART the PC (Start > Power > Restart - not Shut down), plug the Focusrite straight'
                Step '   into the PC, then open TONEX on its own.'
                if ($Script:ReinstallShown) { Step 'B) Do the clean reinstall of the Focusrite driver shown above.' }
                else { Show-ReinstallSteps 'B) If that does not help, do a clean reinstall of the Focusrite driver:' }
                if ($Script:IsAmd) {
                    Step 'C) AMD Ryzen PC: also update the motherboard BIOS and the AMD chipset driver - this fixed'
                    Step '   USB audio problems for many Ryzen users.'
                }
                Step 'D) Still failing with another cable, another port and after a clean reinstall? Contact'
                Step '   Focusrite support (support.focusrite.com) and attach this report.'
            }
        }

        # ---------------------------------------------------------------- tips
        Head 'Once it works - TONEX settings'
        Info '* Only have ONE music app open at a time (TONEX OR AmpliTube, not both).'
        Info '* Settings: Audio device type = ASIO, Device = Focusrite USB ASIO.'
        Info '* Input = the input your guitar is plugged into (press INST on that input).'
        Info '* Left/Right Monitor (outputs) = Output 1 and Output 2. Sample rate 48000, buffer 128 or 256.'
        Info '* Turn OFF "Direct Monitor" on the Focusrite, or you hear the dry guitar on top of the amp sound.'
    } catch {
        Bad ('Unexpected error: ' + $_.Exception.Message)
        Log ($_.ScriptStackTrace)
    } finally {
        $path = Save-Report
        Say ''
        Head 'Report'
        $copied = $false
        try { Set-Clipboard -Value ($Script:LogLines -join "`r`n") -ErrorAction Stop; $copied = $true } catch { }
        if ($path) { Write-Host ('  Saved to: ' + $path) -ForegroundColor White }
        if ($copied) { Write-Host '  The report is also copied - just paste it (Ctrl+V) into WhatsApp / Discord to send it.' -ForegroundColor White }
        Write-Host ''
    }
    if (-not $Script:FromBat) { Wait-Enter 'Press Enter to close' }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }
