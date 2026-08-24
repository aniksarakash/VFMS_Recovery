#===============================================================================
# vmfs-attach.ps1 - Windows-side companion to vmfs-copy.sh
#
# Does the three things vmfs-copy.sh structurally cannot, because it runs on
# Windows: takes the VMFS disk offline so Windows releases it, hands the USB
# enclosure to WSL2 with usbipd, then optionally mounts the datastore with
# vmfs6-fuse and prints the exact copier command to run next.
#
# Detects candidate disks and enclosures, lets you pick, and waits with a live
# clock instead of asking you to guess how long an attach takes.
#
#   .\vmfs-attach.ps1                      # detect + interactive, offline + attach
#   .\vmfs-attach.ps1 -Mount               # also mount VMFS6 inside WSL
#   .\vmfs-attach.ps1 -BusId 3-2 -Mount -Yes
#   .\vmfs-attach.ps1 -DiskNumber 2 -Mount
#   .\vmfs-attach.ps1 -DryRun              # show the plan, change nothing
#   .\vmfs-attach.ps1 -Detach              # reverse it: unmount, detach, online
#
# Must run in an ADMINISTRATOR PowerShell. Offlining a disk and binding a USB
# device are both privileged operations.
#===============================================================================
[CmdletBinding()]
param(
  [string] $BusId,                      # e.g. 3-2; skips enclosure detection
  [int]    $DiskNumber = -1,            # Windows disk number; skips disk detection
  [string] $Distro,                     # WSL distro; default is your default distro
  [string] $Src  = '/mnt/vmfs',         # where to mount the datastore inside WSL
  [string] $Dest = '/mnt/d',            # destination drive, used in the closing hint
  [switch] $Mount,                      # also run vmfs6-fuse
  [switch] $Detach,                     # undo: unmount, usbipd detach, online disk
  [switch] $Yes,                        # no prompts
  [switch] $DryRun,                     # print actions, execute none
  [int]    $TimeoutSec = 90
)

$ErrorActionPreference = 'Continue'

#------------------------------------------------------------------------------
# Presentation. Same vocabulary as vmfs-copy.sh so the two read as one tool.
#------------------------------------------------------------------------------
$E   = [char]27
$R   = "$E[0m"; $B = "$E[1m"; $DIM = "$E[2m"
$RD  = "$E[31m"; $GR = "$E[32m"; $YL = "$E[33m"; $CY = "$E[36m"

function Hr   { Write-Host "$DIM------------------------------------------------------------------------$R" }
function Inf  ($m) { Write-Host "  $m" }
function Ok   ($m) { Write-Host "  $GR[ok]$R $m" }
function Note ($m) { Write-Host "  $YL[! ]$R $m" }
function Bad  ($m) { Write-Host "  $RD[xx]$R $m" }
function Die  ($m) { Bad $m; Write-Host ''; exit 1 }
function Step ($n, $t) { Write-Host ''; Write-Host "  $CY$n$R $B$t$R" }

function Human ($bytes) {
  $u = 'B','K','M','G','T','P'; $i = 0; $b = [double]$bytes
  while ($b -ge 1024 -and $i -lt 5) { $b = $b / 1024; $i++ }
  if ($b -lt 10 -and $i -gt 0) { return ('{0:0.0}{1}' -f $b, $u[$i]) }
  return ('{0:0}{1}' -f $b, $u[$i])
}

function Ask ($prompt, $default) {
  if ($Yes) { return $default }
  $a = Read-Host "  $prompt"
  if ([string]::IsNullOrWhiteSpace($a)) { return $default }
  return $a.Trim()
}

# Everything privileged is funnelled through here so -DryRun is honoured in one
# place rather than remembered at each call site.
function Invoke-Step ($label, [scriptblock] $action) {
  if ($DryRun) { Note "would $label"; return $true }
  try { & $action | Out-Null; return $true }
  catch { Bad "$label failed: $($_.Exception.Message)"; return $false }
}

# A poll with a visible clock. Attach latency varies a lot, because the enclosure
# has to spin up and re-enumerate, so showing elapsed seconds is the difference
# between "working" and "hung" to whoever is watching.
function Wait-For {
  param([scriptblock] $Test, [string] $Label, [int] $Seconds = 60)
  if ($DryRun) { Note "would wait for $Label"; return $true }
  $frames = '|', '/', '-', '\'
  $sw = [Diagnostics.Stopwatch]::StartNew(); $i = 0
  while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    if (& $Test) {
      Write-Host ("`r    $GR[ok]$R $Label $DIM(" + [int]$sw.Elapsed.TotalSeconds + "s)$R" + (' ' * 20))
      return $true
    }
    Write-Host ("`r    $CY" + $frames[$i % 4] + "$R $Label $DIM" + [int]$sw.Elapsed.TotalSeconds + "s$R   ") -NoNewline
    Start-Sleep -Milliseconds 500; $i++
  }
  Write-Host ("`r    $RD[xx]$R $Label, timed out after $Seconds" + "s" + (' ' * 18))
  return $false
}

# Every WSL call goes through one place. The -u root and the -- separator are easy
# to forget, and a missing -- turns the command into wsl.exe's own flags.
function Wsl ([string] $Cmd) {
  $a = @()
  if ($Distro) { $a += @('-d', $Distro) }
  $a += @('-u', 'root', '--', 'bash', '-lc', $Cmd)
  return (& wsl.exe @a 2>&1)
}

# usbipd list is the only source of truth for BUSID, and its output is a table
# rather than anything machine readable. Parse it once, carefully, and stop at
# the "Persisted:" section, whose rows are remembered devices, not present ones.
function Get-Enclosure {
  $raw = & usbipd list 2>&1
  if ($LASTEXITCODE -ne 0) { return @() }
  $out = @()
  foreach ($line in $raw) {
    $t = "$line"
    if ($t -match '^\s*Persisted:') { break }
    if ($t -match '^\s*(\d+-\d+)\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s+(.+?)\s\s+(Not shared|Shared|Attached|Shared \(forced\))\s*$') {
      # Capture every group into locals BEFORE running any other -match. The
      # -match operator overwrites $Matches, and inside a hash literal IsMass is
      # evaluated before Device, so testing the device string in place wiped the
      # capture groups and dropped exactly the mass-storage rows this function
      # exists to find. A failed match leaves $Matches alone, which is why only
      # the enclosure rows disappeared.
      $bus = $Matches[1]; $vidpid = $Matches[2]
      $name = $Matches[3].Trim(); $state = $Matches[4]
      $out += [pscustomobject]@{
        BusId  = $bus
        VidPid = $vidpid
        Device = $name
        State  = $state
        # A drive enclosure announces itself as mass storage. That is a better
        # signal than the vendor string, which is often a bare chipset name.
        IsMass = ($name -match 'Mass Storage|UAS|SCSI|Disk')
      }
    }
  }
  return $out
}

Write-Host ''
Write-Host "$B  VMFS attach helper$R  $DIM(Windows side of the recovery)$R"
Hr

#------------------------------------------------------------------------------
# Preflight
#------------------------------------------------------------------------------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Bad 'Not running as Administrator.'
  Inf ''
  Inf "  Offlining a disk and binding a USB device both need elevation. Reopen"
  Inf "  PowerShell with ${B}Run as administrator${R}, then run this again:"
  Inf "     $DIM$($MyInvocation.MyCommand.Path)$R"
  Write-Host ''
  exit 1
}
Ok 'Running elevated.'

if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
  Bad 'usbipd not found. WSL cannot be handed a USB device without it.'
  Inf "  Install it, then reopen this shell:  $DIM winget install usbipd$R"
  Inf "  ${DIM}or https://github.com/dorssel/usbipd-win/releases$R"
  Write-Host ''; exit 1
}
Ok "usbipd present: $DIM$(& usbipd --version 2>&1 | Select-Object -First 1)$R"

if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
  Die 'wsl.exe not found. Install WSL2 first: wsl --install'
}
$probe = Wsl 'echo wsl-ok'
if ("$probe" -notmatch 'wsl-ok') {
  Die "WSL is not responding. Try 'wsl --shutdown', then run this again. Got: $probe"
}
if ($Distro) { Ok "WSL reachable ($Distro)." } else { Ok 'WSL reachable.' }
if ($DryRun) { Note '-DryRun: nothing will be changed.' }

#==============================================================================
# DETACH MODE. Unwind in reverse order so nothing is left half attached.
#==============================================================================
if ($Detach) {
  Step '1.' 'Unmount the datastore inside WSL'
  $m = Wsl "mountpoint -q '$Src' && echo MOUNTED || echo NO"
  if ("$m" -match 'MOUNTED') {
    if (-not $DryRun) {
      Wsl "fusermount -u '$Src' 2>/dev/null || umount '$Src' 2>/dev/null" | Out-Null
    }
    $still = Wsl "mountpoint -q '$Src' && echo MOUNTED || echo NO"
    if ("$still" -match 'MOUNTED') {
      Note "$Src is still mounted, so something is holding it open."
      Inf "  Find it:  $DIM wsl -u root -- lsof +f -- $Src$R"
      Inf "  ${DIM}A running copy, or a shell sitting inside the mount, is the usual cause.$R"
    } else {
      Ok "Unmounted $Src."
    }
  } else {
    Inf "$DIM$Src was not mounted.$R"
  }

  Step '2.' 'Detach the enclosure from WSL'
  if (-not $BusId) {
    $att = @(Get-Enclosure | Where-Object { $_.State -eq 'Attached' })
    if ($att.Count -eq 1) {
      $BusId = $att[0].BusId
      Inf "Only one attached device: $B$BusId$R $DIM$($att[0].Device)$R"
    } elseif ($att.Count -eq 0) {
      Note 'Nothing is currently attached.'
    } else {
      $BusId = Ask "Which BUSID to detach? [$($att.BusId -join ', ')]" $att[0].BusId
    }
  }
  if ($BusId) {
    if (Invoke-Step "usbipd detach --busid $BusId" { & usbipd detach --busid $BusId }) {
      Ok "Detached $BusId."
    }
  }

  Step '3.' 'Bring the disk back online in Windows'
  $off = @(Get-Disk | Where-Object { $_.IsOffline -and $_.BusType -eq 'USB' })
  if ($off.Count -eq 0) { Inf "${DIM}No offline USB disk to bring back.$R" }
  foreach ($d in $off) {
    Inf "Disk $($d.Number): $($d.FriendlyName) $DIM$(Human $d.Size)$R"
    if (Invoke-Step "online disk $($d.Number)" { Set-Disk -Number $d.Number -IsOffline $false }) {
      Ok "Disk $($d.Number) online."
    }
  }
  Write-Host ''; Hr
  Ok 'Detach complete.'
  Note 'Leave the VMFS disk offline in Windows if you plan to reattach it. While it is online, Windows will offer to format it.'
  Write-Host ''
  exit 0
}

#==============================================================================
# STEP 1. Offline the disk so Windows stops holding it.
#==============================================================================
Step '1.' 'Take the VMFS disk offline in Windows'

$usb = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' } | Sort-Object Number)
if ($usb.Count -eq 0) {
  Bad 'No USB disks found. Is the enclosure powered and plugged in?'
  Inf "  ${DIM}A 3.5 inch enclosure usually needs its own power brick; bus power is not enough.$R"
  Write-Host ''; exit 1
}

$rows = @()
foreach ($d in $usb) {
  $parts = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)
  $fs = @()
  foreach ($p in $parts) {
    $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
    if ($v -and $v.FileSystem) { $fs += $v.FileSystem }
  }
  # The tell for a VMFS disk on Windows: partitions exist, but Windows recognises
  # no filesystem in any of them and assigned no drive letter. That is the state
  # that makes Windows offer to format the disk. The disk is fine. Windows simply
  # has no VMFS driver.
  $letters = @($parts | Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter })
  $seen = 'none'
  if ($fs.Count) { $seen = ($fs -join ',') } elseif ($parts.Count) { $seen = 'unreadable' }
  $rows += [pscustomobject]@{
    Disk    = $d.Number
    Size    = (Human $d.Size)
    Style   = $d.PartitionStyle
    Parts   = $parts.Count
    Windows = $seen
    Offline = $d.IsOffline
    Name    = $d.FriendlyName
    Likely  = ($parts.Count -gt 0 -and $fs.Count -eq 0 -and $letters.Count -eq 0)
  }
}

Write-Host ''
Write-Host "   $DIM  #   SIZE     STYLE  PART  WINDOWS SEES  OFFLINE  MODEL$R"
foreach ($r in $rows) {
  $mark = ' '
  if ($r.Likely) { $mark = "$CY*$R" }
  Write-Host ("   {0} {1,-3} {2,-8} {3,-6} {4,-5} {5,-13} {6,-8} {7}" -f `
      $mark, $r.Disk, $r.Size, $r.Style, $r.Parts, $r.Windows, $r.Offline, $r.Name)
}
Write-Host ''
if ($rows | Where-Object { $_.Likely }) {
  Inf "$CY*$R $DIM= has partitions Windows cannot read, which is the expected shape of a VMFS disk.$R"
}

if ($DiskNumber -lt 0) {
  $guess = @($rows | Where-Object { $_.Likely })
  $default = ''
  if ($guess.Count -ge 1) { $default = "$($guess[0].Disk)" }
  $prompt = 'Disk number to offline and pass to WSL'
  if ($default) { $prompt = "$prompt [$default]" }
  $ansD = Ask $prompt $default
  if ([string]::IsNullOrWhiteSpace($ansD)) { Die 'No disk selected.' }
  $DiskNumber = [int]$ansD
}
$disk = $usb | Where-Object { $_.Number -eq $DiskNumber }
if (-not $disk) { Die "Disk $DiskNumber is not a USB disk, or does not exist." }

$chosen = $rows | Where-Object { $_.Disk -eq $DiskNumber }
if ($chosen.Windows -ne 'unreadable' -and $chosen.Windows -ne 'none') {
  Note "Windows reads a $($chosen.Windows) filesystem on disk $DiskNumber, which does not look like VMFS."
  $c = Ask 'This may be the wrong disk. Continue anyway? [y/N]' 'n'
  if ($c -notmatch '^[yY]') { Die 'Aborted, nothing changed.' }
}
$DiskSize = $disk.Size
Inf "Selected: ${B}disk $DiskNumber$R  $($disk.FriendlyName)  $DIM$(Human $DiskSize)$R"

if ($disk.IsOffline) {
  Ok "Disk $DiskNumber is already offline."
} else {
  if (Invoke-Step "offline disk $DiskNumber" { Set-Disk -Number $DiskNumber -IsOffline $true }) {
    Ok "Disk $DiskNumber offline. Windows has released it."
  } else {
    Bad 'Could not offline the disk.'
    Inf '  Close anything reading it, then do it by hand:'
    Inf "     $DIM diskpart  ->  list disk  ->  select disk $DiskNumber  ->  offline disk$R"
    Write-Host ''; exit 1
  }
}

#==============================================================================
# STEP 2. Hand the enclosure to WSL.
#==============================================================================
Step '2.' 'Attach the enclosure to WSL with usbipd'

$devs = @(Get-Enclosure)
if ($devs.Count -eq 0) {
  Die 'usbipd list returned nothing parseable. Run "usbipd list" by hand and pass -BusId.'
}

Write-Host ''
Write-Host "   $DIM  BUSID   VID:PID     STATE        DEVICE$R"
foreach ($d in $devs) {
  $mark = ' '
  if ($d.IsMass) { $mark = "$CY*$R" }
  $col = ''
  if ($d.State -eq 'Attached') { $col = $GR } elseif ($d.State -eq 'Shared') { $col = $YL }
  Write-Host ("   {0} {1,-7} {2,-11} {3}{4,-12}{5} {6}" -f $mark, $d.BusId, $d.VidPid, $col, $d.State, $R, $d.Device)
}
Write-Host ''

if (-not $BusId) {
  $mass = @($devs | Where-Object { $_.IsMass })
  $default = ''
  if ($mass.Count -ge 1) { $default = $mass[0].BusId }
  if ($mass.Count -gt 1) {
    Inf "${DIM}More than one mass storage device is listed. Pick the enclosure, not another external drive.$R"
  }
  $prompt = 'BUSID of the enclosure'
  if ($default) { $prompt = "$prompt [$default]" }
  $BusId = Ask $prompt $default
  if ([string]::IsNullOrWhiteSpace($BusId)) { Die 'No BUSID selected.' }
}
$dev = $devs | Where-Object { $_.BusId -eq $BusId }
if (-not $dev) { Die "BUSID $BusId is not in usbipd list." }
Inf "Selected: ${B}$BusId$R  $DIM$($dev.VidPid)  $($dev.Device)$R"

# "Not shared" means usbipd has never claimed the device. bind is the one-time
# step that makes it attachable at all, and it is the step most often skipped.
if ($dev.State -eq 'Not shared') {
  if (Invoke-Step "usbipd bind --busid $BusId" { & usbipd bind --busid $BusId }) {
    Ok "Bound $BusId."
  } else {
    Die 'bind failed. Without it, attach cannot work.'
  }
} else {
  Inf "${DIM}Already bound (state: $($dev.State)).$R"
}

if ($dev.State -eq 'Attached') {
  Ok "$BusId is already attached to WSL."
} else {
  if (-not (Invoke-Step "usbipd attach --wsl --busid $BusId" { & usbipd attach --wsl --busid $BusId })) {
    Die 'attach failed. If it reports the device is in use, the disk is not fully offline.'
  }
  Wait-For -Label "usbipd reports $BusId Attached" -Seconds $TimeoutSec -Test {
    $d2 = Get-Enclosure | Where-Object { $_.BusId -eq $BusId }
    return ($d2 -and $d2.State -eq 'Attached')
  } | Out-Null
}

#==============================================================================
# STEP 3. Find the block device inside WSL.
#==============================================================================
Step '3.' 'Locate the disk inside WSL'

# Match on size, not on name. sdX letters are handed out in attach order and
# drift between runs, so yesterday's /dev/sdd is today's /dev/sdc, and writing to
# the wrong one is not recoverable.
$script:SdName = ''
$found = Wait-For -Label 'block device appears in WSL' -Seconds $TimeoutSec -Test {
  $o = Wsl 'lsblk -b -dn -o NAME,SIZE,TYPE 2>/dev/null'
  foreach ($l in @($o)) {
    if ("$l" -match '^\s*(\S+)\s+(\d+)\s+disk') {
      $n = $Matches[1]; $sz = [long]$Matches[2]
      # Tolerance: the size WSL reports can differ from Windows by a few sectors.
      if ([math]::Abs($sz - $DiskSize) -lt 16MB) { $script:SdName = $n; return $true }
    }
  }
  return $false
}
$SdName = $script:SdName

if ($DryRun) {
  $SdName = 'sdX'
} elseif (-not $found -or -not $SdName) {
  Bad "No block device of size $(Human $DiskSize) showed up in WSL."
  Inf '  What WSL can see right now:'
  foreach ($l in @(Wsl 'lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>&1')) { Inf "    $DIM$l$R" }
  Inf ''
  Inf "  ${B}If a device is listed at 0B$R, the enclosure dropped off the bus. That is almost"
  Inf '  always power rather than data. Detach, power cycle the enclosure, attach again:'
  Inf "     $DIM usbipd detach --busid $BusId ; usbipd attach --wsl --busid $BusId$R"
  Write-Host ''; exit 1
}
Ok "Disk is ${B}/dev/$SdName$R inside WSL."

# VMFS lives in a partition, not on the raw disk. Pick the largest one.
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
    Note "No partition found on /dev/$SdName."
    Inf '  A VMFS datastore normally sits in partition 1. Check by hand:'
    Inf "     $DIM wsl -u root -- fdisk -l /dev/$SdName$R"
    Write-Host ''; exit 1
  }
  Ok "Datastore partition: ${B}/dev/$PartName$R $DIM($(Human $best))$R"
}

#==============================================================================
# STEP 4. Mount VMFS6.
#==============================================================================
if (-not $Mount) {
  Write-Host ''; Hr
  Ok 'Attached. The datastore is not mounted yet.'
  Write-Host ''
  Inf "  ${B}Next, inside WSL:$R"
  Inf "     $DIM sudo mkdir -p $Src$R"
  Inf "     $DIM sudo vmfs6-fuse /dev/$PartName $Src$R"
  Inf "     $DIM ./vmfs-copy.sh --src $Src --dest $Dest$R"
  Write-Host ''
  Inf "  ${DIM}Or rerun this with -Mount to do the mount from here.$R"
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
    Inf "$DIM  apt-get update && apt-get install -y vmfs6-tools$R"
    Wsl 'apt-get update -qq && apt-get install -y vmfs6-tools' | Out-Null
    $have2 = Wsl 'command -v vmfs6-fuse >/dev/null 2>&1 && echo YES || echo NO'
    if ("$have2" -match 'NO') {
      Die 'The install did not produce vmfs6-fuse. Run "sudo apt install vmfs6-tools" in WSL and read the error.'
    }
    Ok 'vmfs6-tools installed.'
  }
} else {
  Ok 'vmfs6-fuse present.'
}

$already = Wsl "mountpoint -q '$Src' && echo MOUNTED || echo NO"
if ("$already" -match 'MOUNTED') {
  Ok "$Src is already mounted."
} elseif ($DryRun) {
  Note "would mount /dev/$PartName at $Src"
} else {
  Wsl "mkdir -p '$Src'" | Out-Null
  $out = Wsl "vmfs6-fuse '/dev/$PartName' '$Src' 2>&1"
  $chk = Wsl "mountpoint -q '$Src' && echo MOUNTED || echo NO"
  if ("$chk" -notmatch 'MOUNTED') {
    Bad 'Mount failed.'
    foreach ($l in @($out)) { Inf "    $DIM$l$R" }
    Inf ''
    Inf "  ${B}Lun ID mismatch$R warnings are normal. The disk moved to a different controller."
    Inf "  ${B}Permission denied$R means you are not root inside WSL."
    Inf "  ${B}Cannot open volume$R usually means the wrong partition. Check the others:"
    Inf "     $DIM wsl -u root -- lsblk /dev/$SdName$R"
    Write-Host ''; exit 1
  }
  Ok "Mounted /dev/$PartName at ${B}$Src$R."
}

# Proof it worked: a VMFS datastore holds VM folders. An empty mount is a failed
# mount that returned success, and it is better to say so here than to let the
# copier report "no VM folders found".
if (-not $DryRun) {
  $folders = @(Wsl "ls -1 '$Src' 2>/dev/null | head -40" | Where-Object { "$_".Trim() })
  if ($folders.Count -eq 0) {
    Note "$Src mounted but is empty, which is not a normal VMFS datastore."
  } else {
    Write-Host ''
    Inf "  ${B}$($folders.Count) entries on the datastore:$R"
    foreach ($f in $folders) { Inf "    $CY-$R $f" }
  }
}

Write-Host ''; Hr
Ok 'Datastore is mounted and readable.'
Write-Host ''
Inf "  ${B}Next, inside WSL:$R"
Inf "     $DIM ./vmfs-copy.sh --src $Src --dest $Dest$R"
Write-Host ''
Inf "  ${DIM}When the copy is done, unwind cleanly with:$R"
Inf "     $DIM .\vmfs-attach.ps1 -Detach$R"
Write-Host ''
