#!/usr/bin/env bash
#===============================================================================
# vmfs-copy.sh - interactive VMFS -> destination VM recovery copier
#
# Pulls VM folders off a mounted VMFS datastore onto a destination drive:
# large disk images go through ddrescue (retries + resumable via mapfile),
# small metadata files go through rsync. Live progress bar for both.
#
# Run inside WSL2, AFTER vmfs6-fuse has mounted the datastore.
# Companion to the VMFS-on-USB Recovery & ESXi 8 Restore Playbook.
#
#   ./vmfs-copy.sh                          # interactive menu & dashboard
#   ./vmfs-copy.sh --all --yes              # copy everything, no prompts
#   ./vmfs-copy.sh --src /mnt/vmfs --dest /mnt/d
#   ./vmfs-copy.sh --dry-run                # show the plan, copy nothing
#   ./vmfs-copy.sh --no-ddrescue            # rsync everything (faster, no retry)
#   ./vmfs-copy.sh --big-mb 512             # ddrescue threshold
#   ./vmfs-copy.sh --keep-logs              # also copy vmware-*.log
#   ./vmfs-copy.sh --no-sudo                # already root / source readable
#   ./vmfs-copy.sh --mapdir /mnt/d/.maps    # where ddrescue mapfiles live
#   ./vmfs-copy.sh --menu                   # force interactive menu mode
#===============================================================================

set -uo pipefail

# Locate directory of this script so we can reference companion tools (like verify-staged.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#------------------------------------------------------------------------------
# Defaults - override with flags or interactive menu
#------------------------------------------------------------------------------
SRC="/mnt/vmfs"                   # where vmfs6-fuse mounted the datastore
DEST="/mnt/d"                     # destination drive
MAPDIR=""                         # ddrescue mapfiles + logs; default <DEST>/.vmfs-recovery
BIG_MB=1024                       # files >= this many MB go through ddrescue
ASSUME_ALL=0
ASSUME_YES=0
USE_DDRESCUE=1
KEEP_LOGS=0                       # keep vmware-*.log files from source folder
DRY_RUN=0
NO_SUDO=0                         # skip sudo (already root, or source is world-readable)
FORCE_MENU=0
BAR_W=38

#------------------------------------------------------------------------------
# Arg parsing
#------------------------------------------------------------------------------
usage() { sed -n '2,22p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0; }

ORIG_ARGS=("$@")

while (($#)); do
  case $1 in
    --src)          SRC=${2:?missing value}; shift 2 ;;
    --dest)         DEST=${2:?missing value}; shift 2 ;;
    --mapdir)       MAPDIR=${2:?missing value}; shift 2 ;;
    --big-mb)       BIG_MB=${2:?missing value}; shift 2 ;;
    --all|-a)       ASSUME_ALL=1; shift ;;
    --yes|-y)       ASSUME_YES=1; shift ;;
    --no-ddrescue)  USE_DDRESCUE=0; shift ;;
    --keep-logs)    KEEP_LOGS=1; shift ;;
    --dry-run|-n)   DRY_RUN=1; shift ;;
    --no-sudo)      NO_SUDO=1; shift ;;
    --menu|-m)      FORCE_MENU=1; shift ;;
    -h|--help)      usage ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

MAPDIR=${MAPDIR:-"$DEST/.vmfs-recovery"}

# Interactive menu loop is active if invoked interactively without automated run flags
MENU_LOOP=0
if [[ -t 0 && -t 1 ]] && (( !ASSUME_YES && !ASSUME_ALL )) || (( FORCE_MENU )); then
  MENU_LOOP=1
fi

#------------------------------------------------------------------------------
# Cosmetics & UI Styling
#------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  CY=$'\033[38;5;39m'; GR=$'\033[38;5;41m'; YL=$'\033[38;5;214m'; RD=$'\033[38;5;203m'
  MG=$'\033[38;5;177m'; WH=$'\033[38;5;255m'
  BD=$'\033[38;5;244m' # subtle border
else
  B=''; DIM=''; R=''; CY=''; GR=''; YL=''; RD=''; MG=''; WH=''; BD=''
fi

hr()   { printf '  %s\n' "${DIM}────────────────────────────────────────────────────────────────────────${R}"; }
info() { printf '%s\n' "  $*"; }
ok()   { printf '%s\n' "  ${GR}[ ok ]${R} $*"; }
warn() { printf '%s\n' "  ${YL}[!   ]${R} $*"; }
err()  { printf '%s\n' "  ${RD}[FAIL]${R} $*" >&2; }
die()  {
  err "$*"
  if ((MENU_LOOP)); then
    return_or_exit 1
  else
    exit 1
  fi
}

human() {
  awk -v b="${1:-0}" 'BEGIN{
    split("B K M G T P", u, " "); i=1
    while (b>=1024 && i<6) { b/=1024; i++ }
    if (i==1) printf "%dB", b; else printf "%.1f%s", b, u[i]
  }'
}

bar_str() {   # $1 filled  $2 empty
  local s='' i
  for ((i=0; i<$1; i++)); do s+='█'; done
  for ((i=0; i<$2; i++)); do s+='░'; done
  printf '%s' "$s"
}

draw_bar() {  # $1 pct  $2 suffix
  local pct=${1:-0} suffix=${2:-} filled
  [[ $pct =~ ^[0-9.]+$ ]] || pct=0
  filled=$(awk -v p="$pct" -v w="$BAR_W" 'BEGIN{f=int(p*w/100); if(f<0)f=0; if(f>w)f=w; print f}')
  local empty=$((BAR_W - filled))
  printf '\r    %s[%s%s%s%s]%s %6.2f%%  %s\033[K' \
    "$BD" "$GR" "$(bar_str "$filled" 0)" "$DIM" "$(bar_str 0 "$empty")" "$R" "$pct" "$suffix"
}

# Navigation helper: return to menu or exit
return_or_exit() {
  local code=${1:-0}
  if ((MENU_LOOP)); then
    printf '\n'
    hr
    local ans=""
    read -r -p "  Press [Enter] to return to Main Menu, or 'q' to exit: " ans
    if [[ $ans =~ ^[qQ] ]]; then
      printf '\n  %sExited.%s\n\n' "$DIM" "$R"
      exit "$code"
    fi
    return 0
  else
    exit "$code"
  fi
}

#------------------------------------------------------------------------------
# Cleanup / sudo keepalive
#------------------------------------------------------------------------------
KEEPALIVE_PID=""
cleanup() {
  [[ -n $KEEPALIVE_PID ]] && kill "$KEEPALIVE_PID" 2>/dev/null
  printf '\033[?25h'
}
trap cleanup EXIT
trap 'printf "\n"; err "Interrupted. Recovery progress is safely preserved on disk."; exit 130' INT TERM

#------------------------------------------------------------------------------
# Preflight & Escalation
#------------------------------------------------------------------------------
ensure_sudo() {
  SUDO="sudo"
  if ((NO_SUDO)) || [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    SUDO=""
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    SUDO=""
    warn "sudo not found - continuing unprivileged. VMFS files are normally root-only (mode 600);"
    return 0
  fi

  if sudo -n -v 2>/dev/null; then
    :
  elif [[ -t 0 ]]; then
    sudo -v || { err "sudo authentication failed. Rerun as root, or with --no-sudo."; return 1; }
  else
    warn "sudo credentials not cached and stdin is piped. Proceeding unprivileged."
    SUDO=""
  fi

  if [[ -z $KEEPALIVE_PID ]] || ! kill -0 "$KEEPALIVE_PID" 2>/dev/null; then
    ( while true; do sudo -n true 2>/dev/null; sleep 50; done ) & KEEPALIVE_PID=$!
  fi
  return 0
}

src_is_mounted() {
  awk -v want="$1" '$2 == want { hit = 1 } END { exit !hit }' /proc/mounts 2>/dev/null
}

check_environment_prereqs() {
  ensure_sudo || return 1

  command -v rsync >/dev/null 2>&1 \
    || { err "rsync not found. Install it first: sudo apt install rsync"; return 1; }

  if ((USE_DDRESCUE)) && ! command -v ddrescue >/dev/null 2>&1; then
    warn "ddrescue not found - falling back to rsync for large files."
    warn "Install for bad-sector resilience: sudo apt install gddrescue"
    USE_DDRESCUE=0
  fi

  [[ -d $DEST ]] || {
    err "Destination '$DEST' does not exist. Mount it first: sudo mkdir -p $DEST && sudo mount -t drvfs D: $DEST"
    return 1
  }

  mkdir -p "$MAPDIR" 2>/dev/null || $SUDO mkdir -p "$MAPDIR" 2>/dev/null || {
    err "Cannot create mapfile directory '$MAPDIR' (override with --mapdir)"
    return 1
  }
  return 0
}

# Attach runbook guidance when datastore is unmounted
attach_help() {
  printf '\n  %s\n' "${B}The datastore must be attached and mounted before copying:${R}"
  printf '  %s\n' \
    "  ${CY}1.${R} Windows PowerShell (Admin) - launch the attach helper:" \
    "       .\\vmfs-attach.ps1" \
    "" \
    "  ${CY}2.${R} Or attach manually from Windows Admin PowerShell:" \
    "       usbipd attach --wsl --busid <BUSID>" \
    "" \
    "  ${CY}3.${R} Mount VMFS6 inside WSL (read-only FUSE driver):" \
    "       sudo mkdir -p $SRC" \
    "       sudo vmfs6-fuse /dev/sdX1 $SRC" \
    ""
}

#------------------------------------------------------------------------------
# Dashboard Header & Environment Status Card
#------------------------------------------------------------------------------
show_header() {
  printf '\n'
  printf '  %s╔══════════════════════════════════════════════════════════════════════════╗%s\n' "$CY" "$R"
  printf '  %s║%s     %sVMFS-6 DISK IMAGE EXTRACTION & DATASTORE RECOVERY ENGINE%s          %s║%s\n' "$CY" "$R" "$B$WH" "$R" "$CY" "$R"
  printf '  %s║%s     %sRead-Only Source Extraction  •  ddrescue Resumable  •  rsync%s      %s║%s\n' "$CY" "$R" "$DIM" "$R" "$CY" "$R"
  printf '  %s╚══════════════════════════════════════════════════════════════════════════╝%s\n' "$CY" "$R"
}

show_environment_card() {
  local src_st="${RD}UNMOUNTED / INACTIVE${R}"
  local src_detail="Not detected in /proc/mounts"
  local dev_line=""

  if src_is_mounted "$SRC"; then
    if $SUDO ls -A "$SRC" >/dev/null 2>&1; then
      src_st="${GR}${B}MOUNTED (LIVE)${R}"
      dev_line=$(awk -v m="$SRC" '$2 == m {print $1 " (" $3 ", " $4 ")"}' /proc/mounts 2>/dev/null)
      src_detail="${dev_line:-fuse.vmfs6}"
    else
      src_st="${YL}${B}MOUNTED (ROOT ONLY)${R}"
      src_detail="Accessible via sudo only"
    fi
  elif [[ -d $SRC ]] && [[ -n $($SUDO ls -A "$SRC" 2>/dev/null) ]]; then
    src_st="${YL}${B}ACTIVE (NOT MOUNTPOINT)${R}"
    src_detail="Directory has content"
  fi

  local d_free d_total d_used_pct
  d_free=$(df -B1 --output=avail "$DEST" 2>/dev/null | tail -1 | tr -d ' ')
  d_free=${d_free:-0}
  d_total=$(df -B1 --output=size "$DEST" 2>/dev/null | tail -1 | tr -d ' ')
  d_total=${d_total:-0}
  if ((d_total > 0)); then
    d_used_pct=$(( (d_total - d_free) * 100 / d_total ))
  else
    d_used_pct=0
  fi

  local gauge_w=16
  local g_fill=$(( d_used_pct * gauge_w / 100 ))
  local g_empty=$(( gauge_w - g_fill ))
  local g_bar=""
  local gi
  for ((gi=0; gi<g_fill; gi++)); do g_bar+='█'; done
  local g_dim=""
  for ((gi=0; gi<g_empty; gi++)); do g_dim+='░'; done
  local gauge_str="[${CY}${g_bar}${DIM}${g_dim}${R}] ${d_used_pct}%"

  local ddr_st="${GR}READY${R}"
  if ! command -v ddrescue >/dev/null 2>&1; then
    ddr_st="${YL}NOT INSTALLED (apt install gddrescue)${R}"
  elif ((!USE_DDRESCUE)); then
    ddr_st="${DIM}DISABLED (--no-ddrescue)${R}"
  fi

  local rsync_st="${GR}READY${R}"
  command -v rsync >/dev/null 2>&1 || rsync_st="${RD}MISSING (apt install rsync)${R}"

  local n_maps=0
  if [[ -d $MAPDIR ]]; then
    n_maps=$(find "$MAPDIR" -maxdepth 1 -type f \( -name '*.map' -o -name '*.mapfile' \) 2>/dev/null | wc -l | tr -d ' ')
  fi

  printf '\n'
  printf '  %s┌────────────────────────────────────────────────────────────────────────┐%s\n' "$BD" "$R"
  printf '  %s│%s  %sENVIRONMENT & STORAGE STATUS%s                                           %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$BD" "$R"
  printf '  %s├────────────────────────────────────────────────────────────────────────┤%s\n' "$BD" "$R"
  printf '  %s│%s  Source VMFS:      %-35b  %s│%s\n' "$BD" "$R" "$src_st" "$BD" "$R"
  printf '  %s│%s    Location:       %-53s %s│%s\n' "$BD" "$R" "$SRC" "$BD" "$R"
  printf '  %s│%s    Details:        %-53.53s %s│%s\n' "$BD" "$R" "$src_detail" "$BD" "$R"
  printf '  %s│%s  Destination:      %-53s %s│%s\n' "$BD" "$R" "$DEST" "$BD" "$R"
  printf '  %s│%s    Free Space:     %-20s %-32b %s│%s\n' "$BD" "$R" "$(human "$d_free") available" "$gauge_str" "$BD" "$R"
  printf '  %s│%s  Recovery Vault:   %-53s %s│%s\n' "$BD" "$R" "$MAPDIR" "$BD" "$R"
  printf '  %s│%s    Mapfiles:       %-53s %s│%s\n' "$BD" "$R" "$n_maps session mapfile(s) on disk" "$BD" "$R"
  printf '  %s│%s  Engines:          ddrescue: %-18b rsync: %-14b %s│%s\n' "$BD" "$R" "$ddr_st" "$rsync_st" "$BD" "$R"
  printf '  %s│%s  Copy Config:      Big disk threshold: %-6s MB | Keep logs: %-3s       %s│%s\n' "$BD" "$R" "$BIG_MB" "$( ((KEEP_LOGS)) && echo YES || echo NO )" "$BD" "$R"
  printf '  %s└────────────────────────────────────────────────────────────────────────┘%s\n' "$BD" "$R"
}

show_main_menu() {
  printf '\n'
  printf '  %s┌────────────────────────────────────────────────────────────────────────┐%s\n' "$BD" "$R"
  printf '  %s│%s  %sOPERATION SELECTOR%s                                                     %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$BD" "$R"
  printf '  %s├────────────────────────────────────────────────────────────────────────┤%s\n' "$BD" "$R"
  printf '  %s│%s  %s[1]%s  🚀 Copy All Detected VMs %s(ddrescue + rsync)%s                        %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$DIM" "$R" "$BD" "$R"
  printf '  %s│%s  %s[2]%s  🎯 Select Specific VM(s) to Copy %s(interactive picker)%s               %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$DIM" "$R" "$BD" "$R"
  printf '  %s│%s  %s[3]%s  📋 Dry-Run Simulation %s(calculate byte demands & test)%s               %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$DIM" "$R" "$BD" "$R"
  printf '  %s│%s  %s[4]%s  📁 Inspect Source Datastore Folders & Storage Breakdown%s           %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$R" "$BD" "$R"
  printf '  %s│%s  %s[5]%s  🩺 Run Staged VM Verifier %s(verify-staged.sh audit)%s                   %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$DIM" "$R" "$BD" "$R"
  printf '  %s│%s  %s[6]%s  📜 View ddrescue Mapfiles & Recovery Logs%s                              %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$R" "$BD" "$R"
  printf '  %s│%s  %s[7]%s  ⚙️  Configure Transfer Options %s(Threshold, Engines, Paths)%s            %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$DIM" "$R" "$BD" "$R"
  printf '  %s│%s  %s[Q]%s  🚪 Exit%s                                                                %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$R" "$BD" "$R"
  printf '  %s└────────────────────────────────────────────────────────────────────────┘%s\n' "$BD" "$R"
}

#------------------------------------------------------------------------------
# VM Folder Discovery & Sizing
#------------------------------------------------------------------------------
folder_bytes() {
  $SUDO find "$1" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}'
}

folder_bytes_copyable() {
  if ((KEEP_LOGS)); then
    $SUDO find "$1" -type f ! -name '*.vswp' ! -name '*-ctk.vmdk' \
      -printf '%s\n' 2>/dev/null
  else
    $SUDO find "$1" -type f ! -name '*.vswp' ! -name '*-ctk.vmdk' ! -name '*.log' \
      -printf '%s\n' 2>/dev/null
  fi | awk '{s+=$1} END{print s+0}'
}

NAMES=(); SIZES=(); NBIG=(); STATUS=()

scan_datastore() {
  NAMES=(); SIZES=(); NBIG=(); STATUS=()
  if ! src_is_mounted "$SRC" && [[ ! -d $SRC || -z $($SUDO ls -A "$SRC" 2>/dev/null) ]]; then
    warn "Source '$SRC' is not mounted or has no contents."
    attach_help
    return 1
  fi

  local spin_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  printf '\033[?25l'

  local tmp_list; tmp_list=$(mktemp)
  ($SUDO find "$SRC" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z > "$tmp_list") &
  local fpid=$!
  while kill -0 "$fpid" 2>/dev/null; do
    printf '\r  %s%s%s Scanning %s%s%s ...\033[K' "$CY" "${spin_chars[i]}" "$R" "$B" "$SRC" "$R"
    i=$(( (i + 1) % 10 ))
    sleep 0.08
  done
  wait "$fpid"

  local dir name sz big dsz pct st
  while IFS= read -r -d '' dir; do
    name=$(basename "$dir")
    printf '\r  %s%s%s Probing VM: %s%s%s ...\033[K' "$CY" "${spin_chars[i]}" "$R" "$B" "$name" "$R"
    i=$(( (i + 1) % 10 ))
    sz=$(folder_bytes_copyable "$dir")
    big=$($SUDO find "$dir" -maxdepth 1 -type f -name '*.vmdk' \
            -size +$((BIG_MB - 1))M 2>/dev/null | wc -l | tr -d ' ')
    if [[ -d "$DEST/$name" ]]; then
      dsz=$(folder_bytes_copyable "$DEST/$name")
      pct=$(awk -v d="$dsz" -v s="$sz" 'BEGIN{ if(s>0) printf "%d", d*100/s; else print 0 }')
      if   ((pct >= 100)); then st="${GR}complete (100%)${R}"
      elif ((pct  >   0)); then st="${YL}partial ${pct}%${R}"
      else                      st="${DIM}empty${R}"
      fi
    else
      st="${DIM}absent${R}"
    fi
    NAMES+=("$name"); SIZES+=("$sz"); NBIG+=("$big"); STATUS+=("$st")
  done < "$tmp_list"
  rm -f "$tmp_list"
  printf '\r\033[K\033[?25h'

  return 0
}

print_vm_table() {
  local N=${#NAMES[@]}
  if ((N == 0)); then
    warn "No VM folders found in '$SRC'."
    return 1
  fi
  printf '\n'
  printf '  %s┌─────┬──────────────────────────────────────────┬───────────┬─────────┬──────────────────────┐%s\n' "$CY" "$R"
  printf '  %s│ %-3s │ %-40s │ %-9s │ %-7s │ %-20s │%s\n' "$CY" "#" "VM FOLDER" "SIZE" "DISKS" "DESTINATION" "$R"
  printf '  %s├─────┼──────────────────────────────────────────┼───────────┼─────────┼──────────────────────┤%s\n' "$CY" "$R"
  local i
  for ((i=0; i<N; i++)); do
    printf '  %s│%s %-3s %s│%s %-40.40s %s│%s %9s %s│%s %-7s %s│%s %-30b %s│%s\n' \
      "$CY" "$R" "$((i+1))" "$CY" "$B" "${NAMES[i]}" "$CY" "$R" "$(human "${SIZES[i]}")" "$CY" "$R" "${NBIG[i]} vmdk" "$CY" "${STATUS[i]}" "$CY" "$R"
  done
  printf '  %s└─────┴──────────────────────────────────────────┴───────────┴─────────┴──────────────────────┘%s\n' "$CY" "$R"
  local TOTAL_ALL=0
  for s in "${SIZES[@]}"; do TOTAL_ALL=$((TOTAL_ALL + s)); done
  info "${DIM}$N folders, $(human "$TOTAL_ALL") total to copy. DISKS = .vmdk images >= ${BIG_MB}MB (ddrescue candidates).${R}"
}

#------------------------------------------------------------------------------
# Inspection & Audit Tools
#------------------------------------------------------------------------------
inspect_datastore_detailed() {
  printf '\n%s\n' "${B}Source Datastore Inventory ($SRC):${R}"
  hr
  if ! scan_datastore; then return 1; fi

  local i dir name f count
  for ((i=0; i<${#NAMES[@]}; i++)); do
    name="${NAMES[i]}"
    dir="$SRC/$name"
    printf '\n  %s%s%s %s(%s to copy)%s\n' "$CY$B" "$name" "$R" "$DIM" "$(human "${SIZES[i]}")" "$R"

    # List all files inside
    while IFS= read -r -d '' f; do
      local fname fsize ftype
      fname=$(basename "$f")
      fsize=$(stat -c %s "$f" 2>/dev/null || echo 0)
      if [[ $fname == *.vmx ]]; then
        ftype="${CY}VMX Configuration${R}"
      elif [[ $fname == *-flat.vmdk ]]; then
        ftype="${GR}Flat Disk Image Extent${R}"
      elif [[ $fname == *.vmdk ]]; then
        ftype="${WH}VMDK Descriptor${R}"
      elif [[ $fname == *.nvram ]]; then
        ftype="${DIM}BIOS NVRAM State${R}"
      elif [[ $fname == *.vswp ]]; then
        ftype="${YL}Virtual Swap (Skipped)${R}"
      elif [[ $fname == *.log ]]; then
        ftype="${DIM}VMware Log (Skipped)${R}"
      else
        ftype="${DIM}Metadata / Auxiliary${R}"
      fi
      printf '    %-38.38s  %9s  %b\n' "$fname" "$(human "$fsize")" "$ftype"
    done < <($SUDO find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
  done
  printf '\n'
  ok "Datastore inspection complete. All files read directly via read-only FUSE mount."
}

view_mapfiles() {
  printf '\n%s\n' "${B}ddrescue Recovery Vault & Session Logs ($MAPDIR):${R}"
  hr
  if [[ ! -d $MAPDIR ]]; then
    warn "Mapfile directory '$MAPDIR' does not exist yet."
    return 0
  fi

  local maps=()
  while IFS= read -r -d '' m; do maps+=("$m"); done < <(find "$MAPDIR" -maxdepth 1 -type f \( -name '*.map' -o -name '*.mapfile' \) -print0 2>/dev/null | sort -z)

  if ((${#maps[@]} == 0)); then
    info "No ddrescue mapfiles found in '$MAPDIR'. Once a copy starts, mapfiles are saved here."
    return 0
  fi

  printf '\n'
  printf '  %s┌──────────────────────────────────────────────┬─────────────┬───────────┬──────────────┐%s\n' "$CY" "$R"
  printf '  %s│ %-44s │ %-11s │ %-9s │ %-12s │%s\n' "$CY" "MAPFILE / DISK IMAGE" "RESCUED" "BAD AREAS" "STATUS" "$R"
  printf '  %s├──────────────────────────────────────────────┼─────────────┼───────────┼──────────────┤%s\n' "$CY" "$R"

  for m in "${maps[@]}"; do
    local mbase high log bad st_str
    mbase=$(basename "$m")
    high=$(map_rescued_end "$m")
    log="${m%.*}.ddrescue.log"
    bad=0
    if [[ -f $log ]]; then
      bad=$(grep -oE 'bad areas:[[:space:]]*[0-9]+' "$log" 2>/dev/null | tail -1 | grep -oE '[0-9]+$' || echo 0)
    fi
    if grep -q '^# Finished' "$m" 2>/dev/null; then
      st_str="${GR}Finished${R}"
    else
      st_str="${YL}In Progress${R}"
    fi

    local bad_str="${GR}0${R}"
    if ((bad > 0)); then bad_str="${RD}$bad${R}"; fi

    printf '  %s│%s %-44.44s %s│%s %11s %s│%s %17b %s│%s %-20b %s│%s\n' \
      "$CY" "$R" "$mbase" "$CY" "$R" "$(human "$high")" "$CY" "$bad_str" "$CY" "$st_str" "$CY" "$R"
  done
  printf '  %s└──────────────────────────────────────────────┴─────────────┴───────────┴──────────────┘%s\n' "$CY" "$R"
  info "${DIM}Mapfiles guarantee zero duplicate reads: ddrescue resumes exactly where it stopped.${R}"
}

run_verify_staged() {
  printf '\n%s\n' "${B}Launching Staged VM Pre-flight Verifier...${R}"
  hr
  local v_script="$SCRIPT_DIR/verify-staged.sh"
  if [[ ! -f $v_script ]]; then
    v_script="./verify-staged.sh"
  fi
  if [[ -f $v_script ]]; then
    bash "$v_script" --dest "$DEST" --src "$SRC"
  else
    err "verify-staged.sh not found at '$v_script'."
  fi
}

configure_options() {
  while true; do
    printf '\n'
    printf '  %s┌────────────────────────────────────────────────────────────────────────┐%s\n' "$BD" "$R"
    printf '  %s│%s  %sTRANSFER CONFIGURATION & SETTINGS%s                                      %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$BD" "$R"
    printf '  %s├────────────────────────────────────────────────────────────────────────┤%s\n' "$BD" "$R"
    printf '  %s│%s  [1] Big Disk Threshold:    %-45s %s│%s\n' "$BD" "$R" "${BIG_MB} MB (files >= this use ddrescue)" "$BD" "$R"
    printf '  %s│%s  [2] ddrescue Engine:       %-45s %s│%s\n' "$BD" "$R" "$( ((USE_DDRESCUE)) && echo "${GR}ENABLED (bad-sector retry)${R}" || echo "${YL}DISABLED (rsync only)${R}" )" "$BD" "$R"
    printf '  %s│%s  [3] Keep Log Files:        %-45s %s│%s\n' "$BD" "$R" "$( ((KEEP_LOGS)) && echo "${GR}YES (copy vmware*.log)${R}" || echo "${DIM}NO (exclude logs)${R}" )" "$BD" "$R"
    printf '  %s│%s  [4] Dry-Run Mode:          %-45s %s│%s\n' "$BD" "$R" "$( ((DRY_RUN)) && echo "${YL}ENABLED (no files written)${R}" || echo "${GR}DISABLED (live transfer)${R}" )" "$BD" "$R"
    printf '  %s│%s  [5] Source VMFS Mount:     %-45s %s│%s\n' "$BD" "$R" "$SRC" "$BD" "$R"
    printf '  %s│%s  [6] Destination Directory: %-45s %s│%s\n' "$BD" "$R" "$DEST" "$BD" "$R"
    printf '  %s│%s  [7] Mapfile Directory:     %-45s %s│%s\n' "$BD" "$R" "$MAPDIR" "$BD" "$R"
    printf '  %s│%s  [B] Back to Main Menu%s                                                  %s│%s\n' "$BD" "$R" "$R" "$BD" "$R"
    printf '  %s└────────────────────────────────────────────────────────────────────────┘%s\n' "$BD" "$R"

    local opt val
    read -r -p "  Select setting to change [1-7, B]: " opt
    case ${opt,,} in
      1)
        read -r -p "  Enter new threshold in MB (current: $BIG_MB): " val
        if [[ $val =~ ^[0-9]+$ ]] && ((val > 0)); then BIG_MB=$val; ok "Threshold set to $BIG_MB MB"; fi
        ;;
      2)
        USE_DDRESCUE=$(( 1 - USE_DDRESCUE ))
        ok "ddrescue set to $USE_DDRESCUE"
        ;;
      3)
        KEEP_LOGS=$(( 1 - KEEP_LOGS ))
        ok "Keep logs set to $KEEP_LOGS"
        ;;
      4)
        DRY_RUN=$(( 1 - DRY_RUN ))
        ok "Dry-run set to $DRY_RUN"
        ;;
      5)
        read -r -p "  Enter new source path (current: $SRC): " val
        if [[ -n $val ]]; then SRC=$val; ok "Source set to $SRC"; fi
        ;;
      6)
        read -r -p "  Enter new destination path (current: $DEST): " val
        if [[ -n $val ]]; then DEST=$val; MAPDIR="$DEST/.vmfs-recovery"; ok "Dest set to $DEST"; fi
        ;;
      7)
        read -r -p "  Enter new mapdir path (current: $MAPDIR): " val
        if [[ -n $val ]]; then MAPDIR=$val; ok "Mapdir set to $MAPDIR"; fi
        ;;
      b|back|q|quit|"")
        break
        ;;
      *)
        warn "Unknown option '$opt'"
        ;;
    esac
  done
}

#------------------------------------------------------------------------------
# ddrescue & rsync Copy Engine
#------------------------------------------------------------------------------
ddr_field() {
  tail -c 8000 "$1" 2>/dev/null | tr '\r' '\n' \
    | grep -ao "$2[[:space:]]*[0-9.]*[[:space:]]*[A-Za-z%/]*" | tail -1
}

map_rescued_end() {
  local pos size st end max=0
  while read -r pos size st _; do
    [[ $pos == 0x* && $size == 0x* && $st == '+' ]] || continue
    end=$(( pos + size ))
    (( end > max )) && max=$end
  done < <($SUDO grep -a '^0x' -- "$1" 2>/dev/null)
  printf '%s\n' "$max"
}

map_valid_for() {
  local need cur
  need=$(map_rescued_end "$1")
  (( need > 0 )) || return 0
  cur=$($SUDO stat -c %s -- "$2" 2>/dev/null || printf 0)
  (( cur >= need )) && return 0
  warn "Stale mapfile ignored: ${DIM}$1${R}"
  info "    claims $(human "$need") already written here, but the destination holds $(human "${cur:-0}")."
  return 1
}

adopt_mapfile() {
  local want=$1 sf=$2 df=$3 cand
  if [[ -s $want ]]; then
    map_valid_for "$want" "$df" && return 0
    $SUDO mv -f "$want" "$want.stale" 2>/dev/null || $SUDO rm -f "$want" 2>/dev/null
  fi
  for cand in "$MAPDIR"/*.map "$MAPDIR"/*.mapfile "$MAPDIR"/*map.log \
              "${HOME:-/root}"/*.map "${HOME:-/root}"/*.mapfile "${HOME:-/root}"/*map.log \
              /root/*.map /root/*.mapfile /root/*map.log \
              /home/*/*.map /home/*/*.mapfile /home/*/*map.log; do
    [[ -f $cand && -s $cand ]] || continue
    [[ $cand == "$want" ]] && continue
    $SUDO grep -aqF -- "$df" "$cand" 2>/dev/null || continue
    $SUDO grep -aqF -- "$sf" "$cand" 2>/dev/null || continue
    map_valid_for "$cand" "$df" || continue
    if $SUDO cp -f "$cand" "$want" 2>/dev/null; then
      ok "Resuming from an earlier mapfile: ${DIM}$cand${R}"
      return 0
    fi
  done
  return 0
}

copy_big() {
  local sf=$1 df=$2 mf=$3 total=$4 label=$5
  local log="$MAPDIR/$(basename "$df").ddrescue.log"
  adopt_mapfile "$mf" "$sf" "$df"
  printf '    %sddrescue ->%s %s %s(%s)%s\n' "$CY" "$R" "$label" "$DIM" "$(human "$total")" "$R"
  printf '\033[?25l'

  $SUDO ddrescue -v -b 512 --retry-passes=3 "$sf" "$df" "$mf" >"$log" 2>&1 &
  local pid=$! t0=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    local pct cur rate bad el
    pct=$(ddr_field "$log" 'pct rescued:' | grep -oE '[0-9.]+' | tail -1)
    if [[ -z ${pct:-} ]]; then
      cur=$($SUDO stat -c %s "$df" 2>/dev/null || echo 0)
      pct=$(awk -v c="$cur" -v t="$total" 'BEGIN{ if(t>0) printf "%.2f", c*100/t; else print 0 }')
    fi
    rate=$(ddr_field "$log" 'current rate:' | sed 's/current rate:[[:space:]]*//')
    bad=$(ddr_field  "$log" 'bad areas:'    | grep -oE '[0-9]+' | tail -1)
    el=$((SECONDS - t0))
    local bad_tag="bad:${bad:-0}"
    if [[ ${bad:-0} -gt 0 ]]; then bad_tag="${RD}bad:$bad${R}"; else bad_tag="${GR}bad:0${R}"; fi
    draw_bar "$pct" "${rate:-...}  ${bad_tag}  $((el/60))m$((el%60))s"
    sleep 1
  done
  wait "$pid"; local rc=$?
  printf '\033[?25h'

  local summary
  summary=$(tr '\r' '\n' <"$log" | grep -a 'rescued:' | tail -1 | sed 's/^[[:space:]]*//')
  if ((rc == 0)); then
    draw_bar 100 "complete"
    printf '\n'
    ok "${DIM}${summary}${R}"
  else
    printf '\n'
    err "ddrescue exited $rc - log: $log"
    [[ -n $summary ]] && err "${DIM}${summary}${R}"
  fi
  return $rc
}

copy_rest() {
  local sd=$1 dd=$2; shift 2
  local rcfile; rcfile=$(mktemp)
  printf '    %srsync    ->%s metadata (.vmx / .vmdk descriptor / .nvram / .vmsd)\n' "$CY" "$R"
  printf '\033[?25l'
  local line p
  while IFS= read -r line; do
    p=$(grep -oE '[0-9]+%' <<<"$line" | tail -1 | tr -d '%')
    [[ -n ${p:-} ]] && draw_bar "$p" "files"
  done < <( { $SUDO rsync -ah --info=progress2 --no-inc-recursive "$@" "$sd/" "$dd/" 2>&1; \
              echo $? >"$rcfile"; } | tr '\r' '\n' )
  local rc; rc=$(cat "$rcfile" 2>/dev/null || echo 1); rm -f "$rcfile"
  printf '\033[?25h'
  if [[ ${rc:-1} == 0 ]]; then
    draw_bar 100 "complete"
    printf '\n'
  else
    printf '\n'; err "rsync exited $rc"
  fi
  return "${rc:-1}"
}

# Execute copy for the given array of indices in SEL
execute_copy() {
  local count=0
  local DONE=() FAILED=()

  local SEL_BYTES=0
  printf '\n%s\n' "${B}Recovery Plan Summary:${R}"
  local i idx
  for i in "${SEL[@]}"; do
    idx=$((i-1))
    printf '    %s*%s  %s %s(%s)%s\n' "$CY" "$R" "${NAMES[idx]}" "$DIM" "$(human "${SIZES[idx]}")" "$R"
    SEL_BYTES=$((SEL_BYTES + SIZES[idx]))
  done
  hr

  local DEST_FREE
  DEST_FREE=$(df -B1 --output=avail "$DEST" 2>/dev/null | tail -1 | tr -d ' ')
  DEST_FREE=${DEST_FREE:-0}
  info "Total to copy: ${B}$(human "$SEL_BYTES")${R}   Free at destination: ${B}$(human "$DEST_FREE")${R}"

  if ((SEL_BYTES > DEST_FREE)); then
    err "Not enough free space on destination - need $(human $((SEL_BYTES - DEST_FREE))) more."
    if ! ((ASSUME_YES)); then
      local f=""
      read -r -p "  Continue anyway? [y/N]: " f
      [[ ${f:-} == [yY]* ]] || return 1
    fi
  else
    ok "Destination space check passed ($(human $((DEST_FREE - SEL_BYTES))) would remain)."
  fi

  if ((DRY_RUN)); then
    printf '\n'
    warn "[DRY-RUN] Simulation complete. No bytes written to destination drive."
    return 0
  fi

  if ! ((ASSUME_YES)); then
    printf '\n'
    local go=""
    read -r -p "  Start copy now? [Y/n]: " go
    if [[ $go =~ ^[nN] ]]; then info "Copy cancelled by operator."; return 0; fi
  fi

  for i in "${SEL[@]}"; do
    idx=$((i-1)); local name=${NAMES[idx]}
    count=$((count + 1))
    printf '\n%s\n' "${B}[$count/${#SEL[@]}] Transferring VM: $name${R}"
    hr

    local sdir="$SRC/$name"; local ddir="$DEST/$name"
    $SUDO mkdir -p "$ddir" || { err "mkdir failed: $ddir"; FAILED+=("$name"); continue; }

    local BIG=(); local folder_rc=0
    if ((USE_DDRESCUE)); then
      while IFS= read -r -d '' f; do BIG+=("$f"); done < <(
        $SUDO find "$sdir" -maxdepth 1 -type f -name '*.vmdk' \
          -size +$((BIG_MB - 1))M -printf '%s\t%p\0' 2>/dev/null \
        | sort -z -rn | sed -z 's/^[0-9]*\t//'
      )
    fi

    local EXCL=(--exclude='*.vswp' --exclude='*-ctk.vmdk')
    ((KEEP_LOGS)) || EXCL+=(--exclude='vmware*.log' --exclude='*.log')

    if ((${#BIG[@]})); then
      for f in "${BIG[@]}"; do
        local fname; fname=$(basename "$f")
        local total; total=$($SUDO stat -c %s "$f")
        local mapf="$MAPDIR/${name// /_}--${fname// /_}.map"
        copy_big "$f" "$ddir/$fname" "$mapf" "$total" "$fname" || folder_rc=1
        EXCL+=(--exclude="/$fname")
      done
    else
      info "${DIM}No .vmdk images >= ${BIG_MB}MB - rsync handles the entire folder.${R}"
    fi

    copy_rest "$sdir" "$ddir" "${EXCL[@]}" || folder_rc=1

    # Verify apparent size
    local s_b; s_b=$(folder_bytes_copyable "$sdir")
    local d_b; d_b=$(folder_bytes_copyable "$ddir")
    local vpct
    vpct=$(awk -v d="$d_b" -v s="$s_b" 'BEGIN{ if(s>0) printf "%.1f", d*100/s; else print 0 }')
    if awk -v p="$vpct" 'BEGIN{exit !(p >= 99.5)}'; then
      ok "Integrity Check: $(human "$d_b") / $(human "$s_b") (${vpct}%)"
    else
      warn "Size delta detected: $(human "$d_b") / $(human "$s_b") (${vpct}%)"
      warn "Review mapfiles and logs in $MAPDIR before importing."
    fi

    if ((folder_rc)); then FAILED+=("$name"); else DONE+=("$name"); fi
  done

  # Summary
  printf '\n'; hr
  printf '%s\n' "${B}Recovery Run Summary:${R}"
  for n in "${DONE[@]:-}";   do [[ -n $n ]] && ok "$n staged successfully"; done
  for n in "${FAILED[@]:-}"; do [[ -n $n ]] && err "$n reported errors - see logs in $MAPDIR"; done
  hr
  info "ddrescue mapfiles are safely preserved in ${B}$MAPDIR${R}."
  info "Rerunning resumes cleanly without repeating finished bytes."
  info "Run ${CY}./verify-staged.sh${R} next to audit descriptors, MBR/GPT headers, and VM configuration."
  printf '\n'

  ((${#FAILED[@]} == 0))
  return $?
}

# Interactive selection prompt
do_interactive_selection() {
  if ! scan_datastore; then return 1; fi
  print_vm_table
  local N=${#NAMES[@]}
  if ((N == 0)); then return 1; fi

  SEL=()
  printf '\n'
  local reply=""
  read -r -p "  Select folders [e.g. 1 3, 1-3, all, q]: " reply
  reply=${reply:-}
  if [[ $reply == q || $reply == quit ]]; then info "Cancelled."; return 0; fi
  reply=${reply//,/ }
  for tok in $reply; do
    if [[ $tok == all || $tok == a ]]; then
      for ((i=1; i<=N; i++)); do SEL+=("$i"); done
    elif [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local s=${BASH_REMATCH[1]} e=${BASH_REMATCH[2]}
      ((s<1)) && s=1
      ((e>N)) && e=$N
      for ((i=s; i<=e; i++)); do SEL+=("$i"); done
    elif [[ $tok =~ ^[0-9]+$ ]] && ((tok>=1 && tok<=N)); then
      SEL+=("$tok")
    else
      warn "Ignoring invalid selection: '$tok'"
    fi
  done

  if ((${#SEL[@]})); then
    mapfile -t SEL < <(printf '%s\n' "${SEL[@]}" | awk '!seen[$0]++')
  fi

  ((${#SEL[@]})) || { warn "No valid folders selected."; return 1; }
  execute_copy
}

# Copy all VMs
do_copy_all() {
  if ! scan_datastore; then return 1; fi
  print_vm_table
  local N=${#NAMES[@]}
  if ((N == 0)); then return 1; fi
  SEL=()
  for ((i=1; i<=N; i++)); do SEL+=("$i"); done
  execute_copy
}

# Dry run simulation
do_dry_run() {
  local prev_dry=$DRY_RUN
  DRY_RUN=1
  if ! scan_datastore; then DRY_RUN=$prev_dry; return 1; fi
  print_vm_table
  local N=${#NAMES[@]}
  if ((N == 0)); then DRY_RUN=$prev_dry; return 1; fi
  SEL=()
  for ((i=1; i<=N; i++)); do SEL+=("$i"); done
  execute_copy
  DRY_RUN=$prev_dry
}

#------------------------------------------------------------------------------
# Main Execution Loop
#------------------------------------------------------------------------------
show_header
check_environment_prereqs

# Non-interactive CLI mode: execute directly without interactive loop
if ((!MENU_LOOP)); then
  if ((ASSUME_ALL)); then
    do_copy_all
    exit $?
  else
    do_interactive_selection
    exit $?
  fi
fi

# Interactive Menu Loop
while true; do
  show_environment_card
  show_main_menu

  choice=""
  printf '\n'
  read -r -p "  Select an option [1-7, Q]: " choice
  choice=${choice:-1}

  case ${choice,,} in
    1)
      do_copy_all
      return_or_exit $?
      ;;
    2)
      do_interactive_selection
      return_or_exit $?
      ;;
    3)
      do_dry_run
      return_or_exit $?
      ;;
    4)
      inspect_datastore_detailed
      return_or_exit $?
      ;;
    5)
      run_verify_staged
      return_or_exit $?
      ;;
    6)
      view_mapfiles
      return_or_exit $?
      ;;
    7)
      configure_options
      ;;
    q|quit|exit|0)
      printf '\n  %sExited without further operations.%s\n\n' "$DIM" "$R"
      exit 0
      ;;
    *)
      warn "Unknown choice '$choice'; please select from the menu."
      ;;
  esac
done
