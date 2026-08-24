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
#   ./vmfs-copy.sh                          # detect + interactive selection
#   ./vmfs-copy.sh --all --yes              # everything, no prompts
#   ./vmfs-copy.sh --src /mnt/vmfs --dest /mnt/d
#   ./vmfs-copy.sh --dry-run                # show the plan, copy nothing
#   ./vmfs-copy.sh --no-ddrescue            # rsync everything (faster, no retry)
#   ./vmfs-copy.sh --big-mb 512             # ddrescue threshold
#   ./vmfs-copy.sh --keep-logs              # also copy vmware-*.log
#   ./vmfs-copy.sh --no-sudo                # already root / source readable
#   ./vmfs-copy.sh --mapdir /mnt/d/.maps    # where ddrescue mapfiles live
#===============================================================================

set -uo pipefail

#------------------------------------------------------------------------------
# Defaults - override with flags, no need to edit this file
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
BAR_W=38

#------------------------------------------------------------------------------
# Arg parsing
#------------------------------------------------------------------------------
usage() { sed -n '2,21p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0; }

# Kept before the parser eats them, so any message that has to say "run this
# again" can print the command the operator actually typed rather than a
# reconstruction that quietly drops their other flags.
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
    -h|--help)      usage ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# Mapfiles live beside the DESTINATION, never under $HOME. Running this script
# with sudo flips $HOME to /root, so the same command as you vs. under sudo looks
# in two different directories - which silently orphans an earlier run's mapfile
# and makes ddrescue restart an already-finished image from byte 0. A mapfile is
# only ever a valid claim about one specific output file, so it belongs with it.
MAPDIR=${MAPDIR:-"$DEST/.vmfs-recovery"}

#------------------------------------------------------------------------------
# Cosmetics
#------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  CY=$'\033[38;5;39m'; GR=$'\033[38;5;41m'; YL=$'\033[38;5;214m'; RD=$'\033[38;5;203m'
else
  B=''; DIM=''; R=''; CY=''; GR=''; YL=''; RD=''
fi

hr()   { printf '%s\n' "${DIM}------------------------------------------------------------------------${R}"; }
info() { printf '%s\n' "  $*"; }
ok()   { printf '%s\n' "  ${GR}[ok]${R} $*"; }
warn() { printf '%s\n' "  ${YL}[! ]${R} $*"; }
err()  { printf '%s\n' "  ${RD}[xx]${R} $*" >&2; }
die()  { err "$*"; exit 1; }

human() {
  awk -v b="${1:-0}" 'BEGIN{
    split("B K M G T P", u, " "); i=1
    while (b>=1024 && i<6) { b/=1024; i++ }
    if (i==1) printf "%dB", b; else printf "%.1f%s", b, u[i]
  }'
}

bar_str() {   # $1 filled  $2 empty
  local s='' i
  for ((i=0; i<$1; i++)); do s+='#'; done
  for ((i=0; i<$2; i++)); do s+='.'; done
  printf '%s' "$s"
}

draw_bar() {  # $1 pct  $2 suffix
  local pct=${1:-0} suffix=${2:-} filled
  [[ $pct =~ ^[0-9.]+$ ]] || pct=0
  filled=$(awk -v p="$pct" -v w="$BAR_W" 'BEGIN{f=int(p*w/100); if(f<0)f=0; if(f>w)f=w; print f}')
  printf '\r    %s[%s]%s %6.2f%%  %s\033[K' \
    "$CY" "$(bar_str "$filled" $((BAR_W - filled)))" "$R" "$pct" "$suffix"
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
trap 'printf "\n"; err "Interrupted. Progress is on disk - rerun to resume."; exit 130' INT TERM

#------------------------------------------------------------------------------
# Preflight
#------------------------------------------------------------------------------
printf '\n%s\n' "${B}VMFS recovery copier${R}"
hr

# The three prerequisites all live on the Windows side, outside WSL, so this
# script cannot perform them - it can only refuse to run and say which one is
# missing. Printed on every "no datastore" failure, because a forgotten diskpart
# offline, a detached enclosure, and a datastore that was never mounted all look
# identical from in here: an empty directory.
attach_help() {
  printf '\n  %s\n' "${B}The datastore must be attached and mounted before this script runs:${R}"
  printf '  %s\n' \
    "  ${CY}1.${R} Windows, ${B}admin${R} PowerShell - take the disk offline so Windows lets go of it:" \
    "       diskpart" \
    "       list disk   ${DIM}then${R}   select disk N   ${DIM}then${R}   offline disk   ${DIM}then${R}   exit" \
    "" \
    "  ${CY}2.${R} Windows, ${B}admin${R} PowerShell - hand the enclosure to WSL:" \
    "       usbipd list                          ${DIM}# note the BUSID of the enclosure${R}" \
    "       usbipd bind   --busid <BUSID>        ${DIM}# once per device, needs admin${R}" \
    "       usbipd attach --wsl --busid <BUSID>  ${DIM}# must then read 'Attached'${R}" \
    "" \
    "  ${CY}3.${R} WSL - locate the disk and mount VMFS6:" \
    "       lsblk                                ${DIM}# confirm full size; sdX drifts between attaches${R}" \
    "       sudo mkdir -p $SRC" \
    "       sudo vmfs6-fuse /dev/sdX1 $SRC" \
    ""
}

# Resolve how we escalate BEFORE anything tries to read the datastore. VMFS files
# are mode 600 and the vmfs6-fuse mount is root-owned, so every read below goes
# through $SUDO -- including the check that the source is readable at all. Doing
# this second was the bug: the readability check ran unprivileged and concluded a
# perfectly good datastore was missing.
SUDO="sudo"
if ((NO_SUDO)) || [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  SUDO=""
  if ((NO_SUDO)); then ok "Running without sudo (--no-sudo)"; else ok "Running as root"; fi
elif ! command -v sudo >/dev/null 2>&1; then
  SUDO=""
  warn "sudo not found - continuing unprivileged. VMFS files are normally root-only (mode 600);"
  warn "if reads fail with 'Permission denied', rerun as root."
else
  # -n first: it uses an already-cached credential and never prompts. Only fall
  # back to the prompting form when a terminal is actually there to answer it --
  # a bare "sudo -v" on a stdin nobody is watching blocks forever, which looks
  # exactly like a hung scan of the datastore.
  if sudo -n -v 2>/dev/null; then
    :
  elif [[ -t 0 ]]; then
    sudo -v || die "sudo authentication failed. Rerun as root, or with --no-sudo if the source is readable."
  else
    die "sudo needs a password and there is no terminal to ask on.
       Rerun as root: sudo $0${ORIG_ARGS[*]:+ ${ORIG_ARGS[*]}}"
  fi
  # Refresh the timestamp every 50s. A multi-hour ddrescue outlives the default
  # 15-minute sudo timeout, and losing it mid-copy would stall on a prompt.
  ( while true; do sudo -n true 2>/dev/null; sleep 50; done ) & KEEPALIVE_PID=$!
  ok "sudo cached (VMFS files are root-only, mode 600)"
fi

# Ask the kernel, not stat(). vmfs6-fuse mounts with user_id=0 and without
# allow_other, so to anyone but root every path under the mountpoint fails with
# EACCES -- which makes "[[ -d $SRC ]]" false and made this script announce a live
# datastore as missing, then print the whole re-attach runbook for work that was
# already done. /proc/mounts needs no privilege to read.
src_is_mounted() {
  awk -v want="$1" '$2 == want { hit = 1 } END { exit !hit }' /proc/mounts 2>/dev/null
}

if src_is_mounted "$SRC"; then
  # Mounted and unreadable even through $SUDO is a permissions problem, never a
  # missing datastore, so it must not print the attach runbook.
  if ! $SUDO ls -A "$SRC" >/dev/null 2>&1; then
    err "'$SRC' is mounted, but its contents cannot be read."
    printf '\n  %s\n' "${B}This is a permissions problem, not a missing datastore.${R}"
    printf '  %s\n' \
      "vmfs6-fuse owns the mount as root and does not pass ${B}allow_other${R}, so" \
      "reading it needs root. Rerun exactly as you did, with sudo:" \
      "" \
      "     ${CY}sudo $0${ORIG_ARGS[*]:+ ${ORIG_ARGS[*]}}${R}" \
      "" \
      "${DIM}Nothing needs reattaching or remounting - the datastore is already up.${R}" \
      ""
    exit 1
  fi
  ok "Source mounted: ${B}$SRC${R}"
elif [[ ! -d $SRC ]]; then
  err "Source '$SRC' does not exist."
  attach_help; exit 1
elif [[ -z $($SUDO ls -A "$SRC" 2>/dev/null) ]]; then
  # An empty $SRC is the common shape of every missed step above: the directory
  # survives an unmount, so "it exists" proves nothing about the datastore.
  err "Source '$SRC' exists but is empty - the datastore is not mounted."
  attach_help; exit 1
else
  warn "Source '$SRC' is not a mountpoint but has content - continuing anyway."
fi

[[ -d $DEST ]] || die "Destination '$DEST' does not exist. Try: sudo mkdir -p $DEST && sudo mount -t drvfs ${DEST##*/}: $DEST"

command -v rsync >/dev/null 2>&1 \
  || die "rsync not found - it copies every .vmx/.nvram/.vmsd and any disk below the
       ddrescue threshold, so there is nothing to fall back on. Install it first:
       sudo apt install rsync"

if ((USE_DDRESCUE)) && ! command -v ddrescue >/dev/null 2>&1; then
  warn "ddrescue not found - falling back to rsync for large files."
  warn "Install for bad-sector resilience: sudo apt install gddrescue"
  USE_DDRESCUE=0
fi
if ((USE_DDRESCUE)); then
  ok "ddrescue: $(command -v ddrescue)"
else
  warn "ddrescue disabled - rsync will handle everything (no bad-sector retry)."
fi

DEST_FREE=$(df -B1 --output=avail "$DEST" 2>/dev/null | tail -1 | tr -d ' ')
DEST_FREE=${DEST_FREE:-0}
ok "Destination: ${B}$DEST${R}  ($(human "$DEST_FREE") free)"

mkdir -p "$MAPDIR" 2>/dev/null || $SUDO mkdir -p "$MAPDIR" \
  || die "Cannot create mapfile dir '$MAPDIR' (override with --mapdir)"
ok "Mapfiles/logs: ${B}$MAPDIR${R}"

#------------------------------------------------------------------------------
# DETECTION - enumerate VM folders, size them, check what is already at dest
#------------------------------------------------------------------------------
printf '\n%s\n' "${B}Scanning $SRC ...${R}"

folder_bytes() {   # apparent size of all regular files under $1
  $SUDO find "$1" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}'
}

# Same, but skipping exactly what the copy skips. Measuring a destination against
# the RAW source size can never reach 100% once anything is excluded: a folder
# holding a 24GB .vswp would read "partial" forever no matter how many times it
# finished, and the space check would demand room for bytes never written.
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
while IFS= read -r -d '' dir; do
  name=$(basename "$dir")
  sz=$(folder_bytes_copyable "$dir")
  big=$($SUDO find "$dir" -maxdepth 1 -type f -name '*.vmdk' \
          -size +$((BIG_MB - 1))M 2>/dev/null | wc -l | tr -d ' ')
  if [[ -d "$DEST/$name" ]]; then
    dsz=$(folder_bytes_copyable "$DEST/$name")
    pct=$(awk -v d="$dsz" -v s="$sz" 'BEGIN{ if(s>0) printf "%d", d*100/s; else print 0 }')
    if   ((pct >= 100)); then st="${GR}complete${R}"
    elif ((pct  >   0)); then st="${YL}partial ${pct}%${R}"
    else                      st="${DIM}empty${R}"
    fi
  else
    st="${DIM}absent${R}"
  fi
  NAMES+=("$name"); SIZES+=("$sz"); NBIG+=("$big"); STATUS+=("$st")
done < <($SUDO find "$SRC" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)

N=${#NAMES[@]}
((N)) || die "No VM folders found in '$SRC'."

printf '\n  %s%-3s %-40s %9s %6s  %s%s\n' "$B" "#" "VM FOLDER" "SIZE" "DISKS" "DEST" "$R"
hr
for ((i=0; i<N; i++)); do
  printf '  %-3s %-40.40s %9s %6s  %b\n' \
    "$((i+1))" "${NAMES[i]}" "$(human "${SIZES[i]}")" "${NBIG[i]}" "${STATUS[i]}"
done
hr
TOTAL_ALL=0
for s in "${SIZES[@]}"; do TOTAL_ALL=$((TOTAL_ALL + s)); done
info "${DIM}$N folders, $(human "$TOTAL_ALL") to copy (excludes .vswp/.log). DISKS = .vmdk images >= ${BIG_MB}MB (ddrescue candidates).${R}"

#------------------------------------------------------------------------------
# SELECTION
#------------------------------------------------------------------------------
SEL=()
if ((ASSUME_ALL)); then
  for ((i=1; i<=N; i++)); do SEL+=("$i"); done
else
  printf '\n'
  read -r -p "  Select folders [e.g. 1 3, 1-3, all, q]: " reply
  reply=${reply:-}
  if [[ $reply == q || $reply == quit ]]; then info "Nothing to do."; exit 0; fi
  reply=${reply//,/ }
  for tok in $reply; do
    if [[ $tok == all || $tok == a ]]; then
      for ((i=1; i<=N; i++)); do SEL+=("$i"); done
    elif [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
      s=${BASH_REMATCH[1]}; e=${BASH_REMATCH[2]}
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
fi
((${#SEL[@]})) || die "No valid folders selected."

SEL_BYTES=0
printf '\n%s\n' "${B}Selected:${R}"
for i in "${SEL[@]}"; do
  idx=$((i-1))
  printf '    %s*%s  %s %s(%s)%s\n' "$CY" "$R" "${NAMES[idx]}" "$DIM" "$(human "${SIZES[idx]}")" "$R"
  SEL_BYTES=$((SEL_BYTES + SIZES[idx]))
done
hr
info "Total to copy: ${B}$(human "$SEL_BYTES")${R}   Free at dest: ${B}$(human "$DEST_FREE")${R}"

if ((SEL_BYTES > DEST_FREE)); then
  err "Not enough free space - need $(human $((SEL_BYTES - DEST_FREE))) more."
  if ! ((ASSUME_YES)); then
    read -r -p "  Continue anyway? [y/N]: " f
    [[ ${f:-} == [yY]* ]] || exit 1
  fi
else
  ok "Space check passed ($(human $((DEST_FREE - SEL_BYTES))) would remain)."
fi

if ((DRY_RUN)); then
  printf '\n'; warn "--dry-run: stopping here, nothing copied."; exit 0
fi
if ! ((ASSUME_YES)); then
  printf '\n'
  read -r -p "  Start copy? [y/N]: " go
  [[ ${go:-} == [yY]* ]] || { info "Aborted."; exit 0; }
fi

#------------------------------------------------------------------------------
# COPY
#------------------------------------------------------------------------------
ddr_field() {   # $1 logfile  $2 field label -> last occurrence with its value
  tail -c 8000 "$1" 2>/dev/null | tr '\r' '\n' \
    | grep -ao "$2[[:space:]]*[0-9.]*[[:space:]]*[A-Za-z%/]*" | tail -1
}

# A finished mapfile from an earlier run is the difference between "done in
# seconds" and re-reading 90GB off a drive you are trying to be gentle with.
# Naming and location have drifted across runs (an earlier loop wrote
# "<Folder>-map.log" straight into $HOME), so when nothing sits at the expected
# path, look for a mapfile that names THIS exact source AND this exact output and
# adopt it. Matching both paths is what makes reuse safe: a mapfile asserts which
# regions of one specific output file are already good, so applying one from a
# different destination would mark never-written regions as rescued.

# Highest byte offset a mapfile claims is good: max(pos+size) over "+" blocks.
# Bash arithmetic reads the 0x fields directly. The "current_pos" header line has
# "+" in the second field rather than a 0x size, so requiring both to be hex
# skips it.
map_rescued_end() {   # $1 mapfile -> decimal high-water mark of rescued data
  local pos size st end max=0
  while read -r pos size st _; do
    [[ $pos == 0x* && $size == 0x* && $st == '+' ]] || continue
    end=$(( pos + size ))
    (( end > max )) && max=$end
  done < <($SUDO grep -a '^0x' -- "$1" 2>/dev/null)
  printf '%s\n' "$max"
}

# Matching path strings is not enough. A mapfile is a claim about the CONTENT of
# one specific output file, so if that file was deleted or truncated between runs
# the claim is void - and acting on it is worse than ignoring it, because ddrescue
# would skip every "rescued" range without reading it and report a finished copy
# over a missing or half-written disk image. Trust the mapfile only if the output
# is still at least as large as the region it vouches for.
map_valid_for() {   # $1 mapfile  $2 output file
  local need cur
  need=$(map_rescued_end "$1")
  (( need > 0 )) || return 0                  # nothing claimed yet: harmless
  cur=$($SUDO stat -c %s -- "$2" 2>/dev/null || printf 0)
  (( cur >= need )) && return 0
  warn "Stale mapfile ignored: ${DIM}$1${R}"
  info "    claims $(human "$need") already written here, but the file holds $(human "${cur:-0}")."
  return 1
}

adopt_mapfile() {   # $1 wanted mapfile  $2 source file  $3 output file
  local want=$1 sf=$2 df=$3 cand
  if [[ -s $want ]]; then
    map_valid_for "$want" "$df" && return 0
    # Leaving it in place would make ddrescue skip data that is not there.
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
copy_big() {    # $1 srcfile  $2 dstfile  $3 mapfile  $4 total bytes  $5 label
  local sf=$1 df=$2 mf=$3 total=$4 label=$5
  local log="$MAPDIR/$(basename "$df").ddrescue.log"
  adopt_mapfile "$mf" "$sf" "$df"
  printf '    %sddrescue ->%s %s %s(%s)%s\n' "$DIM" "$R" "$label" "$DIM" "$(human "$total")" "$R"
  printf '\033[?25l'

  $SUDO ddrescue -v -b 512 --retry-passes=3 "$sf" "$df" "$mf" >"$log" 2>&1 &
  local pid=$! t0=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    local pct cur rate bad el
    pct=$(ddr_field "$log" 'pct rescued:' | grep -oE '[0-9.]+' | tail -1)
    if [[ -z ${pct:-} ]]; then                    # ddrescue quiet? poll dest size
      cur=$($SUDO stat -c %s "$df" 2>/dev/null || echo 0)
      pct=$(awk -v c="$cur" -v t="$total" 'BEGIN{ if(t>0) printf "%.2f", c*100/t; else print 0 }')
    fi
    rate=$(ddr_field "$log" 'current rate:' | sed 's/current rate:[[:space:]]*//')
    bad=$(ddr_field  "$log" 'bad areas:'    | grep -oE '[0-9]+' | tail -1)
    el=$((SECONDS - t0))
    draw_bar "$pct" "${rate:-...}  bad:${bad:-0}  $((el/60))m$((el%60))s"
    sleep 1
  done
  wait "$pid"; local rc=$?
  printf '\033[?25h'

  local summary
  summary=$(tr '\r' '\n' <"$log" | grep -a 'rescued:' | tail -1 | sed 's/^[[:space:]]*//')
  if ((rc == 0)); then
    draw_bar 100 "done"; printf '\n'
    ok "${DIM}${summary}${R}"
  else
    printf '\n'
    err "ddrescue exited $rc - log: $log"
    [[ -n $summary ]] && err "${DIM}${summary}${R}"
  fi
  return $rc
}

copy_rest() {   # $1 srcdir  $2 dstdir  $3.. rsync exclude args
  local sd=$1 dd=$2; shift 2
  local rcfile; rcfile=$(mktemp)
  printf '    %srsync    ->%s metadata (.vmx / .vmdk descriptor / .nvram / .vmsd)\n' "$DIM" "$R"
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
    draw_bar 100 "done"; printf '\n'
  else
    printf '\n'; err "rsync exited $rc"
  fi
  return "${rc:-1}"
}

DONE=(); FAILED=(); COUNT=0
for i in "${SEL[@]}"; do
  idx=$((i-1)); name=${NAMES[idx]}
  COUNT=$((COUNT + 1))
  printf '\n%s\n' "${B}[$COUNT/${#SEL[@]}] $name${R}"
  hr

  sdir="$SRC/$name"; ddir="$DEST/$name"
  $SUDO mkdir -p "$ddir" || { err "mkdir failed: $ddir"; FAILED+=("$name"); continue; }

  # --- big disk images, largest first ---
  BIG=(); folder_rc=0
  if ((USE_DDRESCUE)); then
    while IFS= read -r -d '' f; do BIG+=("$f"); done < <(
      $SUDO find "$sdir" -maxdepth 1 -type f -name '*.vmdk' \
        -size +$((BIG_MB - 1))M -printf '%s\t%p\0' 2>/dev/null \
      | sort -z -rn | sed -z 's/^[0-9]*\t//'
    )
  fi

  EXCL=(--exclude='*.vswp' --exclude='*-ctk.vmdk')
  ((KEEP_LOGS)) || EXCL+=(--exclude='vmware*.log' --exclude='*.log')

  if ((${#BIG[@]})); then
    for f in "${BIG[@]}"; do
      fname=$(basename "$f")
      total=$($SUDO stat -c %s "$f")
      mapf="$MAPDIR/${name// /_}--${fname// /_}.map"
      copy_big "$f" "$ddir/$fname" "$mapf" "$total" "$fname" || folder_rc=1
      EXCL+=(--exclude="/$fname")     # handled already; keep rsync off it
    done
  else
    info "${DIM}No .vmdk images >= ${BIG_MB}MB - rsync handles the whole folder.${R}"
  fi

  copy_rest "$sdir" "$ddir" "${EXCL[@]}" || folder_rc=1

  # --- verify: apparent size src vs dest ---
  s_b=$(folder_bytes_copyable "$sdir"); d_b=$(folder_bytes_copyable "$ddir")
  vpct=$(awk -v d="$d_b" -v s="$s_b" 'BEGIN{ if(s>0) printf "%.1f", d*100/s; else print 0 }')
  if awk -v p="$vpct" 'BEGIN{exit !(p >= 99.5)}'; then
    ok "Verified: $(human "$d_b") / $(human "$s_b")  (${vpct}%)"
  else
    warn "Size delta: $(human "$d_b") / $(human "$s_b")  (${vpct}%) - both sides already"
    warn "exclude .vswp/.log, so this is a real shortfall. Check the logs in $MAPDIR."
  fi

  if ((folder_rc)); then FAILED+=("$name"); else DONE+=("$name"); fi
done

#------------------------------------------------------------------------------
# SUMMARY
#------------------------------------------------------------------------------
printf '\n'; hr
printf '%s\n' "${B}Summary${R}"
for n in "${DONE[@]:-}";   do [[ -n $n ]] && ok "$n"; done
for n in "${FAILED[@]:-}"; do [[ -n $n ]] && err "$n - see logs in $MAPDIR"; done
hr
info "ddrescue mapfiles kept in ${B}$MAPDIR${R} - rerunning this script resumes;"
info "it never restarts a disk image from zero."
info "Confirm ${B}bad areas: 0${R} above for every image before restoring on ESXi."
printf '\n'
((${#FAILED[@]})) && exit 1 || exit 0
