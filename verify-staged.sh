#!/usr/bin/env bash
#===============================================================================
# verify-staged.sh - pre-flight check on the VM folders staged for a restore
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
#   ./verify-staged.sh                       # check every staged VM
#   ./verify-staged.sh --dest /mnt/e         # destination other than /mnt/d
#   ./verify-staged.sh --src  /mnt/vmfs      # source mount, for the backup diffs
#   ./verify-staged.sh --ram  8192           # require this memSize per VM
#   ./verify-staged.sh --vcpu 4              # require this numvcpus per VM
#   ./verify-staged.sh --host-ram 32768      # host RAM for the budget check
#===============================================================================

set -uo pipefail

DEST=/mnt/d
SRC=/mnt/vmfs
WANT_RAM=8192                     # only enforced when --ram is passed
WANT_VCPU=4                       # only enforced when --vcpu is passed
RAM_SET=0; VCPU_SET=0
HOST_RAM=32768                    # host RAM in MB, for the budget check
HOST_RESERVE=6144                 # what ESXi itself needs of it

while (($#)); do
  case $1 in
    --dest) DEST=${2:?}; shift 2 ;;
    --src)  SRC=${2:?};  shift 2 ;;
    --ram)  WANT_RAM=${2:?};  RAM_SET=1;  shift 2 ;;
    --vcpu) WANT_VCPU=${2:?}; VCPU_SET=1; shift 2 ;;
    --host-ram) HOST_RAM=${2:?}; shift 2 ;;
    -h|--help) sed -n '3,21p' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
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

# Expected image size for one VM, in 512-byte sectors. The descriptor sitting
# beside the copy is the authority; if rsync has not delivered it yet, fall back
# to the descriptor on the source mount, then to the source image itself. Prints
# nothing when none of the three can answer, and the caller reports that as
# unknown rather than inventing a size and failing the VM against it.
expected_sectors() {  # $1 = folder basename
  local n=$1 d line
  for d in "$DEST/$n/$n.vmdk" "$SRC/$n/$n.vmdk"; do
    [[ -f $d ]] || continue
    line=$(grep -m1 -E '^RW[[:space:]]+[0-9]+[[:space:]]+VMFS' "$d")
    if [[ -n $line ]]; then awk '{print $2}' <<<"$line"; return; fi
  done
  if [[ -f "$SRC/$n/$n-flat.vmdk" ]]; then
    echo $(( $(stat -c %s "$SRC/$n/$n-flat.vmdk") / 512 ))
  fi
}

# Human-readable size. GiB is the unit these images live in, but a small test
# or a copy that has barely started reads better in MiB than as 0.0 GiB.
gib() {
  awk -v b="${1:-0}" 'BEGIN{
    if (b >= 1073741824) printf "%.1f GiB", b/1073741824;
    else                 printf "%.1f MiB", b/1048576
  }'
}

# Whether each image has reached the size its descriptor declares. Section 2
# reads this: on an image that is still being written, a missing boot structure
# is a "not yet", and only on a finished image is it a defect.
declare -A COMPLETE

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
  sec=$(expected_sectors "$n"); exp=$(( ${sec:-0} * 512 ))
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
  gpt=$(dd if="$f" bs=512 count=1 skip=1 2>/dev/null | tr -d '\0' | head -c 8)
  if [[ $sig == 55aa ]]; then
    ok "$n: protective MBR signature 55aa"
  elif [[ ${COMPLETE[$n]} == 1 ]]; then
    bad "$n: sector 0 reads '$sig'"
  else
    warn "$n: sector 0 reads '$sig', but the copy is unfinished - recheck at the end"
  fi
  if [[ $gpt == "EFI PART" ]]; then
    ok "$n: valid EFI PART GPT header"
  elif [[ ${COMPLETE[$n]} == 1 ]]; then
    bad "$n: sector 1 reads '$gpt'"
  else
    warn "$n: sector 1 reads '$gpt', but the copy is unfinished - recheck at the end"
  fi
done

#------------------------------------------------------------------------------
hdr "3. Descriptor agrees with the image"
for n in "${VMS[@]}"; do
  d="$DEST/$n/$n.vmdk"
  [[ -f $d ]] || { warn "$n: descriptor not delivered yet (rsync runs after ddrescue)"; continue; }
  line=$(grep -m1 '^RW' "$d")
  sec=$(awk '{print $2}' <<<"$line"); typ=$(awk '{print $3}' <<<"$line")
  ext=$(sed -e 's/^[^"]*"//' -e 's/".*$//' <<<"$line")
  s=$(stat -c %s "$DEST/$n/$n-flat.vmdk")
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
  # A CD-ROM can hang off sata, ide, or scsi, so find whichever device calls
  # itself an atapi-cdrom instead of assuming the controller this recovery used.
  # The dots in the greps below stand in for the quote characters around a value.
  cdrom=$(awk -F. '/[.]deviceType = "atapi-cdrom"/{print $1; exit}' "$f")
  if [[ -z $cdrom ]]; then
    ok "$n: no CD-ROM device to detach"
  else
    grep -q "^$cdrom[.]fileName = .auto detect.$"   "$f" && ok "$n: $cdrom auto detect"        || bad "$n: $cdrom fileName"
    grep -q "^$cdrom[.]startConnected = .FALSE.$"   "$f" && ok "$n: $cdrom startConnected off" || bad "$n: $cdrom startConnected"
  fi
done

#------------------------------------------------------------------------------
hdr "6. Sizing - and the rule that stops power-on"
total=0
BUDGET=$(( HOST_RAM - HOST_RESERVE ))
for n in "${VMS[@]}"; do
  f=$(vmx_for "$DEST/$n" "$n"); [[ -f $f ]] || continue
  v=$(grep -oP '(?<=^numvcpus = ")[0-9]+'             "$f")
  m=$(grep -oP '(?<=^memSize = ")[0-9]+'              "$f")
  c=$(grep -oP '(?<=^cpuid\.coresPerSocket = ")[0-9]+' "$f")
  # --ram and --vcpu become requirements only when you state them. Left unset,
  # the values are reported rather than judged, because there is no generally
  # correct memSize for someone else's VM.
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
printf '  %s---- combined guest RAM: %s MB of a %s MB host%s\n' "$DIM" "$total" "$HOST_RAM" "$R"
if (( total <= BUDGET )); then
  ok "leaves $(( (HOST_RAM - total) / 1024 )) GB for ESXi and headroom"
else
  bad "over budget - ESXi needs about $(( HOST_RESERVE / 1024 )) GB of the $(( HOST_RAM / 1024 ))"
fi

#------------------------------------------------------------------------------
hdr "7. Identity preserved"
for n in "${VMS[@]}"; do
  f=$(vmx_for "$DEST/$n" "$n"); [[ -f $f ]] || continue
  # Any controller can carry the disk, so read every fileName value and compare
  # it as a literal string, not as a pattern: these folder names contain dots.
  ref=0
  while IFS= read -r val; do
    [[ $val == "$n.vmdk" ]] && ref=1
  done < <(awk -F'"' '/^[a-z]+[0-9]+:[0-9]+[.]fileName = /{print $2}' "$f")
  if (( ref )); then
    ok "$n: disk reference is relative to its own folder"
  else
    bad "$n: no controller line points at $n.vmdk"
  fi
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
