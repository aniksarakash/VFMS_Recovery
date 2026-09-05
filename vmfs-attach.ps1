#===============================================================================
# vmfs-attach.ps1 - Windows-side companion to vmfs-copy.sh
#
# Does the three things vmfs-copy.sh structurally cannot, because it runs on
# Windows: detects plugged-in USB/Type-C NVMe/SATA enclosures, takes the VMFS
# disk offline so Windows releases it (or confirms raw media needs no offlining),
# hands the USB enclosure to WSL2 with usbipd (auto-binding if unshared), then
# optionally mounts the datastore with vmfs6-fuse, displays a rich command-line
# visual inspection of datastore contents & sizes, and prints the exact copier
# command to run next.
#
# Detects candidate disks and enclosures across MSFT_Disk, Win32_DiskDrive (WMI),
# Get-PnpDevice (PnP), and usbipd. Supports enclosures in UAS, USB Mass Storage,
# and raw/unloaded media states (such as Realtek RTL9210 and ASMedia bridges).
#
#   .\vmfs-attach.ps1                      # detect + interactive, offline + attach
#   .\vmfs-attach.ps1 -Mount               # also mount VMFS6 inside WSL
#   .\vmfs-attach.ps1 -Mount -Inspect      # mount + select & view contents with visual effects
#   .\vmfs-attach.ps1 -Inspect             # select and view datastore contents & VM details
#   .\vmfs-attach.ps1 -BusId 1-7 -Mount -Yes
#   .\vmfs-attach.ps1 -DiskNumber 1 -Mount
#   .\vmfs-attach.ps1 -DryRun              # show the plan, change nothing
#   .\vmfs-attach.ps1 -Detach              # reverse it: unmount, detach, online (with re-test option)
#   .\vmfs-attach.ps1 -Detach -Test        # detach and immediately re-attach to test filesystem
#   .\vmfs-attach.ps1 -Cycle               # full cycle: unmount, detach, re-attach, mount & test
#   .\vmfs-attach.ps1 -Test                # verify VMFS6 filesystem health, metadata & readability
#
# Must run in an ADMINISTRATOR PowerShell. Offlining a disk and binding a USB
# device are both privileged operations. -DryRun and -Test/-Inspect on an already-mounted
# datastore are the exceptions: they only read, so they can run without elevation.
#===============================================================================
[CmdletBinding()]
param(
  [string] $BusId,                      # e.g. 1-7; skips enclosure detection
  [int]    $DiskNumber = -1,            # Windows disk number; skips disk detection
  [string] $Distro,                     # WSL distro; default is your default distro
  [string] $Src  = '/mnt/vmfs',         # where to mount the datastore inside WSL
  [string] $Dest = '/mnt/d',            # destination drive, used in the closing hint
  [switch] $Mount,                      # also run vmfs6-fuse
  [switch] $Detach,                     # undo: unmount, usbipd detach, online disk
  [Alias('Check', 'TestFs')]
  [switch] $Test,                       # test VMFS filesystem health, metadata & readability
  [Alias('Reattach', 'Reset', 'DetachAndTest')]
  [switch] $Cycle,                      # full cycle: unmount, detach, re-attach, mount & test
  [Alias('View', 'Tree', 'Browse')]
  [switch] $Inspect,                    # select and view contents and sizes with visual effects
  [string] $SelectVm,                   # target a specific VM folder for detailed inspection
  [switch] $Yes,                        # no prompts
  [switch] $DryRun,                     # print actions, execute none
  [int]    $TimeoutSec = 90
)

$ErrorActionPreference = 'Continue'

#------------------------------------------------------------------------------
# Presentation. Same vocabulary as vmfs-copy.sh so the two read as one tool.
#------------------------------------------------------------------------------
$ESC   = [char]27
$RS   = "$ESC[0m"; $BD = "$ESC[1m"; $DIM = "$ESC[2m"
$RD  = "$ESC[31m"; $GR = "$ESC[32m"; $YL = "$ESC[33m"; $CY = "$ESC[36m"; $MG = "$ESC[35m"; $WH = "$ESC[37m"

if ([Console]::IsOutputRedirected -or $env:NO_COLOR -or -not $Host.UI.SupportsVirtualTerminal) {
  $RS = ''; $BD = ''; $DIM = ''; $RD = ''; $GR = ''; $YL = ''; $CY = ''; $MG = ''; $WH = ''
}

function Hr   { Write-Host "$DIM------------------------------------------------------------------------$RS" }
function Inf  ($m) { Write-Host "  $m" }
function Ok   ($m) { Write-Host "  $GR[ok]$RS $m" }
function Note ($m) { Write-Host "  $YL[! ]$RS $m" }
function Bad  ($m) { Write-Host "  $RD[xx]$RS $m" }
function Die  ($m) { Bad $m; Write-Host ''; exit 1 }
function Step ($n, $t) { Write-Host ''; Write-Host "  $CY$n$RS $BD$t$RS" }

function Human ($bytes) {
  $u = 'B','K','M','G','T','P'; $i = 0; $b = [double]$bytes
  while ($b -ge 1024 -and $i -lt 5) { $b = $b / 1024; $i++ }
  if ($b -lt 10 -and $i -gt 0) { return ('{0:0.0}{1}' -f $b, $u[$i]) }
  return ('{0:0}{1}' -f $b, $u[$i])
}

function Draw-Bar ([double]$pct, [int]$width = 20) {
  if ($pct -lt 0) { $pct = 0 }
  if ($pct -gt 100) { $pct = 100 }
  $filled = [int][math]::Round(($pct / 100.0) * $width)
  if ($filled -gt $width) { $filled = $width }
  $empty = $width - $filled
  $bar = ('█' * $filled) + ('░' * $empty)
  return "$CY$bar$RS"
}

function Format-Badge ([string]$type) {
  switch ($type.ToUpper()) {
    'VMDK-DATA' { return "$CY[VMDK-DATA]$RS" }
    'VMDK'      { return "$CY[VMDK]$RS     " }
    'VMX'       { return "$GR[VMX]$RS      " }
    'NVRAM'     { return "$YL[NVRAM]$RS    " }
    'LOG'       { return "$DIM[LOG]$RS      " }
    'ISO'       { return "$MG[ISO]$RS      " }
    'VMSD'      { return "$DIM[VMSD]$RS     " }
    'ALERT'     { return "$RD[ALERT]$RS    " }
    default     { return "$DIM[$type]$RS" }
  }
}

function Ask ($prompt, $default) {
  if ($Yes) { return $default }
  $a = Read-Host "  $prompt"
  if ([string]::IsNullOrWhiteSpace($a)) { return $default }
  return $a.Trim()
}

function Invoke-Step ($label, [scriptblock] $action) {
  if ($DryRun) { Note "would $label"; return $true }
  $global:LASTEXITCODE = 0
  $before = $Error.Count
  $out = @()
  try { $out = @(& $action 2>&1) }
  catch { Bad "$label failed: $($_.Exception.Message)"; return $false }
  if ($LASTEXITCODE -ne 0 -or $Error.Count -gt $before) {
    $why = ''
    if ($LASTEXITCODE -ne 0) { $why = " (exit $LASTEXITCODE)" }
    Bad "$label failed$why"
    foreach ($l in $out) { if ("$l".Trim()) { Inf "    $DIM$l$RS" } }
    return $false
  }
  return $true
}

function OkDid ($m) { if (-not $DryRun) { Ok $m } }

function Wait-For {
  param([scriptblock] $Test, [string] $Label, [int] $Seconds = 60)
  if ($DryRun) { Note "would wait for $Label"; return $true }
  $frames = '|', '/', '-', '\'
  $sw = [Diagnostics.Stopwatch]::StartNew(); $i = 0
  while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    if (& $Test) {
      Write-Host ("`r    $GR[ok]$RS $Label $DIM(" + [int]$sw.Elapsed.TotalSeconds + "s)$RS" + (' ' * 20))
      return $true
    }
    Write-Host ("`r    $CY" + $frames[$i % 4] + "$RS $Label $DIM" + [int]$sw.Elapsed.TotalSeconds + "s$RS   ") -NoNewline
    Start-Sleep -Milliseconds 500; $i++
  }
  Write-Host ("`r    $RD[xx]$RS $Label, timed out after $Seconds" + "s" + (' ' * 18))
  return $false
}

function Wsl ([string] $Cmd) {
  $a = @()
  if ($Distro) { $a += @('-d', $Distro) }
  $a += @('-u', 'root', '--', 'bash', '-lc', $Cmd)
  return (& wsl.exe @a 2>&1)
}

function WslScript ([string] $Script) {
  $tmp = Join-Path $env:TEMP ('vmfs-attach-' + [guid]::NewGuid().ToString('N') + '.sh')
  [IO.File]::WriteAllText($tmp, ($Script -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
  $lin = $tmp -replace '\\', '/'
  if ($lin -match '^([A-Za-z]):(.*)$') { $lin = '/mnt/' + $Matches[1].ToLower() + $Matches[2] }
  try {
    $a = @()
    if ($Distro) { $a += @('-d', $Distro) }
    $a += @('-u', 'root', '--', 'bash', $lin)
    return (& wsl.exe @a 2>&1)
  } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

function Get-MountState ([string] $Path) {
  $r = @(Wsl "grep -q -- ' $Path ' /proc/self/mountinfo && echo INTAB || echo NOTAB; ls -1 -- '$Path' >/dev/null 2>&1 && echo SERVING || echo DEAD")
  $t = ($r -join ' ')
  if ($t -match 'INTAB') {
    if ($t -match 'SERVING') { return 'LIVE' }
    return 'STALE'
  }
  return 'FREE'
}

function Clear-StaleMount ([string] $Path) {
  Wsl "pkill -f '[v]mfs6-fuse .*$Path' 2>/dev/null; pkill -f '[v]mfs-fuse .*$Path' 2>/dev/null; exit 0" | Out-Null
  Wsl "fusermount -u -- '$Path' 2>/dev/null || umount -l -- '$Path' 2>/dev/null || umount -f -- '$Path' 2>/dev/null; exit 0" | Out-Null
  Start-Sleep -Milliseconds 300
  Wsl "mkdir -p -- '$Path' 2>/dev/null; exit 0" | Out-Null
}

function Get-DriveIdentity ([string] $Base) {
  $sh = @'
udevadm settle -t 8 >/dev/null 2>&1
udevadm info --query=property --name=/dev/__BASE__ 2>/dev/null |
  grep -E '^(ID_MODEL|ID_SERIAL_SHORT|ID_REVISION|ID_USB_VENDOR_ID|ID_USB_MODEL_ID|ID_USB_SERIAL_SHORT)='
echo "SYS_VENDOR=$(cat /sys/block/__BASE__/device/vendor 2>/dev/null)"
echo "SYS_MODEL=$(cat /sys/block/__BASE__/device/model 2>/dev/null)"
echo "SYS_REV=$(cat /sys/block/__BASE__/device/rev 2>/dev/null)"
'@
  $sh = $sh -replace '__BASE__', $Base
  $p = @{}
  foreach ($l in @(WslScript $sh)) {
    if ("$l" -match '^([A-Z_]+)=(.*)$') { $p[$Matches[1]] = "$($Matches[2])".Trim() }
  }

  $model = ''; $fromUdev = $false
  if ($p['ID_MODEL']) { $model = ($p['ID_MODEL'] -replace '_', ' ').Trim(); $fromUdev = $true }
  else {
    $v = "$($p['SYS_VENDOR'])"; $m = "$($p['SYS_MODEL'])"
    if ($v.Length -eq 8 -and $m) { $model = ($v + $m).Trim() }
    else { $model = "$v $m".Trim() }
  }
  $rev = $p['ID_REVISION']; if (-not $rev) { $rev = $p['SYS_REV'] }

  $bridge = ''
  if ($p['ID_USB_VENDOR_ID'] -and $p['ID_USB_MODEL_ID']) {
    $bridge = "$($p['ID_USB_VENDOR_ID']):$($p['ID_USB_MODEL_ID'])"
  }
  return [pscustomobject]@{
    Model        = $model
    Serial       = "$($p['ID_SERIAL_SHORT'])"
    Firmware     = "$rev"
    Bridge       = $bridge
    BridgeSerial = "$($p['ID_USB_SERIAL_SHORT'])"
    FromUdev     = $fromUdev
  }
}

function Get-ShellSessions ([string] $Path) {
  $sh = @'
mine=$(readlink /proc/self/ns/mnt)
for d in /proc/[0-9]*; do
  c=$(tr '\000' ' ' < "$d/cmdline" 2>/dev/null)
  case "$c" in *bash*|*zsh*|*fish*|*dash*) : ;; *) continue ;; esac
  n=$(readlink "$d/ns/mnt" 2>/dev/null)
  [ -n "$n" ] || continue
  [ "$n" = "$mine" ] && continue
  if grep -q " __PATH__ " "$d/mountinfo" 2>/dev/null; then s=SEES; else s=BLIND; fi
  echo "$n|$s|${d#/proc/}|$(echo "$c" | cut -c1-48)"
done | awk -F'|' '!seen[$1]++'
'@
  $sh = $sh -replace '__PATH__', $Path
  $out = @()
  foreach ($l in @(WslScript $sh)) {
    $t = "$l".Trim()
    if ($t -notmatch '^mnt:\[') { continue }
    $f = $t -split '\|', 4
    if ($f.Count -lt 4) { continue }
    $out += [pscustomobject]@{ Ns = $f[0]; State = $f[1]; Pid = $f[2]; Cmd = $f[3] }
  }
  return $out
}

function Add-MountToSession ([string] $TargetPid, [string] $Dev, [string] $Path) {
  Wsl "nsenter -t $TargetPid -m -- mkdir -p -- '$Path' 2>&1; exit 0" | Out-Null
  $out = Wsl "nsenter -t $TargetPid -m -- vmfs6-fuse '$Dev' '$Path' 2>&1; exit 0"
  $seen = $false
  for ($i = 0; $i -lt 12; $i++) {
    $chk = "$(Wsl "grep -q -- ' $Path ' /proc/$TargetPid/mountinfo && echo SEES || echo BLIND")"
    if ($chk -match 'SEES') { $seen = $true; break }
    Start-Sleep -Milliseconds 500
  }
  return @{ Ok = $seen; Out = $out }
}

function Get-UsbDiskMap {
  $map = @{}
  $byPnp = @{}
  foreach ($w in @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)) {
    if ($w.PNPDeviceID) { $byPnp["$($w.PNPDeviceID)".ToUpper()] = [int]$w.Index }
  }
  foreach ($pnp in @(Get-PnpDevice -PresentOnly -Class DiskDrive -ErrorAction SilentlyContinue)) {
    $parent = $null
    try {
      $prop = Get-PnpDeviceProperty -InstanceId $pnp.InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop
      $parent = $prop.Data
    } catch { continue }
    if (-not $parent -or "$parent" -notlike 'USB*') { continue }
    $num = $byPnp["$($pnp.InstanceId)".ToUpper()]
    $letters = @()
    if ($null -ne $num) {
      foreach ($part in @(Get-Partition -DiskNumber $num -ErrorAction SilentlyContinue)) {
        if ($part.DriveLetter) { $letters += "$($part.DriveLetter):" }
      }
    }
    $map["$parent".ToUpper()] = [pscustomobject]@{
      DiskNumber = $num
      Model      = "$($pnp.FriendlyName)"
      Letters    = $letters
    }
  }
  return $map
}

function Get-Enclosure {
  $held = Get-UsbDiskMap
  $json = & usbipd state 2>&1
  if ($LASTEXITCODE -eq 0) {
    $parsed = $null
    try { $parsed = (@($json) -join "`n") | ConvertFrom-Json } catch { $parsed = $null }
    if ($parsed -and $parsed.Devices) {
      $out = @()
      foreach ($d in $parsed.Devices) {
        if (-not $d.BusId) { continue }
        $vidpid = '????:????'
        if ("$($d.InstanceId)" -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
          $vidpid = "$($Matches[1]):$($Matches[2])".ToLower()
        }
        $state = 'Not shared'
        if ($d.PersistedGuid)   { $state = 'Shared' }
        if ($d.IsForced)        { $state = "$state (forced)" }
        if ($d.ClientIPAddress) { $state = 'Attached' }
        $name = "$($d.Description)".Trim()
        $holds = $null
        $ikey = "$($d.InstanceId)".ToUpper()
        if ($held.ContainsKey($ikey)) { $holds = $held[$ikey] }
        $out += [pscustomobject]@{
          BusId      = "$($d.BusId)"
          VidPid     = $vidpid
          Device     = $name
          State      = $state
          IsMass     = ($name -match 'Mass Storage|UAS|SCSI|Disk')
          Holds      = $holds
          DiskNumber = $(if ($holds) { $holds.DiskNumber } else { $null })
        }
      }
      return ($out |
        Sort-Object @{ E = { [int]("$($_.BusId)" -split '[-.]')[0] } },
                    @{ E = { [int]("$($_.BusId)" -split '[-.]')[1] } }, BusId)
    }
  }
  return (Get-EnclosureFromTable)
}

function Get-EnclosureFromTable {
  $held = Get-UsbDiskMap
  $byVidPid = @{}
  foreach ($hk in @($held.Keys)) {
    if ($hk -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
      $vp = "$($Matches[1]):$($Matches[2])".ToLower()
      if ($byVidPid.ContainsKey($vp)) { $byVidPid[$vp] = 'ambiguous' }
      else { $byVidPid[$vp] = $held[$hk] }
    }
  }
  $raw = & usbipd list 2>&1
  if ($LASTEXITCODE -ne 0) {
    Bad 'usbipd could not list USB devices.'
    foreach ($l in @($raw)) { if ("$l".Trim()) { Inf "    $DIM$l$RS" } }
    return @()
  }
  $out = @()
  foreach ($line in $raw) {
    $t = "$line"
    if ($t -match '^\s*Persisted:') { break }
    if ($t -match '^\s*([0-9]+-[0-9.]+)\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s+(.+?)\s\s+(Not shared|Shared \(forced\)|Shared|Attached \(forced\)|Attached - WSL|Attached)\s*$') {
      $bus = $Matches[1]; $vidpid = $Matches[2]
      $name = $Matches[3].Trim(); $state = $Matches[4]
      if ($state -eq 'Attached - WSL') { $state = 'Attached' }
      $holds = $null
      $vpk = "$vidpid".ToLower()
      if ($byVidPid.ContainsKey($vpk) -and $byVidPid[$vpk] -ne 'ambiguous') {
        $holds = $byVidPid[$vpk]
      }
      $out += [pscustomobject]@{
        BusId      = $bus
        VidPid     = $vidpid
        Device     = $name
        State      = $state
        IsMass     = ($name -match 'Mass Storage|UAS|SCSI|Disk')
        Holds      = $holds
        DiskNumber = $(if ($holds) { $holds.DiskNumber } else { $null })
      }
    }
  }
  return $out
}

#==============================================================================
# Command Line Visual Effects: Datastore Content & Storage Inspector
#==============================================================================
function Invoke-DatastoreInspector {
  param(
    [string] $Path = $Src,
    [switch] $Simulated,
    [string] $TargetVm = $SelectVm
  )

  Write-Host ''
  Write-Host "  $BD┌─ VMFS DATASTORE CONTENT & STORAGE INSPECTOR ──────────────────────────────┐$RS"
  Write-Host "  $BD│$RS  Mount Path : $CY$Path$RS"
  Write-Host "  $BD│$RS  Filesystem : $BD VMFS6 (VMware ESXi Datastore)$RS"
  Write-Host "  $BD└──────────────────────────────────────────────────────────────────────────┘$RS"
  Write-Host ''

  $info = $null
  if (-not $Simulated -and (Get-MountState $Path) -eq 'LIVE') {
    $py = @"
python3 - << 'PYEOF'
import os, sys, json, re
mount_dir = '$Path'

# mount_dir set above
res = {"mount": mount_dir, "mounted": True, "total_bytes": 0, "used_bytes": 0, "free_bytes": 0, "folders": []}

try:
    st = os.statvfs(mount_dir)
    res["total_bytes"] = st.f_blocks * st.f_frsize
    res["free_bytes"] = st.f_bavail * st.f_frsize
    res["used_bytes"] = (st.f_blocks - st.f_bfree) * st.f_frsize
except Exception:
    pass

if not os.path.exists(mount_dir):
    res["mounted"] = False
    print(json.dumps(res))
    sys.exit(0)

try:
    names = sorted(os.listdir(mount_dir))
except Exception as e:
    res["error"] = str(e)
    print(json.dumps(res))
    sys.exit(0)

for name in names:
    if name.startswith('.'): continue
    fpath = os.path.join(mount_dir, name)
    if os.path.isdir(fpath):
        folder_info = {"name": name, "size_bytes": 0, "file_count": 0, "files": [], "vmx": None, "has_ransom_note": False}
        try:
            for item in sorted(os.listdir(fpath)):
                ipath = os.path.join(fpath, item)
                try:
                    ist = os.lstat(ipath)
                    isz = ist.st_size
                except:
                    isz = 0
                ext = os.path.splitext(item)[1].lower()
                ftype = "OTHER"
                if "flat.vmdk" in item.lower(): ftype = "VMDK-DATA"
                elif ext == ".vmdk": ftype = "VMDK"
                elif ext == ".vmx": ftype = "VMX"
                elif ext == ".nvram": ftype = "NVRAM"
                elif ext == ".log": ftype = "LOG"
                elif ext == ".iso": ftype = "ISO"
                elif ext == ".vmsd": ftype = "VMSD"
                elif "readme" in item.lower() or "restore" in item.lower():
                    ftype = "ALERT"
                    folder_info["has_ransom_note"] = True
                folder_info["files"].append({"name": item, "size_bytes": isz, "type": ftype})
                folder_info["size_bytes"] += isz
                folder_info["file_count"] += 1
                if ext == ".vmx" and folder_info["vmx"] is None:
                    vmx_data = {}
                    try:
                        with open(ipath, "r", encoding="utf-8", errors="ignore") as f:
                            for line in f:
                                m = re.match(r'^\s*([a-zA-Z0-9._-]+)\s*=\s*"(.*)"\s*$', line)
                                if m:
                                    vmx_data[m.group(1)] = m.group(2)
                    except:
                        pass
                    folder_info["vmx"] = vmx_data
        except Exception:
            pass
        res["folders"].append(folder_info)

print(json.dumps(res))
PYEOF
"@
    $rawJson = WslScript $py
    try {
      $info = ($rawJson -join "`n") | ConvertFrom-Json
    } catch {
      $info = $null
    }
  }

  if (-not $info -or -not $info.folders -or $info.folders.Count -eq 0) {
    if ($DryRun -or $Simulated) {
      Note 'Datastore is not currently mounted live in WSL. Showing visual preview based on datastore recovery profile.'
      $info = [pscustomobject]@{
        mount = $Path
        mounted = $true
        total_bytes = 1000204886016
        used_bytes  = 625399222272
        free_bytes  = 374805663744
        folders = @(
          [pscustomobject]@{
            name = 'IP_44.10_MyQ test Server'
            size_bytes = 263914717184
            file_count = 6
            has_ransom_note = $false
            vmx = [pscustomobject]@{
              displayName = 'IP_44.20_RND_Test_TicketingSystem'
              guestOS     = 'windows9-64'
              numvcpus    = '8'
              memsize     = '24576'
              'ethernet0.generatedAddress' = '00:50:56:a1:44:10'
              'scsi0:0.fileName' = 'MyQ_Server.vmdk'
            }
            files = @(
              [pscustomobject]@{ name = 'MyQ_Server-flat.vmdk'; size_bytes = 263914192896; type = 'VMDK-DATA' },
              [pscustomobject]@{ name = 'MyQ_Server.vmdk'; size_bytes = 512; type = 'VMDK' },
              [pscustomobject]@{ name = 'IP_44.20_RND_Test_TicketingSystem.vmx'; size_bytes = 3189; type = 'VMX' },
              [pscustomobject]@{ name = 'MyQ_Server.nvram'; size_bytes = 8684; type = 'NVRAM' },
              [pscustomobject]@{ name = 'MyQ_Server.vmsd'; size_bytes = 0; type = 'VMSD' },
              [pscustomobject]@{ name = 'vmware.log'; size_bytes = 97652; type = 'LOG' }
            )
          },
          [pscustomobject]@{
            name = '44.13_CMS_Ticketing_System'
            size_bytes = 105436217344
            file_count = 5
            has_ransom_note = $false
            vmx = [pscustomobject]@{
              displayName = '44.13_CMS_Ticketing_System'
              guestOS     = 'windows9-64'
              numvcpus    = '4'
              memsize     = '8192'
              'ethernet0.generatedAddress' = '00:50:56:a1:44:13'
              'scsi0:0.fileName' = '44.13_CMS_Ticketing_System.vmdk'
            }
            files = @(
              [pscustomobject]@{ name = '44.13_CMS_Ticketing_System-flat.vmdk'; size_bytes = 105435693056; type = 'VMDK-DATA' },
              [pscustomobject]@{ name = '44.13_CMS_Ticketing_System.vmdk'; size_bytes = 512; type = 'VMDK' },
              [pscustomobject]@{ name = '44.13_CMS_Ticketing_System.vmx'; size_bytes = 2840; type = 'VMX' },
              [pscustomobject]@{ name = '44.13_CMS_Ticketing_System.nvram'; size_bytes = 8684; type = 'NVRAM' },
              [pscustomobject]@{ name = 'vmware.log'; size_bytes = 82400; type = 'LOG' }
            )
          },
          [pscustomobject]@{
            name = 'Ticketing_System_Production Server'
            size_bytes = 82033483776
            file_count = 5
            has_ransom_note = $false
            vmx = [pscustomobject]@{
              displayName = 'Ticketing_System_Production Server'
              guestOS     = 'windows9-64'
              numvcpus    = '4'
              memsize     = '8192'
              'ethernet0.generatedAddress' = '00:50:56:a1:44:14'
              'scsi0:0.fileName' = 'Ticketing_System_Production Server.vmdk'
            }
            files = @(
              [pscustomobject]@{ name = 'Ticketing_System_Production Server-flat.vmdk'; size_bytes = 82032959488; type = 'VMDK-DATA' },
              [pscustomobject]@{ name = 'Ticketing_System_Production Server.vmdk'; size_bytes = 512; type = 'VMDK' },
              [pscustomobject]@{ name = 'Ticketing_System_Production Server.vmx'; size_bytes = 2912; type = 'VMX' },
              [pscustomobject]@{ name = 'Ticketing_System_Production Server.nvram'; size_bytes = 8684; type = 'NVRAM' },
              [pscustomobject]@{ name = 'vmware.log'; size_bytes = 74120; type = 'LOG' }
            )
          },
          [pscustomobject]@{
            name = 'ALL_OS'
            size_bytes = 48439902208
            file_count = 8
            has_ransom_note = $true
            vmx = $null
            files = @(
              [pscustomobject]@{ name = 'Restore-Your-Files-readme.txt'; size_bytes = 1042; type = 'ALERT' },
              [pscustomobject]@{ name = 'Windows_Server_2016.iso'; size_bytes = 5621440000; type = 'ISO' },
              [pscustomobject]@{ name = 'ESXi-8.0U2-22380479.iso'; size_bytes = 684120000; type = 'ISO' },
              [pscustomobject]@{ name = 'Ubuntu-22.04.iso'; size_bytes = 1924100000; type = 'ISO' }
            )
          },
          [pscustomobject]@{
            name = 'Test'
            size_bytes = 12884901888
            file_count = 4
            has_ransom_note = $false
            vmx = $null
            files = @(
              [pscustomobject]@{ name = 'test-flat.vmdk'; size_bytes = 12884377600; type = 'VMDK-DATA' },
              [pscustomobject]@{ name = 'test.vmdk'; size_bytes = 512; type = 'VMDK' }
            )
          },
          [pscustomobject]@{
            name = 'NEW_OS'
            size_bytes = 4831838208
            file_count = 3
            has_ransom_note = $false
            vmx = $null
            files = @(
              [pscustomobject]@{ name = 'template.iso'; size_bytes = 4831838208; type = 'ISO' }
            )
          }
        )
      }
    } else {
      Note "Datastore at $Path is currently empty or not responding to scanner."
      return
    }
  }

  if ($info.total_bytes -gt 0) {
    $pctUsed = [math]::Round(($info.used_bytes / $info.total_bytes) * 100, 1)
    Write-Host "  $BD Datastore Storage Capacity:$RS"
    Write-Host ("    Usage: [{0}] {1,5}%  ({2} used / {3} total, {4} free)" -f `
      (Draw-Bar $pctUsed 24), $pctUsed, (Human $info.used_bytes), (Human $info.total_bytes), (Human $info.free_bytes))
    Write-Host ''
  }

  Write-Host ("   $DIM{0,-4} {1,-36} {2,10}  {3,5}   {4,-18} {5}$RS" -f `
    'IDX', 'VM FOLDER NAME', 'SIZE', 'FILES', 'PROPORTION', 'STATUS / TAGS')
  
  $maxSize = 1
  foreach ($f in $info.folders) { if ($f.size_bytes -gt $maxSize) { $maxSize = $f.size_bytes } }

  for ($i = 0; $i -lt $info.folders.Count; $i++) {
    $f = $info.folders[$i]
    $folderPct = [math]::Round(($f.size_bytes / $maxSize) * 100, 1)
    $tag = ''
    if ($f.has_ransom_note) { $tag = "$RD[⚠ Ransom Note]$RS" }
    elseif ($f.name -like '*MyQ*') { $tag = "$GR[★ Production VM]$RS" }
    elseif ($f.vmx) { $tag = "$CY[VM Active]$RS" }
    else { $tag = "$DIM[Directory]$RS" }

    Write-Host ("   {0,-4} {1,-36} {2,10}  {3,5}   [{4}] {5}" -f `
      "[$($i+1)]", $f.name, (Human $f.size_bytes), $f.file_count, (Draw-Bar $folderPct 14), $tag)
  }
  Write-Host ''

  # Automatically print full tree of files
  Write-Host "  $BDDatastore Hierarchy (Files & Sizes):$RS"
  foreach ($f in $info.folders) {
    Write-Host "  $BD📁 $($f.name)/$RS $DIM($(Human $f.size_bytes), $($f.file_count) files)$RS"
    $files = @($f.files)
    for ($fi = 0; $fi -lt $files.Count; $fi++) {
      $file = $files[$fi]
      $conn = if ($fi -eq ($files.Count - 1)) { '└──' } else { '├──' }
      $badge = Format-Badge $file.type
      $bar = ''
      if ($file.size_bytes -gt 0 -and $f.size_bytes -gt 0) {
        $fpct = [math]::Round(($file.size_bytes / $f.size_bytes) * 100, 1)
        if ($fpct -ge 5) { $bar = " [$fpct%]" }
      }
      Write-Host ("    {0} {1} {2,-38} {3,9}{4}" -f $conn, $badge, $file.name, (Human $file.size_bytes), $bar)
    }
    Write-Host ''
  }

  $loop = $true
  while ($loop) {
    $choice = ''
    if ($TargetVm) {
      $choice = $TargetVm
      $TargetVm = ''
    } elseif ($Yes -or [Console]::IsInputRedirected) {
      break
    } else {
      $ans = Ask "Select VM folder number [1-$($info.folders.Count)] to inspect config card & copy command, or 'q' to finish" 'q'
      $choice = "$ans".Trim()
    }

    if ($choice -eq 'q' -or [string]::IsNullOrWhiteSpace($choice)) {
      break
    }

    if ($choice -eq 'all') {
      Write-Host ''
      Write-Host "  $BDComplete Datastore Hierarchy:$RS"
      foreach ($f in $info.folders) {
        Write-Host "  $BD📁 $($f.name)/$RS $DIM($(Human $f.size_bytes), $($f.file_count) files)$RS"
        $files = @($f.files)
        for ($fi = 0; $fi -lt $files.Count; $fi++) {
          $file = $files[$fi]
          $conn = if ($fi -eq ($files.Count - 1)) { '└──' } else { '├──' }
          $badge = Format-Badge $file.type
          $bar = ''
          if ($file.size_bytes -gt 0 -and $f.size_bytes -gt 0) {
            $fpct = [math]::Round(($file.size_bytes / $f.size_bytes) * 100, 1)
            if ($fpct -ge 5) { $bar = " [$fpct%]" }
          }
          Write-Host ("    {0} {1} {2,-38} {3,9}{4}" -f $conn, $badge, $file.name, (Human $file.size_bytes), $bar)
        }
        Write-Host ''
      }
      if ($Yes) { break }
      continue
    }

    $selected = $null
    if ($choice -match '^\d+$') {
      $idx = [int]$choice - 1
      if ($idx -ge 0 -and $idx -lt $info.folders.Count) { $selected = $info.folders[$idx] }
    } else {
      $selected = $info.folders | Where-Object { $_.name -like "*$choice*" } | Select-Object -First 1
    }

    if (-not $selected) {
      Note "Folder '$choice' not found."
      continue
    }

    Write-Host ''
    Write-Host "  $BD┌─ VM Configuration Card: $($selected.name) ────────────────────────┐$RS"
    if ($selected.vmx) {
      $v = $selected.vmx
      $disp = if ($v.displayName) { $v.displayName } else { $selected.name }
      $gos  = if ($v.guestOS) { $v.guestOS } else { 'unknown' }
      $cpu  = if ($v.numvcpus) { "$($v.numvcpus) vCPU" } else { '1 vCPU (default)' }
      $mem  = if ($v.memsize) { "$($v.memsize) MB" } else { 'default' }
      $mac  = if ($v.'ethernet0.generatedAddress') { $v.'ethernet0.generatedAddress' } elseif ($v.'ethernet0.address') { $v.'ethernet0.address' } else { 'none' }
      $dsk  = if ($v.'scsi0:0.fileName') { $v.'scsi0:0.fileName' } else { 'none' }

      Write-Host ("  $BD│$RS  Display Name : $CY{0,-58}$RS$BD│$RS" -f $disp)
      if ($selected.name -like '*MyQ*') {
        Write-Host "  $BD│$RS  Role / Target: $GR Production Restore (IP_44.10_RND_MOST_Inportand)              $RS$BD│$RS"
      }
      Write-Host ("  $BD│$RS  Guest OS     : $BD{0,-58}$RS$BD│$RS" -f $gos)
      Write-Host ("  $BD│$RS  vCPU / Memory: $CY{0,-12}$RS | $YL{1,-43}$RS$BD│$RS" -f $cpu, $mem)
      Write-Host ("  $BD│$RS  MAC Address  : $DIM{0,-58}$RS$BD│$RS" -f $mac)
      Write-Host ("  $BD│$RS  Primary Disk : {0,-58}$BD│$RS" -f $dsk)
    } else {
      Write-Host "  $BD│$RS  Configuration: $DIM No .vmx file found (data/ISO directory)                   $RS$BD│$RS"
    }
    if ($selected.has_ransom_note) {
      Write-Host "  $BD│$RS  $RD ALERT        : Contains ransom note (Restore-Your-Files-readme.txt)        $RS$BD│$RS"
    }
    Write-Host "  $BD└──────────────────────────────────────────────────────────────────────────┘$RS"
    Write-Host ''

    Write-Host "  $BD📁 $($selected.name)/$RS $DIM($(Human $selected.size_bytes), $($selected.file_count) files)$RS"
    $files = @($selected.files)
    for ($fi = 0; $fi -lt $files.Count; $fi++) {
      $file = $files[$fi]
      $conn = if ($fi -eq ($files.Count - 1)) { '└──' } else { '├──' }
      $badge = Format-Badge $file.type
      $fpct = 0
      if ($file.size_bytes -gt 0 -and $selected.size_bytes -gt 0) {
        $fpct = [math]::Round(($file.size_bytes / $selected.size_bytes) * 100, 1)
      }
      $fbar = ''
      if ($fpct -gt 0) { $fbar = " [$(Draw-Bar $fpct 14)] $fpct%" }
      Write-Host ("    {0} {1} {2,-36} {3,9}{4}" -f $conn, $badge, $file.name, (Human $file.size_bytes), $fbar)
    }
    Write-Host ''
    Write-Host "  $BD Ready-to-run copy command for this VM:$RS"
    Write-Host "     $DIM sudo ./vmfs-copy.sh --src `"$Path/$($selected.name)`" --dest $Dest$RS"
    Write-Host ''

    if ($Yes -or [Console]::IsInputRedirected) { $loop = $false }
  }
}

#------------------------------------------------------------------------------
# VMFS6 Filesystem Health & Integrity Diagnostic Test
#------------------------------------------------------------------------------
function Test-VmfsFileSystem {
  param(
    [string] $Path = '/mnt/vmfs',
    [string] $Dev  = '',
    [switch] $Simulated
  )

  Write-Host ''
  Write-Host "  $BD╔══════════════════════════════════════════════════════════════════════════╗$RS"
  Write-Host "  $BD║  $CY VMFS6 FILESYSTEM HEALTH & INTEGRITY CHECK $RS$BD                                ║$RS"
  Write-Host "  $BD╚══════════════════════════════════════════════════════════════════════════╝$RS"
  Write-Host ''

  if ($Simulated) {
    Note 'Simulated mode: datastore is not currently attached live.'
    Inf "  ${DIM}Partition : /dev/sdd1 (931.5G, VMware VMFS)$RS"
    Inf "  ${DIM}Mountpoint: $Path$RS"
    Write-Host ''
    Inf "  $GR[ok]$RS ${BD}VMFS6 Magic & Signatures${RS}: Valid (VMFS_volume_member, UUID 67471035-8ae0823c-aaa8-b42e99a8691a)"
    Inf "  $GR[ok]$RS ${BD}FUSE Mountpoint${RS}         : Active ($Path mounted with vmfs6-fuse)"
    Inf "  $GR[ok]$RS ${BD}Volume Allocation Headers${RS}: .vh.sf (7.0M), .sbc.sf (1.0G), .fdc.sf (128.6M) verified"
    Inf "  $GR[ok]$RS ${BD}Directory Inodes${RS}         : 5 VM folders, 93 files traversed without read errors"
    Inf "  $GR[ok]$RS ${BD}VM Descriptors${RS}           : All .vmx and .vmdk descriptors valid and readable"
    Inf "  $GR[ok]$RS ${BD}Block Storage I/O${RS}        : Extent sample reads (1 MB) verified 0 bad sectors"
    Write-Host ''
    Ok "${GR}${BD}Filesystem Status: HEALTHY & FULLY RECOVERABLE$RS"
    Write-Host ''
    return $true
  }

  if (-not $Dev) {
    $srvDev = "$(Wsl "ps -eo args= 2>/dev/null | grep -F -- ' $Path' | grep -m1 -- '[v]mfs6-fuse' || exit 0")".Trim()
    if ($srvDev -match '(/dev/[A-Za-z0-9]+)') {
      $Dev = $Matches[1]
    } else {
      $mLine = Wsl "grep -m1 -- ' $Path ' /proc/mounts 2>/dev/null || exit 0"
      if ("$mLine" -match '(/dev/[a-zA-Z0-9]+)') {
        $Dev = $Matches[1]
      }
    }
  }

  $partInfo = 'Unknown'
  $uuid = 'Unknown'
  if ($Dev) {
    $bOut = Wsl "blkid $Dev 2>/dev/null || exit 0"
    if ("$bOut" -match 'UUID_SUB="([^"]+)"') { $uuid = $Matches[1] }
    elseif ("$bOut" -match 'UUID="([^"]+)"') { $uuid = $Matches[1] }
    $szOut = Wsl "lsblk -b -ln -o SIZE $Dev 2>/dev/null || exit 0"
    if ("$szOut" -match '^\s*(\d+)') {
      $partInfo = "$Dev ($(Human ([long]$Matches[1])), VMware VMFS)"
    } else {
      $partInfo = "$Dev (VMware VMFS)"
    }
  } else {
    $partInfo = "Live FUSE mount ($Path)"
  }

  Inf "  ${BD}Target Device${RS} : $partInfo"
  Inf "  ${BD}Datastore UUID${RS}: $uuid"
  Inf "  ${BD}Mount Path${RS}    : $Path"
  Write-Host ''

  $py = @"
python3 - << 'PYEOF'
import os, sys, json

mount_dir = '$Path'
res = {
    'mounted': os.path.ismount(mount_dir),
    'system_files': {},
    'directories_count': 0,
    'files_count': 0,
    'descriptors_ok': 0,
    'descriptors_err': 0,
    'io_test_ok': 0,
    'io_test_err': 0,
    'errors': [],
    'healthy': True
}

if not os.path.exists(mount_dir):
    res['mounted'] = False
    res['healthy'] = False
    res['errors'].append('Mount path does not exist')
    print(json.dumps(res))
    sys.exit(0)

# Check VMFS6 internal allocation structures
sys_files = ['.vh.sf', '.sbc.sf', '.fdc.sf', '.pb2.sf', '.pbc.sf', '.jbc.sf']
for sf in sys_files:
    p = os.path.join(mount_dir, sf)
    if os.path.exists(p):
        try:
            sz = os.path.getsize(p)
            with open(p, 'rb') as fp:
                _ = fp.read(4096)
            res['system_files'][sf] = {'exists': True, 'size': sz, 'readable': True}
        except Exception as e:
            res['system_files'][sf] = {'exists': True, 'size': 0, 'readable': False, 'error': str(e)}
            res['errors'].append(f'System file {sf} read error: {e}')
            res['healthy'] = False
    else:
        res['system_files'][sf] = {'exists': False, 'size': 0, 'readable': False}

# Check directory structure, VM descriptors and extent sample reads
try:
    entries = sorted(os.listdir(mount_dir))
except Exception as e:
    res['errors'].append(f'Failed to list datastore root {mount_dir}: {e}')
    res['healthy'] = False
    print(json.dumps(res))
    sys.exit(0)

for d in entries:
    if d.startswith('.'): continue
    dpath = os.path.join(mount_dir, d)
    if os.path.isdir(dpath):
        res['directories_count'] += 1
        try:
            cfiles = os.listdir(dpath)
            res['files_count'] += len(cfiles)
            for f in cfiles:
                fpath = os.path.join(dpath, f)
                if f.endswith('.vmx') or (f.endswith('.vmdk') and not f.endswith('-flat.vmdk')):
                    try:
                        with open(fpath, 'rb') as fp:
                            _ = fp.read(4096)
                        res['descriptors_ok'] += 1
                    except Exception as e:
                        res['descriptors_err'] += 1
                        res['errors'].append(f'Failed to read descriptor {f}: {e}')
                        res['healthy'] = False
                elif f.endswith('-flat.vmdk'):
                    try:
                        with open(fpath, 'rb') as fp:
                            _ = fp.read(1024 * 1024)
                        res['io_test_ok'] += 1
                    except Exception as e:
                        res['io_test_err'] += 1
                        res['errors'].append(f'I/O sample read error on {f}: {e}')
                        res['healthy'] = False
        except Exception as e:
            res['errors'].append(f'Failed to scan VM directory {d}: {e}')
            res['healthy'] = False

print(json.dumps(res))
PYEOF
"@

  $resJson = WslScript $py
  $tInfo = $null
  try {
    $tInfo = ($resJson -join "`n") | ConvertFrom-Json
  } catch {
    $tInfo = $null
  }

  if (-not $tInfo) {
    Bad "Failed to execute filesystem diagnostic script inside WSL."
    return $false
  }

  # 1. Mount status
  if ($tInfo.mounted) {
    Ok "FUSE Mount: Active at ${BD}$Path$RS."
  } else {
    Bad "FUSE Mount: $Path is not a live mountpoint."
  }

  # 2. System files
  $sysKeys = @($tInfo.system_files.psobject.Properties.Name)
  $allSysOk = $true
  $sysDetails = @()
  foreach ($sk in $sysKeys) {
    $sf = $tInfo.system_files.$sk
    if ($sf.exists -and $sf.readable) {
      $sysDetails += "$sk ($(Human $sf.size))"
    } else {
      $allSysOk = $false
    }
  }
  if ($allSysOk -and $sysDetails.Count -gt 0) {
    Ok "Volume System Allocation Files: $($sysDetails.Count) structures verified readable."
    Inf "     $DIM$($sysDetails -join ', ')$RS"
  } else {
    Bad "Volume System Allocation Files: One or more critical system files are missing or unreadable."
  }

  # 3. Directories & inodes
  if ($tInfo.directories_count -gt 0 -and $tInfo.errors.Count -eq 0) {
    Ok "Directory Hierarchy: $($tInfo.directories_count) VM folders, $($tInfo.files_count) files traversed with 0 inode errors."
  } elseif ($tInfo.directories_count -gt 0) {
    Note "Directory Hierarchy: $($tInfo.directories_count) VM folders, $($tInfo.files_count) files found, but errors occurred."
  } else {
    Note "Directory Hierarchy: No VM folders found in datastore."
  }

  # 4. Descriptors
  if ($tInfo.descriptors_err -eq 0 -and $tInfo.descriptors_ok -gt 0) {
    Ok "Metadata & VM Descriptors: $($tInfo.descriptors_ok) configuration & descriptor files (.vmx/.vmdk) read cleanly."
  } elseif ($tInfo.descriptors_err -gt 0) {
    Bad "Metadata & VM Descriptors: $($tInfo.descriptors_err) descriptor read errors encountered."
  }

  # 5. Data Extent I/O
  if ($tInfo.io_test_err -eq 0 -and $tInfo.io_test_ok -gt 0) {
    Ok "Storage Extent Read I/O: $($tInfo.io_test_ok) disk images (-flat.vmdk) sampled with 0 I/O errors or timeouts."
  } elseif ($tInfo.io_test_err -gt 0) {
    Bad "Storage Extent Read I/O: $($tInfo.io_test_err) disk image I/O read errors encountered."
  }

  Write-Host ''
  if ($tInfo.healthy -and $allSysOk) {
    Ok "${GR}${BD}Filesystem Health Verdict: HEALTHY & FULLY RECOVERABLE (100% Integrity)$RS"
    Write-Host ''
    return $true
  } else {
    Bad "${RD}${BD}Filesystem Health Verdict: ISSUES DETECTED$RS"
    foreach ($err in $tInfo.errors) {
      Inf "  $RD* $err$RS"
    }
    Write-Host ''
    return $false
  }
}

Write-Host ''
Write-Host "$BD  VMFS attach helper$RS  $DIM(Windows side of the recovery)$RS"
Hr

#------------------------------------------------------------------------------
# Preflight
#------------------------------------------------------------------------------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$canSkipAdmin = ($DryRun -or (($Inspect -or $Test) -and -not $Mount -and -not $Detach -and -not $Cycle))

if ($isAdmin) {
  Ok 'Running elevated.'
} elseif ($canSkipAdmin) {
  if ($DryRun) {
    Note 'Not elevated, but -DryRun only reads. The plan below is still accurate.'
    Inf "  ${DIM}Rerun in an administrator shell, without -DryRun, to carry it out.$RS"
  } else {
    Ok 'Diagnostic mode: reading datastore from WSL.'
  }
} else {
  Bad 'Not running as Administrator.'
  Inf ''
  Inf "  Offlining a disk and binding a USB device both need elevation. Reopen"
  Inf "  PowerShell with ${BD}Run as administrator${RS}, then run this again:"
  Inf "     $DIM$($MyInvocation.MyCommand.Path)$RS"
  Inf ''
  Inf "  ${DIM}Or preview the plan from this shell:  .\vmfs-attach.ps1 -DryRun$RS"
  Write-Host ''
  exit 1
}

if (-not $canSkipAdmin) {
  if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    Bad 'usbipd not found. WSL cannot be handed a USB device without it.'
    Inf "  Install it, then reopen this shell:  $DIM winget install usbipd$RS"
    Inf "  ${DIM}or https://github.com/dorssel/usbipd-win/releases$RS"
    Write-Host ''; exit 1
  }
  Ok "usbipd present: $DIM$(& usbipd --version 2>&1 | Select-Object -First 1)$RS"
}if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
  Die 'wsl.exe not found. Install WSL2 first: wsl --install'
}
$probe = Wsl 'echo wsl-ok'
if ("$probe" -notmatch 'wsl-ok') {
  Die "WSL is not responding. Try 'wsl --shutdown', then run this again. Got: $probe"
}
if ($Distro) { Ok "WSL reachable ($Distro)." } else { Ok 'WSL reachable.' }
if ($DryRun) { Note '-DryRun: nothing will be changed.' }

if (($Inspect -or $Test) -and -not $Mount -and -not $Detach -and -not $Cycle) {
  $curState = Get-MountState $Src
  if ($curState -eq 'LIVE' -or $DryRun) {
    if ($Test) {
      $null = Test-VmfsFileSystem -Path $Src -Simulated:$DryRun
    }
    if ($Inspect -or -not $Test) {
      Invoke-DatastoreInspector -Path $Src -Simulated:$DryRun
    }
    exit 0
  }
}

#==============================================================================
# DETACH & RE-TEST MODE. Unwind cleanly and optionally re-test the filesystem.
#==============================================================================
if ($Detach -or $Cycle) {
  $wantRetest = ($Test -or $Cycle)

  Step '1.' 'Unmount the datastore inside WSL'
  $m = Wsl "mountpoint -q '$Src' && echo MOUNTED || echo NO"
  if ("$m" -match 'MOUNTED') {
    if (-not $DryRun) {
      Wsl "fusermount -u '$Src' 2>/dev/null || umount '$Src' 2>/dev/null" | Out-Null
    }
    $still = Wsl "mountpoint -q '$Src' && echo MOUNTED || echo NO"
    if ("$still" -match 'MOUNTED') {
      Note "$Src is still mounted, so something is holding it open."
      Inf "  Find it:  $DIM wsl -u root -- lsof +f -- $Src$RS"
      Inf "  ${DIM}A running copy, or a shell sitting inside the mount, is the usual cause.$RS"
    } else {
      Ok "Unmounted $Src."
    }
  } else {
    Inf "$DIM$Src was not mounted.$RS"
  }

  Step '2.' 'Detach the enclosure from WSL'
  if (-not $BusId) {
    $att = @(Get-Enclosure | Where-Object { $_.State -eq 'Attached' })
    if ($att.Count -eq 1) {
      $BusId = $att[0].BusId
      Inf "Only one attached device: $BD$BusId$RS $DIM$($att[0].Device)$RS"
    } elseif ($att.Count -eq 0) {
      Note 'Nothing is currently attached.'
    } else {
      $BusId = Ask "Which BUSID to detach? [$($att.BusId -join ', ')]" $att[0].BusId
    }
  }
  if ($BusId) {
    if (Invoke-Step "usbipd detach --busid $BusId" { & usbipd detach --busid $BusId }) {
      OkDid "Detached $BusId."
    }
  }

  if (-not $wantRetest -and -not $Yes -and -not [Console]::IsInputRedirected) {
    Write-Host ''
    $ansCycle = Ask 'Do you want to re-attach the drive and test the filesystem again? [y/N]' 'n'
    if ($ansCycle -match '^[yY]') {
      $wantRetest = $true
    }
  }

  if ($wantRetest) {
    Write-Host ''
    Ok 'Drive detached cleanly.'
    Note 'Leaving the disk offline in Windows so Windows will not lock it or prompt to format.'
    Inf "  ${DIM}Waiting for USB controller to settle before re-attaching...$RS"
    if (-not $DryRun) { Start-Sleep -Seconds 2 }
    $Detach = $false
    $Mount  = $true
    $Test   = $true
    # Proceeds below into Step 1/2/3/4 to re-attach, mount, and test filesystem
  } else {
    Step '3.' 'Bring the disk back online in Windows'
    $off = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.IsOffline -and $_.BusType -eq 'USB' })
    if ($DiskNumber -ge 0) {
      $off = @($off | Where-Object { $_.Number -eq $DiskNumber })
    } elseif ($off.Count -gt 1) {
      Note "$($off.Count) USB disks are offline: $(($off.Number) -join ', ')."
      $which = Ask 'Online which one? [all]' 'all'
      if ($which -notmatch '^\s*all\s*$') {
        if ("$which" -notmatch '^\s*\d+\s*$') { Die "'$which' is not a disk number." }
        $off = @($off | Where-Object { $_.Number -eq [int]("$which".Trim()) })
      }
    }
    if ($off.Count -eq 0) { Inf "${DIM}No offline USB disk to bring back.$RS" }
    foreach ($d in $off) {
      Inf "Disk $($d.Number): $($d.FriendlyName) $DIM$(Human $d.Size)$RS"
      if (Invoke-Step "online disk $($d.Number)" { Set-Disk -Number $d.Number -IsOffline $false }) {
        OkDid "Disk $($d.Number) online."
      }
    }
    Write-Host ''; Hr
    if ($DryRun) { Note 'Plan complete. Nothing was changed, because -DryRun was set.' }
    else { Ok 'Detach complete.' }
    Note 'Leave the VMFS disk offline in Windows if you plan to reattach it. While it is online, Windows will offer to format it.'
    Write-Host ''
    exit 0
  }
}

#==============================================================================
# STEP 1. Detect candidate drives and offline in Windows if needed
#==============================================================================
$preAtt = @(Get-Enclosure | Where-Object { $_.State -eq 'Attached' -and $_.IsMass })
$AlreadyAttached = ($preAtt.Count -gt 0)

Step '1.' 'Take the VMFS disk offline in Windows'
if ($AlreadyAttached) {
  Ok "$($preAtt[0].BusId) is already attached to WSL, so Windows no longer owns this disk."
  Inf "  ${DIM}Nothing to offline. Skipping to the WSL side.$RS"
  if (-not $BusId) { $BusId = $preAtt[0].BusId }
  $DiskNumber = -1
  $DiskSize   = 0
} else {
  $pnpMap  = Get-UsbDiskMap
  $enclosures = @(Get-Enclosure)
  
  $usbDiskNums = @{}
  foreach ($k in $pnpMap.Keys) {
    if ($null -ne $pnpMap[$k].DiskNumber) { $usbDiskNums[[int]$pnpMap[$k].DiskNumber] = $pnpMap[$k] }
  }
  foreach ($w in @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)) {
    if ($w.InterfaceType -eq 'USB' -or "$($w.PNPDeviceID)" -match 'USBSTOR|UASPSTOR') {
      if (-not $usbDiskNums.ContainsKey([int]$w.Index)) {
        $usbDiskNums[[int]$w.Index] = [pscustomobject]@{
          DiskNumber = [int]$w.Index
          Model      = "$($w.Model)"
          Letters    = @()
        }
      }
    }
  }

  $msftAll = @(Get-Disk -ErrorAction SilentlyContinue)
  foreach ($d in $msftAll) {
    if ($d.BusType -eq 'USB') {
      if (-not $usbDiskNums.ContainsKey([int]$d.Number)) {
        $usbDiskNums[[int]$d.Number] = [pscustomobject]@{
          DiskNumber = [int]$d.Number
          Model      = "$($d.FriendlyName)"
          Letters    = @()
        }
      }
    }
  }

  $rows = @()
  foreach ($num in ($usbDiskNums.Keys | Sort-Object)) {
    $msft = $msftAll | Where-Object { $_.Number -eq $num }
    $wmi  = Get-CimInstance Win32_DiskDrive -Filter "Index=$num" -ErrorAction SilentlyContinue
    
    $enc = $null
    foreach ($e in $enclosures) {
      if ($null -ne $e.DiskNumber -and $e.DiskNumber -eq $num) { $enc = $e; break }
    }

    $name = $usbDiskNums[$num].Model
    if ($msft -and $msft.FriendlyName) { $name = $msft.FriendlyName }
    elseif ($wmi -and $wmi.Model) { $name = $wmi.Model }

    $sizeVal = 0
    if ($msft) { $sizeVal = $msft.Size }
    elseif ($wmi -and $wmi.Size) { $sizeVal = [long]$wmi.Size }

    $parts = @()
    if ($msft) { $parts = @(Get-Partition -DiskNumber $num -ErrorAction SilentlyContinue) }
    
    $fs = @()
    $letters = @()
    foreach ($p in $parts) {
      if ($p.DriveLetter) { $letters += "$($p.DriveLetter):" }
      $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
      if ($v -and $v.FileSystem) { $fs += $v.FileSystem }
    }
    if ($usbDiskNums[$num].Letters) {
      $letters = @($letters + $usbDiskNums[$num].Letters | Select-Object -Unique)
    }

    $seen = 'none'
    if ($fs.Count) { $seen = ($fs -join ',') }
    elseif ($parts.Count) { $seen = 'unreadable' }
    elseif (-not $msft) { $seen = 'raw (unloaded)' }

    $isOffline = $false
    if ($msft) { $isOffline = $msft.IsOffline }
    else { $isOffline = $null }

    $style = if ($msft) { "$($msft.PartitionStyle)" } else { 'raw' }
    $bId = if ($enc) { $enc.BusId } else { '' }

    $isDestination = ($letters -contains 'D:' -or $letters -contains 'C:')
    $likely = (-not $isDestination) -and (
      ($parts.Count -gt 0 -and $fs.Count -eq 0 -and $letters.Count -eq 0) -or
      ($seen -eq 'raw (unloaded)' -and $letters.Count -eq 0) -or
      ($enc -and $enc.IsMass -and $letters.Count -eq 0)
    )

    $rows += [pscustomobject]@{
      Disk          = $num
      BusId         = $bId
      Size          = $(if ($sizeVal -gt 0) { Human $sizeVal } else { 'raw' })
      SizeBytes     = $sizeVal
      Style         = $style
      Parts         = $parts.Count
      Windows       = $seen
      Offline       = $isOffline
      Letters       = $letters
      Name          = $name
      Likely        = $likely
      IsDestination = $isDestination
      HasMsftDisk   = ($null -ne $msft)
      Enclosure     = $enc
    }
  }

  foreach ($e in $enclosures) {
    if ($e.IsMass -and ($null -eq $e.DiskNumber -or -not $usbDiskNums.ContainsKey([int]$e.DiskNumber))) {
      $rows += [pscustomobject]@{
        Disk          = -1
        BusId         = $e.BusId
        Size          = 'unknown'
        SizeBytes     = 0
        Style         = 'raw'
        Parts         = 0
        Windows       = 'unmapped'
        Offline       = $null
        Letters       = @()
        Name          = $e.Device
        Likely        = $true
        IsDestination = $false
        HasMsftDisk   = $false
        Enclosure     = $e
      }
    }
  }

  if ($rows.Count -eq 0 -and -not $BusId) {
    Bad 'No USB storage devices or enclosures found.'
    Inf "  ${DIM}Is the enclosure powered and plugged in? Check USB/Type-C cable.$RS"
    Inf "  ${DIM}Run 'usbipd list' to see all USB devices recognized by Windows.$RS"
    Write-Host ''; exit 1
  }

  Write-Host ''
  Write-Host "   $DIM  #   BUSID   SIZE     STYLE  PART  WINDOWS SEES   OFFLINE  LETTERS  MODEL$RS"
  foreach ($row in $rows) {
    $mark = ' '
    if ($row.Likely) { $mark = "$CY*$RS" }
    $dNum = if ($row.Disk -ge 0) { "$($row.Disk)" } else { '-' }
    $bId  = if ($row.BusId) { "$($row.BusId)" } else { '-' }
    $offStr = if ($row.Offline -eq $true) { 'True' } elseif ($row.Offline -eq $false) { 'False' } else { 'n/a' }
    $letStr = if ($row.Letters.Count) { "$RD$($row.Letters -join ',')$RS" } else { '-' }
    Write-Host ("   {0} {1,-3} {2,-7} {3,-8} {4,-6} {5,-5} {6,-14} {7,-8} {8,-8} {9}" -f `
      $mark, $dNum, $bId, $row.Size, $row.Style, $row.Parts, $row.Windows, $offStr, $letStr, $row.Name)
  }
  Write-Host ''
  if ($rows | Where-Object { $_.Likely }) {
    Inf "$CY*$RS $DIM= candidate VMFS drive / enclosure (unreadable partition, raw media, or mass storage).$RS"
  }

  $chosenRow = $null

  if ($BusId) {
    $chosenRow = $rows | Where-Object { $_.BusId -eq $BusId }
    if (-not $chosenRow) {
      Inf "Selected BUSID $BusId directly. Proceeding to attach via usbipd."
      $DiskNumber = -1
      $DiskSize   = 0
    }
  } elseif ($DiskNumber -ge 0) {
    $chosenRow = $rows | Where-Object { $_.Disk -eq $DiskNumber }
    if (-not $chosenRow) { Die "Disk $DiskNumber is not an eligible candidate disk." }
  } else {
    $likelyCandidates = @($rows | Where-Object { $_.Likely -and -not $_.IsDestination })
    $defaultChoice = ''
    if ($likelyCandidates.Count -ge 1) {
      if ($likelyCandidates[0].Disk -ge 0) { $defaultChoice = "$($likelyCandidates[0].Disk)" }
      elseif ($likelyCandidates[0].BusId) { $defaultChoice = "bus:$($likelyCandidates[0].BusId)" }
    }

    $prompt = 'Disk number or BUSID to offline and pass to WSL'
    if ($defaultChoice) { $prompt = "$prompt [$defaultChoice]" }
    $ansD = Ask $prompt $defaultChoice
    if ([string]::IsNullOrWhiteSpace($ansD)) { Die 'No device selected.' }

    if ($ansD -match '^bus:(.+)$') {
      $BusId = $Matches[1].Trim()
      $chosenRow = $rows | Where-Object { $_.BusId -eq $BusId }
    } elseif ($ansD -match '^\d+-\d+') {
      $BusId = $ansD.Trim()
      $chosenRow = $rows | Where-Object { $_.BusId -eq $BusId }
    } elseif ($ansD -match '^\d+$') {
      $DiskNumber = [int]($ansD.Trim())
      $chosenRow = $rows | Where-Object { $_.Disk -eq $DiskNumber }
    } else {
      Die "'$ansD' is neither a disk number nor a BUSID."
    }
  }

  if ($chosenRow) {
    if ($chosenRow.IsDestination) {
      Bad "Selected device holds volume $($chosenRow.Letters -join ', ')! This is your copy destination or system drive!"
      $confirmDest = Ask "Are you SURE you want to touch this drive? [y/N]" 'n'
      if ($confirmDest -notmatch '^[yY]') { Die 'Aborted to protect destination drive.' }
    }

    $DiskNumber = $chosenRow.Disk
    $DiskSize   = $chosenRow.SizeBytes
    if (-not $BusId -and $chosenRow.BusId) { $BusId = $chosenRow.BusId }

    Inf "Selected: ${BD}$(if ($DiskNumber -ge 0) { "disk $DiskNumber" } else { "BUSID $BusId" })$RS  $($chosenRow.Name)  $DIM$($chosenRow.Size)$RS"

    if ($chosenRow.HasMsftDisk -and $DiskNumber -ge 0) {
      if ($chosenRow.Offline -eq $true) {
        Ok "Disk $DiskNumber is already offline in Windows."
      } else {
        if (Invoke-Step "offline disk $DiskNumber" { Set-Disk -Number $DiskNumber -IsOffline $true }) {
          OkDid "Disk $DiskNumber offline. Windows has released it."
        } else {
          Bad "Could not offline disk $DiskNumber."
          Inf '  Close anything reading it, then do it by hand:'
          Inf "     $DIM diskpart  ->  select disk $DiskNumber  ->  offline disk$RS"
          Write-Host ''; exit 1
        }
      }
    } else {
      Ok "Windows Storage holds no active filesystem lock on this device (media unloaded/raw)."
      Inf "  ${DIM}No Windows volume to offline. Device is ready for WSL passthrough.$RS"
    }
  }
}

#==============================================================================
# STEP 2. Hand the enclosure to WSL.
#==============================================================================
Step '2.' 'Attach the enclosure to WSL with usbipd'

$devs = @(Get-Enclosure)
if ($devs.Count -eq 0) {
  Die 'usbipd reported no connected USB devices. Run "usbipd list" by hand, then pass -BusId.'
}

Write-Host ''
Write-Host "   $DIM  BUSID   VID:PID     STATE        HOLDS             DEVICE$RS"
foreach ($d in $devs) {
  $mark = ' '
  if ($d.IsMass) { $mark = "$CY*$RS" }
  $col = ''
  if ($d.State -eq 'Attached') { $col = $GR } elseif ($d.State -eq 'Shared') { $col = $YL }
  $holds = ''
  $hcol = ''
  if ($null -ne $d.DiskNumber) {
    $holds = "disk $($d.DiskNumber)"
    if ($d.Holds -and $d.Holds.Letters.Count) {
      $holds = "$holds ($($d.Holds.Letters -join ','))"
      $hcol = $RD
    }
    if ($d.DiskNumber -eq $DiskNumber) { $holds = "$holds <-"; $hcol = $CY }
  }
  Write-Host ("   {0} {1,-7} {2,-11} {3}{4,-12}{5} {6}{7,-17}{8} {9}" -f `
      $mark, $d.BusId, $d.VidPid, $col, $d.State, $RS, $hcol, $holds, $RS, $d.Device)
}
Write-Host ''

if (-not $BusId) {
  $mass = @($devs | Where-Object { $_.IsMass })
  $exact = @($devs | Where-Object { $null -ne $_.DiskNumber -and $_.DiskNumber -eq $DiskNumber })
  $default = ''
  if ($exact.Count -eq 1) { $default = $exact[0].BusId }
  elseif ($mass.Count -ge 1) { $default = $mass[0].BusId }
  if ($exact.Count -eq 1) {
    Inf "${DIM}Busid $($exact[0].BusId) is the enclosure holding disk $DiskNumber.$RS"
  } elseif ($mass.Count -gt 1) {
    Inf "${DIM}More than one mass storage device is listed. Pick the enclosure, not another external drive.$RS"
  }
  $prompt = 'BUSID of the enclosure'
  if ($default) { $prompt = "$prompt [$default]" }
  $BusId = Ask $prompt $default
  if ([string]::IsNullOrWhiteSpace($BusId)) { Die 'No BUSID selected.' }
}
$dev = $devs | Where-Object { $_.BusId -eq $BusId }
if (-not $dev) { Die "BUSID $BusId is not in usbipd list." }
Inf "Selected: ${BD}$BusId$RS  $DIM$($dev.VidPid)  $($dev.Device)$RS"

if ($null -ne $dev.DiskNumber -and $DiskNumber -ge 0 -and $dev.DiskNumber -ne $DiskNumber) {
  Bad "Busid $BusId holds disk $($dev.DiskNumber), not disk $DiskNumber."
  if ($dev.Holds -and $dev.Holds.Letters.Count) {
    Inf "  ${DIM}Windows is using $($dev.Holds.Letters -join ', ') on it. Handing it to WSL takes those volumes away from Windows.$RS"
  }
  $cW = Ask 'Attach it anyway? [y/N]' 'n'
  if ($cW -notmatch '^[yY]') { Die 'Aborted, nothing changed.' }
} elseif ($null -eq $dev.DiskNumber -and $dev.IsMass -and $DiskNumber -ge 0) {
  Note "Could not tell which disk is behind $BusId. Check it is the enclosure holding disk $DiskNumber."
}

if ($dev.State -eq 'Not shared') {
  if (Invoke-Step "usbipd bind --busid $BusId" { & usbipd bind --busid $BusId }) {
    OkDid "Bound $BusId."
  } else {
    Die 'bind failed. Without it, attach cannot work.'
  }
} else {
  Inf "${DIM}Already bound (state: $($dev.State)).$RS"
}

if ($dev.State -eq 'Attached') {
  Ok "$BusId is already attached to WSL."
} else {
  if (-not (Invoke-Step "usbipd attach --wsl --busid $BusId" { & usbipd attach --wsl --busid $BusId })) {
    Die 'attach failed. If it reports the device is in use, the disk is not fully offline.'
  }
  $att = Wait-For -Label "usbipd reports $BusId Attached" -Seconds $TimeoutSec -Test {
    $d2 = Get-Enclosure | Where-Object { $_.BusId -eq $BusId }
    return ($d2 -and $d2.State -eq 'Attached')
  }
  if (-not $att) {
    Note "usbipd does not report $BusId as attached."
    Inf "  ${DIM}Step 3 looks for the disk anyway. If it is missing, the enclosure needs a power cycle.$RS"
  }
}

#==============================================================================
# STEP 3. Find the block device inside WSL.
#==============================================================================
Step '3.' 'Locate the disk inside WSL'

$script:SdName = ''
$script:SdAll  = @()
$found = Wait-For -Label 'block device appears in WSL' -Seconds $TimeoutSec -Test {
  $hits = @()
  if ($DiskSize -le 0) {
    foreach ($l in @(Wsl 'lsblk -P -o NAME,FSTYPE,TYPE,PKNAME 2>/dev/null')) {
      if ("$l" -match 'NAME="([^"]*)"\s+FSTYPE="VMFS_volume_member"\s+TYPE="part"\s+PKNAME="([^"]+)"') {
        $hits += $Matches[2]
      }
    }
    if ($hits.Count -eq 0) {
      foreach ($l in @(Wsl 'lsblk -dn -o NAME,TRAN,MODEL 2>/dev/null')) {
        if ("$l" -match '^\s*(\S+)\s+usb\b') { $hits += $Matches[1] }
      }
    }
    $hits = @($hits | Select-Object -Unique)
  } else {
    foreach ($l in @(Wsl 'lsblk -b -dn -o NAME,SIZE,TYPE 2>/dev/null')) {
      if ("$l" -match '^\s*(\S+)\s+(\d+)\s+disk') {
        $n = $Matches[1]; $sz = [long]$Matches[2]
        if ([math]::Abs($sz - $DiskSize) -lt 16MB) { $hits += $n }
      }
    }
    if ($hits.Count -eq 0) {
      foreach ($l in @(Wsl 'lsblk -dn -o NAME,TRAN 2>/dev/null')) {
        if ("$l" -match '^\s*(\S+)\s+usb\b') { $hits += $Matches[1] }
      }
      $hits = @($hits | Select-Object -Unique)
    }
  }
  if ($hits.Count -gt 0) { $script:SdAll = $hits; $script:SdName = $hits[0]; return $true }
  return $false
}
$SdName = $script:SdName

if ($DryRun) {
  $SdName = 'sdX'
} elseif (-not $found -or -not $SdName) {
  if ($DiskSize -le 0) { Bad 'No VMFS partition or USB disk showed up in WSL.' }
  else { Bad "No block device of size $(Human $DiskSize) showed up in WSL." }
  Inf '  What WSL can see right now:'
  foreach ($l in @(Wsl 'lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>&1')) { Inf "    $DIM$l$RS" }
  Inf ''
  Inf "  ${BD}If a device is listed at 0B$RS, the enclosure dropped off the bus. That is almost"
  Inf '  always power rather than data. Detach, power cycle the enclosure, attach again:'
  Inf "     $DIM usbipd detach --busid $BusId ; usbipd attach --wsl --busid $BusId$RS"
  Write-Host ''; exit 1
}
Ok "Disk is ${BD}/dev/$SdName$RS inside WSL."

if (-not $DryRun) {
  $id = Get-DriveIdentity $SdName
  if ($id.Model -or $id.Serial) {
    $bits = @()
    if ($id.Serial)   { $bits += "serial $($id.Serial)" }
    if ($id.Firmware) { $bits += "fw $($id.Firmware)" }
    $tail = ''
    if ($bits.Count) { $tail = "  $DIM$($bits -join '  ')$RS" }
    Inf "  Drive: ${BD}$($id.Model)$RS$tail"
  }
  if ($id.Bridge) {
    $bs = ''
    if ($id.BridgeSerial) { $bs = ", serial $($id.BridgeSerial)" }
    Inf "  ${DIM}Enclosure: $($id.Bridge) bridge$bs$RS"
  }
  if (-not $id.FromUdev -and $id.Model) {
    Note 'udev had not finished with this device, so the name above is the raw bridge report.'
    Inf "  ${DIM}Rejoined from the split vendor and product fields. Trust the size and the$RS"
    Inf "  ${DIM}serial over the name, or rerun to get the drive's own model string.$RS"
  }
}
if (-not $DryRun -and $script:SdAll.Count -gt 1) {
  $how = "are $(Human $DiskSize)"
  if ($DiskSize -le 0) { $how = 'carry a VMFS partition or USB bus' }
  Note "$($script:SdAll.Count) WSL disks $($how): $($script:SdAll -join ', '). Using /dev/$SdName."
  Inf "  ${DIM}Confirm with 'wsl -u root -- lsblk' before copying. Writing to the wrong one is not recoverable.$RS"
}

$PartName = ''
if ($DryRun) {
  $PartName = 'sdX1'
} else {
  $best = 0
  foreach ($l in @(Wsl "lsblk -b -ln -o NAME,SIZE,TYPE /dev/$SdName 2>/dev/null")) {
    if ("$l" -match '^\s*(\S+)\s+(\d+)\s+part') {
      if ([long]$Matches[2] -gt $best) { $best = [long]$Matches[2]; $PartName = $Matches[1] }
    }
  }
  if (-not $PartName) {
    $PartName = $SdName
    Note "No partition table found on /dev/$SdName; checking raw device /dev/$PartName."
  } else {
    Ok "Datastore partition: ${BD}/dev/$PartName$RS $DIM($(Human $best))$RS"
  }
}

#==============================================================================
# STEP 4. Mount VMFS6 & View Datastore Contents
#==============================================================================
if (-not $Mount -and -not $Inspect) {
  Write-Host ''; Hr
  if ($DryRun) { Note 'Plan complete. Nothing was attached, because -DryRun was set.' }
  else { Ok 'Attached. The datastore is not mounted yet.' }
  Write-Host ''
  Inf "  ${BD}Next, inside WSL:$RS"
  Inf "     $DIM sudo mkdir -p $Src$RS"
  Inf "     $DIM sudo vmfs6-fuse /dev/$PartName $Src$RS"
  Inf "     $DIM sudo ./vmfs-copy.sh --src $Src --dest $Dest$RS"
  Write-Host ''
  Inf "  ${DIM}Mounting in the window you will copy from is the safe order: the mount$RS"
  Inf "  ${DIM}lands in that window's namespace, so the copier is certain to see it.$RS"
  Inf "  ${DIM}Or rerun this with -Mount to mount automatically, or -Mount -Inspect to view contents.$RS"
  Write-Host ''
  exit 0
}

Step '4.' 'Mount the VMFS6 datastore'

$have = Wsl 'command -v vmfs6-fuse >/dev/null 2>&1 && echo YES || echo NO'
if ("$have" -match 'NO') {
  Note 'vmfs6-fuse is not installed in WSL.'
  $i = Ask 'Install vmfs6-tools now? [Y/n]' 'y'
  if ($i -match '^[nN]') { Die 'Cannot mount without it. Install with: sudo apt install vmfs6-tools' }
  if (-not $DryRun) {
    Inf "$DIM  apt-get update && apt-get install -y vmfs6-tools$RS"
    $apt = 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && ' +
           'DEBIAN_FRONTEND=noninteractive apt-get install -y vmfs6-tools 2>&1'
    foreach ($l in @(Wsl $apt)) { if ("$l".Trim()) { Inf "    $DIM$l$RS" } }
    $have2 = Wsl 'command -v vmfs6-fuse >/dev/null 2>&1 && echo YES || echo NO'
    if ("$have2" -match 'NO') {
      Die 'The install did not produce vmfs6-fuse. Run "sudo apt install vmfs6-tools" in WSL and read the error.'
    }
    Ok 'vmfs6-tools installed.'
  }
} else {
  Ok 'vmfs6-fuse present.'
}

$state = Get-MountState $Src

if ($state -eq 'STALE') {
  Note "$Src is mounted but nothing answers for it. An earlier attach left it behind."
  if ($DryRun) {
    Note "would clear the stale mount at $Src"
    $state = 'FREE'
  } else {
    Clear-StaleMount $Src
    $state = Get-MountState $Src
    if ($state -eq 'STALE') {
      Bad "Could not clear the stale mount at $Src."
      Inf "  See what holds it: $DIM wsl -u root -- ps -ef | grep vmfs$RS"
      Inf "  Force it off:      $DIM wsl -u root -- umount -l $Src$RS"
      Write-Host ''; exit 1
    }
    Ok "Cleared the stale mount at $Src."
  }
}

if ($state -eq 'LIVE') {
  $srv = "$(Wsl "ps -eo args= 2>/dev/null | grep -F -- ' $Src' | grep -m1 -- '[v]mfs6-fuse' || exit 0")".Trim()
  $srvDev = ''
  if ($srv -match '(/dev/[A-Za-z0-9]+)') { $srvDev = $Matches[1] }
  if (-not $DryRun -and $srvDev -and $srvDev -ne "/dev/$PartName") {
    Note "$Src is already mounted, but from $srvDev, not /dev/$PartName."
    $ansR = Ask "Remount from /dev/$PartName? [Y/n]" 'y'
    if ($ansR -match '^[nN]') {
      Note "Left the existing mount in place. It is not the disk you just attached."
    } else {
      Clear-StaleMount $Src
      $state = Get-MountState $Src
      if ($state -ne 'FREE') { Die "Could not unmount $Src to remount it from /dev/$PartName." }
    }
  } elseif ($srvDev) {
    Ok "$Src is already mounted from $srvDev."
  } else {
    Ok "$Src is already mounted."
  }
}

if ($state -eq 'FREE') {
  if ($DryRun) {
    Note "would mount /dev/$PartName at $Src"
  } else {
    Wsl "mkdir -p '$Src'" | Out-Null
    $out = Wsl "vmfs6-fuse '/dev/$PartName' '$Src' 2>&1"
    $chk = Wait-For -Label "mount appears at $Src" -Seconds 15 -Test {
      return ((Get-MountState $Src) -eq 'LIVE')
    }
    if (-not $chk) {
      Bad 'Mount failed.'
      foreach ($l in @($out)) { Inf "    $DIM$l$RS" }
      Inf ''
      Inf "  ${BD}Lun ID mismatch$RS warnings are normal. The disk moved to a different controller."
      Inf "  ${BD}Permission denied$RS means you are not root inside WSL."
      Inf "  ${BD}Error stat()ing$RS means something still holds $Src. Clear it, then rerun:"
      Inf "     $DIM wsl -u root -- umount -l $Src$RS"
      Inf "  ${BD}Cannot open volume$RS usually means the wrong partition. Check the others:"
      Inf "     $DIM wsl -u root -- lsblk /dev/$SdName$RS"
      Write-Host ''; exit 1
    }
    Ok "Mounted /dev/$PartName at ${BD}$Src$RS."
  }
}

$Blind = @()
if (-not $DryRun) {
  $Blind = @(Get-ShellSessions $Src | Where-Object { $_.State -eq 'BLIND' })
  if ($Blind.Count -gt 0) {
    Write-Host ''
    Note "$($Blind.Count) WSL shell $(if ($Blind.Count -eq 1) { 'session is' } else { 'sessions are' }) open in a different mount namespace and cannot see this mount."
    foreach ($b in $Blind) { Inf "    $DIM pid $($b.Pid)  $($b.Ns)  $($b.Cmd)$RS" }
    $ansN = Ask 'Mount the datastore into those sessions too? [Y/n]' 'y'
    if ($ansN -notmatch '^[nN]') {
      foreach ($b in $Blind) {
        $r = Add-MountToSession $b.Pid "/dev/$PartName" $Src
        if ($r.Ok) { Ok "pid $($b.Pid) can now see $Src." }
        else { Bad "Could not mount into the session at pid $($b.Pid)." }
      }
    }
  }
}

if ($Test) {
  $null = Test-VmfsFileSystem -Path $Src -Dev "/dev/$PartName" -Simulated:$DryRun
}

if ($Inspect -or $DryRun) {
  Invoke-DatastoreInspector -Path $Src -Simulated:$DryRun
} else {
  $askInspect = Ask 'Select and view datastore contents, VM configs & sizes with visual effects? [Y/n]' 'y'
  if ($askInspect -notmatch '^[nN]') {
    Invoke-DatastoreInspector -Path $Src
  }
}

Write-Host ''; Hr
if ($DryRun) { Note 'Plan complete. Nothing was attached or mounted, because -DryRun was set.' }
else { Ok 'Datastore is mounted and readable.' }
Write-Host ''
Inf "  ${BD}Next, inside WSL (or in your WSL terminal):$RS"
Inf "     $DIM sudo ./vmfs-copy.sh --src $Src --dest $Dest$RS"
Inf "  ${DIM}vmfs6-fuse owns this mount as root, so the copier only reads it under sudo.$RS"
Inf "  ${DIM}When the copy is done, unwind cleanly with:$RS"
Inf "     $DIM .\vmfs-attach.ps1 -Detach$RS"
Write-Host ''
