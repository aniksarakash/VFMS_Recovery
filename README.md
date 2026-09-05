<!-- ════════════════════════════════════════════════════════════════════════ -->
<!--                            HERO  /  3D BANNER                             -->
<!-- ════════════════════════════════════════════════════════════════════════ -->

<div align="center">

<a href="https://github.com/aniksarakash/VFMS_Recovery">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:0F2027,50:203A43,100:2C5364&height=210&section=header&text=VMFS%20Recovery&fontSize=62&fontColor=ffffff&animation=fadeIn&fontAlignY=36&desc=Pull%20live%20VMs%20off%20a%20dead%20VMFS%20datastore%20%E2%80%94%20USB%20enclosure%20%E2%86%92%20WSL2%20%E2%86%92%20ESXi%208&descAlignY=58&descSize=16" alt="VMFS Recovery" width="100%" />
</a>

<br/>

<a href="https://git.io/typing-svg">
  <img src="https://readme-typing-svg.demolab.com?font=JetBrains+Mono&weight=600&size=21&pause=900&color=39BAE6&center=true&vCenter=true&width=820&height=46&lines=Drive+out+of+the+host.+In+a+USB+enclosure.;Windows+can't+read+VMFS.+WSL2+can.;ddrescue+the+disk+images.+rsync+the+rest.;bad+areas%3A+0+%E2%80%94+that's+a+clean+recovery." alt="Typing SVG" />
</a>

<br/><br/>

<!-- ── NAV BADGES (anchor links, for-the-badge) ─────────────────────────── -->
<a href="#tldr"><img src="https://img.shields.io/badge/TL;DR-0F2027?style=for-the-badge&logo=bookstack&logoColor=39BAE6" alt="Jump to the TL;DR" /></a>
<a href="#-quick-start"><img src="https://img.shields.io/badge/Quick_Start-16537e?style=for-the-badge&logo=rocket&logoColor=white" alt="Jump to Quick Start" /></a>
<a href="#-the-copier-script"><img src="https://img.shields.io/badge/The_Script-203A43?style=for-the-badge&logo=gnubash&logoColor=white" alt="Jump to the copier script" /></a>
<a href="#-full-walkthrough"><img src="https://img.shields.io/badge/Walkthrough-2C5364?style=for-the-badge&logo=readthedocs&logoColor=white" alt="Jump to the full walkthrough" /></a>
<a href="#-troubleshooting-reference"><img src="https://img.shields.io/badge/Troubleshoot-b23c17?style=for-the-badge&logo=gnometerminal&logoColor=white" alt="Jump to troubleshooting" /></a>
<a href="#-frequently-asked-questions"><img src="https://img.shields.io/badge/FAQ-6b4c9a?style=for-the-badge&logo=stackoverflow&logoColor=white" alt="Jump to frequently asked questions" /></a>
<a href="#-restoring-on-esxi-8"><img src="https://img.shields.io/badge/ESXi_Restore-607078?style=for-the-badge&logo=vmware&logoColor=white" alt="Jump to restoring on ESXi 8" /></a>

<br/>

<!-- ── STATUS BADGES (flat-square) ──────────────────────────────────────── -->
<img src="https://img.shields.io/badge/platform-Windows_11_%7C_WSL2-0078D6?style=flat-square&logo=windows11&logoColor=white" alt="Platform: Windows 11 with WSL2" />
<img src="https://img.shields.io/badge/filesystem-VMFS6-607078?style=flat-square&logo=vmware&logoColor=white" alt="Filesystem: VMFS6" />
<img src="https://img.shields.io/badge/engine-ddrescue_+_rsync-2ea44f?style=flat-square&logo=gnu&logoColor=white" alt="Copy engines: ddrescue and rsync" />
<img src="https://img.shields.io/badge/resumable-yes-39BAE6?style=flat-square&logo=databricks&logoColor=white" alt="Resumable: yes, via ddrescue mapfile" />
<img src="https://img.shields.io/badge/data_loss-ZERO-success?style=flat-square&logo=shield&logoColor=white" alt="Data loss in the field recovery: zero" />
<img src="https://img.shields.io/badge/status-field--tested-orange?style=flat-square&logo=checkmarx&logoColor=white" alt="Status: field-tested on a real recovery" />
<img src="https://img.shields.io/badge/last_verified-Aug_2026-blue?style=flat-square&logo=calendar&logoColor=white" alt="Last verified August 2026" />
<img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square&logo=opensourceinitiative&logoColor=white" alt="License: MIT" />

<br/><br/>

<!-- ── TECH STACK ICONS ─────────────────────────────────────────────────── -->
<img src="https://skillicons.dev/icons?i=linux,bash,powershell,windows,git,github,md&theme=dark" alt="Tech stack: Linux, Bash, PowerShell, Windows, Git, GitHub, Markdown" />

</div>

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

<!-- ════════════════════════════════════════════════════════════════════════ -->

<a id="tldr"></a>

> [!NOTE]
> **The 20-second version.** A drive that used to back a VMware **VMFS6** datastore is now sitting in a **USB enclosure**. Windows sees it but can't read the filesystem. This repo attaches it into **WSL2**, mounts it with `vmfs6-fuse`, then runs one interactive script, [`vmfs-copy.sh`](vmfs-copy.sh), that **`ddrescue`s the big disk images** (retry + resume on bad sectors) and **`rsync`s the metadata**, with a **live progress bar, folder detection, and interactive selection**. Copy lands on your `D:` drive; then you register the VM on a fresh **ESXi 8** host. Every failure mode below actually happened during a real recovery.

<br/>

## 📌 What This Repository Is

**VMFS Recovery** is a field-tested playbook plus three scripts, [`vmfs-attach.ps1`](vmfs-attach.ps1) for the Windows half, [`vmfs-copy.sh`](vmfs-copy.sh) for the Linux half, and [`verify-staged.sh`](verify-staged.sh) to check the result before you import it, for **recovering VMware virtual machines from a bare VMFS6 datastore disk**: a drive that has been physically pulled out of an ESXi host and plugged into a Windows PC through a USB enclosure.

**The problem.** Windows cannot read VMFS. There is no native Windows VMFS driver, so the disk shows up in Disk Management as a healthy partition with no drive letter, no recognized filesystem, and an offer to format it. Nothing on it is damaged. Windows simply doesn't speak the filesystem.

**The method.** [`vmfs-attach.ps1`](vmfs-attach.ps1) offlines the disk in Windows and hands the enclosure to **WSL2** through `usbipd-win`, `vmfs6-fuse` mounts the VMFS6 volume inside Linux, and `vmfs-copy.sh` copies each VM folder out with the right tool per file: **`ddrescue`** for the multi-gigabyte `-flat.vmdk` disk images (bad-sector retries, resumable via mapfile) and **`rsync`** for the small `.vmx` / `.nvram` / descriptor files.

**The result.** A complete, restorable VM folder on an ordinary NTFS drive, ready to register on a fresh **ESXi 8** host with `vim-cmd solo/registervm`. **No working hypervisor is needed to read the disk**, only WSL2.

**Who it's for.** Anyone holding a VMFS disk from a failed, decommissioned, or compromised ESXi host, with no running host left to plug it back into.

> [!TIP]
> **About the spelling.** The filesystem is **VMFS**, *Virtual Machine File System*. This repository's name transposes the letters as `VFMS_Recovery`. If you got here searching for **VFMS recovery**, **VMFS recovery** is the correct term, and this is the right place.

<br/>

## 🧭 Table of Contents

<table>
<tr>
<td width="50%" valign="top">

**Getting the data out**
- [📌 What This Repository Is](#-what-this-repository-is)
- [🎯 When to Use This](#-when-to-use-this)
- [🧱 Prerequisites](#-prerequisites)
- [🗺 The Process at a Glance](#-the-process-at-a-glance)
- [⚡ Quick Start](#-quick-start)
- [🪟 The Attach Script (Windows)](#-the-attach-script-windows)
- [🖥 The Copier Script](#-the-copier-script)
- [✅ The Verifier Script](#verify-stagedsh-wsl)
- [📖 Full Walkthrough](#-full-walkthrough)

</td>
<td width="50%" valign="top">

**When things go sideways · getting it back up**
- [♻ Recovering After a Crash](#-recovering-after-a-crash-power-loss-or-wsl-restart)
- [🚀 Restoring on ESXi 8](#-restoring-on-esxi-8)
- [🧭 Migrating to New Hardware](MIGRATION.md)
- [🔧 Troubleshooting Reference](#-troubleshooting-reference)
- [🧾 Exact Error Messages, Decoded](#-exact-error-messages-decoded)
- [❓ Frequently Asked Questions](#-frequently-asked-questions)
- [🎛 Script Reference](#-script-reference-flags--internals)
- [🗒 Field Notes](#-field-notes)
- [🙋 Author & License](#-author--license)

</td>
</tr>
</table>

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## 🎯 When to Use This

The drive is **no longer in an ESXi host**. It's out, in an enclosure, plugged into a USB port. Windows Disk Management shows it as a single healthy *"Primary Partition"* with **no drive letter and no recognized filesystem** (Windows can't read VMFS natively) and refuses to mount it. **That's the signal you're in the right place.**

<div align="center">

| You have… | This repo gives you… |
|---|---|
| 🔌 A bare VMFS drive in a USB enclosure | A WSL2 attach + mount recipe that actually works |
| 💾 50-100 GB+ `-flat.vmdk` disk images | `ddrescue` with retries + a **resumable** mapfile |
| 🧩 Small `.vmx` / `.nvram` / descriptor files | `rsync`, fast, with swap/log files excluded |
| ⚠ A drive with **bad sectors** | Sector-level recovery instead of a hard mid-copy fail |
| 🧨 A crash / power-loss / WSL freeze mid-copy | A step-by-step **resume** sequence, never restarts from zero |
| 🚀 A fresh ESXi 8 host to restore onto | `vim-cmd` register + first-boot handling |

</div>

> [!WARNING]
> **If this recovery follows a security incident** rather than a hardware failure, don't power the recovered VM straight onto a production network. Boot it on an **isolated/quarantine portgroup**, scan it, *then* reconnect. More in the [restore section](#-restoring-on-esxi-8).

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## 🧱 Prerequisites

| Tool | Runs on | Purpose | Install |
|---|---|---|---|
| **`usbipd-win`** | Windows | Shares a USB device into WSL2's Linux kernel | `winget install usbipd` · or the [releases page](https://github.com/dorssel/usbipd-win/releases) |
| **WSL2** (Ubuntu) | Windows | A real Linux kernel that can read VMFS | `wsl --install` |
| **`vmfs6-fuse`** | WSL2 | FUSE driver to mount a VMFS6 volume | via `vmfs6-tools`, package manager first, else build from source |
| **`gddrescue`** (→ `ddrescue`) | WSL2 | Sector-level recovery for a degrading drive | `sudo apt install gddrescue` |
| **`rsync`** | WSL2 | Bulk copy for everything that isn't a giant image | usually preinstalled · else `sudo apt install rsync` |
| **`xxd`** | WSL2 | Reads the MBR signature back off the copy in [`verify-staged.sh`](verify-staged.sh) | usually preinstalled · else `sudo apt install xxd` |
| **PowerShell** (admin) | Windows | Runs [`vmfs-attach.ps1`](vmfs-attach.ps1); `diskpart` and `usbipd` both need elevation | preinstalled · Windows PowerShell 5.1 or PowerShell 7+ |

> [!TIP]
> **Known-good enclosure fingerprint for this workflow: `0bda:9210`** (Realtek UAS bridge). A different VID:PID claiming to be mass storage **is not it**, and the near-miss is not always an unrelated device. In the [attach-script screenshot](#-the-attach-script-windows), `0bda:9201` one busid over is the enclosure holding the **destination** drive `D:`; attaching that one hands your copy target to WSL and takes it away from Windows. `152d:0583` has turned up on this bench too. Always confirm the VID:PID in `usbipd list` before attaching, and prefer the script, whose `HOLDS` column resolves each bridge to the disk behind it.

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## 🗺 The Process at a Glance

```mermaid
flowchart TD
    A(["🔌 Physical drive in USB enclosure"]) --> B["🪟 Windows: usbipd list"]
    B --> C{"Enclosure shows<br/>a busid?"}
    C -- No --> C1["Unplug / replug,<br/>check usbipd list again"] --> B
    C -- Yes --> D["🪟 diskpart:<br/>select disk N → offline disk"]
    D --> E["🪟 usbipd attach<br/>--wsl --busid X-Y"]
    E --> F["🐧 WSL: sleep 15; lsblk"]
    F --> G{"Real size shown?<br/>e.g. 931.5G"}
    G -- "0B / missing" --> G1["Read-Capacity failure,<br/>reattach, wait longer"] --> E
    G -- Yes --> H["🐧 sudo vmfs6-fuse<br/>/dev/sdX1 /mnt/vmfs"]
    H --> J["🐧 sudo ls -lh /mnt/vmfs"]
    J --> K["▶ sudo ./vmfs-copy.sh"]
    K --> L{"Per folder: image<br/>≥ threshold?"}
    L -- Yes --> M["🩺 ddrescue the -flat.vmdk<br/>(sector-level, resumable)"]
    L -- No --> N["📄 rsync the folder<br/>(minus .vswp / .log)"]
    M --> N2["📄 rsync the rest"]
    N --> O["✅ ./verify-staged.sh<br/>bad areas 0 · exact size ·<br/>EFI PART readable on the copy"]
    N2 --> O
    O --> O2{"Any<br/>failures?"}
    O2 -- Yes --> O3["🛠 Fix before importing,<br/>a bad image boots once"] --> O
    O2 -- No --> P(["🚀 ESXi 8 restore"])

    classDef win fill:#0F2027,stroke:#0078D6,color:#fff;
    classDef nix fill:#1b2b34,stroke:#39BAE6,color:#fff;
    classDef ok  fill:#0f3d2e,stroke:#2ea44f,color:#fff;
    class B,D,E win; class F,H,J,K nix; class O,P ok;
```

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=cylinder&color=0:16537e,100:0F2027&height=90&text=Quick%20Start&fontSize=34&fontColor=ffffff&fontAlignY=52" alt="Quick Start" width="100%" />
</div>

## ⚡ Quick Start

Three scripts, two shells. The Windows one attaches the disk; the Linux ones copy the files and then check that what landed is actually importable.

**1. Windows, in an administrator PowerShell.** Offlines the disk, hands the enclosure to WSL2, mounts the datastore:

```powershell
git clone https://github.com/aniksarakash/VFMS_Recovery.git
cd VFMS_Recovery
.\vmfs-attach.ps1 -Mount
```

**2. WSL, as root.** Detect the VM folders, pick the ones you want, copy them:

```bash
chmod +x vmfs-copy.sh
sudo ./vmfs-copy.sh                       # launches interactive graphical dashboard & menu
# or non-interactive: sudo ./vmfs-copy.sh --all --yes --src /mnt/vmfs --dest /mnt/d
```

`sudo` is not optional here. `vmfs6-fuse` owns the mount as root and does not pass `allow_other`, so to any other user *every* path under `/mnt/vmfs` fails with `EACCES`. Run the copier as yourself and it cannot read one byte of the datastore; it now says so and hands you the `sudo` line rather than claiming the source is missing.

**3. Before you trust it**, check that what landed is importable. Read-only, and safe to run while a copy is still going:

```bash
chmod +x verify-staged.sh
./verify-staged.sh                        # launches interactive audit suite & budget validator
# or non-interactive: ./verify-staged.sh --dest /mnt/d
```

`bad areas: 0` means the *copy* was clean; it says nothing about whether the image still has a readable partition table at the other end. This reads sector 0 and 1 back **off the destination** and exits non-zero if anything fails, so you find out now rather than at power-on.

**4. When the copy is finished**, unwind cleanly from Windows:

```powershell
.\vmfs-attach.ps1 -Detach
```

Already have the datastore mounted? Go straight to step 2. Prefer to do the Windows half by hand? Every command is in the [walkthrough](#-full-walkthrough), and [the attach script](#-the-attach-script-windows) explains exactly what it is automating.

```bash
sudo mkdir -p /mnt/vmfs && sudo vmfs6-fuse /dev/sdd1 /mnt/vmfs   # sdX drifts, run lsblk first
```

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## 🪟 The Attach Script (Windows)

[`vmfs-attach.ps1`](vmfs-attach.ps1) covers the half of the job the copier structurally cannot. `vmfs-copy.sh` runs **inside** WSL, and from in there it has no way to offline a Windows disk or bind a USB device to itself: `diskpart` and `usbipd` are Windows executables that need an elevated Windows shell. Those steps were manual, and a forgotten one looks exactly like an empty datastore.

Running `.\vmfs-attach.ps1` with no flags launches the **interactive CLI dashboard** with live hardware detection, an operations menu, and a persistent navigation loop:

```powershell
.\vmfs-attach.ps1                 # interactive graphical dashboard with live status & menu loop
.\vmfs-attach.ps1 -Mount          # offline the disk, attach to WSL, mount VMFS6
.\vmfs-attach.ps1 -Mount -Inspect # mount and inspect datastore contents and sizes with visual effects
.\vmfs-attach.ps1 -Inspect        # view datastore contents, VM configs, and copy commands
.\vmfs-attach.ps1 -Test           # verify VMFS6 filesystem health, metadata & readability
.\vmfs-attach.ps1 -Cycle          # full cycle: unmount, detach, re-attach, mount & test filesystem
.\vmfs-attach.ps1 -Detach         # unmount, detach, online (with option to re-test filesystem)
.\vmfs-attach.ps1 -Detach -Test   # detach and immediately re-attach to test filesystem again
.\vmfs-attach.ps1 -DryRun         # show the plan, change nothing
```

> [!IMPORTANT]
> It must run in an **administrator** PowerShell. Offlining a disk and binding a USB device are both privileged operations, and the script refuses to continue rather than failing halfway through.

### Interactive Dashboard & Menu Loop

When invoked interactively, `vmfs-attach.ps1` renders a real-time status card and operation selector:

```text
  ┌────────────────────────────────────────────────────────────────────────┐
  │  SYSTEM & HARDWARE STATUS                                              │
  ├────────────────────────────────────────────────────────────────────────┤
  │  PowerShell:       RUNNING ELEVATED (Admin)                            │
  │  WSL2 Kernel:      READY (Ubuntu, Linux 5.15.167.4-microsoft-WSL2+)    │
  │  USB Enclosure:    3-4  Realtek 9210 (Corsair MP600 PRO NH 932G)       │
  │  VMFS Mount:       /mnt/vmfs  [LIVE]  (/dev/sdd1 mounted)              │
  └────────────────────────────────────────────────────────────────────────┘

  ┌────────────────────────────────────────────────────────────────────────┐
  │  OPERATION SELECTOR                                                    │
  ├────────────────────────────────────────────────────────────────────────┤
  │  [1]  🚀 Attach & Mount Datastore (Windows -> WSL passthrough)         │
  │  [2]  🔍 Mount & Inspect Datastore Contents (visual storage inspector) │
  │  [3]  🩺 Verify & Test Filesystem Health (VMFS6 metadata & extents)    │
  │  [4]  🔄 Full Recovery Cycle (detach, re-attach, mount & test)         │
  │  [5]  📁 Inspect Datastore Hierarchy & Virtual Machine Configs         │
  │  [6]  🔌 Detach Enclosure & Return Disk Online                         │
  │  [7]  📋 Dry-Run Simulation (preview all steps, change nothing)        │
  │  [Q]  🚪 Exit                                                          │
  └────────────────────────────────────────────────────────────────────────┘
```

> [!TIP]
> **Persistent Menu Loop:** Every command and test pauses with `Press [Enter] to return to Main Menu, or 'q' to exit:`. Pressing **Enter** returns smoothly to the dashboard, letting you test, inspect, cycle, or detach without having to restart the script.

### What a run looks like

<div align="center">
  <img src="docs/img/attach-run.png" alt="vmfs-attach.ps1 running elevated: the disk table marks the 932G GPT disk Windows reads as unreadable, and the usbipd table resolves busid 3-2 to disk 1 while 3-4 still holds disk 2 (D:)" width="100%" />
  <br/>
  <em>A real run. The boxed row is the VMFS disk (<strong>932G, 5 partitions, <code>unreadable</code></strong>), and busid <code>3-2</code> is the enclosure holding it. <code>3-4</code> holds <code>disk 2 (D:)</code>, the copy destination; attaching that one to WSL would have pulled the destination out from under the copy.</em>
</div>

Illustrative output, showing the two-enclosure case that makes manual attaching risky:

```text
  VMFS attach helper  (Windows side of the recovery)
------------------------------------------------------------------------
  [ok] Running elevated.
  [ok] usbipd present: 4.3.0
  [ok] WSL reachable.

  1. Take the VMFS disk offline in Windows

     #   SIZE     STYLE  PART  WINDOWS SEES  OFFLINE  MODEL
   *  2   931G     GPT    1     unreadable    False    Realtek 9210 SCSI Disk Device
      3   3.6T     GPT    2     NTFS          False    WD Elements 25A3

   * = has partitions Windows cannot read, which is the expected shape of a VMFS disk.

  Disk number to offline and pass to WSL [2]: 2
  Selected: disk 2  Realtek 9210 SCSI Disk Device  931G
  [ok] Disk 2 offline. Windows has released it.

  2. Attach the enclosure to WSL with usbipd

     BUSID   VID:PID     STATE        HOLDS             DEVICE
   *  3-2     0bda:9210   Shared       disk 2 <-         USB Attached SCSI (UAS) Mass Storage Device
   *  3-4     0bda:9201   Not shared   disk 3 (D:)       USB Attached SCSI (UAS) Mass Storage Device

  Busid 3-2 is the enclosure holding disk 2.
  BUSID of the enclosure [3-2]: 3-2
  Selected: 3-2  0bda:9210  USB Attached SCSI (UAS) Mass Storage Device
  Already bound (state: Shared).
    [ok] usbipd reports 3-2 Attached (3s)

  3. Locate the disk inside WSL
    [ok] block device appears in WSL (6s)
  [ok] Disk is /dev/sdd inside WSL.
  [ok] Datastore partition: /dev/sdd1 (931G)

  4. Mount the VMFS6 datastore
  [ok] vmfs6-fuse present.
  [ok] Mounted /dev/sdd1 at /mnt/vmfs.

  3 entries on the datastore:
    - IP_44.10_MyQ test Server
    - IP_172.17.44.34_SQL
    - Ticketing_System_Production Server

------------------------------------------------------------------------
  [ok] Datastore is mounted and readable.

  Next, inside WSL:
     sudo ./vmfs-copy.sh --src /mnt/vmfs --dest /mnt/d
```

Run it a second time (to add `-Mount` to an attach that already happened, say) and step 1 has nothing to do, which it says rather than asking you to pick a disk:

```text
  1. Take the VMFS disk offline in Windows
  [ok] 3-2 is already attached to WSL, so Windows no longer owns this disk.
    Nothing to offline. Skipping to the WSL side.
```

### The six things it does that a manual attach doesn't

1. **Detects candidate VMFS disks and enclosures across all hardware layers.** Searches across `MSFT_Disk`, `Win32_DiskDrive` (WMI), `Get-PnpDevice` (PnP), and `usbipd`. Reliably detects USB-C and USB 3.x NVMe and SATA enclosures (including Realtek RTL9210, ASMedia ASM2464, and JMicron bridges) even when Windows Storage has not mounted media (`MediaLoaded: False`, raw partition). The `*` marks any disk or enclosure with unreadable partitions, raw media, or mass storage with no Windows drive letters. If you pick one Windows *can* read, the script warns before touching it, and it strictly protects your destination drive (`D:`) from being pulled out from under a copy.
2. **Names the disk behind each USB bridge, and refuses the wrong enclosure.** Attaching a device to WSL *takes it away from Windows*. On a bench with two identical bridge chips, picking the wrong busid does not merely grab the wrong source, it removes the copy destination from Windows, mid-write if a copy is running. The `HOLDS` column resolves each bridge to a disk number (and any drive letters, in red) by walking `DEVPKEY_Device_Parent` from every disk up to its USB node, which carries the serial and so cannot collide between identical chips. That makes the enclosure holding your chosen disk the *default*, and a busid that holds a different disk is refused unless you confirm it by name.
3. **Matches the block device by size, not by name.** `sdX` letters are handed out in attach order, so yesterday's `/dev/sdd` is today's `/dev/sdc`. The script waits for a device whose size matches the Windows disk (within a few sectors) and reports the letter it actually found, then picks the largest partition on it. On a re-run Windows no longer owns the disk and cannot report a size at all, so it identifies the datastore by its VMFS signature instead: `lsblk` names a `VMFS_volume_member` partition outright, which is a stronger signal than size ever was.
4. **Waits with a visible clock.** Attach and enumeration take anywhere from two to thirty seconds, because the enclosure has to spin up and re-enumerate. A spinner with elapsed seconds is the difference between "working" and "hung", and a timeout ends in a diagnosis rather than a hang: a device listed at `0B` means the enclosure dropped off the bus, which is almost always power.
5. **Unwinds in the right order.** `-Detach` unmounts the FUSE mount first, then detaches the USB device, then brings the disk back online, and tells you which process is holding the mount if the unmount fails.
6. **Inspects datastore contents and VM configs with command line visual effects.** Passing `-Inspect` (or `-View`) provides a terminal inspector with a storage capacity gauge, VM folder breakdown with proportional usage bars, and interactive drilldown into any VM folder. The drilldown displays a VM configuration card (extracting `displayName`, vCPUs, RAM, guest OS, MAC address, and virtual disk paths from `.vmx`), file breakdown with badges (`[VMDK]`, `[VMX]`, `[NVRAM]`, `[LOG]`), and prints the exact ready-to-run copier command for that VM.

> [!NOTE]
> The script never formats, partitions, or writes to the source disk. The only changes it makes on Windows are the disk's online/offline state and the `usbipd` binding, both of which `-Detach` reverses.

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## 🖥 The Copier Script

[`vmfs-copy.sh`](vmfs-copy.sh) is the heart of this repo, an interactive recovery engine that **detects** every VM folder, provides a **smart operations menu**, lets you **select** or **dry-run** your pull, and transfers each VM with the **right engine per file** (`ddrescue` for large flat images, `rsync` for metadata). It is built to be re-run: `ddrescue` mapfiles guarantee an interrupted copy **resumes**, never restarting a disk image from zero.

### Interactive Dashboard & Live Status Card

Running `sudo ./vmfs-copy.sh` with no flags launches the **interactive CLI dashboard**:

```text
  ╔══════════════════════════════════════════════════════════════════════════╗
  ║     VMFS-6 DISK IMAGE EXTRACTION & DATASTORE RECOVERY ENGINE          ║
  ║     Read-Only Source Extraction  •  ddrescue Resumable  •  rsync      ║
  ╚══════════════════════════════════════════════════════════════════════════╝

  ┌────────────────────────────────────────────────────────────────────────┐
  │  ENVIRONMENT & STORAGE STATUS                                          │
  ├────────────────────────────────────────────────────────────────────────┤
  │  Source VMFS:      MOUNTED (LIVE)                                      │
  │    Location:       /mnt/vmfs                                           │
  │    Details:        /dev/sdd1 (fuse.vmfs6, ro,nodev,nosuid)             │
  │  Destination:      /mnt/d                                              │
  │    Free Space:     942.1G available     [████████░░░░░░░░] 52%         │
  │  Recovery Vault:   /mnt/d/.vmfs-recovery                               │
  │    Mapfiles:       3 session mapfile(s) on disk                        │
  │  Engines:          ddrescue: READY              rsync: READY           │
  │  Copy Config:      Big disk threshold: 1024 MB | Keep logs: NO         │
  └────────────────────────────────────────────────────────────────────────┘

  ┌────────────────────────────────────────────────────────────────────────┐
  │  OPERATION SELECTOR                                                    │
  ├────────────────────────────────────────────────────────────────────────┤
  │  [1]  🚀 Copy All Detected VMs (ddrescue + rsync)                       │
  │  [2]  🎯 Select Specific VM(s) to Copy (interactive picker)            │
  │  [3]  📋 Dry-Run Simulation (calculate byte demands & test)            │
  │  [4]  📁 Inspect Source Datastore Folders & Storage Breakdown          │
  │  [5]  🩺 Run Staged VM Verifier (verify-staged.sh audit)                │
  │  [6]  📜 View ddrescue Mapfiles & Recovery Logs                        │
  │  [7]  ⚙️  Configure Transfer Options (Threshold, Engines, Paths)         │
  │  [Q]  🚪 Exit                                                          │
  └────────────────────────────────────────────────────────────────────────┘
```

> [!TIP]
> **Persistent Menu Loop:** Every command pauses with `Press [Enter] to return to Main Menu, or 'q' to exit:`. Pressing **Enter** refreshes the storage gauge and returns straight to the menu.

### What a run looks like

<div align="center">
  <img src="docs/img/copier-detect-and-copy.png" alt="vmfs-copy.sh detection table listing five VM folders with a DEST column reading complete, absent, absent, partial 99% and empty, then ddrescue copying the selected 90.2G flat vmdk at 15269 kB/s with bad:0" width="100%" />
  <br/>
  <em>Detection, selection, space check, copy, all in one pass. The boxed <strong>DEST</strong> column is the whole point of re-running: <code>complete</code> is done, <code>absent</code> has never been touched, <code>partial 99%</code> resumes from the mapfile.</em>
</div>

During extraction, `vmfs-copy.sh` renders animated spinners and a real-time **Unicode block progress bar**:

```text
  ⠋ Scanning /mnt/vmfs ...  ⠙ Probing VM: IP_44.10_MyQ test Server ...

  ┌─────┬──────────────────────────────────────────┬───────────┬─────────┬──────────────────────┐
  │ #   │ VM FOLDER                                │ SIZE      │ DISKS   │ DESTINATION          │
  ├─────┼──────────────────────────────────────────┼───────────┼─────────┼──────────────────────┤
  │ 1   │ IP_44.10_MyQ test Server                 │    94.4G  │ 1 vmdk  │ absent               │
  │ 2   │ Ticketing_System_Production Server       │    61.2G  │ 1 vmdk  │ partial 38%          │
  │ 3   │ 44.20_Software                           │    48.9G  │ 1 vmdk  │ complete (100%)      │
  └─────┴──────────────────────────────────────────┴───────────┴─────────┴──────────────────────┘
  3 folders, 204.5G total to copy. DISKS = .vmdk images >= 1024MB (ddrescue candidates).

  [1/2] Transferring VM: IP_44.10_MyQ test Server
  ────────────────────────────────────────────────────────────────────────
    ddrescue -> MyQ_Server-flat.vmdk (94.4G)
    [████████████████████████████░░░░░░░░░░]  74.19%  118MB/s  bad:0  12m03s
```

<div align="center">

`absent` · `partial 38%` · `complete`, the **DEST** column tells you at a glance what's already been copied, so a resumed run only touches what's left.

</div>

Run it without root and it stops before scanning, because it cannot read the mount at all. It says which problem that is, and prints back the command you typed with `sudo` in front:

```text
  ✗ '/mnt/vmfs' is mounted, but its contents cannot be read.

  This is a permissions problem, not a missing datastore.
  vmfs6-fuse owns the mount as root and does not pass allow_other, so
  reading it needs root. Rerun exactly as you did, with sudo:

       sudo ./vmfs-copy.sh --src /mnt/vmfs --dest /mnt/d

  Nothing needs reattaching or remounting - the datastore is already up.
```

That distinction matters more than it looks: the earlier version tested the mount with `[[ -d ]]`, which is *false* when `stat` returns `EACCES`, so a live datastore was reported as **missing** and the full re-attach runbook was printed for work that was already done.

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## ✅ The Verifier Script

[`verify-staged.sh`](verify-staged.sh) is a **100% read-only pre-flight auditor** that runs inside WSL2 to inspect what landed on your destination drive *before* you import anything into ESXi. It answers the question the copier can't: ***is this actually importable and will it boot?***

Running `./verify-staged.sh` with no flags launches the **interactive verification dashboard**:

```text
  ╔══════════════════════════════════════════════════════════════════════════╗
  ║       VMFS STAGED VM RESTORE VERIFIER & PRE-FLIGHT AUDITOR             ║
  ║      Read-Only Integrity Checks  •  MBR/GPT Probing  •  ESXi Ready     ║
  ╚══════════════════════════════════════════════════════════════════════════╝

  ┌────────────────────────────────────────────────────────────────────────┐
  │  VERIFICATION TARGET & HOST CONFIGURATION                              │
  ├────────────────────────────────────────────────────────────────────────┤
  │  Staged Destination:   /mnt/d                                          │
  │    Staged VMs Found:   3 VM folder(s)  (204.5 GiB flat images)         │
  │  Source Datastore:     /mnt/vmfs             LIVE FUSE MOUNT           │
  │  Target Host RAM:      32768 MB  (ESXi Reserve: 6144 MB | Guest: 26624)│
  │  VM Constraints:       Default (advisory)                              │
  └────────────────────────────────────────────────────────────────────────┘

  ┌────────────────────────────────────────────────────────────────────────┐
  │  OPERATION SELECTOR                                                    │
  ├────────────────────────────────────────────────────────────────────────┤
  │  [1]  🔍 Run Complete 9-Point Verification Suite (All Staged VMs)       │
  │  [2]  🎯 Verify Specific Staged VM Folder (interactive picker)          │
  │  [3]  💾 Audit ESXi Host Resource Budget & Sizing Constraints          │
  │  [4]  📜 Inspect ddrescue Mapfiles & Sector Integrity Logs              │
  │  [5]  🗂️ View VM Descriptors & Flat Extent Byte Alignment               │
  │  [6]  🧹 Scan for Dirty / Temporary Files (*.lck, *.vmem, *.vswp)       │
  │  [7]  ⚙️  Configure Verification Constraints (Host RAM, Limits)         │
  │  [Q]  🚪 Exit                                                          │
  └────────────────────────────────────────────────────────────────────────┘
```

### The 9-Point Verification Suite

1. **Image completeness**: Asserts flat image byte size matches **that VM's own descriptor extent** (`RW <sectors> VMFS`), and confirms `bad areas: 0` in ddrescue mapfiles/logs.
2. **Boot structures**: Extracts sector 0 (protective MBR `0x55aa`) and sector 1 (`EFI PART` GPT header) directly off the copy with micro-spinner probing.
3. **Descriptor agreement**: Validates extent declaration byte-for-byte against the `-flat.vmdk`.
4. **VMX syntax & structure**: Confirms no duplicate keys, strict LF line endings (ESXi rejects CR), and clean `key = "value"` pairs.
5. **Dead-host keys & CD-ROM**: Ensures host-pinned keys (`numa.autosize`, `migrate.hostLog`, `/vmfs/volumes/`) are scrubbed, and CD-ROM is auto-detect and disconnected.
6. **Sizing & core divisibility**: Asserts `cpuid.coresPerSocket` divides evenly into `numvcpus` (ESXi refuses power-on if invalid) and audits guest RAM against host memory with a visual budget gauge:
   ```text
     Host RAM Budget: [██████████████░░░░░░] 68%  (22528 MB of 32768 MB)
     [ ok ] leaves 10 GB for ESXi and headroom
   ```
7. **Identity preservation**: Verifies disk reference is relative (`fileName = "<name>.vmdk"`) and `uuid.bios` is retained.
8. **Reversible backups**: Checks that `.vmx.original` or `.bak-*` files exist and diffs against the live mount.
9. **Must not ship**: Scans for lock files (`*.lck`), memory swap (`*.vswp`), suspend state (`*.vmss`), and snapshot delta chains.

At the end of an audit, a clear verdict card is rendered:

```text
  ┌────────────────────────────────────────────────────────────────────────┐
  │  VERIFICATION AUDIT SUMMARY                                            │
  ├────────────────────────────────────────────────────────────────────────┤
  │  PASS: 19          FAIL: 0           WARN: 0                           │
  ├────────────────────────────────────────────────────────────────────────┤
  │  STATUS: [ ALL CHECKS PASSED - 100% READY FOR ESXi IMPORT ]            │
  └────────────────────────────────────────────────────────────────────────┘
```

### The three things it does that a plain `cp` won't

```mermaid
flowchart LR
    S(["📁 VM folder"]) --> D{"file type?"}
    D -- "*-flat.vmdk<br/>(≥ 1 GB)" --> DD["🩺 ddrescue<br/>-b 512 --retry-passes=3<br/>+ mapfile → resumable"]
    D -- ".vmx .nvram<br/>descriptors" --> RS["📄 rsync -ah<br/>--info=progress2"]
    D -- "*.vswp *.log<br/>*-ctk.vmdk" --> EX["🚫 excluded<br/>(not needed to restore)"]
    DD --> V["✅ verify<br/>size src vs dest"]
    RS --> V
    V --> DONE(["Clean copy on /mnt/d"])

    classDef a fill:#12232e,stroke:#39BAE6,color:#fff;
    classDef b fill:#0f3d2e,stroke:#2ea44f,color:#fff;
    classDef c fill:#3a2a12,stroke:#e0a72e,color:#fff;
    class DD a; class RS a; class EX c; class V,DONE b;
```

1. **`ddrescue` for the big disk images**: retries and works *around* bad sectors instead of failing the whole file. The mapfile records exactly what's been read, so a re-run resumes.
2. **`rsync` for everything small**, running `ddrescue` file-by-file on a 4 KB `.vmx` gains nothing; `rsync` is faster and handles them in one shot.
3. **Excludes what a restore doesn't need**, `*.vswp` swap and `*.log` files are skipped by default (keep the logs with `--keep-logs`).

> [!TIP]
> **Test the plan before committing to it:** `sudo ./vmfs-copy.sh --dry-run` prints the detection table, the space check, and exactly what *would* be copied, and stops. Nothing is written.

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## 📖 Full Walkthrough

<details open>
<summary><strong>Step 1: Identify &amp; offline the drive (Windows)</strong></summary>

> [!TIP]
> [`vmfs-attach.ps1`](vmfs-attach.ps1) does this whole step, including working out which disk is the VMFS one. What follows is the manual equivalent, worth reading once so you know what the script is doing on your behalf.

<br/>

```powershell
usbipd list
```

Confirm the enclosure is present and note its **busid**. Its known fingerprint is **`0bda:9210`**. Then offline the disk so Windows releases its lock before WSL claims it:

```
diskpart
DISKPART> list disk
DISKPART> select disk 1
DISKPART> offline disk
```

> [!IMPORTANT]
> The disk number isn't fixed. Confirm it against the **size** (e.g. 931 GB) in `list disk` every time. Don't assume it's always `disk 1`.

</details>

<details>
<summary><strong>Step 2: Attach to WSL2</strong></summary>

> [!TIP]
> `.\vmfs-attach.ps1` does steps 1 and 2 in one pass, and waits for the device to finish enumerating instead of leaving you to guess how long that takes.

<br/>

```powershell
usbipd attach --wsl --busid 3-2
```

In WSL, give the kernel time to enumerate it before checking:

```bash
sleep 15
lsblk
```

You want the drive at its **real size** (e.g. `931.5G`), not `0B`. A partition like `sdd1` with no mountpoint yet is correct here: attached but not mounted.

</details>

<details>
<summary><strong>Step 3: Mount the VMFS volume</strong></summary>

> [!TIP]
> `.\vmfs-attach.ps1 -Mount` does this step as well, installs `vmfs6-tools` if it is missing, and lists the datastore contents afterwards as proof the mount actually worked.

<br/>

```bash
sudo mkdir -p /mnt/vmfs
sudo vmfs6-fuse /dev/sdd1 /mnt/vmfs
sudo ls -lh /mnt/vmfs          # always sudo, the VM files are root-only
```

A `Lun ID mismatch` warning here is **expected and harmless** (see [Troubleshooting](#-troubleshooting-reference)).

</details>

<details>
<summary><strong>Step 4: Run the copier</strong></summary>

<br/>

```bash
sudo ./vmfs-copy.sh --src /mnt/vmfs --dest /mnt/d
```

Pick folders when prompted (`1 3`, `1-3`, `all`, or `q`). The script handles the per-file engine choice, the progress bar, and the size verification for you. Prefer the manual approach or want to understand what it runs under the hood? The equivalent by hand:

```bash
SRC="/mnt/vmfs"; DEST="/mnt/d"
folder="IP_44.10_MyQ test Server"

sudo mkdir -p "$DEST/$folder" "$DEST/.vmfs-recovery"
# big disk image → ddrescue (resumable via mapfile)
sudo ddrescue -v -b 512 --retry-passes=3 \
  "$SRC/$folder/$folder-flat.vmdk" "$DEST/$folder/$folder-flat.vmdk" \
  "/mnt/d/.vmfs-recovery/${folder// /_}.map"
# everything else → rsync
sudo rsync -avh --progress "$SRC/$folder/" "$DEST/$folder/" \
  --exclude='*-flat.vmdk' --exclude='*.vswp' --exclude='*.log'
```

</details>

<details>
<summary><strong>Step 5: Verify</strong></summary>

<br/>

The script prints a `Verified: … (100.0%)` line per folder. To double-check by hand, every `-flat.vmdk` that went through `ddrescue` should end with:

```
rescued: 96636 MB,   bad areas: 0,   run time: ...
```

**`bad areas: 0`** (equivalently `errsize: 0` in the mapfile) = a clean, complete recovery. If it's non-zero, see [Troubleshooting](#-troubleshooting-reference). And a quick size sanity check:

```bash
sudo du -sh "/mnt/vmfs/$folder"
sudo du -sh "/mnt/d/$folder"
```

</details>

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## ♻ Recovering After a Crash, Power Loss, or WSL Restart

Running multiple `ddrescue`/`rsync` jobs at once against a USB-attached drive, through WSL2's virtualized USB stack, is more fragile than it looks. In practice it has hung WSL and browned out a bus-powered enclosure under combined current draw. This is the recovery sequence, **in order**. Each step assumes the previous one is confirmed working.

```mermaid
flowchart TD
    A(["💥 Freeze / crash / drive dropout"]) --> B["🪟 wsl --list --verbose"]
    B --> C{"WSL still Running?"}
    C -- "No / stuck" --> D["wsl --shutdown, wait ~10s"]
    C -- Yes --> D
    D --> E["🪟 usbipd list,<br/>reattach source if needed"]
    E --> F["🐧 sleep 15; lsblk,<br/>note the CURRENT sdX,<br/>it may have drifted"]
    F --> G["🐧 remount:<br/>sudo vmfs6-fuse /dev/sdX1 /mnt/vmfs"]
    G --> H["🐧 sudo ls -lh /mnt/vmfs,<br/>all folders present?"]
    H --> I{"Did the DESTINATION<br/>drive lose power?"}
    I -- Yes --> J["🪟 chkdsk D: /f"]
    J --> K{"Clean?"}
    K -- No --> K1["Fix FS errors<br/>before writing anything"]
    K -- Yes --> L["🐧 ls /mnt/d"]
    I -- No --> L
    L --> M{"'No such device'?"}
    M -- Yes --> N["sudo mount -t drvfs D: /mnt/d"] --> L
    M -- "lists fine" --> O["▶ sudo ./vmfs-copy.sh, same flags.<br/>Detection shows 'partial %',<br/>ddrescue resumes from mapfile"]

    classDef win fill:#0F2027,stroke:#0078D6,color:#fff;
    classDef nix fill:#1b2b34,stroke:#39BAE6,color:#fff;
    classDef ok  fill:#0f3d2e,stroke:#2ea44f,color:#fff;
    class B,E,J win; class F,G,H,L,N nix; class O ok;
```

<div align="center">
  <img src="docs/img/copier-resume-throughput.png" alt="A re-run of vmfs-copy.sh after an interrupted session: the summary shows the previous VM complete, two stale mapfiles are ignored because the destination file holds 0B, and ddrescue is at 43.92% with bad:0 while Task Manager shows the destination USB disk writing at 9.5 MB/s" width="100%" />
  <br/>
  <em>A re-run after an interrupted session, with the destination drive's own counters beside it. The previous VM is already <code>complete</code>; the two <code>Stale mapfile ignored</code> lines are the guard described in the <a href="#i-deleted-the-recovered-files-but-kept-the-ddrescue-mapfile-will-a-re-run-notice">FAQ</a> refusing to trust a mapfile that claims 90.0G against a 0B file, so this copy correctly starts from zero rather than reporting a finished image in a second.</em>
</div>

> [!NOTE]
> **Why resuming is safe.** `ddrescue` reads its mapfile and only re-attacks sectors not already marked rescued; `rsync` only re-sends files that are missing or changed. Neither restarts from zero. What breaks in a crash isn't the recovery logic; it's the layers underneath (WSL's VM state, the drvfs bridge, the USB attachment, enclosure power) that need re-establishing.

> [!CAUTION]
> **If the destination drive lost power specifically,** a clean `chkdsk /f` confirms the filesystem structure, but *not* that the file being written at the crash is complete to the last byte (a hard power loss can drop the drive's write cache). Treat `bad areas: 0` after resuming, or a final size match against the source, as the real confirmation, not chkdsk alone.

**One habit that prevents most of the confusion here:** run `lsblk` fresh immediately before referencing any `/dev/sdX` path. Device letters drift across detach/reattach cycles; a path that was `sdd1` earlier may be `sde1` later for the exact same physical drive.

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## 🚀 Restoring on ESXi 8

> [!TIP]
> Moving to **different** hardware, or hit a networking wall trying to bench the VMs
> in VMware Workstation first? See **[MIGRATION.md](MIGRATION.md)**. It covers vCPU
> and RAM budgeting for a smaller host, the `.vswp` space nobody accounts for, what
> booting in Workstation changes on disk, and why a guest keeping its old subnet
> cannot be reached from a different one.

> [!CAUTION]
> **If a ransom note turns up on the recovered datastore, the restore changes shape.**
> Copy and verify exactly as described above, since a note does not stop the images
> being readable, but the first power-on then belongs on a portgroup with **no uplink**,
> before any scan and before any credential is reused. The note itself is evidence:
> leave it on the read-only mount, and treat what it tells you to do as the attacker's
> preference rather than advice. [MIGRATION.md](MIGRATION.md) opens with the full
> procedure and the specific checks that distinguish "the boot structures survived"
> from "the guests are clean."

After the copy, each recovered folder should hold: the small text descriptor `VMName.vmdk`, the large `VMName-flat.vmdk`, `VMName.vmx`, `VMName.nvram`, maybe `.vmsd`. (The script excludes `*.vswp` swap and `*.log`; keep logs with `--keep-logs`, harmless, just not needed.)

```mermaid
flowchart LR
    A(["📁 Recovered VM folder"]) --> B["📤 Copy to ESXi 8 datastore<br/>scp / datastore browser"]
    B --> C["📝 Register the VM<br/>vim-cmd / Host Client"]
    C --> D{"'Copied' or 'Moved'<br/>on first boot?"}
    D -- "Copied ✅ (safe default)" --> E["Fresh UUID + MAC"]
    D -- Moved --> F["Keeps identity,<br/>only if no conflict"]
    E --> G["🔌 Reattach NIC to a<br/>valid portgroup"]
    F --> G
    G --> H{"Tied to a<br/>security incident?"}
    H -- Yes --> H1["🛡 Boot on isolated<br/>portgroup, scan first"]
    H -- No --> I(["⚡ Power on"])
    H1 --> I

    classDef step fill:#1b2b34,stroke:#39BAE6,color:#fff;
    classDef warn fill:#3a2012,stroke:#e0672e,color:#fff;
    classDef ok fill:#0f3d2e,stroke:#2ea44f,color:#fff;
    class B,C,E,F,G step; class H1 warn; class I ok;
```

**1. Get the files onto the datastore.**

```bash
# Option A: scp (enable SSH: Host Client → Manage → Services → TSM-SSH → Start)
scp -r "/mnt/d/IP_44.10_MyQ test Server" root@<esxi-host-ip>:/vmfs/volumes/<datastore>/
```
*Option B*: Host Client → Storage → Datastore Browser → **Upload Folder**. Simpler for a one-off, slower for very large files.

**2. Register the VM** (so ESXi uses the recovered disk, not a blank one from the New VM wizard):

```bash
vim-cmd solo/registervm "/vmfs/volumes/<datastore>/IP_44.10_MyQ test Server/IP_44.10_MyQ test Server.vmx"
vim-cmd vmsvc/getallvms
```

**3. Power on & handle first-boot prompts:**

```bash
vim-cmd vmsvc/power.on <Vmid>
```

- Asked **copied vs moved**? Choose **"I copied it"** unless it's a guaranteed 1:1 replacement; "copied" issues a fresh UUID/MAC and avoids conflicts. **If the original host is dead and will never run again, that caveat applies to you: pick "I moved it".** It preserves `uuid.bios` (so Windows activation survives) and the original MAC. A changed MAC makes Windows enumerate a *new* NIC, stranding the guest's static IP on a hidden device that no longer exists. That is the usual reason a restored server comes up with no address.
- The NIC will likely show disconnected (the old portgroup doesn't exist here); fix under VM Settings → Network Adapter.
- A hardware-compatibility complaint → use **Upgrade VM Compatibility**, don't rebuild.

**4. If the descriptor `.vmdk` is missing or suspect,** regenerate it against the flat file rather than hand-editing geometry; this doubles as an integrity check:

```bash
vmkfstools -i "/vmfs/volumes/<datastore>/VMName/VMName.vmdk" \
             "/vmfs/volumes/<datastore>/VMName/VMName-imported.vmdk" -d thin
```

> [!WARNING]
> **Security-incident note.** If this is incident response rather than a plain hardware failure, don't plug the restored VM straight into production. Power it on with the NIC on an **isolated/quarantine** portgroup, let it get scanned, then reconnect. And if any `-flat.vmdk` had a non-zero `errsize`, expect some in-guest damage; run `chkdsk /f` (Windows guest) or `fsck` (Linux) after boot to contain it.

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## 🔧 Troubleshooting Reference

<details>
<summary><strong>🔧 lsblk shows the drive at 0B (or not at all) right after attaching</strong></summary>

<br/>**Cause:** the kernel hasn't finished enumerating the device, or it attached in a mode that triggers a `Read Capacity` failure.

**Fix:**
- Wait longer: `sleep 15`, sometimes 20-30s on a slower enclosure.
- Detach/reattach: `usbipd detach --busid X-Y`, then `usbipd attach --wsl --busid X-Y`.
- Check enumeration in `usbipd list`. A plain `USB Mass Storage Device` (legacy mode) has been more failure-prone than `USB Attached SCSI (UAS) Mass Storage Device`. **UAS mode is the reliable one** for this enclosure.
</details>

<details>
<summary><strong>🔧 The enclosure disappears from <code>usbipd list</code> entirely</strong></summary>

<br/>**Cause:** a USB bus re-enumeration hiccup, usually right after a Windows-side disk state change like offlining it in `diskpart`.

**Fix:** physically unplug and replug the enclosure, then `usbipd list` again. Confirm the VID:PID before attaching: this enclosure is **`0bda:9210`**. A different device coincidentally showing as mass storage isn't it.
</details>

<details>
<summary><strong>🔧 Permission denied on <code>ls /mnt/vmfs</code> right after mounting</strong></summary>

<br/>**Cause:** the mount was done with `sudo`, so the FUSE mount is root-owned with `default_permissions`, and the VM files underneath are `-rw-------` (mode 600), normal for VMFS.

**Fix:** nothing's broken; prefix every command touching `/mnt/vmfs` with `sudo`, and run the copier itself as `sudo ./vmfs-copy.sh`. It routes every read through `sudo` internally and, if you start it unprivileged, caches the credential and refreshes it every 50 seconds so a multi-hour `ddrescue` cannot stall on an expired timestamp.
</details>

<details>
<summary><strong>🔧 The copier says the source "does not exist" but you just mounted it</strong></summary>

<br/>**Cause:** you are not root. `vmfs6-fuse` mounts with `user_id=0` and without `allow_other`, so to any other user *every* path under the mountpoint fails with `EACCES`, and a `[[ -d ]]` test on an `EACCES` path is false. A perfectly good datastore therefore looked absent.

**Fix:** rerun with `sudo`. The script now asks `/proc/mounts` (readable unprivileged) instead of trusting `stat`, so a current version diagnoses this by name and hands you the exact command rather than printing the re-attach runbook.
```bash
sudo ./vmfs-copy.sh --src /mnt/vmfs --dest /mnt/d
```
</details>

<details>
<summary><strong>🔧 <code>-Mount</code> reports the datastore mounted and lists the VMs, but the copier says it "exists but is empty"</strong></summary>

<br/>**Cause:** the two are looking at different **mount namespaces**. A mount belongs to a namespace, not to the machine, and WSL does not put every session in the same one: the `wsl.exe` calls `vmfs-attach.ps1` makes from an elevated PowerShell can land in one namespace while the WSL window you type the copier into sits in another. Both views are honest. `vmfs6-fuse` really is running, `/mnt/vmfs` really does list seven VM folders in the script's session, and in your window `/mnt/vmfs` really is an empty directory. Nothing is stale, so every check phrased as "is it mounted?" answers yes.

Confirm it in one line, comparing the mount namespace of your shell against the one holding the server:

```bash
readlink /proc/self/ns/mnt          # your window
sudo ps -eo pid,args | grep '[v]mfs6-fuse'
sudo readlink /proc/<that-pid>/ns/mnt   # different id = different view
```

A `vmfs6-fuse` alive with `/mnt/vmfs` in its own `/proc/<pid>/mountinfo` and absent from yours is the whole diagnosis.

**Fix:** mount it in the window you are going to copy from, which puts the mount in that window's namespace by construction:

```bash
sudo mkdir -p /mnt/vmfs
sudo vmfs6-fuse /dev/sdX8 /mnt/vmfs
sudo ./vmfs-copy.sh --src /mnt/vmfs --dest /mnt/d
```

A current `vmfs-attach.ps1 -Mount` checks for this before it claims success: it enumerates the mount namespaces that hold a shell, names any that cannot see the mount, and offers to mount into them with `nsenter -t <pid> -m`. A second read-only `vmfs6-fuse` against the same partition is safe. Note that `wsl --shutdown` also clears it, by ending every namespace at once, but it drops the `usbipd` attach with them and you start from step 1.
</details>

<details>
<summary><strong>🔧 The drive reports a different model name on every attach</strong></summary>

<br/>**Cause:** two devices, two identities, and a race between them. A USB-to-NVMe bridge has to fit the drive's model string into the SCSI INQUIRY vendor and product fields, 8 bytes and 16, so a `Force MP600` leaves the bridge split in half:

```bash
cat /sys/block/sdX/device/vendor   # Force MP     <- 8 bytes, full
cat /sys/block/sdX/device/model    # 600
cat /sys/block/sdX/device/rev      # 1.00         <- the bridge, not the drive
```

udev reads the drive underneath directly and publishes the whole string, along with the drive's own serial and firmware:

```bash
udevadm info --query=property --name=/dev/sdX | grep -E 'ID_MODEL|ID_SERIAL_SHORT|ID_REVISION'
# ID_MODEL=Force_MP600
# ID_SERIAL_SHORT=202882290001285556AE
# ID_REVISION=EGFM11.3
```

`lsblk`'s `MODEL`, `SERIAL` and `REV` columns come from the udev database, and udev is still processing the device for a moment after the block node appears, which is exactly when a script that polls for `/dev/sdX` asks. Win the race and you get `Force MP600 202882290001285556AE EGFM11.3`; lose it and you get `600 1.00`. Same drive, same enclosure, different answer.

**Fix:** a current `vmfs-attach.ps1` runs `udevadm settle` first, takes udev's answer, and only falls back to the raw fields if it never arrives, rejoining the halves when the vendor field is full at all 8 bytes, because that is what a split looks like. It also prints the enclosure on its own line, since `ID_USB_SERIAL_SHORT` is the **bridge's** serial and stays the same when you swap the drive inside it:

```
  Drive: Force MP600  serial 202882290001285556AE  fw EGFM11.3
  Enclosure: 0bda:9210 bridge, serial 0129380055F9
```

Whatever the name says, identify the disk by **size and serial**. The `sdX` letter is not stable either: it is assigned in attach order and moves between runs.
</details>

<details>
<summary><strong>🔧 <code>vmfs-attach.ps1</code> asks which disk to offline, and the VMFS disk isn't listed</strong></summary>

<br/>**Cause:** the enclosure is *already* attached to WSL. `usbipd attach` removes the device from Windows, so `Get-Disk` cannot see that disk at all, and the list you're looking at is the other drives on the bench, one of which is your copy destination.

**Fix:** don't pick anything. A current version detects this before step 1 and skips it (`3-2 is already attached to WSL, so Windows no longer owns this disk`), then identifies the datastore inside WSL by its VMFS signature rather than by a size Windows can no longer report. If you're on an older copy, run `.\vmfs-attach.ps1 -DryRun` to see the real state, or `-Detach` to unwind and start clean.
</details>

<details>
<summary><strong>🔧 <code>VMFS: Warning: Lun ID mismatch</code> when mounting</strong></summary>

<br/>**Cause:** the volume's metadata still carries the LUN ID from the original host's controller, which won't match a USB enclosure. Expected any time you read a VMFS volume through different hardware than it was created on.

**Fix:** none needed, it's a warning, not a failure. The mount proceeds.
</details>

<details>
<summary><strong>🔧 rsync (or cp) dies mid-transfer with an I/O error / "file has vanished"</strong></summary>

<br/>**Cause:** a physically bad sector on the source. `rsync`/`cp` don't retry; they fail the file and stop.

**Fix:** confirm with `dmesg | tail -30` (a repeated I/O error at the same LBA). Switch that one file to `ddrescue`, which is exactly what `vmfs-copy.sh` already routes every `-flat.vmdk` through:
```bash
sudo ddrescue -v -b 512 --retry-passes=3 "SOURCE" "DEST" "MAPFILE.map"
```
Everything that already copied cleanly stays copied; no need to redo it.
</details>

<details>
<summary><strong>🔧 ddrescue finishes with a non-zero <code>errsize</code> / bad areas</strong></summary>

<br/>**Cause:** some sectors are permanently unreadable even after retries.

**Options:**
- Re-run the exact same command / re-run `vmfs-copy.sh`; it resumes from the mapfile and only re-attacks bad areas, so another pass is cheap.
- Two-phase for a large file: a fast `ddrescue -n` pass (no retries, grabs everything easy), then a focused retry pass on the same mapfile.
- If it stays non-zero, that data is gone. The mapfile records exactly which regions; repair the rest in-guest post-restore with `chkdsk`/`fsck`.
</details>

<details>
<summary><strong>🔧 Destination drive doesn't show up under <code>/mnt/</code> in WSL</strong></summary>

<br/>**Cause:** either the drive letter isn't initialized on the Windows side, or WSL's automount hasn't picked it up.

**Fix:** confirm it has a letter in Windows Disk Management, then mount manually:
```bash
sudo mkdir -p /mnt/d
sudo mount -t drvfs D: /mnt/d
```
</details>

<details>
<summary><strong>🔧 WSL becomes unresponsive after multiple concurrent jobs</strong></summary>

<br/>**Cause:** several I/O-heavy jobs in parallel through WSL2's virtualized USB stack is fragile; it can hang the WSL VM itself.

**Fix:** from Windows, `wsl --list --verbose` to check whether WSL is actually still running (sometimes it's just the terminal that's stuck). If it's genuinely hung, `wsl --shutdown` resets cleanly, then follow [Recovering After a Crash](#-recovering-after-a-crash-power-loss-or-wsl-restart). Nothing already on disk is lost.

**Prevention:** one copy operation at a time against a given physical drive, which is exactly how `vmfs-copy.sh` runs by design (folders are processed sequentially, never in parallel).
</details>

<details>
<summary><strong>🔧 The USB enclosure disconnects mid-copy (drive drops out)</strong></summary>

<br/>**Cause:** often power, not software: a spinning HDD under multiple concurrent read streams draws more current than one sequential stream. A bus-powered enclosure on a marginal supply can brown out.

**Fix:** reconnect (`usbipd list` → `usbipd attach`), then confirm with `dmesg -T | tail -50`: look for I/O errors or a device reset around that time, and nothing repeating after.

**Prevention:** use the enclosure's own power adapter; if bus-powered only, route through a *powered* USB hub. Short, known-good cable. And one job at a time; the script already enforces that.
</details>

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## 🧾 Exact Error Messages, Decoded

The literal strings this recovery produces, so you can match what's on your screen. Most of them are **not** failures.

| What you see | Where | What it actually means | Do this |
|---|---|---|---|
| `VMFS: Warning: Lun ID mismatch` | `vmfs6-fuse` mount | The volume still records the original host's LUN ID, which a USB enclosure can't match | **Nothing.** It's a warning; the mount succeeds |
| `ls: cannot open directory '/mnt/vmfs': Permission denied` | after mounting | VM files on VMFS are mode `600` and the FUSE mount is root-owned | Prefix with `sudo` (the copier routes its own reads through it) |
| `Source '/mnt/vmfs' does not exist` | copier startup | You are not root, so `stat` on the mount returns `EACCES` and the existence test came back false | Rerun as `sudo ./vmfs-copy.sh`; current versions say "cannot be read" instead |
| `'/mnt/vmfs' is mounted, but its contents cannot be read` | copier startup | The mount is up and root-owned; nothing is broken | Rerun the same command with `sudo` |
| `sudo needs a password and there is no terminal to ask on` | copier startup | Started without a TTY (a wrapper, `nohup`, a hook) so the password prompt had nowhere to go | Rerun as `sudo ./vmfs-copy.sh`, or pre-cache with `sudo -v` first |
| `Busid 3-4 holds disk 2, not disk 1` | `vmfs-attach.ps1` step 2 | The chosen busid is the *other* enclosure; attaching it would take that disk away from Windows | Answer `n` and pick the busid the `HOLDS` column points at with `<-` |
| `lsblk` shows the disk as `0B` | after `usbipd attach` | The kernel hit a `Read Capacity` failure or hasn't finished enumerating | `sleep 15`, then detach and reattach |
| `Input/output error` | mid-copy | A physically unreadable sector on the source | Route that file through `ddrescue`, not `cp`/`rsync` |
| `rsync: ... file has vanished` | mid-copy | Same bad-sector read failure, reported by `rsync` | Confirm with `dmesg \| tail -30`, then use `ddrescue` |
| `bad areas: 1` (or any non-zero `errsize`) | end of `ddrescue` | Sectors that stayed unreadable after retries | Re-run to retry cheaply; if it persists, that data is gone |
| `ls: cannot access '/mnt/d': No such device` | destination | WSL's `drvfs` bridge to the Windows drive dropped | `sudo mount -t drvfs D: /mnt/d` |
| `/dev/sdd1 does not exist` | remount after a crash | The device letter drifted across reattach | Run `lsblk` fresh and use the **current** `sdX` |
| `/usr/bin/env: 'bash\r': No such file or directory` | running the script | The file was saved with Windows CRLF line endings | `sed -i 's/\r$//' vmfs-copy.sh` (this repo pins LF via `.gitattributes`) |
| `The disk is offline because of policy set by an administrator` | Windows `diskpart` | Expected, you offlined it on purpose so WSL can claim it | Nothing; this is the goal |
| `This virtual machine might have been moved or copied` | ESXi first boot | ESXi noticed a new UUID/path | Answer **"I copied it"** unless it's a guaranteed 1:1 replacement |
| `Failed to lock the file` | ESXi power-on | The disk is already registered or held by another VM | Unregister the duplicate, then power on |

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## ❓ Frequently Asked Questions

### Can Windows read a VMFS drive?

No. Windows has no native VMFS driver, so a VMFS disk appears in Disk Management as a healthy partition with **no drive letter and no recognized filesystem**, and Windows offers to format it. Nothing is wrong with the disk. Windows just can't parse VMFS. **Do not let it format the disk.** Read it from Linux instead: this repo passes the disk into WSL2 and mounts it with `vmfs6-fuse`.

### How do I mount a VMFS6 datastore on Windows 11?

Through WSL2, in four steps: offline the disk in `diskpart` so Windows releases its lock, share and attach it with `usbipd attach --wsl --busid X-Y`, confirm it appears at full size in `lsblk`, then mount it inside Linux with `sudo vmfs6-fuse /dev/sdX1 /mnt/vmfs`. Every command touching the mount needs `sudo`, because VMFS files are mode `600`.

### Can I recover VMs from a VMFS disk without an ESXi host?

Yes. You never need a hypervisor to *read* the disk, `vmfs6-fuse` in WSL2 is enough to mount the datastore and copy the VM folders off. You only need an ESXi host at the end, to *run* the recovered VM. The recovered folder is ordinary files, so you can keep it on an NTFS drive indefinitely and restore it whenever a host is available.

### Should I use ddrescue or rsync to copy a VMDK?

Use **`ddrescue` for the large `-flat.vmdk` disk images** and **`rsync` for everything else**. `rsync` and `cp` abort the whole file on the first unreadable sector, which is exactly the wrong behavior on a drive you suspect is dying. `ddrescue` retries, works *around* bad sectors, and records progress in a mapfile so an interrupted copy resumes. For 4 KB `.vmx` and descriptor files `ddrescue` buys nothing, and `rsync` moves them in one pass.

### How do I resume an interrupted ddrescue copy?

Re-run the **exact same command with the same mapfile path**. `ddrescue` reads the mapfile, skips every range already marked rescued, and attacks only the gaps. Re-running `vmfs-copy.sh` with the same flags does this automatically. The one thing that breaks resume is losing the mapfile, which is why this script keeps mapfiles next to the **destination** (`<dest>/.vmfs-recovery`) rather than under `$HOME`, since running under `sudo` changes `$HOME` to `/root` and would look in the wrong directory.

### Does resuming a ddrescue copy re-read everything first?

No, and it doesn't take twice as long. Already-rescued ranges are skipped without being read or rewritten, a resumed run of a finished image reports `tried: 0 B` and completes in about a second. A hard crash can cost at most the last mapfile flush (roughly 30 seconds of progress). Note that the log line `Starting positions: infile = 0 B, outfile = 0 B` appears even on a perfect resume, so it does **not** mean a restart, check `tried:` instead.

### Why does a folder show "partial" when the copy already finished?

Because a percentage measured against the *raw* source size can never reach 100% once files are deliberately excluded. `vmfs-copy.sh` skips `*.vswp` swap files, `*-ctk.vmdk` change-tracking maps, and `*.log`, so a folder holding a 24 GB `.vswp` would read "partial" forever. The script now compares **copyable** bytes on both sides, so a genuinely complete folder reports `complete`. A real shortfall is still flagged.

### Do I need the .vswp file to restore a VM?

No. A `.vswp` file is the VM's memory swap, created fresh by the host at power-on and meaningless once the VM is off. It's also frequently the largest file in the folder, often tens of gigabytes, so copying it wastes hours and space. The same goes for `*-ctk.vmdk` change-tracking files and `vmware-*.log`. All are excluded by default.

### What does `bad areas: 0` mean in ddrescue output?

It means **every sector was read successfully, a clean, complete recovery.** It's the single number worth checking before you trust a recovered disk image; the equivalent field in the mapfile is `errsize: 0`. A matching file size is reassuring but weaker: a size match only proves the right number of bytes exist, while `bad areas: 0` proves they were all actually read from the source.

### ESXi asks "I copied it" or "I moved it" on first boot, which do I pick?

Pick **"I copied it"**. That issues a fresh UUID and MAC address, which avoids colliding with the original VM if it ever comes back online. Choose "I moved it" only when this host is a guaranteed 1:1 replacement and the original will never run again, it preserves the identity, including the MAC, which is what you want if something is licensed to it.

### Is it safe to mount a VMFS volume with vmfs6-fuse?

Mounting is safe, and this workflow only ever reads. Treat the source as strictly read-only for the duration of a recovery: never write to `/mnt/vmfs`, never repartition or "repair" the source disk, and get a verified copy off it first. If the drive is degrading, every extra read costs you something, which is why resume support matters, and why running one copy at a time is deliberate.

### Does this work on VMFS5 instead of VMFS6?

Yes, with a different FUSE driver. Use `vmfs-fuse` from **`vmfs-tools`** for VMFS3/VMFS5 volumes, and `vmfs6-fuse` from **`vmfs6-tools`** for VMFS6. Everything downstream, the `ddrescue` and `rsync` strategy, `vmfs-copy.sh`, the ESXi 8 restore, is identical, since it all operates on ordinary files once the volume is mounted.

### Why does WSL2 hang during a large USB copy?

Because several I/O-heavy jobs running at once through WSL2's virtualized USB stack is fragile enough to hang the WSL VM itself, and a bus-powered enclosure can brown out under the combined current draw of multiple read streams. Run **one copy at a time** against a given physical drive, `vmfs-copy.sh` processes folders sequentially by design, and power the enclosure from its own adapter or a powered hub.

### Do I have to take the disk offline in Windows before attaching it to WSL?

Yes. While Windows holds the disk online it keeps the device claimed, and `usbipd bind` or `usbipd attach` will report the device as in use. Offline it first with `diskpart` (`select disk N`, `offline disk`) or let [`vmfs-attach.ps1`](vmfs-attach.ps1) do it. Offline is also the safer state: while the VMFS disk is online, Windows repeatedly offers to format it, because it cannot read the filesystem.

### Do I have to run the copier with sudo?

In practice, yes. `vmfs6-fuse` mounts the datastore as root without `allow_other`, so every path under `/mnt/vmfs` returns `EACCES` to anyone else. The copier routes each read through `sudo` internally, so starting it as your normal user *can* work, it caches the credential and refreshes it every 50 seconds so a multi-hour `ddrescue` cannot stall on an expired timestamp. `sudo ./vmfs-copy.sh` is still the better habit: it removes that dependency entirely, and it cannot be caught by a password prompt with no terminal to answer it.

### Is it safe to re-run `vmfs-attach.ps1` after a successful attach?

Yes, and it's the normal way to add `-Mount` to an attach you already did. It detects that the enclosure is already handed to WSL and skips the offline step rather than asking you to pick a disk, which matters because `usbipd attach` removes the device from Windows: at that point `Get-Disk` lists only the *other* drives on the bench, one of which is your copy destination. Every step is idempotent, an already-bound device isn't re-bound, an already-mounted datastore isn't remounted.

### Does the copier script handle the diskpart and usbipd steps?

No, and it cannot. `vmfs-copy.sh` runs inside WSL, and `diskpart` and `usbipd` are Windows executables that need an elevated Windows shell, so from inside WSL there is no way to offline a Windows disk or bind a USB device to itself. That is what [`vmfs-attach.ps1`](vmfs-attach.ps1) is for. If the datastore is not mounted, the copier now refuses to start and prints all three prerequisite steps, because a missed step and an empty datastore look identical from inside WSL.

### I deleted the recovered files but kept the ddrescue mapfile. Will a re-run notice?

Yes. A mapfile is a claim about the content of one specific output file, so if that file was deleted or truncated the claim is void: acting on it would make `ddrescue` skip every range marked rescued without reading it, then report a finished copy over a missing or half-written disk image, in about a second. `vmfs-copy.sh` compares the highest offset the mapfile vouches for against the actual size of the destination file, and ignores the mapfile if the file is smaller or gone:

```text
  [! ] Stale mapfile ignored: /home/you/VM-map.log
      claims 90.0G already written here, but the file holds 0B.
```

The copy then starts from zero, which is correct, because there is nothing on the destination to resume onto.

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## 🎛 Script Reference (flags & internals)

### `vmfs-attach.ps1` (Windows, elevated)

```text
.\vmfs-attach.ps1 [options]
```

| Flag | Default | Does |
|---|---|---|
| `-Mount` | off | Also mount the datastore with `vmfs6-fuse` after attaching |
| `-Menu` | off | Force launch interactive action suite dashboard |
| `-Inspect` | off | Select and view datastore contents, VM configs & sizes with visual effects |
| `-Test` | off | Run comprehensive VMFS6 filesystem health, allocation & descriptor integrity test |
| `-Cycle` | off | Full cycle: unmount, detach enclosure, re-attach to WSL, mount & test filesystem |
| `-Detach` | off | Reverse everything: unmount, `usbipd detach`, bring the disk online (with option to re-test) |
| `-BusId <id>` | auto-detect | Skip enclosure detection, e.g. `3-2` |
| `-DiskNumber <n>` | auto-detect | Skip disk detection, e.g. `2` |
| `-Src <path>` | `/mnt/vmfs` | Mount point to create inside WSL |
| `-Dest <path>` | `/mnt/d` | Destination drive, used only in the closing hint |
| `-Distro <name>` | default distro | Which WSL distro to work in |
| `-Yes` | off | Accept the detected defaults, no prompts |
| `-DryRun` | off | Print every action, change nothing. The only mode that runs **unelevated**, so you can read the plan from a normal shell |
| `-TimeoutSec <n>` | `90` | How long to wait for attach and for the block device to appear |

### `vmfs-copy.sh` (WSL)

```text
sudo ./vmfs-copy.sh [options]
```

| Flag | Default | Does |
|---|---|---|
| `--src <path>` | `/mnt/vmfs` | Where `vmfs6-fuse` mounted the datastore |
| `--dest <path>` | `/mnt/d` | Destination drive |
| `--mapdir <path>` | `<dest>/.vmfs-recovery` | Where `ddrescue` mapfiles + per-file logs live |
| `--big-mb <N>` | `1024` | `.vmdk` files ≥ N MB go through `ddrescue`; smaller via `rsync` |
| `--all`, `-a` | off | Select every folder, skip the picker |
| `--yes`, `-y` | off | Assume "yes" to the start/space prompts |
| `--no-ddrescue` | off | `rsync` everything (faster, **no** bad-sector retry) |
| `--keep-logs` | off | Also copy `vmware-*.log` files |
| `--dry-run`, `-n` | off | Print the plan + space check, copy nothing |
| `--no-sudo` | off | Already root / source is readable, call tools directly |
| `--menu`, `-m` | off | Force launch interactive operations menu dashboard |
| `--help`, `-h` | (none) | Usage |

**Design choices baked in:**

- 🔁 **Resumable by default**, mapfiles persist in `--mapdir`; re-running never restarts a disk image from zero.
- 🧮 **Space check before it starts**, refuses (or warns) if the selection won't fit on the destination.
- 🎚 **Sequential, never parallel**, one folder at a time, because concurrent USB I/O is what browns out enclosures and hangs WSL.
- 🧾 **Verifies every folder**, compares apparent size of source vs destination and flags any real shortfall (excluded `.vswp`/`.log` are accounted for).
- 🖱 **Flexible selection**, `1 3`, ranges `1-3`, `all`, or `q` to bail; de-duplicates overlapping picks.
- 🎨 **Degrades gracefully**, no `ddrescue`? Falls back to `rsync`. No TTY? Drops the colors. Not root and no `sudo`? Warns instead of dying.
- 🧭 **Persistent Menu Loop**, every action returns to the interactive dashboard when Enter is pressed.

> [!NOTE]
> **Common flag combos.** `--all --yes` = unattended full pull. `--dry-run` = see the plan, touch nothing. `--big-mb 512` = treat 512 MB+ images as `ddrescue` candidates. `--no-ddrescue` = healthy drive, want speed over bad-sector resilience.

### `verify-staged.sh` (WSL)

```text
./verify-staged.sh [options]
```

| Flag | Default | Does |
|---|---|---|
| `--dest <path>` | `/mnt/d` | Destination drive holding staged VM folders |
| `--src <path>` | `/mnt/vmfs` | Source mount point for live baseline `.vmx` diffs |
| `--vm <name>` | all VMs | Verify a single specific VM folder under `--dest` |
| `--ram <MB>` | advisory | Enforce exact `memSize` per VM |
| `--vcpu <N>` | advisory | Enforce exact `numvcpus` per VM |
| `--host-ram <MB>` | `32768` | Host physical RAM in MB for guest budget calculations |
| `--menu`, `-m` | off | Force launch interactive verification dashboard |
| `--help`, `-h` | (none) | Usage |

Read-only pre-flight on what the copier produced, run **before** you import anything. It answers the question the copier can't: *is this actually importable?* Every folder holding a `-flat.vmdk` is checked, whatever its size.

- 📏 **Image completeness**, exact byte size against **that VM's own descriptor extent**, so a 90 GiB image and a 256 GiB one are each measured against what their own `RW <sectors> VMFS` line declares. Plus `# Finished` and `bad areas: 0` from the ddrescue mapfile and log.
- 🧬 **Boot structures survived**, checks the protective MBR signature and the `EFI PART` GPT header **on the destination copy**, not the source. That is the difference between "ddrescue reported success" and "the image will boot".
- 🧾 **vmx sanity**, no duplicate keys, LF endings, every line parsing as `key = "value"`.
- 🧹 **Dead-host keys gone**, `numa.autosize.*`, `migrate.hostLog`, `sched.swap.derivedName`, and any surviving absolute `/vmfs/volumes/` path. The CD-ROM check finds whichever device declares itself an `atapi-cdrom`, on `sata`, `ide`, or `scsi`, and passes a VM that has no CD-ROM at all.
- ⚙️ **The rule that stops power-on**, asserts `cpuid.coresPerSocket` divides evenly into `numvcpus`, and totals guest RAM against `--host-ram` (default 32768 MB) less the ~6 GB ESXi keeps for itself.
- 🔒 **Sizing you asked for, not sizing it assumed**, `--ram` and `--vcpu` are enforced only when you pass them. Left off, the values are reported rather than judged, because there is no generally correct `memSize` for someone else's VM.
- 🗄 **Backups kept**, confirms an untouched original still sits beside every edited file, and diffs it against the live mount where both are available.

Safe to run while a copy is still in progress. An unfinished image is a warning, not a failure, and that extends to the boot structures: a missing MBR on a half-written image is reported as "recheck at the end", and only counts against a copy that has reached its declared size. Exits non-zero if anything fails, so it works as a gate in front of `ovftool`.

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## 🗒 Field Notes

- These are **personal field notes from a real recovery session**, not official VMware/Broadcom documentation, cross-check anything safety-critical against current vendor docs, especially exact CLI flags, which shift between ESXi releases.
- **Busid numbers, `/dev/sdX` letters, drive letters, and folder names will all differ next time.** Only the *shape* of the process stays the same, that's what the diagrams and the script are for.
- **Known-good enclosure:** `0bda:9210` (Realtek UAS bridge). It's shown power sensitivity under concurrent multi-stream I/O, run one copy operation at a time against it. The script does this by default.
- **`bad areas: 0` is the number that matters.** A size match is a good sign; a clean `ddrescue` summary is the proof.
- **Last verified: 25 August 2026**. Windows 11 Pro (build 26200), WSL2 Ubuntu, GNU `ddrescue` 1.27, against a 931 GB VMFS6 volume in a Realtek `0bda:9210` enclosure.
- **Machine-readable summaries live alongside this README**, [`llms.txt`](llms.txt) for LLMs and answer engines, [`CITATION.cff`](CITATION.cff) if you need to cite this.

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## 🙋 Author & License

<div align="center">

**Anik Sarker Akash**

<a href="https://github.com/aniksarakash"><img src="https://img.shields.io/badge/GitHub-@aniksarakash-181717?style=for-the-badge&logo=github&logoColor=white" alt="GitHub profile: @aniksarakash" /></a>

Released under the **MIT License**, use it, adapt it, recover your data with it.

</div>

<br/>

<img src="https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/rainbow.png" alt="" width="100%" />

## 🔎 Also Known As

The phrasings people actually use for this problem. If any of these is what you searched for, you're in the right place.

**The filesystem**. VMFS · VMFS6 · VMFS5 · **VFMS** *(common transposition of VMFS)* · Virtual Machine File System · VMware datastore · `-flat.vmdk` · flat VMDK · VMDK descriptor file · `.vmx` · `.nvram`

**The situation**, recover a VMware VM from a bare VMFS drive · read a VMFS disk on Windows · VMFS drive shows no filesystem in Disk Management · Windows wants to format my VMFS disk · drive pulled from a dead ESXi host · recover VMs without an ESXi host · ESXi host failed but the disk is fine · decommissioned ESXi host data recovery · VMFS datastore in a USB enclosure · read a VMware datastore without vSphere · get VMs off a hypervisor that won't boot

**The tooling**, mount VMFS in WSL2 · `vmfs6-fuse` · `vmfs6-tools` · `vmfs-fuse` · `usbipd-win` · `usbipd attach --wsl` · WSL2 USB passthrough · `diskpart offline disk` · `drvfs` · `ddrescue` VMDK bad sectors · GNU ddrescue mapfile · resume an interrupted ddrescue · `rsync` exclude `.vswp` · Realtek `0bda:9210` UAS enclosure

**The restore**, register a recovered VM on ESXi 8 · `vim-cmd solo/registervm` · `vmkfstools -i` to regenerate a descriptor · "I copied it" vs "I moved it" · reattach the NIC portgroup after a restore · upgrade VM compatibility

**Adjacent problems this covers**. VMFS data recovery on Windows 11 · virtual machine disaster recovery runbook · bad-sector recovery for very large disk images · resumable multi-hundred-gigabyte copy over USB · post-incident ESXi recovery onto a quarantine portgroup

<br/>

<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:2C5364,50:203A43,100:0F2027&height=120&section=footer&text=bad%20areas%3A%200&fontSize=26&fontColor=ffffff&fontAlignY=70&animation=twinkling" alt="bad areas: 0 - a clean recovery" width="100%" />
</div>
