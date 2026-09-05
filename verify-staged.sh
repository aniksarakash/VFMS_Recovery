#!/usr/bin/env bash
#===============================================================================
# verify-staged.sh - pre-flight check on VM folders staged for an ESXi restore
#
# Read-only. Reads the copies on the destination drive, the ddrescue mapfiles
# beside them, and the still-mounted source, and reports whether what you are
# about to import is actually importable.
#
# Run inside WSL2, after vmfs-copy.sh. Safe to run while a copy is in progress -
# an unfinished image is reported as a warning, not a failure.
#
# Every VM folder holding a -flat.vmdk is checked. The expected image size comes
# from that VM's own descriptor extent line, so folders of different sizes are
# all checked correctly; --ram and --vcpu are only enforced when you pass them.
#
#   ./verify-staged.sh                       # interactive dashboard & menu
#   ./verify-staged.sh --dest /mnt/d         # destination drive
#   ./verify-staged.sh --src  /mnt/vmfs      # source mount, for backup diffs
#   ./verify-staged.sh --ram  8192           # require this memSize per VM
#   ./verify-staged.sh --vcpu 4              # require this numvcpus per VM
#   ./verify-staged.sh --host-ram 32768      # host RAM for the budget check
#   ./verify-staged.sh --menu                # force interactive menu
#===============================================================================

set -uo pipefail

DEST="/mnt/d"
SRC="/mnt/vmfs"
WANT_RAM=8192                     # only enforced when --ram is passed
WANT_VCPU=4                       # only enforced when --vcpu is passed
RAM_SET=0
VCPU_SET=0
HOST_RAM=32768                    # host RAM in MB, for budget check
HOST_RESERVE=6144                 # what ESXi itself needs of it
FORCE_MENU=0
SPECIFIC_VM=""

ORIG_ARGS=("$@")

while (($#)); do
  case $1 in
    --dest)     DEST=${2:?}; shift 2 ;;
    --src)      SRC=${2:?};  shift 2 ;;
    --ram)      WANT_RAM=${2:?};  RAM_SET=1;  shift 2 ;;
    --vcpu)     WANT_VCPU=${2:?}; VCPU_SET=1; shift 2 ;;
    --host-ram) HOST_RAM=${2:?}; shift 2 ;;
    --vm)       SPECIFIC_VM=${2:?}; shift 2 ;;
    --menu|-m)  FORCE_MENU=1; shift ;;
    -h|--help)  sed -n '3,22p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

MENU_LOOP=0
if [[ -t 0 && -t 1 ]] && (( ${#ORIG_ARGS[@]} == 0 )) || (( FORCE_MENU )); then
  MENU_LOOP=1
fi

#------------------------------------------------------------------------------
# Cosmetics & UI Styling
#------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  CY=$'\033[38;5;39m'; GR=$'\033[38;5;41m'; YL=$'\033[38;5;214m'; RD=$'\033[38;5;203m'
  MG=$'\033[38;5;177m'; WH=$'\033[38;5;255m'
  BD=$'\033[38;5;244m'
else
  B=''; DIM=''; R=''; CY=''; GR=''; YL=''; RD=''; MG=''; WH=''; BD=''
fi

PASS=0; FAIL=0; WARN=0
reset_counts() { PASS=0; FAIL=0; WARN=0; }
ok()   { printf '  %s[ ok ]%s %s\n' "$GR" "$R" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %s[FAIL]%s %s\n' "$RD" "$R" "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  %s[warn]%s %s\n' "$YL" "$R" "$*"; WARN=$((WARN+1)); }
info() { printf '  %s\n' "$*"; }
hdr()  { printf '\n%s== %s%s\n' "$CY$B" "$*" "$R"; }
hr()   { printf '  %s\n' "${DIM}────────────────────────────────────────────────────────────────────────${R}"; }

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

gib() {
  awk -v b="${1:-0}" 'BEGIN{
    if (b >= 1073741824) printf "%.1f GiB", b/1073741824;
    else                 printf "%.1f MiB", b/1048576
  }'
}

#------------------------------------------------------------------------------
# VM Discovery Helpers
#------------------------------------------------------------------------------
vmx_for() {  # $1 = folder, $2 = basename
  [[ -f "$1/$2.vmx.t130" ]] && { echo "$1/$2.vmx.t130"; return; }
  echo "$1/$2.vmx"
}

expected_sectors() {  # $1 = folder basename
  local n=$1 d line
  for d in "$DEST/$n/$n.vmdk" "$SRC/$n/$n.vmdk"; do
    [[ -f $d ]] || continue
    line=$(grep -m1 -E '^RW[[:space:]]+[0-9]+[[:space:]]+VMFS' "$d" 2>/dev/null)
    if [[ -n $line ]]; then awk '{print $2}' <<<"$line"; return; fi
  done
  if [[ -f "$SRC/$n/$n-flat.vmdk" ]]; then
    echo $(( $(stat -c %s "$SRC/$n/$n-flat.vmdk" 2>/dev/null || echo 0) / 512 ))
  fi
}

get_staged_vms() {
  local list=()
  if [[ -d $DEST ]]; then
    for d in "$DEST"/*/; do
      [[ -d $d ]] || continue
      d=${d%/}
      local n
      n=$(basename "$d")
      [[ $n == .* || $n == '$RECYCLE.BIN' || $n == 'System Volume Information' ]] && continue
      [[ -f "$d/$n-flat.vmdk" || -f "$d/$n.vmdk" ]] && list+=("$n")
    done
  fi
  printf '%s\n' "${list[@]:-}"
}

#------------------------------------------------------------------------------
# Dashboard Header & Target Card
#------------------------------------------------------------------------------
show_header() {
  printf '\n'
  printf '  %s╔══════════════════════════════════════════════════════════════════════════╗%s\n' "$CY" "$R"
  printf '  %s║%s       %sVMFS STAGED VM RESTORE VERIFIER & PRE-FLIGHT AUDITOR%s             %s║%s\n' "$CY" "$R" "$B$WH" "$R" "$CY" "$R"
  printf '  %s║%s      %sRead-Only Integrity Checks  •  MBR/GPT Probing  •  ESXi Ready%s     %s║%s\n' "$CY" "$R" "$DIM" "$R" "$CY" "$R"
  printf '  %s╚══════════════════════════════════════════════════════════════════════════╝%s\n' "$CY" "$R"
}

show_target_card() {
  local vms=()
  while IFS= read -r l; do [[ -n $l ]] && vms+=("$l"); done < <(get_staged_vms)

  local src_st="${RD}UNMOUNTED / OFFLINE${R}"
  if awk -v want="$SRC" '$2 == want { hit = 1 } END { exit !hit }' /proc/mounts 2>/dev/null; then
    src_st="${GR}${B}LIVE FUSE MOUNT${R}"
  elif [[ -d $SRC ]] && [[ -n $(ls -A "$SRC" 2>/dev/null) ]]; then
    src_st="${YL}${B}READABLE DIRECTORY${R}"
  fi

  local total_bytes=0
  for n in "${vms[@]:-}"; do
    local f="$DEST/$n/$n-flat.vmdk"
    if [[ -f $f ]]; then
      local sz; sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
      total_bytes=$((total_bytes + sz))
    fi
  done

  local budget=$(( HOST_RAM - HOST_RESERVE ))
  local req_str="Default (advisory)"
  if ((RAM_SET || VCPU_SET)); then
    req_str=""
    ((RAM_SET)) && req_str+="RAM: ${WANT_RAM}MB "
    ((VCPU_SET)) && req_str+="vCPU: ${WANT_VCPU}"
  fi

  printf '\n'
  printf '  %s┌────────────────────────────────────────────────────────────────────────┐%s\n' "$BD" "$R"
  printf '  %s│%s  %sVERIFICATION TARGET & HOST CONFIGURATION%s                                %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$BD" "$R"
  printf '  %s├────────────────────────────────────────────────────────────────────────┤%s\n' "$BD" "$R"
  printf '  %s│%s  Staged Destination:   %-50s %s│%s\n' "$BD" "$R" "$DEST" "$BD" "$R"
  printf '  %s│%s    Staged VMs Found:   %-50s %s│%s\n' "$BD" "$R" "${#vms[@]} VM folder(s)  ($(gib "$total_bytes") flat images)" "$BD" "$R"
  printf '  %s│%s  Source Datastore:     %-20s  %-28b %s│%s\n' "$BD" "$R" "$SRC" "$src_st" "$BD" "$R"
  printf '  %s│%s  Target Host RAM:      %-50s %s│%s\n' "$BD" "$R" "${HOST_RAM} MB  (ESXi Reserve: ${HOST_RESERVE} MB | Guest Budget: ${budget} MB)" "$BD" "$R"
  printf '  %s│%s  VM Constraints:       %-50s %s│%s\n' "$BD" "$R" "$req_str" "$BD" "$R"
  printf '  %s└────────────────────────────────────────────────────────────────────────┘%s\n' "$BD" "$R"
}

show_main_menu() {
  printf '\n'
  printf '  %s┌────────────────────────────────────────────────────────────────────────┐%s\n' "$BD" "$R"
  printf '  %s│%s  %sOPERATION SELECTOR%s                                                     %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$BD" "$R"
  printf '  %s├────────────────────────────────────────────────────────────────────────┤%s\n' "$BD" "$R"
  printf '  %s│%s  %s[1]%s  🔍 Run Complete 9-Point Verification Suite %s(All Staged VMs)%s         %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$DIM" "$R" "$BD" "$R"
  printf '  %s│%s  %s[2]%s  🎯 Verify Specific Staged VM Folder %s(interactive picker)%s            %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$DIM" "$R" "$BD" "$R"
  printf '  %s│%s  %s[3]%s  💾 Audit ESXi Host Resource Budget & Sizing Constraints%s           %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$R" "$BD" "$R"
  printf '  %s│%s  %s[4]%s  📜 Inspect ddrescue Mapfiles & Sector Integrity Logs%s                %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$R" "$BD" "$R"
  printf '  %s│%s  %s[5]%s  🗂️ View VM Descriptors & Flat Extent Byte Alignment%s                 %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$R" "$BD" "$R"
  printf '  %s│%s  %s[6]%s  🧹 Scan for Dirty / Temporary Files %s(*.lck, *.vmem, *.vswp)%s         %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$DIM" "$R" "$BD" "$R"
  printf '  %s│%s  %s[7]%s  ⚙️  Configure Verification Constraints %s(Host RAM, Limits)%s           %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$DIM" "$R" "$BD" "$R"
  printf '  %s│%s  %s[Q]%s  🚪 Exit%s                                                                %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$R" "$BD" "$R"
  printf '  %s└────────────────────────────────────────────────────────────────────────┘%s\n' "$BD" "$R"
}

#------------------------------------------------------------------------------
# Core Verification Checks
#------------------------------------------------------------------------------
declare -A COMPLETE

check_1_image_completeness() {
  local target_vms=("$@")
  hdr "1. Image completeness"
  for n in "${target_vms[@]}"; do
    local f="$DEST/$n/$n-flat.vmdk"
    if [[ ! -f $f ]]; then
      bad "$n: no flat image ($n-flat.vmdk) found under $DEST/$n"
      COMPLETE[$n]=0
      continue
    fi
    local s; s=$(stat -c %s "$f" 2>/dev/null || echo 0)
    local sec; sec=$(expected_sectors "$n")
    local exp=$(( ${sec:-0} * 512 ))
    COMPLETE[$n]=0
    if (( exp == 0 )); then
      warn "$n: $(gib "$s") copied, but no descriptor says how large it should be"
    elif (( s == exp )); then
      COMPLETE[$n]=1
      ok "$n: exactly $s bytes ($(gib "$s"))"
    elif (( s < exp )); then
      warn "$n: $s of $exp bytes ($((s * 100 / exp))%) - copy still running"
    else
      bad "$n: $s bytes, larger than the $exp bytes the descriptor declares"
    fi
  done
  for m in "$DEST"/.vmfs-recovery/*.map; do
    [[ -e $m ]] || continue
    grep -q '^# Finished' "$m" 2>/dev/null \
      && ok "ddrescue finished: $(basename "$m" .map | cut -c1-46)" \
      || warn "ddrescue in progress: $(basename "$m" .map | cut -c1-46)"
  done
  for l in "$DEST"/.vmfs-recovery/*.ddrescue.log; do
    [[ -e $l ]] || continue
    local b
    b=$(grep -oE 'bad areas:[[:space:]]*[0-9]+' "$l" 2>/dev/null | tail -1 | grep -oE '[0-9]+$' || echo "")
    [[ -n ${b:-} ]] || continue
    [[ $b -eq 0 ]] && ok "bad areas: 0 ($(basename "$l" .ddrescue.log | cut -c1-34))" \
                   || bad "bad areas: $b ($(basename "$l"))"
  done
}

check_2_boot_structures() {
  local target_vms=("$@")
  hdr "2. Boot structures survived the copy"
  local spin_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local si=0
  for n in "${target_vms[@]}"; do
    local f="$DEST/$n/$n-flat.vmdk"
    if [[ ! -f $f ]]; then
      bad "$n: flat image missing"
      continue
    fi
    printf '  %s%s%s Reading sector 0 & 1 for %s%s%s ...\r' "$CY" "${spin_chars[si]}" "$R" "$B" "$n" "$R"
    si=$(( (si + 1) % 10 ))
    local sig gpt
    sig=$(dd if="$f" bs=1 skip=510 count=2 2>/dev/null | xxd -p 2>/dev/null || echo "")
    gpt=$(dd if="$f" bs=512 count=1 skip=1 2>/dev/null | tr -d '\0' | head -c 8 2>/dev/null || echo "")
    printf '\r\033[K'
    if [[ $sig == 55aa ]]; then
      ok "$n: protective MBR signature 55aa"
    elif [[ ${COMPLETE[$n]:-0} == 1 ]]; then
      bad "$n: sector 0 reads '$sig'"
    else
      warn "$n: sector 0 reads '$sig', but the copy is unfinished - recheck at the end"
    fi
    if [[ $gpt == "EFI PART" ]]; then
      ok "$n: valid EFI PART GPT header"
    elif [[ ${COMPLETE[$n]:-0} == 1 ]]; then
      bad "$n: sector 1 reads '$gpt'"
    else
      warn "$n: sector 1 reads '$gpt', but the copy is unfinished - recheck at the end"
    fi
  done
}

check_3_descriptor_agreement() {
  local target_vms=("$@")
  hdr "3. Descriptor agrees with the image"
  for n in "${target_vms[@]}"; do
    local d="$DEST/$n/$n.vmdk"
    [[ -f $d ]] || { warn "$n: descriptor not delivered yet (rsync runs after ddrescue)"; continue; }
    local line sec typ ext s
    line=$(grep -m1 '^RW' "$d" 2>/dev/null || echo "")
    sec=$(awk '{print $2}' <<<"$line")
    typ=$(awk '{print $3}' <<<"$line")
    ext=$(sed -e 's/^[^"]*"//' -e 's/".*$//' <<<"$line")
    s=$(stat -c %s "$DEST/$n/$n-flat.vmdk" 2>/dev/null || echo 0)
    if [[ ! $sec =~ ^[0-9]+$ || $typ != VMFS ]]; then
      bad "$n: extent line is $line"
    elif [[ $ext != "$n-flat.vmdk" ]]; then
      bad "$n: extent names $ext, not $n-flat.vmdk"
    elif (( sec * 512 == s )); then
      ok "$n: RW $sec VMFS -> $ext, matches the image byte for byte"
    else
      warn "$n: descriptor declares $(( sec * 512 )) bytes, image holds $s"
    fi
  done
}

check_4_vmx_structure() {
  local target_vms=("$@")
  hdr "4. vmx structure"
  for n in "${target_vms[@]}"; do
    local f; f=$(vmx_for "$DEST/$n" "$n")
    [[ -f $f ]] || { bad "$n: no vmx at $f"; continue; }
    local dup cr mal
    dup=$(sed 's/[[:space:]]*=.*//' "$f" | grep -v '^$' | sort | uniq -d)
    [[ -z $dup ]] && ok "$n: no duplicate keys" || bad "$n: duplicate keys: $(echo $dup)"
    cr=$(tr -cd '\r' < "$f" | wc -c)
    [[ $cr -eq 0 ]] && ok "$n: LF endings, no CR" || bad "$n: $cr CR bytes - ESXi wants LF"
    mal=$(grep -vE '^\.?[A-Za-z_][A-Za-z0-9_.:]*[[:space:]]*=[[:space:]]*".*"$|^$' "$f" 2>/dev/null || true)
    [[ -z $mal ]] && ok "$n: every line parses as key = \"value\"" || bad "$n: malformed -> $mal"
  done
}

check_5_dead_host_keys() {
  local target_vms=("$@")
  hdr "5. Dead-host keys gone, CD-ROM detached"
  for n in "${target_vms[@]}"; do
    local f; f=$(vmx_for "$DEST/$n" "$n")
    [[ -f $f ]] || continue
    local clean=1
    for k in 'numa\.autosize' 'migrate\.hostLog' 'migrate\.hostlog' \
             'sched\.swap\.derivedName' 'cdrom-image' '/vmfs/volumes/'; do
      grep -qE "$k" "$f" 2>/dev/null && { bad "$n: still contains $k"; clean=0; }
    done
    ((clean)) && ok "$n: no dead-host keys, no absolute /vmfs/volumes path"

    local cdrom
    cdrom=$(awk -F. '/[.]deviceType = "atapi-cdrom"/{print $1; exit}' "$f" 2>/dev/null || true)
    if [[ -z $cdrom ]]; then
      ok "$n: no CD-ROM device to detach"
    else
      grep -q "^$cdrom[.]fileName = .auto detect.$"   "$f" 2>/dev/null && ok "$n: $cdrom auto detect"        || bad "$n: $cdrom fileName"
      grep -q "^$cdrom[.]startConnected = .FALSE.$"   "$f" 2>/dev/null && ok "$n: $cdrom startConnected off" || bad "$n: $cdrom startConnected"
    fi
  done
}

check_6_sizing_and_budget() {
  local target_vms=("$@")
  hdr "6. Sizing - and the rule that stops power-on"
  local total=0
  local budget=$(( HOST_RAM - HOST_RESERVE ))
  for n in "${target_vms[@]}"; do
    local f; f=$(vmx_for "$DEST/$n" "$n")
    [[ -f $f ]] || continue
    local v m c
    v=$(grep -oP '(?<=^numvcpus = ")[0-9]+'             "$f" 2>/dev/null || echo "")
    m=$(grep -oP '(?<=^memSize = ")[0-9]+'              "$f" 2>/dev/null || echo "")
    c=$(grep -oP '(?<=^cpuid\.coresPerSocket = ")[0-9]+' "$f" 2>/dev/null || echo "")
    if (( RAM_SET )); then
      [[ ${m:-} == "$WANT_RAM" ]] && ok "$n: memSize $m" || bad "$n: memSize ${m:-unset}, expected $WANT_RAM"
    else
      [[ -n ${m:-} ]] && ok "$n: memSize $m MB" || bad "$n: memSize unset"
    fi
    if (( VCPU_SET )); then
      [[ ${v:-} == "$WANT_VCPU" ]] && ok "$n: numvcpus $v" || bad "$n: numvcpus ${v:-unset}, expected $WANT_VCPU"
    else
      [[ -n ${v:-} ]] && ok "$n: numvcpus $v" || bad "$n: numvcpus unset"
    fi
    if [[ -n ${v:-} && -n ${c:-} ]] && (( v % c == 0 )); then
      ok "$n: coresPerSocket $c divides into numvcpus $v"
    else
      bad "$n: coresPerSocket ${c:-unset} does not divide into ${v:-unset} - power-on fails"
    fi
    total=$((total + ${m:-0}))
  done

  # Visual Host RAM Allocation Gauge
  local pct=0
  if ((HOST_RAM > 0)); then pct=$(( total * 100 / HOST_RAM )); fi
  local gauge_w=20
  local g_fill=$(( pct * gauge_w / 100 ))
  ((g_fill > gauge_w)) && g_fill=$gauge_w
  local g_empty=$(( gauge_w - g_fill ))
  local g_bar="" gi
  for ((gi=0; gi<g_fill; gi++)); do g_bar+='█'; done
  local g_dim=""
  for ((gi=0; gi<g_empty; gi++)); do g_dim+='░'; done

  printf '\n'
  printf '  %sHost RAM Budget:%s [%s%s%s%s] %d%%  (%d MB of %d MB)\n' \
    "$DIM" "$R" "$CY" "$g_bar" "$DIM" "$g_dim" "$pct" "$total" "$HOST_RAM"
  if (( total <= budget )); then
    ok "leaves $(( (HOST_RAM - total) / 1024 )) GB for ESXi and headroom"
  else
    bad "over budget - ESXi needs about $(( HOST_RESERVE / 1024 )) GB of the $(( HOST_RAM / 1024 )) GB host"
  fi
}

check_7_identity() {
  local target_vms=("$@")
  hdr "7. Identity preserved"
  for n in "${target_vms[@]}"; do
    local f; f=$(vmx_for "$DEST/$n" "$n")
    [[ -f $f ]] || continue
    local ref=0 val
    while IFS= read -r val; do
      [[ $val == "$n.vmdk" ]] && ref=1
    done < <(awk -F'"' '/^[a-z]+[0-9]+:[0-9]+[.]fileName = /{print $2}' "$f" 2>/dev/null)
    if (( ref )); then
      ok "$n: disk reference is relative to its own folder"
    else
      bad "$n: no controller line points at $n.vmdk"
    fi
    grep -q '^uuid.bios = ' "$f" 2>/dev/null && ok "$n: uuid.bios present (Windows activation)" || bad "$n: uuid.bios missing"
    local dname
    dname=$(grep -oP '(?<=^displayName = ").*(?=")' "$f" 2>/dev/null || echo "$n")
    info "       displayName: ${DIM}$dname${R}"
  done
}

check_8_backups() {
  local target_vms=("$@")
  hdr "8. Backups kept, and honest"
  for n in "${target_vms[@]}"; do
    local found=0
    shopt -s nullglob
    local backups=("$DEST/$n/"*original "$DEST/$n/"*.bak-*)
    shopt -u nullglob
    for b in "${backups[@]:-}"; do
      [[ -e $b ]] || continue
      found=$((found+1))
      case $b in
        *.vmx.original|*.vmx.testcfg-original)
          if [[ -f "$SRC/$n/$n.vmx" ]]; then
            cmp -s "$b" "$SRC/$n/$n.vmx" \
              && ok "$n: $(basename "$b") is byte-identical to live source" \
              || warn "$n: $(basename "$b") differs from live source vmx"
          else
            ok "$n: preserved $(basename "$b") (source not mounted, skipped diff)"
          fi ;;
        *) ok "$n: preserved $(basename "$b")" ;;
      esac
    done
    (( found )) || warn "$n: nothing preserved as *original / *.bak-* - edits are not reversible"
  done
}

check_9_must_not_ship() {
  local target_vms=("$@")
  hdr "9. Must not ship (clean restore directory)"
  for n in "${target_vms[@]}"; do
    shopt -s nullglob
    local junk=("$DEST/$n/"*.lck "$DEST/$n/"*.vmss "$DEST/$n/"*.vmem "$DEST/$n/"*-00000*.vmdk)
    shopt -u nullglob
    if ((${#junk[@]})); then
      for j in "${junk[@]}"; do warn "$n: remove before ESXi transfer -> $(basename "$j")"; done
    else
      ok "$n: no lock, no suspend state, no memory dump, no snapshot delta chain"
    fi
  done
}

#------------------------------------------------------------------------------
# Full 9-Point Verification Suite
#------------------------------------------------------------------------------
run_full_verification() {
  local target_vms=("$@")
  if ((${#target_vms[@]} == 0)); then
    while IFS= read -r l; do [[ -n $l ]] && target_vms+=("$l"); done < <(get_staged_vms)
  fi

  if ((${#target_vms[@]} == 0)); then
    printf '\n'
    warn "No VM folders with a -flat.vmdk or .vmdk found under '$DEST'."
    info "Run ${CY}./vmfs-copy.sh${R} first to stage VMs to ${B}$DEST${R}."
    return 1
  fi

  reset_counts
  printf '\n%sAuditing %d staged VM folder(s) under %s%s\n' "$B" "${#target_vms[@]}" "$DEST" "$R"
  hr

  check_1_image_completeness "${target_vms[@]}"
  check_2_boot_structures "${target_vms[@]}"
  check_3_descriptor_agreement "${target_vms[@]}"
  check_4_vmx_structure "${target_vms[@]}"
  check_5_dead_host_keys "${target_vms[@]}"
  check_6_sizing_and_budget "${target_vms[@]}"
  check_7_identity "${target_vms[@]}"
  check_8_backups "${target_vms[@]}"
  check_9_must_not_ship "${target_vms[@]}"

  # Audit Verdict Card
  printf '\n'
  printf '  %s┌────────────────────────────────────────────────────────────────────────┐%s\n' "$BD" "$R"
  printf '  %s│%s  %sVERIFICATION AUDIT SUMMARY%s                                             %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$BD" "$R"
  printf '  %s├────────────────────────────────────────────────────────────────────────┤%s\n' "$BD" "$R"
  printf '  %s│%s  PASS: %s%-10d%s  FAIL: %s%-10d%s  WARN: %s%-10d%s           %s│%s\n' \
    "$BD" "$R" "$GR$B" "$PASS" "$R" "$RD$B" "$FAIL" "$R" "$YL$B" "$WARN" "$R" "$BD" "$R"
  printf '  %s├────────────────────────────────────────────────────────────────────────┤%s\n' "$BD" "$R"
  if (( FAIL == 0 && WARN == 0 )); then
    printf '  %s│%s  STATUS: %s[ ALL CHECKS PASSED - 100%% READY FOR ESXi IMPORT ]%s            %s│%s\n' "$BD" "$R" "$GR$B" "$R" "$BD" "$R"
  elif (( FAIL == 0 )); then
    printf '  %s│%s  STATUS: %s[ NO FAILURES - REVIEW ADVISORY WARNINGS ABOVE ]%s               %s│%s\n' "$BD" "$R" "$YL$B" "$R" "$BD" "$R"
  else
    printf '  %s│%s  STATUS: %s[ FAILURES DETECTED - RESOLVE BEFORE IMPORTING TO ESXi ]%s       %s│%s\n' "$BD" "$R" "$RD$B" "$R" "$BD" "$R"
  fi
  printf '  %s└────────────────────────────────────────────────────────────────────────┘%s\n' "$BD" "$R"

  ((FAIL == 0))
  return $?
}

# Specific VM selector
verify_specific_vm() {
  local all_vms=()
  while IFS= read -r l; do [[ -n $l ]] && all_vms+=("$l"); done < <(get_staged_vms)
  if ((${#all_vms[@]} == 0)); then
    warn "No staged VM folders found under '$DEST'."
    return 1
  fi

  printf '\n%sStaged VMs available for verification:%s\n' "$B" "$R"
  hr
  local i
  for ((i=0; i<${#all_vms[@]}; i++)); do
    printf '  %s[%d]%s %s\n' "$CY" "$((i+1))" "$R" "${all_vms[i]}"
  done
  printf '\n'
  local pick=""
  read -r -p "  Select a VM to verify [1-${#all_vms[@]}, q]: " pick
  if [[ $pick =~ ^[qQ] || -z $pick ]]; then info "Cancelled."; return 0; fi
  if [[ $pick =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#all_vms[@]})); then
    local chosen="${all_vms[$((pick-1))]}"
    run_full_verification "$chosen"
  else
    warn "Invalid selection '$pick'"
    return 1
  fi
}

configure_constraints() {
  while true; do
    printf '\n'
    printf '  %s┌────────────────────────────────────────────────────────────────────────┐%s\n' "$BD" "$R"
    printf '  %s│%s  %sVERIFICATION CONSTRAINTS & LIMITS%s                                      %s│%s\n' "$BD" "$R" "$CY$B" "$R" "$BD" "$R"
    printf '  %s├────────────────────────────────────────────────────────────────────────┤%s\n' "$BD" "$R"
    printf '  %s│%s  [1] Host RAM Total:        %-45s %s│%s\n' "$BD" "$R" "${HOST_RAM} MB" "$BD" "$R"
    printf '  %s│%s  [2] ESXi Reserved RAM:     %-45s %s│%s\n' "$BD" "$R" "${HOST_RESERVE} MB" "$BD" "$R"
    printf '  %s│%s  [3] Required VM RAM:       %-45s %s│%s\n' "$BD" "$R" "$( ((RAM_SET)) && echo "${WANT_RAM} MB (enforced)" || echo "Flexible (advisory)" )" "$BD" "$R"
    printf '  %s│%s  [4] Required VM vCPU:      %-45s %s│%s\n' "$BD" "$R" "$( ((VCPU_SET)) && echo "${WANT_VCPU} vCPU (enforced)" || echo "Flexible (advisory)" )" "$BD" "$R"
    printf '  %s│%s  [5] Staged Directory:      %-45s %s│%s\n' "$BD" "$R" "$DEST" "$BD" "$R"
    printf '  %s│%s  [6] Source Datastore:      %-45s %s│%s\n' "$BD" "$R" "$SRC" "$BD" "$R"
    printf '  %s│%s  [B] Back to Main Menu%s                                                  %s│%s\n' "$BD" "$R" "$R" "$BD" "$R"
    printf '  %s└────────────────────────────────────────────────────────────────────────┘%s\n' "$BD" "$R"

    local opt val
    read -r -p "  Select setting to change [1-6, B]: " opt
    case ${opt,,} in
      1)
        read -r -p "  Enter new Host RAM in MB (current: $HOST_RAM): " val
        if [[ $val =~ ^[0-9]+$ ]] && ((val > 0)); then HOST_RAM=$val; ok "Host RAM set to $HOST_RAM MB"; fi
        ;;
      2)
        read -r -p "  Enter ESXi Reserve RAM in MB (current: $HOST_RESERVE): " val
        if [[ $val =~ ^[0-9]+$ ]] && ((val > 0)); then HOST_RESERVE=$val; ok "Host reserve set to $HOST_RESERVE MB"; fi
        ;;
      3)
        read -r -p "  Enter required VM RAM in MB (or 0 for flexible): " val
        if [[ $val =~ ^[0-9]+$ ]]; then
          if ((val > 0)); then WANT_RAM=$val; RAM_SET=1; ok "Enforcing memSize = $WANT_RAM"; else RAM_SET=0; ok "RAM check is flexible"; fi
        fi
        ;;
      4)
        read -r -p "  Enter required VM vCPU count (or 0 for flexible): " val
        if [[ $val =~ ^[0-9]+$ ]]; then
          if ((val > 0)); then WANT_VCPU=$val; VCPU_SET=1; ok "Enforcing numvcpus = $WANT_VCPU"; else VCPU_SET=0; ok "vCPU check is flexible"; fi
        fi
        ;;
      5)
        read -r -p "  Enter new staged destination path (current: $DEST): " val
        if [[ -n $val ]]; then DEST=$val; ok "Destination set to $DEST"; fi
        ;;
      6)
        read -r -p "  Enter source datastore path (current: $SRC): " val
        if [[ -n $val ]]; then SRC=$val; ok "Source set to $SRC"; fi
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
# Main Execution
#------------------------------------------------------------------------------
show_header

# Non-interactive CLI invocation
if ((!MENU_LOOP)); then
  if [[ -n $SPECIFIC_VM ]]; then
    run_full_verification "$SPECIFIC_VM"
  else
    run_full_verification
  fi
  exit $?
fi

# Interactive Menu Loop
while true; do
  show_target_card
  show_main_menu

  choice=""
  printf '\n'
  read -r -p "  Select an option [1-7, Q]: " choice
  choice=${choice:-1}

  all_vms=()
  while IFS= read -r l; do [[ -n $l ]] && all_vms+=("$l"); done < <(get_staged_vms)

  case ${choice,,} in
    1)
      run_full_verification
      return_or_exit $?
      ;;
    2)
      verify_specific_vm
      return_or_exit $?
      ;;
    3)
      reset_counts
      check_6_sizing_and_budget "${all_vms[@]}"
      return_or_exit $?
      ;;
    4)
      reset_counts
      check_1_image_completeness "${all_vms[@]}"
      return_or_exit $?
      ;;
    5)
      reset_counts
      check_3_descriptor_agreement "${all_vms[@]}"
      return_or_exit $?
      ;;
    6)
      reset_counts
      check_9_must_not_ship "${all_vms[@]}"
      return_or_exit $?
      ;;
    7)
      configure_constraints
      ;;
    q|quit|exit|0)
      printf '\n  %sExited.%s\n\n' "$DIM" "$R"
      exit 0
      ;;
    *)
      warn "Unknown choice '$choice'; please select from the menu."
      ;;
  esac
done
