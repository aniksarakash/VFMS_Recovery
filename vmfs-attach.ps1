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
# device are both privileged operations. -DryRun is the exception: it only reads,
# so it runs from an ordinary shell and is the safe way to check the plan first.
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
$ESC   = [char]27
$RS   = "$ESC[0m"; $BD = "$ESC[1m"; $DIM = "$ESC[2m"
$RD  = "$ESC[31m"; $GR = "$ESC[32m"; $YL = "$ESC[33m"; $CY = "$ESC[36m"

# Escape codes are worse than no colour when nothing is going to interpret them:
# a redirected log fills up with [2m and [0m, and so does a console without
# virtual terminal support.
if ([Console]::IsOutputRedirected -or $env:NO_COLOR -or -not $Host.UI.SupportsVirtualTerminal) {
  $RS = ''; $BD = ''; $DIM = ''; $RD = ''; $GR = ''; $YL = ''; $CY = ''
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

function Ask ($prompt, $default) {
  if ($Yes) { return $default }
  $a = Read-Host "  $prompt"
  if ([string]::IsNullOrWhiteSpace($a)) { return $default }
  return $a.Trim()
}

# Everything privileged is funnelled through here so -DryRun is honoured in one
# place rather than remembered at each call site.
#
# Failure has to be detected two ways, because neither kind of command used below
# throws. Set-Disk writes a NON-TERMINATING error, so with $ErrorActionPreference
# at 'Continue' a catch block never sees it. usbipd is a native executable, which
# never throws at all and reports failure only in its exit code. Trusting the
# catch alone meant a refused offline and a failed bind both returned $true and
# printed a green [ok], while "| Out-Null" discarded the message that said why,
# and every later step then ran against a disk Windows still owned.
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

# A success line that must stay silent during a dry run, because in a dry run the
# step it is reporting did not happen.
function OkDid ($m) { if (-not $DryRun) { Ok $m } }

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
      Write-Host ("`r    $GR[ok]$RS $Label $DIM(" + [int]$sw.Elapsed.TotalSeconds + "s)$RS" + (' ' * 20))
      return $true
    }
    Write-Host ("`r    $CY" + $frames[$i % 4] + "$RS $Label $DIM" + [int]$sw.Elapsed.TotalSeconds + "s$RS   ") -NoNewline
    Start-Sleep -Milliseconds 500; $i++
  }
  Write-Host ("`r    $RD[xx]$RS $Label, timed out after $Seconds" + "s" + (' ' * 18))
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

# usbipd's own state is the only source of truth for BUSID. Prefer "usbipd state",
# which is JSON, over "usbipd list", whose table truncates long device names to an
# ellipsis and whose STATE wording has changed across versions ("Attached - WSL" on
# usbipd 3.x, "Attached" on 4.x and later). A truncated name loses the "Mass
# Storage" that the enclosure is recognised by, and unexpected STATE wording drops
# the row entirely, which reads as "no devices found" with the enclosure plugged in.
function Get-Enclosure {
  $json = & usbipd state 2>&1
  if ($LASTEXITCODE -eq 0) {
    $parsed = $null
    try { $parsed = (@($json) -join "`n") | ConvertFrom-Json } catch { $parsed = $null }
    if ($parsed -and $parsed.Devices) {
      $out = @()
      foreach ($d in $parsed.Devices) {
        # No BusId means persisted-but-absent: a remembered binding for hardware
        # that is not plugged in. Offering it would only offer a choice that fails.
        if (-not $d.BusId) { continue }
        $vidpid = '????:????'
        if ("$($d.InstanceId)" -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
          $vidpid = "$($Matches[1]):$($Matches[2])".ToLower()
        }
        # PersistedGuid is set once a device has been bound, ClientIPAddress only
        # while a client holds it. That is what the STATE column is derived from,
        # so reading it directly does not depend on how STATE is worded.
        $state = 'Not shared'
        if ($d.PersistedGuid)   { $state = 'Shared' }
        if ($d.IsForced)        { $state = "$state (forced)" }
        if ($d.ClientIPAddress) { $state = 'Attached' }
        $name = "$($d.Description)".Trim()
        $out += [pscustomobject]@{
          BusId  = "$($d.BusId)"
          VidPid = $vidpid
          Device = $name
          State  = $state
          # A drive enclosure announces itself as mass storage. That is a better
          # signal than the vendor string, which is often a bare chipset name.
          IsMass = ($name -match 'Mass Storage|UAS|SCSI|Disk')
        }
      }
      # usbipd state returns devices unordered, and a plain string sort puts 2-10
      # ahead of 2-5. Sort on the numbers so the table reads like usbipd list.
      return ($out |
        Sort-Object @{ E = { [int]("$($_.BusId)" -split '[-.]')[0] } },
                    @{ E = { [int]("$($_.BusId)" -split '[-.]')[1] } }, BusId)
    }
  }
  return (Get-EnclosureFromTable)
}

# Fallback for usbipd older than 4.0, which has no "state" command. Parse the
# table carefully and stop at the "Persisted:" section, whose rows are remembered
# devices, not present ones.
function Get-EnclosureFromTable {
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
    # Longest state alternatives first: the lazy device group would otherwise let
    # "Attached" match and leave " - WSL" stranded before the anchor.
    if ($t -match '^\s*([0-9]+-[0-9.]+)\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s+(.+?)\s\s+(Not shared|Shared \(forced\)|Shared|Attached \(forced\)|Attached - WSL|Attached)\s*$') {
      # Capture every group into locals BEFORE running any other -match. The
      # -match operator overwrites $Matches, and inside a hash literal IsMass is
      # evaluated before Device, so testing the device string in place wiped the
      # capture groups and dropped exactly the mass-storage rows this function
      # exists to find. A failed match leaves $Matches alone, which is why only
      # the enclosure rows disappeared.
      $bus = $Matches[1]; $vidpid = $Matches[2]
      $name = $Matches[3].Trim(); $state = $Matches[4]
      if ($state -eq 'Attached - WSL') { $state = 'Attached' }
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
Write-Host "$BD  VMFS attach helper$RS  $DIM(Windows side of the recovery)$RS"
Hr

#------------------------------------------------------------------------------
# Preflight
#------------------------------------------------------------------------------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if ($me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Ok 'Running elevated.'
} elseif ($DryRun) {
  # Every detection step is a read: Get-Disk, usbipd state and lsblk all work
  # unelevated. Refusing to even show the plan from a normal shell made -DryRun
  # useless at the one moment it is most wanted, which is before touching a disk.
  Note 'Not elevated, but -DryRun only reads. The plan below is still accurate.'
  Inf "  ${DIM}Rerun in an administrator shell, without -DryRun, to carry it out.$RS"
} else {
  Bad 'Not running as Administrator.'
  Inf ''
  Inf "  Offlining a disk and binding a USB device both need elevation. Reopen"
  Inf "  PowerShell with ${BD}Run as administrator${RS}, then run this again:"
  Inf "     $DIM$($MyInvocation.MyCommand.Path)$RS"
  Inf ''
  Inf "  ${DIM}Or preview the plan from this shell:  .mfs-attach.ps1 -DryRun$RS"
  Write-Host ''
  exit 1
}

if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
  Bad 'usbipd not found. WSL cannot be handed a USB device without it.'
  Inf "  Install it, then reopen this shell:  $DIM winget install usbipd$RS"
  Inf "  ${DIM}or https://github.com/dorssel/usbipd-win/releases$RS"
  Write-Host ''; exit 1
}
Ok "usbipd present: $DIM$(& usbipd --version 2>&1 | Select-Object -First 1)$RS"

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

  Step '3.' 'Bring the disk back online in Windows'
  $off = @(Get-Disk | Where-Object { $_.IsOffline -and $_.BusType -eq 'USB' })
  # Scope this when there is a choice. Onlining every offline USB disk is wrong for
  # anyone keeping another one offline deliberately, and Windows offers to format a
  # VMFS disk the moment it comes back.
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

#==============================================================================
# STEP 1. Offline the disk so Windows stops holding it.
#==============================================================================
Step '1.' 'Take the VMFS disk offline in Windows'

$usb = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' } | Sort-Object Number)
if ($usb.Count -eq 0) {
  Bad 'No USB disks found. Is the enclosure powered and plugged in?'
  Inf "  ${DIM}A 3.5 inch enclosure usually needs its own power brick; bus power is not enough.$RS"
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
Write-Host "   $DIM  #   SIZE     STYLE  PART  WINDOWS SEES  OFFLINE  MODEL$RS"
foreach ($row in $rows) {
  $mark = ' '
  if ($row.Likely) { $mark = "$CY*$RS" }
  Write-Host ("   {0} {1,-3} {2,-8} {3,-6} {4,-5} {5,-13} {6,-8} {7}" -f `
      $mark, $row.Disk, $row.Size, $row.Style, $row.Parts, $row.Windows, $row.Offline, $row.Name)
}
Write-Host ''
if ($rows | Where-Object { $_.Likely }) {
  Inf "$CY*$RS $DIM= has partitions Windows cannot read, which is the expected shape of a VMFS disk.$RS"
}

if ($DiskNumber -lt 0) {
  $guess = @($rows | Where-Object { $_.Likely })
  $default = ''
  if ($guess.Count -ge 1) { $default = "$($guess[0].Disk)" }
  $prompt = 'Disk number to offline and pass to WSL'
  if ($default) { $prompt = "$prompt [$default]" }
  $ansD = Ask $prompt $default
  if ([string]::IsNullOrWhiteSpace($ansD)) { Die 'No disk selected.' }
  # A bare [int] cast on a typo threw a raw .NET conversion error at the user.
  if ("$ansD" -notmatch '^\s*\d+\s*$') { Die "'$ansD' is not a disk number." }
  $DiskNumber = [int]("$ansD".Trim())
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
Inf "Selected: ${BD}disk $DiskNumber$RS  $($disk.FriendlyName)  $DIM$(Human $DiskSize)$RS"

if ($disk.IsOffline) {
  Ok "Disk $DiskNumber is already offline."
} else {
  if (Invoke-Step "offline disk $DiskNumber" { Set-Disk -Number $DiskNumber -IsOffline $true }) {
    OkDid "Disk $DiskNumber offline. Windows has released it."
  } else {
    Bad 'Could not offline the disk.'
    Inf '  Close anything reading it, then do it by hand:'
    Inf "     $DIM diskpart  ->  list disk  ->  select disk $DiskNumber  ->  offline disk$RS"
    Write-Host ''; exit 1
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
Write-Host "   $DIM  BUSID   VID:PID     STATE        DEVICE$RS"
foreach ($d in $devs) {
  $mark = ' '
  if ($d.IsMass) { $mark = "$CY*$RS" }
  $col = ''
  if ($d.State -eq 'Attached') { $col = $GR } elseif ($d.State -eq 'Shared') { $col = $YL }
  Write-Host ("   {0} {1,-7} {2,-11} {3}{4,-12}{5} {6}" -f $mark, $d.BusId, $d.VidPid, $col, $d.State, $RS, $d.Device)
}
Write-Host ''

if (-not $BusId) {
  $mass = @($devs | Where-Object { $_.IsMass })
  $default = ''
  if ($mass.Count -ge 1) { $default = $mass[0].BusId }
  if ($mass.Count -gt 1) {
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

# "Not shared" means usbipd has never claimed the device. bind is the one-time
# step that makes it attachable at all, and it is the step most often skipped.
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
  # Not | Out-Null: a timeout here is the single most useful signal that the
  # enclosure dropped off the bus, and discarding it left Step 3 to fail instead.
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

# Match on size, not on name. sdX letters are handed out in attach order and
# drift between runs, so yesterday's /dev/sdd is today's /dev/sdc, and writing to
# the wrong one is not recoverable.
$script:SdName = ''
$script:SdAll  = @()
$found = Wait-For -Label 'block device appears in WSL' -Seconds $TimeoutSec -Test {
  $hits = @()
  foreach ($l in @(Wsl 'lsblk -b -dn -o NAME,SIZE,TYPE 2>/dev/null')) {
    if ("$l" -match '^\s*(\S+)\s+(\d+)\s+disk') {
      $n = $Matches[1]; $sz = [long]$Matches[2]
      # Tolerance: the size WSL reports can differ from Windows by a few sectors.
      if ([math]::Abs($sz - $DiskSize) -lt 16MB) { $hits += $n }
    }
  }
  # Collect every match rather than taking the first. WSL's own virtual disks are
  # round numbers, so a 1TB enclosure and a 1TiB ext4 vhdx can both be present.
  if ($hits.Count -gt 0) { $script:SdAll = $hits; $script:SdName = $hits[0]; return $true }
  return $false
}
$SdName = $script:SdName

if ($DryRun) {
  $SdName = 'sdX'
} elseif (-not $found -or -not $SdName) {
  Bad "No block device of size $(Human $DiskSize) showed up in WSL."
  Inf '  What WSL can see right now:'
  foreach ($l in @(Wsl 'lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>&1')) { Inf "    $DIM$l$RS" }
  Inf ''
  Inf "  ${BD}If a device is listed at 0B$RS, the enclosure dropped off the bus. That is almost"
  Inf '  always power rather than data. Detach, power cycle the enclosure, attach again:'
  Inf "     $DIM usbipd detach --busid $BusId ; usbipd attach --wsl --busid $BusId$RS"
  Write-Host ''; exit 1
}
Ok "Disk is ${BD}/dev/$SdName$RS inside WSL."
if (-not $DryRun -and $script:SdAll.Count -gt 1) {
  Note "$($script:SdAll.Count) WSL disks are $(Human $DiskSize): $($script:SdAll -join ', '). Using /dev/$SdName."
  Inf "  ${DIM}Confirm with 'wsl -u root -- lsblk' before copying. Writing to the wrong one is not recoverable.$RS"
}

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
    Inf "     $DIM wsl -u root -- fdisk -l /dev/$SdName$RS"
    Write-Host ''; exit 1
  }
  Ok "Datastore partition: ${BD}/dev/$PartName$RS $DIM($(Human $best))$RS"
}

#==============================================================================
# STEP 4. Mount VMFS6.
#==============================================================================
if (-not $Mount) {
  Write-Host ''; Hr
  if ($DryRun) { Note 'Plan complete. Nothing was attached, because -DryRun was set.' }
  else { Ok 'Attached. The datastore is not mounted yet.' }
  Write-Host ''
  Inf "  ${BD}Next, inside WSL:$RS"
  Inf "     $DIM sudo mkdir -p $Src$RS"
  Inf "     $DIM sudo vmfs6-fuse /dev/$PartName $Src$RS"
  Inf "     $DIM ./vmfs-copy.sh --src $Src --dest $Dest$RS"
  Write-Host ''
  Inf "  ${DIM}Or rerun this with -Mount to do the mount from here.$RS"
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
    # DEBIAN_FRONTEND keeps a package's configure prompt from blocking forever on a
    # stdin nobody is watching, and the output is shown rather than sent to Out-Null
    # so that a slow mirror looks slow instead of looking hung.
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

$already = Wsl "mountpoint -q '$Src' && echo MOUNTED || echo NO"
if ("$already" -match 'MOUNTED') {
  Ok "$Src is already mounted."
} elseif ($DryRun) {
  Note "would mount /dev/$PartName at $Src"
} else {
  Wsl "mkdir -p '$Src'" | Out-Null
  $out = Wsl "vmfs6-fuse '/dev/$PartName' '$Src' 2>&1"
  # vmfs6-fuse daemonises, so the mount can still be settling when it returns.
  # Asking mountpoint exactly once reported a perfectly good mount as a failure.
  $chk = Wait-For -Label "mount appears at $Src" -Seconds 15 -Test {
    return ("$(Wsl "mountpoint -q '$Src' && echo MOUNTED || echo NO")" -match 'MOUNTED')
  }
  if (-not $chk) {
    Bad 'Mount failed.'
    foreach ($l in @($out)) { Inf "    $DIM$l$RS" }
    Inf ''
    Inf "  ${BD}Lun ID mismatch$RS warnings are normal. The disk moved to a different controller."
    Inf "  ${BD}Permission denied$RS means you are not root inside WSL."
    Inf "  ${BD}Cannot open volume$RS usually means the wrong partition. Check the others:"
    Inf "     $DIM wsl -u root -- lsblk /dev/$SdName$RS"
    Inf "  ${DIM}The mount is root owned, so run the copier with sudo rather than as yourself.$RS"
    Write-Host ''; exit 1
  }
  Ok "Mounted /dev/$PartName at ${BD}$Src$RS."
}

# Proof it worked: a VMFS datastore holds VM folders. An empty mount is a failed
# mount that returned success, and it is better to say so here than to let the
# copier report "no VM folders found".
if (-not $DryRun) {
  $total   = "$(Wsl "ls -1 '$Src' 2>/dev/null | wc -l")".Trim()
  $folders = @(Wsl "ls -1 '$Src' 2>/dev/null | head -40" | Where-Object { "$_".Trim() })
  if ($folders.Count -eq 0) {
    Note "$Src mounted but is empty, which is not a normal VMFS datastore."
  } else {
    Write-Host ''
    # $total, not $folders.Count: the listing is capped at 40, so reporting the
    # capped number as the total made a 200 VM datastore look like a 40 VM one.
    $cap = ''
    if ($folders.Count -lt [int]"0$total") { $cap = "$DIM, first $($folders.Count)$RS" }
    Inf "  ${BD}$total entries on the datastore$RS${cap}:"
    foreach ($f in $folders) { Inf "    $CY-$RS $f" }
  }
}

Write-Host ''; Hr
if ($DryRun) { Note 'Plan complete. Nothing was attached or mounted, because -DryRun was set.' }
else { Ok 'Datastore is mounted and readable.' }
Write-Host ''
Inf "  ${BD}Next, inside WSL:$RS"
Inf "     $DIM ./vmfs-copy.sh --src $Src --dest $Dest$RS"
Write-Host ''
Inf "  ${DIM}When the copy is done, unwind cleanly with:$RS"
Inf "     $DIM .\vmfs-attach.ps1 -Detach$RS"
Write-Host ''
