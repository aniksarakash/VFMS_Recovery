#!/usr/bin/env bash
#===============================================================================
# verify-staged.sh - pre-flight check on the VM folders staged for the T130
#
# Read-only. Reads the copies on the destination drive, the ddrescue mapfiles
# beside them, and the still-mounted source, and reports whether what you are
# about to import is actually importable.
#
# Run inside WSL2, after vmfs-copy.sh. Safe to run while a copy is in progress -
# an unfinished image is reported as a warning, not a failure.
#
#   ./verify-staged.sh                       # check both VMs
#   ./verify-staged.sh --dest /mnt/e         # destination other than /mnt/d
#   ./verify-staged.sh --src  /mnt/vmfs      # source mount, for the backup diffs
#   ./verify-staged.sh --ram  8192           # expected memSize per VM
#   ./verify-staged.sh --vcpu 4              # expected numvcpus per VM
#===============================================================================

set -uo pipefail

DEST=/mnt/d
SRC=/mnt/vmfs
WANT_RAM=8192
WANT_VCPU=4
SECTORS=188743680                 # 90 GiB at 512 B/sector
SIZE=$((SECTORS * 512))           # 96636764160

while (($#)); do
  case $1 in
    --dest) DEST=${2:?}; shift 2 ;;
    --src)  SRC=${2:?};  shift 2 ;;
    --ram)  WANT_RAM=${2:?};  shift 2 ;;
    --vcpu) WANT_VCPU=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done

if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  GR=$'\033[38;5;41m'; YL=$'\033[38;5;214m'; RD=$'\033[38;5;203m'
else B=''; DIM=''; R=''; GR=''; YL=''; RD=''; fi

PASS=0; FAIL=0; WARN=0
ok()   { printf '  %s[ ok ]%s %s\n' "$GR" "$R" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %s[FAIL]%s %s\n' "$RD" "$R" "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  %s[warn]%s %s\n' "$YL" "$R" "$*"; WARN=$((WARN+1)); }
hdr()  { printf '\n%s== %s%s\n' "$B" "$*" "$R"; }

# Folder name -> the vmx that will actually be imported. 44.13's edited file is
# parked under .vmx.t130 until its rsync pass has delivered the untouched one,
# because rsync would overwrite a plain .vmx.
vmx_for() {  # $1 = folder, $2 = basename
  [[ -f "$1/$2.vmx.t130" ]] && { echo "$1/$2.vmx.t130"; return; }
  echo "$1/$2.vmx"
}

VMS=()
for d in "$DEST"/*/; do
  d=${d%/}; n=$(basename "$d")
  [[ $n == .* || $n == '$RECYCLE.BIN' || $n == 'System Volume Information' ]] && continue
  [[ -f "$d/$n-flat.vmdk" ]] && VMS+=("$n")
done
((${#VMS[@]})) || { echo "No VM folders with a -flat.vmdk under $DEST"; exit 1; }
printf '%sChecking %d VM folder(s) under %s%s\n' "$DIM" "${#VMS[@]}" "$DEST" "$R"

#------------------------------------------------------------------------------
hdr "1. Image completeness"
for n in "${VMS[@]}"; do
  f="$DEST/$n/$n-flat.vmdk"; s=$(stat -c %s "$f")
  if [[ $s -eq $SIZE ]]; then ok "$n: exactly $SIZE bytes (90 GiB)"
  else warn "$n: $s of $SIZE bytes ($((s * 100 / SIZE))%) - copy still running"; fi
done
for m in "$DEST"/.vmfs-recovery/*.map; do
  [[ -e $m ]] || continue
  grep -q '^# Finished' "$m" \
    && ok "ddrescue finished: $(basename "$m" .map | cut -c1-46)" \
    || warn "ddrescue not finished: $(basename "$m" .map | cut -c1-46)"
done
for l in "$DEST"/.vmfs-recovery/*.ddrescue.log; do
  [[ -e $l ]] || continue
  b=$(grep -oE 'bad areas:[[:space:]]*[0-9]+' "$l" | tail -1 | grep -oE '[0-9]+$')
  [[ -n ${b:-} ]] || continue
  [[ $b -eq 0 ]] && ok "bad areas: 0 ($(basename "$l" .ddrescue.log | cut -c1-34))" \
                 || bad "bad areas: $b ($(basename "$l"))"
done

#------------------------------------------------------------------------------
hdr "2. Boot structures survived the copy"
for n in "${VMS[@]}"; do
  f="$DEST/$n/$n-flat.vmdk"
  sig=$(dd if="$f" bs=1 skip=510 count=2 2>/dev/null | xxd -p)
  gpt=$(dd if="$f" bs=512 count=1 skip=1 2>/dev/null | head -c 8)
  [[ $sig == 55aa ]]      && ok "$n: protective MBR signature 55aa"  || bad "$n: sector 0 reads '$sig'"
  [[ $gpt == "EFI PART" ]] && ok "$n: valid EFI PART GPT header"     || bad "$n: sector 1 reads '$gpt'"
done

#------------------------------------------------------------------------------
hdr "3. Descriptor agrees with the image"
for n in "${VMS[@]}"; do
  d="$DEST/$n/$n.vmdk"
  [[ -f $d ]] || { warn "$n: descriptor not delivered yet (rsync runs after ddrescue)"; continue; }
  grep -q "RW $SECTORS VMFS \"$n-flat.vmdk\"" "$d" \
    && ok "$n: RW $SECTORS VMFS -> $n-flat.vmdk" \
    || bad "$n: extent line is $(grep '^RW' "$d")"
done

#------------------------------------------------------------------------------
hdr "4. vmx structure"
for n in "${VMS[@]}"; do
  f=$(vmx_for "$DEST/$n" "$n")
  [[ -f $f ]] || { bad "$n: no vmx at $f"; continue; }
  dup=$(sed 's/[[:space:]]*=.*//' "$f" | grep -v '^$' | sort | uniq -d)
  [[ -z $dup ]] && ok "$n: no duplicate keys" || bad "$n: duplicate keys: $(echo $dup)"
  cr=$(tr -cd '\r' < "$f" | wc -c)
  [[ $cr -eq 0 ]] && ok "$n: LF endings, no CR" || bad "$n: $cr CR bytes - ESXi wants LF"
  # a leading dot is legal: ESXi itself writes .encoding as the first line
  mal=$(grep -vE '^\.?[A-Za-z_][A-Za-z0-9_.:]*[[:space:]]*=[[:space:]]*".*"$|^$' "$f")
  [[ -z $mal ]] && ok "$n: every line parses as key = \"value\"" || bad "$n: malformed -> $mal"
done

#------------------------------------------------------------------------------
hdr "5. Dead-host keys gone, CD-ROM detached"
for n in "${VMS[@]}"; do
  f=$(vmx_for "$DEST/$n" "$n"); [[ -f $f ]] || continue
  clean=1
  for k in 'numa\.autosize' 'migrate\.hostLog' 'migrate\.hostlog' \
           'sched\.swap\.derivedName' 'cdrom-image' '/vmfs/volumes/'; do
    grep -qE "$k" "$f" && { bad "$n: still contains $k"; clean=0; }
  done
  ((clean)) && ok "$n: no dead-host keys, no absolute /vmfs/volumes path"
  grep -q 'sata0:0.deviceType = "atapi-cdrom"'   "$f" && ok "$n: CD-ROM atapi-cdrom"        || bad "$n: CD-ROM deviceType"
  grep -q 'sata0:0.fileName = "auto detect"'     "$f" && ok "$n: CD-ROM auto detect"        || bad "$n: CD-ROM fileName"
  grep -q 'sata0:0.startConnected = "FALSE"'     "$f" && ok "$n: CD-ROM startConnected off" || bad "$n: CD-ROM startConnected"
done

#------------------------------------------------------------------------------
hdr "6. Sizing - and the rule that stops power-on"
total=0
for n in "${VMS[@]}"; do
  f=$(vmx_for "$DEST/$n" "$n"); [[ -f $f ]] || continue
  v=$(grep -oP '(?<=^numvcpus = ")[0-9]+'             "$f")
  m=$(grep -oP '(?<=^memSize = ")[0-9]+'              "$f")
  c=$(grep -oP '(?<=^cpuid\.coresPerSocket = ")[0-9]+' "$f")
  [[ ${m:-} == "$WANT_RAM" ]]  && ok "$n: memSize $m"  || bad "$n: memSize ${m:-unset}, expected $WANT_RAM"
  [[ ${v:-} == "$WANT_VCPU" ]] && ok "$n: numvcpus $v" || bad "$n: numvcpus ${v:-unset}, expected $WANT_VCPU"
  if [[ -n ${v:-} && -n ${c:-} ]] && (( v % c == 0 )); then
    ok "$n: coresPerSocket $c divides into numvcpus $v"
  else
    bad "$n: coresPerSocket ${c:-unset} does not divide into ${v:-unset} - power-on fails"
  fi
  total=$((total + ${m:-0}))
done
printf '  %s---- combined guest RAM: %s MB on a 32 GB host%s\n' "$DIM" "$total" "$R"
(( total <= 26624 )) && ok "leaves $(( (32768 - total) / 1024 )) GB for ESXi and headroom" \
                     || bad "over budget - ESXi needs ~6 GB of the 32"

#------------------------------------------------------------------------------
hdr "7. Identity preserved"
for n in "${VMS[@]}"; do
  f=$(vmx_for "$DEST/$n" "$n"); [[ -f $f ]] || continue
  grep -q "nvme0:0.fileName = \"$n.vmdk\"" "$f" \
    && ok "$n: disk reference is relative to its own folder" \
    || bad "$n: disk reference is $(grep -E 'nvme0:0.fileName|scsi0:0.fileName' "$f")"
  grep -q '^uuid.bios = ' "$f" && ok "$n: uuid.bios present (Windows activation)" || bad "$n: uuid.bios missing"
  printf '  %s       displayName %s%s\n' "$DIM" "$(grep -oP '(?<=^displayName = ").*(?=")' "$f")" "$R"
done

#------------------------------------------------------------------------------
hdr "8. Backups kept, and honest"
for n in "${VMS[@]}"; do
  found=0
  # Match both naming shapes: "<file>.original" and "<file>.<role>-original",
  # plus timestamped "<file>.bak-<stamp>". A glob of *.original alone silently
  # misses .production-original, because the separator there is a hyphen.
  shopt -s nullglob
  backups=("$DEST/$n/"*original "$DEST/$n/"*.bak-*)
  shopt -u nullglob
  for b in "${backups[@]}"; do
    found=$((found+1))
    # Only the copy taken from the live mount can be compared against it.
    case $b in
      *.vmx.original|*.vmx.testcfg-original)
        if [[ -f "$SRC/$n/$n.vmx" ]]; then
          cmp -s "$b" "$SRC/$n/$n.vmx" \
            && ok "$n: $(basename "$b") is byte-identical to the live source" \
            || warn "$n: $(basename "$b") differs from the live source vmx"
        else
          ok "$n: kept $(basename "$b") (source not mounted, not compared)"
        fi ;;
      *) ok "$n: kept $(basename "$b")" ;;
    esac
  done
  (( found )) || warn "$n: nothing preserved as *original / *.bak-* - edits are not reversible"
done

#------------------------------------------------------------------------------
hdr "9. Must not ship"
for n in "${VMS[@]}"; do
  shopt -s nullglob
  junk=("$DEST/$n/"*.lck "$DEST/$n/"*.vmss "$DEST/$n/"*.vmem "$DEST/$n/"*-00000*.vmdk)
  shopt -u nullglob
  if ((${#junk[@]})); then
    for j in "${junk[@]}"; do warn "$n: delete before transfer -> $(basename "$j")"; done
  else
    ok "$n: no lock, no suspend state, no snapshot delta chain"
  fi
done

#------------------------------------------------------------------------------
hdr "RESULT"
printf '  pass=%s%d%s  fail=%s%d%s  warn=%s%d%s\n' \
  "$GR" "$PASS" "$R" "$RD" "$FAIL" "$R" "$YL" "$WARN" "$R"
if (( FAIL == 0 && WARN == 0 )); then
  echo "  Everything staged under $DEST is ready to import."
elif (( FAIL == 0 )); then
  echo "  No failures. Warnings above are things to finish or clean up, not defects."
else
  echo "  $FAIL failure(s) - do not import until these are resolved."
fi
exit $(( FAIL > 0 ))
