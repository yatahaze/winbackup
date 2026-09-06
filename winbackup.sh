#!/usr/bin/env bash
# winbackup.sh -- back up Windows user data from a Linux live USB into a plain folder tree.
#
#   sudo bash winbackup.sh                 interactive backup (menus)
#   sudo bash winbackup.sh --dry-run       do everything except the copy; nothing is written to the destination
#   sudo bash winbackup.sh --restore       copy categories from a previous backup back onto a Windows drive
#   sudo bash winbackup.sh --src DIR --dst DIR [--extra DIR]...
#                                          use already-mounted directories instead of picking partitions
#   bash winbackup.sh --answers FILE ...   scripted mode: read menu answers from FILE (used by tests/selftest.sh)
#
# Needs only what the Pop!_OS live ISO ships: bash, whiptail, rsync, ntfs-3g, python3 (stdlib), lsblk, du.
# Companion file: winbackup-excludes.txt next to this script (created with defaults if missing).
#
# Design notes (the non-obvious bits):
#  * One rsync per source DRIVE, rooted at the drive root. What you selected becomes rsync
#    include rules (see gen_filter). This means (a) the output mirrors C:\ exactly and
#    (b) every pattern in the exclude file is matched against "Users/x/AppData/..." paths,
#    so "AppData/Local/Temp/" works no matter which categories you picked.
#  * The size estimate is an rsync --dry-run with the same rules, so it agrees with what
#    the copy will do and is resume-aware ("to copy now" excludes files already present).
#  * The source is only ever mounted read-only. The two fallbacks that touch NTFS metadata
#    (ntfsfix, remove_hiberfile) are only tried if every read-only attempt failed AND you say yes.
#  * Symlinks/junctions (e.g. "My Documents" -> Documents compatibility links) are skipped,
#    since ntfs-3g shows junctions as symlinks and they point at things we copy anyway.

set -u
shopt -s nullglob
umask 022
VERSION="2.0"

# ---------------------------------------------------------------- args
DRY=0; MODE=backup; SRC_OVERRIDE=""; DST_OVERRIDE=""; EXTRA_OVERRIDES=(); ANSWERS=""; EXCL_SUMMARY=1
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1;;
    --restore) MODE=restore;;
    --src) SRC_OVERRIDE=$2; shift;;
    --dst) DST_OVERRIDE=$2; shift;;
    --extra) EXTRA_OVERRIDES+=("$2"); shift;;
    --answers) ANSWERS=$2; shift;;
    --no-excluded-summary) EXCL_SUMMARY=0;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
  shift
done

# ---------------------------------------------------------------- basics
die()  { echo "ERROR: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }
hr()   { numfmt --to=iec --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }
now()  { date '+%Y-%m-%d %H:%M:%S'; }

for t in rsync whiptail lsblk du python3 findmnt; do command -v "$t" >/dev/null 2>&1 || die "Missing tool: $t"; done
if [ -z "$SRC_OVERRIDE" ] && [ "$EUID" -ne 0 ]; then die "Run with sudo (needed to mount drives)."; fi

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
EXC_FILE="$SCRIPT_DIR/winbackup-excludes.txt"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/winbackup.XXXXXX")
MNT=/mnt/winbackup
OUR_MOUNTS=()
STAMP_DATE=$(date +%Y-%m-%d)

cleanup() {
  local rc=$?
  sync
  # unmount in reverse order of mounting; lazy unmount as a fallback so we never hang at exit
  local i
  for (( i=${#OUR_MOUNTS[@]}-1; i>=0; i-- )); do
    umount "${OUR_MOUNTS[$i]}" 2>/dev/null || umount -l "${OUR_MOUNTS[$i]}" 2>/dev/null
  done
  [ ${#OUR_MOUNTS[@]} -gt 0 ] && echo "Unmounted ${#OUR_MOUNTS[@]} drive(s). Safe to reboot/unplug."
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM

# ---------------------------------------------------------------- prompts
# All user interaction goes through ask_* so that --answers FILE can drive the script
# non-interactively (one answer per line, in the order the questions are asked).
# Answers are read from fd 9 so the cursor survives the $(...) subshells the prompts run in
# (bash seeks a regular file back to just after the line it consumed).
if [ -n "$ANSWERS" ]; then exec 9<"$ANSWERS" || die "--answers: cannot read $ANSWERS"; fi
next_answer() {
  local a; IFS= read -r -u 9 a || die "--answers: ran out of answers"
  printf '%s\n' "$a"
}
text_lines() { printf '%s\n' "$1" | wc -l; }
dlg_h() {  # clamp a dialog height to the terminal (whiptail --scrolltext handles the overflow)
  local max; max=$(tput lines 2>/dev/null || echo 24); max=$(( max - 2 ))
  [ "$1" -gt "$max" ] && echo "$max" || echo "$1"
}
stat_num() {  # file key -> number from an rsync --stats line (0 if absent)
  local v; v=$(grep -m1 "^$2" "$1" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"
}
# rsync patterns treat * ? [ ] \ as wildcards; escape them in paths we generate rules from
esc() { printf '%s\n' "$1" | sed 's/[][*?\\]/\\&/g'; }

ask_menu() {   # title text tag item [tag item...]  -> chosen tag
  local t=$1 m=$2; shift 2
  if [ -n "$ANSWERS" ]; then local a; a=$(next_answer); echo "[$t] -> $a" >&2; printf '%s\n' "$a"; return; fi
  local n=$(( $# / 2 )) h; h=$(( n < 12 ? n : 12 ))
  whiptail --title "$t" --menu "$m" "$(dlg_h $(( h + 7 + $(text_lines "$m") )))" 90 "$h" "$@" 3>&1 1>&2 2>&3
}
ask_check() {  # title text tag item ON|OFF ...  -> chosen tags, one per line
  local t=$1 m=$2; shift 2
  if [ -n "$ANSWERS" ]; then
    local a; a=$(next_answer)
    if [ "$a" = "@all" ]; then local k; for (( k=1; k<=$#; k+=3 )); do printf '%s\n' "${!k}"; done
    elif [ -n "$a" ]; then tr ';' '\n' <<<"$a"; fi
    return 0
  fi
  local n=$(( $# / 3 )) h; h=$(( n < 12 ? n : 12 ))
  whiptail --title "$t" --separate-output --checklist "$m" "$(dlg_h $(( h + 7 + $(text_lines "$m") )))" 90 "$h" "$@" 3>&1 1>&2 2>&3
}
ask_input() {  # title text default -> string
  if [ -n "$ANSWERS" ]; then local a; a=$(next_answer); [ "$a" = "@default" ] && a=$3; printf '%s\n' "$a"; return; fi
  whiptail --title "$1" --inputbox "$2" "$(dlg_h $(( 8 + $(text_lines "$2") )))" 80 "$3" 3>&1 1>&2 2>&3
}
ask_yesno() {  # title text [--defaultno] -> 0 yes / 1 no
  if [ -n "$ANSWERS" ]; then local a; a=$(next_answer); [ "$a" = yes ]; return; fi
  local extra=(); [ -n "${3:-}" ] && extra=("$3")
  whiptail --title "$1" --scrolltext --yesno "$2" "$(dlg_h $(( 6 + $(text_lines "$2") )))" 90 "${extra[@]}"
}
ask_msg() {    # title text
  if [ -n "$ANSWERS" ]; then printf '\n[%s]\n%s\n' "$1" "$2" >&2; return; fi
  whiptail --title "$1" --scrolltext --msgbox "$2" "$(dlg_h $(( 6 + $(text_lines "$2") )))" 90
}

# ---------------------------------------------------------------- partitions
# list_parts [fstype-regex] -> lines "dev|fstype|size|label|mountpoint"
list_parts() {
  local want=${1:-'ntfs|exfat|vfat|ext4|ext3|xfs|btrfs'} line NAME FSTYPE SIZE LABEL MOUNTPOINT TYPE
  lsblk -pnP -o NAME,FSTYPE,SIZE,LABEL,MOUNTPOINT,TYPE 2>/dev/null | while read -r line; do
    # lsblk -P prints KEY="value" pairs with shell-safe escaping, so eval is the intended way to read it
    NAME=""; FSTYPE=""; SIZE=""; LABEL=""; MOUNTPOINT=""; TYPE=""
    eval "$line"
    [[ "$FSTYPE" =~ ^($want)$ ]] || continue
    [ "$TYPE" = part ] || [ "$TYPE" = disk ] || [ "$TYPE" = crypt ] || continue
    printf '%s|%s|%s|%s|%s\n' "$NAME" "$FSTYPE" "$SIZE" "$LABEL" "$MOUNTPOINT"
  done
}
# pick_part title text fstype-regex [exclude-dev] -> device
pick_part() {
  local items=() dev fs size label mp desc
  while IFS='|' read -r dev fs size label mp; do
    [ -n "${4:-}" ] && [ "$dev" = "$4" ] && continue
    desc="${label:-(no label)}  $size  $fs"
    [ -n "$mp" ] && desc="$desc  [mounted: $mp]"
    items+=("$dev" "$desc")
  done < <(list_parts "$3")
  [ ${#items[@]} -gt 0 ] || { ask_msg "No partitions" "No suitable partitions found (looked for: $3).\nIs the drive plugged in? Check with: lsblk -f"; return 1; }
  ask_menu "$1" "$2" "${items[@]}"
}
part_label() { lsblk -no LABEL "$1" 2>/dev/null | head -1; }
part_fstype() { lsblk -no FSTYPE "$1" 2>/dev/null | head -1; }
current_mount() { findmnt -rn -o TARGET -S "$1" 2>/dev/null | head -1; }
current_mount_opts() { findmnt -rn -o OPTIONS -S "$1" 2>/dev/null | head -1; }

# try_mount dev mountpoint fstype options  (fstype "" = let mount pick)
try_mount() {
  echo "$(now) mount -t ${3:-auto} -o $4 $1 $2" >>"$WORK/mount.log"
  if [ -n "$3" ]; then mount -t "$3" -o "$4" "$1" "$2" >>"$WORK/mount.log" 2>&1
  else mount -o "$4" "$1" "$2" >>"$WORK/mount.log" 2>&1; fi
}
mount_log_tail() { tail -n 6 "$WORK/mount.log" 2>/dev/null; }

# mount_ro dev mountpoint  -> prints the directory to read from
# Read-only chain: ntfs-3g ro -> kernel ntfs3 ro -> ntfs3 ro,force. Handles the usual
# "unclean / hibernated / fast-startup" states without touching the disk. Only if all of those
# fail do we offer ntfsfix (clears the dirty flag) and remove_hiberfile (deletes hiberfil.sys).
mount_ro() {   # dev mountpoint [quiet]  (quiet = no interactive fallbacks; used for extra drives)
  local dev=$1 mp=$2 quiet=${3:-} fs cur
  fs=$(part_fstype "$dev")
  cur=$(current_mount "$dev")
  if [ -n "$cur" ]; then
    # The live desktop auto-mounts drives read-write. Prefer to remount read-only ourselves;
    # if it is busy (file manager open) we just use it as-is -- we never write to it either way.
    if umount "$cur" 2>>"$WORK/mount.log"; then :; else
      note "$dev is in use at $cur; using that mount (read only)."; echo "$cur"; return 0
    fi
  fi
  mkdir -p "$mp"
  if [ "$fs" != ntfs ]; then
    try_mount "$dev" "$mp" "" ro && { OUR_MOUNTS+=("$mp"); echo "$mp"; return 0; }
    return 1
  fi
  local a
  for a in "ntfs-3g|ro" "ntfs3|ro" "ntfs3|ro,force"; do
    try_mount "$dev" "$mp" "${a%%|*}" "${a#*|}" && { OUR_MOUNTS+=("$mp"); echo "$mp"; return 0; }
  done
  [ -n "$quiet" ] && return 1
  if ask_yesno "Source mount failed" "$(printf 'Could not mount %s read-only.\n\n%s\n\nLast resort 1: run "ntfsfix -d" on it. This clears the NTFS dirty flag and\nresets the journal (a tiny metadata write; no file data is touched). Try it?' "$dev" "$(mount_log_tail)")"; then
    ntfsfix -d "$dev" >>"$WORK/mount.log" 2>&1
    try_mount "$dev" "$mp" ntfs-3g ro && { OUR_MOUNTS+=("$mp"); echo "$mp"; return 0; }
  fi
  if ask_yesno "Source mount failed" "$(printf 'Still could not mount %s.\n\nLast resort 2: mount once with remove_hiberfile (deletes hiberfil.sys, i.e. the\nsaved hibernation state) and then remount read-only. Try it?' "$dev")"; then
    try_mount "$dev" "$mp" ntfs-3g remove_hiberfile && umount "$mp" 2>>"$WORK/mount.log"
    try_mount "$dev" "$mp" ntfs-3g ro && { OUR_MOUNTS+=("$mp"); echo "$mp"; return 0; }
  fi
  return 1
}

# mount_rw dev mountpoint -> prints writable directory (destination only; fixes are automatic here)
mount_rw() {
  local dev=$1 mp=$2 fs cur
  fs=$(part_fstype "$dev")
  cur=$(current_mount "$dev")
  if [ -n "$cur" ]; then
    if [[ ",$(current_mount_opts "$dev")," == *,rw,* ]]; then echo "$cur"; return 0; fi
    umount "$cur" 2>>"$WORK/mount.log" || { note "$dev is mounted read-only at $cur and busy."; return 1; }
  fi
  mkdir -p "$mp"
  if [ "$fs" != ntfs ]; then
    try_mount "$dev" "$mp" "" rw && { OUR_MOUNTS+=("$mp"); echo "$mp"; return 0; }
    return 1
  fi
  if ! try_mount "$dev" "$mp" ntfs-3g rw; then
    note "Destination is marked unclean/hibernated; running ntfsfix -d $dev"
    ntfsfix -d "$dev" >>"$WORK/mount.log" 2>&1
    if ! try_mount "$dev" "$mp" ntfs-3g rw; then
      # hibernated destination: remove the hiberfile (it is useless without the Windows install it belongs to)
      try_mount "$dev" "$mp" ntfs-3g rw,remove_hiberfile && umount "$mp" 2>>"$WORK/mount.log"
      try_mount "$dev" "$mp" ntfs-3g rw || try_mount "$dev" "$mp" ntfs3 rw,force || return 1
    fi
  fi
  OUR_MOUNTS+=("$mp"); echo "$mp"
}

# resolve_ci base relpath -> base/relpath with each existing component matched case-insensitively
resolve_ci() {
  local cur=$1 rel=${2#/} comp m
  IFS='/' read -r -a parts <<<"$rel"
  for comp in "${parts[@]}"; do
    [ -z "$comp" ] && continue
    if [ -e "$cur/$comp" ]; then cur="$cur/$comp"; continue; fi
    m=$(find "$cur" -mindepth 1 -maxdepth 1 -iname "$comp" -print -quit 2>/dev/null)
    if [ -n "$m" ]; then cur=$m; else cur="$cur/$comp"; fi
  done
  printf '%s\n' "$cur"
}
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._ -' '_'; }

# ---------------------------------------------------------------- python helpers (stdlib only)
# Progress renderer: reads rsync --info=progress2,name1 output and draws two lines:
# overall progress across all jobs (using the pre-computed size estimate) and the current file.
read -r -d '' PY_PROGRESS <<'PY'
import sys, re, time, os
label, offset, total, statsfile = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
prog = re.compile(r'^\s*([\d,]+)\s+(\d+)%\s+(\S+)\s+(\d+:\d+:\d+)')
statkeys = ('Number of files', 'Number of regular files transferred', 'Total file size', 'Total transferred file size')
noise = ('sending incremental', 'sent ', 'total size', 'Number of', 'Total ', 'File list', 'Literal data',
         'Matched data', 'skipping', 'created directory', 'rsync', '(DRY RUN)', 'delta-transmission')
def hr(n):
    for u in ('B','K','M','G','T'):
        if n < 1024 or u == 'T': return f'{n:.1f}{u}' if u != 'B' else f'{int(n)}B'
        n /= 1024
def cols():
    try: return os.get_terminal_size().columns
    except OSError: return 100
stats, cur, done, rate, t0, last = [], '', 0, '', time.time(), 0.0
def draw():
    ov = min(offset + done, total) if total else 0
    pct = int(100 * ov / total) if total else 100
    el = time.time() - t0
    eta = ''
    if done > 0 and el > 2 and total:
        rem = (total - ov) / (done / el); eta = f'ETA {int(rem//3600)}:{int(rem%3600//60):02d}:{int(rem%60):02d}'
    l1 = f'{label}  overall {pct:3d}%  {hr(ov)} / {hr(total)}   {rate}  {eta}'
    w = cols(); l2 = '  ' + (cur if len(cur) < w - 3 else '...' + cur[-(w - 6):])
    sys.stdout.write('\r\x1b[2K' + l1[:w-1] + '\n\x1b[2K' + l2[:w-1] + '\x1b[1A\r'); sys.stdout.flush()
buf = ''
while True:
    chunk = sys.stdin.buffer.read(8192)
    if not chunk: break
    buf += chunk.decode('utf-8', 'replace')
    parts = re.split(r'[\r\n]', buf); buf = parts.pop()
    for line in parts:
        if not line.strip(): continue
        m = prog.match(line)
        if m:
            done = int(m.group(1).replace(',', '')); rate = m.group(3)
        elif line.startswith(statkeys):
            stats.append(line)
        elif not line.startswith(noise):
            cur = line
        if time.time() - last > 0.15:
            draw(); last = time.time()
draw(); sys.stdout.write('\n\n'); sys.stdout.flush()
with open(statsfile, 'w') as f: f.write('\n'.join(stats) + '\n')
PY

# Excluded-folders summary: takes "abs_path<TAB>pattern" lines, sizes them with du, writes a report.
read -r -d '' PY_EXCL <<'PY'
import sys, subprocess, collections
hidden, outfile, topn = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = []
with open(hidden, encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.rstrip('\n')
        if line.count('\t') == 2: rows.append(tuple(line.split('\t')))
sizes = {}
if rows:
    inp = b''.join(p.encode('utf-8', 'surrogateescape') + b'\0' for p, _, _ in rows)
    out = subprocess.run(['du', '-sb', '--files0-from=-'], input=inp, capture_output=True).stdout
    for l in out.decode('utf-8', 'replace').splitlines():
        if '\t' in l:
            s, p = l.split('\t', 1)
            try: sizes[p] = int(s)
            except ValueError: pass
def hr(n):
    for u in ('B','K','M','G','T'):
        if n < 1024 or u == 'T': return f'{n:.1f}{u}' if u != 'B' else f'{int(n)}B'
        n /= 1024
items = sorted(((sizes.get(p, 0), disp, pat) for p, disp, pat in rows), reverse=True)
total = sum(s for s, _, _ in items)
bypat = collections.Counter()
for s, _, pat in items: bypat[pat] += s
with open(outfile, 'w') as f:
    f.write(f'Excluded by winbackup-excludes.txt: {hr(total)} in {len(items)} paths\n\n')
    f.write(f'--- largest {min(topn, len(items))} excluded paths ---\n')
    for s, p, pat in items[:topn]: f.write(f'{hr(s):>9}  {p}    [{pat}]\n')
    f.write('\n--- total per pattern ---\n')
    for pat, s in bypat.most_common(): f.write(f'{hr(s):>9}  {pat}\n')
print(total)
for s, p, pat in items[:8]: print(f'{hr(s):>9}  {p if len(p) <= 72 else "..." + p[-69:]}')
PY

# Store-only zip (no deflate: speed over size), zip64 so >4GB archives and files work.
read -r -d '' PY_ZIP <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
base = os.path.basename(src.rstrip('/'))
files, total = [], 0
for dp, dn, fn in os.walk(src):
    for n in fn:
        p = os.path.join(dp, n)
        try: s = os.path.getsize(p)
        except OSError: continue
        files.append((p, s)); total += s
done = n = 0
with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_STORED, allowZip64=True) as z:
    for p, s in files:
        try: z.write(p, os.path.join(base, os.path.relpath(p, src)))
        except OSError as e: print(f'\nzip: skipped {p}: {e}', file=sys.stderr)
        n += 1; done += s
        if n % 100 == 0 or n == len(files):
            print(f'\r  zip: {n}/{len(files)} files  {done/2**30:.2f} / {total/2**30:.2f} GiB', end='', flush=True)
print()
PY

# ---------------------------------------------------------------- exclude file
ensure_exclude_file() {
  [ -f "$EXC_FILE" ] && return
  note "No $EXC_FILE found; writing built-in defaults there (edit it and rerun to change)."
  # A minimal default so the script still works if the companion file is missing.
  cat >"$EXC_FILE" <<'X'
# winbackup-excludes.txt (auto-generated minimal defaults; see project README for the full list)
NTUSER.DAT*
ntuser.dat*
UsrClass.dat*
*.tmp
Thumbs.db
$RECYCLE.BIN/
System Volume Information/
AppData/Local/Temp/
AppData/Local/Microsoft/Windows/INetCache/
AppData/Local/Microsoft/Windows/WebCache/
AppData/Local/Microsoft/Windows/Explorer/thumbcache_*
AppData/Local/Packages/*/LocalCache/
AppData/Local/Packages/*/TempState/
AppData/Local/Packages/*/AC/
AppData/**/Cache/
AppData/**/Code Cache/
AppData/**/GPUCache/
AppData/**/Service Worker/CacheStorage/
AppData/Local/NVIDIA/
AppData/Local/D3DSCache/
node_modules/
steamapps/shadercache/
steamapps/downloading/
steamapps/temp/
X
}

# ---------------------------------------------------------------- drives / jobs model
# DRV_ROOT[i]   directory the drive is readable at (rsync source root)
# DRV_NAME[i]   "C" for the Windows drive, otherwise Drive_<label>
# DRV_PREFIX[i] "" for C, "Drive_<label>/" for others (subfolder inside the backup)
# DRV_WANT[i]   newline-separated relative paths to copy
# DRV_XCL[i]    newline-separated relative paths to explicitly exclude (category turned off)
DRV_ROOT=(); DRV_NAME=(); DRV_DEV=(); DRV_PREFIX=(); DRV_WANT=(); DRV_XCL=()
add_drive() { DRV_ROOT+=("$1"); DRV_NAME+=("$2"); DRV_DEV+=("$3"); DRV_PREFIX+=("$4"); DRV_WANT+=(""); DRV_XCL+=(""); }
want() { DRV_WANT[$1]+="$2"$'\n'; }
xcl()  { DRV_XCL[$1]+="$2"$'\n'; }

# gen_filter i -> writes $WORK/filter_$i, an rsync merge-file:
#   - explicit excludes (categories the user turned off)
#   + every wanted path and each of its ancestors
#   - <ancestor>/*   for ancestors that are not themselves wanted (so siblings are not copied)
#   - /*             nothing else at the drive root
# Combined with --exclude-from (junk, listed FIRST on the rsync command line so it wins).
gen_filter() {
  local i=$1 f="$WORK/filter_$1" root=${DRV_ROOT[$1]} w p
  declare -A leaf=() anc=()
  : >"$f"
  while IFS= read -r w; do [ -n "$w" ] && echo "- /$w" >>"$f"; done <<<"${DRV_XCL[$i]}"   # already escaped by caller
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    leaf[$w]=1
    p=$w; while [[ "$p" == */* ]]; do p=${p%/*}; anc[$p]=1; done
  done <<<"${DRV_WANT[$i]}"
  for w in "${!leaf[@]}"; do
    if [ -d "$root/$w" ]; then echo "+ /$(esc "$w")/" >>"$f"; else echo "+ /$(esc "$w")" >>"$f"; fi
  done
  for w in "${!anc[@]}"; do [ -n "${leaf[$w]:-}" ] || echo "+ /$(esc "$w")/" >>"$f"; done
  for w in "${!anc[@]}"; do [ -n "${leaf[$w]:-}" ] || echo "- /$(esc "$w")/*" >>"$f"; done
  echo "- /*" >>"$f"
}

# rsync options shared by estimate/copy/verify. No -l: junctions show up as symlinks, skip them.
RS_BASE=(-r -t --no-perms --no-owner --no-group --modify-window=2 --partial --info=nonreg0)

# ================================================================= BACKUP
backup_main() {
  ensure_exclude_file
  local SRC SRC_DEV="" DST_DEV="" DSTROOT DST NAME RESUMED=0

  # ---- 1. source drive ----
  if [ -n "$SRC_OVERRIDE" ]; then
    SRC=$(readlink -f "$SRC_OVERRIDE"); [ -d "$SRC" ] || die "--src not a directory: $SRC"
  else
    SRC_DEV=$(pick_part "SOURCE: which partition is the Windows C: drive?" \
      "Pick the partition that holds \\Users and \\Windows. It will be mounted READ-ONLY.
Drives the live desktop already opened are shown with [mounted: ...]." ntfs) || exit 1
    SRC=$(mount_ro "$SRC_DEV" "$MNT/src") || { ask_msg "Mount failed" "Could not mount $SRC_DEV read-only.
$(mount_log_tail)"; exit 1; }
  fi
  [ -d "$SRC/Users" ] || ask_yesno "No Users folder" "No \\Users folder found on the source ($SRC).
Is this really the Windows drive? Continue anyway (you can still pick root folders)?" || exit 1
  add_drive "$SRC" "C" "$SRC_DEV" ""

  # ---- 2. destination drive + folder ----
  if [ -n "$DST_OVERRIDE" ]; then
    DSTROOT=$(readlink -f "$DST_OVERRIDE"); [ -d "$DSTROOT" ] || die "--dst not a directory: $DSTROOT"
  else
    DST_DEV=$(pick_part "DESTINATION: where should the backup go?" \
      "Pick the partition to write to (e.g. the DrivePool disk). It will be mounted read-write." \
      'ntfs|exfat|vfat|ext4|ext3|xfs|btrfs' "$SRC_DEV") || exit 1
    [ "$DST_DEV" = "$SRC_DEV" ] && die "Source and destination are the same partition."
    if [ "$DRY" = 1 ]; then
      DSTROOT=$(mount_ro "$DST_DEV" "$MNT/dst") || { ask_msg "Mount failed" "Could not mount $DST_DEV.
$(mount_log_tail)"; exit 1; }
    else
      DSTROOT=$(mount_rw "$DST_DEV" "$MNT/dst") || { ask_msg "Mount failed" "Could not mount $DST_DEV read-write.
$(mount_log_tail)"; exit 1; }
    fi
    [ "$(part_fstype "$DST_DEV")" = vfat ] && ask_msg "FAT32 destination" "Warning: $DST_DEV is FAT32, which cannot hold files over 4 GB. Such files will fail and be listed in _errors.log. exFAT or NTFS is better."
  fi
  case "$DSTROOT/" in "$SRC/"*) die "Destination is inside the source drive.";; esac

  # top-level folder on the destination (PoolPart.* folders are DrivePool's; hidden on Windows)
  local items=("/" "(drive root)") d n
  for d in "$DSTROOT"/* "$DSTROOT"/.[!.]*; do
    [ -d "$d" ] || continue; n=$(basename "$d")
    case "$n" in 'System Volume Information'|'$RECYCLE.BIN'|'$Recycle.Bin'|'found.000') continue;; esac
    if [[ "$n" == PoolPart.* ]]; then items+=("$n" "DrivePool folder: files put here show up in the pool"); else items+=("$n" ""); fi
  done
  items+=("__type__" "(type a path; matched case-insensitively)")
  local SUB
  SUB=$(ask_menu "Destination folder" "Where on ${DST_DEV:-$DSTROOT} should the backup folder be created?" "${items[@]}") || exit 1
  if [ "$SUB" = "__type__" ]; then
    SUB=$(ask_input "Destination path" "Path on the destination drive (created if missing; case-insensitive match):" "PoolPart.xxxx/Backups") || exit 1
  fi
  [ "$SUB" = "/" ] && SUB=""
  local BASE; BASE=$(resolve_ci "$DSTROOT" "$SUB")
  NAME=$(ask_input "Backup folder name" "Name of the backup folder inside $(basename "${BASE:-/}")/
(rerun with the same name later to RESUME an interrupted backup):" "WinBackup_$STAMP_DATE") || exit 1
  [ -n "$NAME" ] || die "Empty folder name."
  DST=$(resolve_ci "$BASE" "$NAME")
  if [ -d "$DST" ]; then
    local started; started=$(grep -m1 '^Started:' "$DST/_summary.txt" 2>/dev/null | cut -d' ' -f2-)
    if ask_yesno "Folder exists" "$DST already exists${started:+ (backup started $started)}.

RESUME into it? Files already copied are skipped, so this continues where it left off.
Choose No to create a new folder with the time appended instead."; then
      RESUMED=1
    else
      DST="$BASE/${NAME}_$(date +%H%M)"
    fi
  fi
  if [ "$DRY" = 0 ]; then
    mkdir -p "$DST" || die "Cannot create $DST"
    touch "$DST/.winbackup_write_test" 2>/dev/null || die "Destination is not writable: $DST"
    rm -f "$DST/.winbackup_write_test"
  fi

  # ---- 3. other NTFS drives (D:, E:) mounted read-only for Steam scan / extra folders ----
  local dev fs size label mp x i
  if [ -n "$SRC_OVERRIDE" ]; then
    for x in "${EXTRA_OVERRIDES[@]}"; do add_drive "$(readlink -f "$x")" "Drive_$(sanitize "$(basename "$x")")" "" "Drive_$(sanitize "$(basename "$x")")/"; done
  else
    i=0
    while IFS='|' read -r dev fs size label mp; do
      [ "$dev" = "$SRC_DEV" ] && continue; [ "$dev" = "$DST_DEV" ] && continue
      i=$((i+1))
      local r; r=$(mount_ro "$dev" "$MNT/extra$i" quiet 2>/dev/null) || { note "Skipping $dev (could not mount read-only)"; continue; }
      local dn; dn="Drive_$(sanitize "${label:-$(basename "$dev")}")"
      add_drive "$r" "$dn" "$dev" "$dn/"
    done < <(list_parts ntfs)
  fi

  # ---- 4. users ----
  local USERS=() u
  if [ -d "$SRC/Users" ]; then
    items=()
    for d in "$SRC"/Users/*/; do
      n=$(basename "$d")
      case "$n" in Default|"Default User"|"All Users"|defaultuser0|WDAGUtilityAccount) continue;; esac
      if [ "$n" = Public ]; then items+=("$n" "(shared Public Desktop/Documents/etc.)" ON); else items+=("$n" "" ON); fi
    done
    if [ ${#items[@]} -gt 0 ]; then
      local out; out=$(ask_check "User profiles" "Which user profiles to back up? (Space toggles, Enter confirms)" "${items[@]}") || exit 1
      [ -n "$out" ] && mapfile -t USERS <<<"$out"
    fi
  fi

  # ---- 5. categories ----
  local CATS
  CATS=$(ask_check "What to back up" "Space toggles, Enter confirms. Junk (caches, temp, registry hives) is always skipped:" \
    docs     "Desktop, Documents, Downloads, Pictures, Videos, Music, Saved Games, Favorites, Contacts" ON \
    roaming  "AppData\\Roaming  (app settings, browser profiles, game saves)" ON \
    local    "AppData\\Local + LocalLow  (bigger: browser/Discord data, Unity saves, app data)" ON \
    dotfiles "Hidden home files (.ssh, .gitconfig, .config, .vscode, ...)" ON \
    other    "Everything else in the profile (OneDrive, misc folders and files)" ON \
    steam    "Steam libraries: steamapps + userdata (scanned on all NTFS drives)" ON \
    root     "Other folders at the root of C: (you pick next; Windows.old is listed)" OFF \
    pdata    "ProgramData (shared app data; can be large)" OFF \
    ) || exit 1
  has() { grep -qx "$1" <<<"$CATS"; }
  local DOCS=(Desktop Documents Downloads Pictures Videos Music "Saved Games" Favorites Contacts Links Searches "3D Objects")
  for u in "${USERS[@]}"; do
    local P="$SRC/Users/$u" R="Users/$u"
    if has docs; then for d in "${DOCS[@]}"; do [ -e "$P/$d" ] && want 0 "$R/$d"; done; fi
    has roaming && [ -d "$P/AppData/Roaming" ] && want 0 "$R/AppData/Roaming"
    if has local; then for d in Local LocalLow; do [ -d "$P/AppData/$d" ] && want 0 "$R/AppData/$d"; done; fi
    if has dotfiles; then for d in "$P"/.[!.]* "$P"/..?*; do want 0 "$R/$(basename "$d")"; done; fi
    if has other; then
      want 0 "$R"
      has docs     || for d in "${DOCS[@]}"; do xcl 0 "$(esc "$R/$d")/"; done
      has roaming  || xcl 0 "$(esc "$R/AppData/Roaming")/"
      has local    || { xcl 0 "$(esc "$R/AppData/Local")/"; xcl 0 "$(esc "$R/AppData/LocalLow")/"; }
      has dotfiles || xcl 0 "$(esc "$R")/.*"
    fi
  done

  # ---- 6. Steam libraries anywhere on any NTFS drive ----
  if has steam; then
    local S_DRV=() S_REL=() s rel
    for i in "${!DRV_ROOT[@]}"; do
      while IFS= read -r s; do
        rel=${s#"${DRV_ROOT[$i]}"/}; rel=${rel%/steamapps}
        S_DRV+=("$i"); S_REL+=("$rel")
      done < <(find "${DRV_ROOT[$i]}" -maxdepth 4 -type d -iname steamapps \
                 -not -path '*/$RECYCLE.BIN/*' -not -path '*/System Volume Information/*' -not -path '*/Windows/*' 2>/dev/null)
    done
    if [ ${#S_DRV[@]} -gt 0 ]; then
      items=()
      for i in "${!S_DRV[@]}"; do items+=("$i" "${DRV_NAME[${S_DRV[$i]}]}:\\${S_REL[$i]//\//\\}" ON); done
      local picked; picked=$(ask_check "Steam libraries found" "steamapps (games + saves) and userdata (cloud saves, config) are copied from each:" "${items[@]}") || exit 1
      while IFS= read -r i; do
        [ -n "$i" ] || continue
        for d in steamapps userdata config; do
          [ -d "${DRV_ROOT[${S_DRV[$i]}]}/${S_REL[$i]}/$d" ] && want "${S_DRV[$i]}" "${S_REL[$i]}/$d"
        done
      done <<<"$picked"
    else
      note "No Steam libraries found."
    fi
  fi

  # ---- 7. root folders on C: ----
  if has root; then
    items=()
    for d in "$SRC"/*/; do
      n=$(basename "$d")
      case "$n" in Windows|Users|ProgramData|'$Recycle.Bin'|'$RECYCLE.BIN'|'System Volume Information'|PerfLogs|Recovery|'$WinREAgent'|'Documents and Settings') continue;; esac
      items+=("$n" "" OFF)
    done
    if [ ${#items[@]} -gt 0 ]; then
      local out; out=$(ask_check "Root folders on C:" "Extra folders at the root of the Windows drive:" "${items[@]}") || exit 1
      while IFS= read -r n; do [ -n "$n" ] && want 0 "$n"; done <<<"$out"
    fi
  fi
  has pdata && [ -d "$SRC/ProgramData" ] && want 0 ProgramData

  # ---- 8. folders on other drives ----
  local O_DRV=() O_NAME=()
  for i in "${!DRV_ROOT[@]}"; do
    [ "$i" = 0 ] && continue
    for d in "${DRV_ROOT[$i]}"/*/; do
      n=$(basename "$d")
      case "$n" in '$RECYCLE.BIN'|'$Recycle.Bin'|'System Volume Information'|Windows|'Program Files'|'Program Files (x86)'|ProgramData|found.000) continue;; esac
      O_DRV+=("$i"); O_NAME+=("$n")
    done
  done
  if [ ${#O_DRV[@]} -gt 0 ]; then
    items=()
    for i in "${!O_DRV[@]}"; do
      n="${O_NAME[$i]}"; local desc=""
      [[ "$n" == PoolPart.* ]] && desc="(DrivePool data)"
      items+=("$i" "${DRV_NAME[${O_DRV[$i]}]}:\\$n  $desc" OFF)
    done
    local out; out=$(ask_check "Folders on other drives" "Other NTFS drives were found. Tick any folders to include (saved under Drive_<label>\\ in the backup). Steam libraries are handled separately." "${items[@]}") || exit 1
    while IFS= read -r i; do [ -n "$i" ] && want "${O_DRV[$i]}" "${O_NAME[$i]}"; done <<<"$out"
  fi

  # ---- 9. estimate ----
  local any=0; for i in "${!DRV_ROOT[@]}"; do [ -n "${DRV_WANT[$i]}" ] && any=1; done
  [ "$any" = 1 ] || { ask_msg "Nothing selected" "Nothing to back up."; exit 1; }

  local EXC_USED="$WORK/excludes_used.txt"; cp "$EXC_FILE" "$EXC_USED"
  local ERRLOG="$WORK/errors.log"; : >"$ERRLOG"
  local EST_XFER=() EST_SEL=() EST_NFILES=() TOT_SEL=0 TOT_XFER=0 TOT_N=0
  local HIDDEN="$WORK/hidden.tsv"; : >"$HIDDEN"
  clear 2>/dev/null; echo "Scanning selected folders (this walks every file once; no copying yet)..."
  for i in "${!DRV_ROOT[@]}"; do
    EST_XFER[$i]=0; EST_SEL[$i]=0; EST_NFILES[$i]=0
    [ -n "${DRV_WANT[$i]}" ] || continue
    gen_filter "$i"
    local dest="$DST/${DRV_PREFIX[$i]}" est="$WORK/est_$i"
    [ -d "$dest" ] || dest="$WORK/empty_$i/"; mkdir -p "$dest"
    echo "  ${DRV_NAME[$i]}: $(tr '\n' ' ' <<<"${DRV_WANT[$i]}" | cut -c1-150)"
    rsync "${RS_BASE[@]}" -n --stats --debug=FILTER --exclude-from="$EXC_USED" --filter="merge $WORK/filter_$i" \
      "${DRV_ROOT[$i]}/" "$dest/" >"$est" 2>>"$ERRLOG"
    EST_SEL[$i]=$(stat_num "$est" 'Total file size')
    EST_XFER[$i]=$(stat_num "$est" 'Total transferred file size')
    EST_NFILES[$i]=$(stat_num "$est" 'Number of regular files transferred')
    TOT_SEL=$((TOT_SEL + EST_SEL[i])); TOT_XFER=$((TOT_XFER + EST_XFER[i])); TOT_N=$((TOT_N + EST_NFILES[i]))
    # "hiding <kind> <path> because of pattern <pat>": keep only hits from the exclude FILE
    # (category on/off rules from gen_filter also print here; those are not "junk").
    awk -v root="${DRV_ROOT[$i]}" -v drv="${DRV_NAME[$i]}" -v exc="$EXC_USED" '
      BEGIN { while ((getline l < exc) > 0) { if (l ~ /^[[:space:]]*(#|;|$)/) continue; sub(/[[:space:]]+$/, "", l); pat[l]=1 } }
      /^\[sender\] hiding (file|directory) / {
        s=$0; sub(/^\[sender\] hiding (file|directory) /, "", s)
        n=index(s, " because of pattern "); if (!n) next
        p=substr(s, 1, n-1); q=substr(s, n+20)
        if (q in pat) { d=p; gsub("/", "\\", d); printf "%s/%s\t%s:\\%s\t%s\n", root, p, drv, d, q }
      }' "$est" >>"$HIDDEN"
    echo "     selected $(hr "${EST_SEL[$i]}"), to copy $(hr "${EST_XFER[$i]}") in ${EST_NFILES[$i]} files"
  done
  local FREE; FREE=$(df -B1 --output=avail "$DSTROOT" 2>/dev/null | tail -1); FREE=${FREE:-0}

  local EXCL_TXT="" EXCL_TOTAL=0
  if [ "$EXCL_SUMMARY" = 1 ] && [ -s "$HIDDEN" ]; then
    echo "Sizing excluded junk folders..."
    local out; out=$(python3 -c "$PY_EXCL" "$HIDDEN" "$WORK/excluded_summary.txt" 40)
    EXCL_TOTAL=$(head -1 <<<"$out"); EXCL_TXT=$(tail -n +2 <<<"$out")
  fi

  local SUMMARY
  SUMMARY="Source:        ${SRC_DEV:-$SRC} $( [ -n "$SRC_DEV" ] && printf '"%s"' "$(part_label "$SRC_DEV")" ) (read-only)
Destination:   ${DST_DEV:-} $DST$( [ "$RESUMED" = 1 ] && echo '   [RESUMING]' )
Users:         ${USERS[*]:-(none)}
Categories:    $(tr '\n' ' ' <<<"$CATS")

Selected data:      $(hr "$TOT_SEL")
Already there:      $(hr $((TOT_SEL - TOT_XFER)))
To copy now:        $(hr "$TOT_XFER")  ($TOT_N files)
Excluded junk:      $(hr "$EXCL_TOTAL")  (full list: _excluded_summary.txt)
Free on dest:       $(hr "$FREE")"
  if [ "$TOT_XFER" -ge "$FREE" ]; then
    ask_msg "Not enough space" "$SUMMARY

Not enough free space on the destination. Untick categories or pick another drive."
    [ "$DRY" = 1 ] || exit 1
  fi
  ask_yesno "Confirm" "$SUMMARY

Largest excluded items:
${EXCL_TXT:-(none)}

$( [ "$DRY" = 1 ] && echo 'DRY RUN: nothing will be written. Continue?' || echo 'Start the copy?')" || exit 1

  # ---- 10. copy ----
  local ZIP=no
  [ "$DRY" = 0 ] && ask_yesno "Zip" "Also pack the finished backup into ONE .zip next to the folder?
(store-only, no compression: fast. The folder is kept too. Needs another $(hr "$TOT_SEL") free.)" --defaultno && ZIP=yes

  local T_START; T_START=$(now)
  if [ "$DRY" = 0 ]; then
    ERRLOG="$DST/_errors.log"; cp "$WORK/errors.log" "$ERRLOG" 2>/dev/null || : >"$ERRLOG"
    cp "$EXC_USED" "$DST/_excludes_used.txt"
    [ -f "$WORK/excluded_summary.txt" ] && cp "$WORK/excluded_summary.txt" "$DST/_excluded_summary.txt"
    [ "$RESUMED" = 1 ] || printf 'Started: %s\n' "$T_START" >"$DST/_summary.txt"
  fi
  clear 2>/dev/null
  echo "winbackup $VERSION  $( [ "$DRY" = 1 ] && echo '*** DRY RUN ***' )"
  echo "-> $DST"; echo
  local offset=0 FAILED=0 rc COPIED=0 NCOPIED=0
  for i in "${!DRV_ROOT[@]}"; do
    [ -n "${DRV_WANT[$i]}" ] || continue
    local dest="$DST/${DRV_PREFIX[$i]}" st="$WORK/stats_$i"
    echo "== ${DRV_NAME[$i]}  ($(hr "${EST_XFER[$i]}") to copy)"
    [ "$DRY" = 1 ] || mkdir -p "$dest"
    echo "=== $(now) ${DRV_NAME[$i]} (${DRV_ROOT[$i]}) -> $dest" >>"$ERRLOG"
    rsync "${RS_BASE[@]}" --info=progress2,name1 --stats \
      $( [ "$DRY" = 1 ] && printf -- '--dry-run' ) \
      --exclude-from="$EXC_USED" --filter="merge $WORK/filter_$i" "${DRV_ROOT[$i]}/" "$dest/" 2>>"$ERRLOG" \
      | python3 -c "$PY_PROGRESS" "[${DRV_NAME[$i]}]" "$offset" "$TOT_XFER" "$st"
    rc=${PIPESTATUS[0]}
    case $rc in
      0) ;;
      23|24) FAILED=$((FAILED+1)); echo "(rsync exit $rc: some files could not be read; see _errors.log)";;
      *)  FAILED=$((FAILED+1)); echo "rsync exit $rc for ${DRV_NAME[$i]} (see _errors.log)"; tail -3 "$ERRLOG";;
    esac
    COPIED=$((COPIED + $(stat_num "$st" 'Total transferred file size')))
    NCOPIED=$((NCOPIED + $(stat_num "$st" 'Number of regular files transferred')))
    offset=$((offset + EST_XFER[i]))
  done
  local ERRN; ERRN=$(grep -c '^rsync:' "$ERRLOG" 2>/dev/null); ERRN=${ERRN:-0}

  if [ "$DRY" = 1 ]; then
    echo; echo "DRY RUN complete. Would copy $(hr "$TOT_XFER") in $TOT_N files to $DST"
    echo "Read errors during scan: $ERRN (see $WORK/errors.log before this shell exits: $(cat "$WORK/errors.log" 2>/dev/null | head -5))"
    return 0
  fi

  # ---- 11. verify ----
  local VERIFY VRES="skipped"
  VERIFY=$(ask_menu "Verify" "Check the copy? (reads the destination again)" \
    quick "Quick: every selected file exists on the destination with the same size+time (recommended)" \
    full  "Full: re-read and checksum every file on both sides (takes as long as the copy)" \
    skip  "Skip") || VERIFY=skip
  if [ "$VERIFY" != skip ]; then
    local VLOG="$DST/_verify.log" vmiss=0; : >"$VLOG"
    for i in "${!DRV_ROOT[@]}"; do
      [ -n "${DRV_WANT[$i]}" ] || continue
      echo "== verifying ${DRV_NAME[$i]} ($VERIFY)..."
      rsync "${RS_BASE[@]}" -n -i $( [ "$VERIFY" = full ] && printf -- '--checksum' ) \
        --exclude-from="$EXC_USED" --filter="merge $WORK/filter_$i" "${DRV_ROOT[$i]}/" "$DST/${DRV_PREFIX[$i]}/" 2>>"$ERRLOG" \
        | grep -E '^[>.<c]f' | sed "s|^|${DRV_PREFIX[$i]}|" >>"$VLOG"
    done
    vmiss=$(grep -c . "$VLOG"); vmiss=${vmiss:-0}
    if [ "$vmiss" = 0 ]; then VRES="OK ($VERIFY): every selected file is present at the destination"
    else VRES="$vmiss file(s) missing or different -- see _verify.log (usually the unreadable ones from _errors.log)"; fi
    echo "   $VRES"
  fi

  # ---- 12. manifest, README, summary ----
  echo "== writing manifest..."
  find "$DST" -type f ! -name '_*' ! -name 'README_RESTORE.txt' -printf '%s\t%P\n' 2>/dev/null | sort -t$'\t' -k2 >"$DST/_manifest.tsv"
  local MAN_N MAN_B; MAN_N=$(wc -l <"$DST/_manifest.tsv"); MAN_B=$(awk -F'\t' '{s+=$1} END{print s+0}' "$DST/_manifest.tsv")
  local T_END; T_END=$(now)
  cat >>"$DST/_summary.txt" <<S
Run:        $T_START  ->  $T_END   (winbackup $VERSION$( [ "$RESUMED" = 1 ] && echo ', resumed'))
Source:     ${SRC_DEV:-$SRC} $( [ -n "$SRC_DEV" ] && part_label "$SRC_DEV" )
Users:      ${USERS[*]:-(none)}
Categories: $(tr '\n' ' ' <<<"$CATS")
Selected:   $(hr "$TOT_SEL")   copied this run: $(hr "$COPIED") in $NCOPIED files
Excluded:   $(hr "$EXCL_TOTAL") of junk (see _excluded_summary.txt)
Errors:     $ERRN lines in _errors.log
Verify:     $VRES
On disk:    $(hr "$MAN_B") in $MAN_N files (_manifest.tsv)
S
  write_readme "$DST" "${USERS[*]:-}" "$(tr '\n' ' ' <<<"$CATS")"

  # ---- 13. zip ----
  if [ "$ZIP" = yes ]; then
    local zp="$DST.zip" zfree; zfree=$(df -B1 --output=avail "$DSTROOT" | tail -1)
    if [ "$MAN_B" -ge "$zfree" ]; then echo "Not enough space for the zip ($(hr "$MAN_B") needed); skipped."
    else
      echo "== zipping to $zp (store-only)..."
      rm -f "$zp"; python3 -c "$PY_ZIP" "$DST" "$zp" 2>>"$ERRLOG" && echo "   zip done: $(du -h "$zp" | cut -f1)"
    fi
  fi
  sync
  ask_msg "Done" "Backup finished.

$DST

Copied this run:  $(hr "$COPIED") in $NCOPIED files
On disk now:      $(hr "$MAN_B") in $MAN_N files
Read errors:      $ERRN  $( [ "$ERRN" -gt 0 ] && echo '-> see _errors.log (typically locked/encrypted/OneDrive-placeholder files)' )
Verify:           $VRES

README_RESTORE.txt in the folder explains how to put things back.
Drives will be unmounted when you press OK."
}

write_readme() {  # dst users categories
  cat >"$1/README_RESTORE.txt" <<R
WINDOWS USER-DATA BACKUP   (made by winbackup.sh $VERSION from a Linux live USB)
=====================================================================
Backup folder:  $(basename "$1")
Users:          $2
Categories:     $3
See _summary.txt for sizes/dates, _errors.log for files that could not be read,
_excluded_summary.txt for the biggest things deliberately skipped, _manifest.tsv for
every file (size <TAB> path), _excludes_used.txt for the skip rules that were applied.

LAYOUT
  This folder mirrors the Windows C: drive, so   Users\\ryan\\Documents\\x.docx   here was
  C:\\Users\\ryan\\Documents\\x.docx   on the old install.
  Drive_<label>\\...   = folders from other drives (D:, E:), same relative layout.
  Steam libraries are wherever they were (e.g. Program Files (x86)\\Steam\\steamapps).

RESTORING (from Windows Explorer, after the fresh install)
  Personal files:  copy Users\\<name>\\Documents, Desktop, Pictures... into C:\\Users\\<newname>\\
  App settings:    close the app, then copy Users\\<name>\\AppData\\Roaming\\<App> (and/or
                   AppData\\Local\\<App>) into C:\\Users\\<newname>\\AppData\\...   AppData is hidden:
                   type %APPDATA% or %LOCALAPPDATA% in the Explorer address bar.
  Browser profile: Chrome/Edge: AppData\\Local\\Google\\Chrome\\User Data (browser closed).
                   Firefox: AppData\\Roaming\\Mozilla\\Firefox\\Profiles.
  Game saves:      Documents\\My Games, Saved Games, AppData\\LocalLow\\<studio>, AppData\\Roaming\\<game>,
                   Steam\\userdata\\<id>\\<appid>\\remote.
  Steam games:     copy ...\\Steam\\steamapps\\common\\<Game> + the matching steamapps\\appmanifest_<id>.acf
                   into the new Steam library, then Steam > Library > Install (it will verify, not re-download).
  SSH/git/dev:     Users\\<name>\\.ssh, .gitconfig, .config, ... -> C:\\Users\\<newname>\\
  Windows may ask for admin rights or complain about permissions: right-click > Properties >
  Security > Advanced > take ownership if a restored folder is not accessible.

  Or boot the live USB again and run:  sudo bash winbackup.sh --restore
  (pick this folder, pick the new Windows drive, tick what to put back; it can map old
  user names to new ones).

NOT INCLUDED (on purpose)
  Registry hives (NTUSER.DAT), caches, temp files, junctions like "My Documents", OneDrive
  files that were online-only placeholders (they were never on the disk), and everything in
  _excludes_used.txt. Installed programs must be reinstalled; their settings are in AppData.
R
}

# ================================================================= RESTORE
restore_main() {
  local BK_DEV="" BKROOT BK TGT_DEV="" TGT
  if [ -n "$SRC_OVERRIDE" ]; then BKROOT=$(readlink -f "$SRC_OVERRIDE"); else
    BK_DEV=$(pick_part "RESTORE: where is the backup?" "Pick the partition that holds the backup folder." \
      'ntfs|exfat|vfat|ext4|ext3|xfs|btrfs') || exit 1
    BKROOT=$(mount_ro "$BK_DEV" "$MNT/bk") || { ask_msg "Mount failed" "Could not mount $BK_DEV.
$(mount_log_tail)"; exit 1; }
  fi
  echo "Looking for backups on $BK_DEV..."
  local items=() f
  while IFS= read -r f; do f=$(dirname "$f"); items+=("${f#"$BKROOT"/}" "$(grep -m1 '^Run:' "$f/_summary.txt" 2>/dev/null | cut -c13-50)"); done \
    < <(find "$BKROOT" -maxdepth 6 -name README_RESTORE.txt -not -path '*/$RECYCLE.BIN/*' 2>/dev/null | sort)
  [ ${#items[@]} -gt 0 ] || { ask_msg "No backups" "No folder containing README_RESTORE.txt found on $BK_DEV (searched 6 levels deep)."; exit 1; }
  items+=("__type__" "(type a path)")
  BK=$(ask_menu "Backup folder" "Backups found on $BK_DEV:" "${items[@]}") || exit 1
  [ "$BK" = "__type__" ] && { BK=$(ask_input "Backup path" "Path of the backup folder on $BK_DEV:" "") || exit 1; }
  BK=$(resolve_ci "$BKROOT" "$BK"); [ -d "$BK" ] || die "Not a directory: $BK"

  if [ -n "$DST_OVERRIDE" ]; then TGT=$(readlink -f "$DST_OVERRIDE"); else
    TGT_DEV=$(pick_part "RESTORE: target Windows drive" "Pick the NEW Windows C: partition to restore INTO (mounted read-write)." ntfs "$BK_DEV") || exit 1
    TGT=$(mount_rw "$TGT_DEV" "$MNT/tgt") || { ask_msg "Mount failed" "Could not mount $TGT_DEV read-write.
$(mount_log_tail)"; exit 1; }
  fi
  [ -d "$TGT/Users" ] || ask_yesno "No Users folder" "$TGT_DEV has no \\Users folder. Is this really the new Windows drive? Continue?" || exit 1

  # items: Users/<u>/<x> for each profile entry, plus any other top-level folder (except Drive_*)
  local d u n I_SRC=() I_DST=() I_LABEL=()
  for d in "$BK"/Users/*/; do
    u=$(basename "$d")
    for n in "$d"* "$d".[!.]*; do
      [ -e "$n" ] || continue
      I_SRC+=("$n"); I_DST+=("Users/$u/$(basename "$n")"); I_LABEL+=("Users\\$u\\$(basename "$n")")
    done
  done
  for d in "$BK"/*/; do
    n=$(basename "$d")
    case "$n" in Users|Drive_*) continue;; esac
    I_SRC+=("$d"); I_DST+=("$n"); I_LABEL+=("$n\\")
  done
  local i
  items=(); for i in "${!I_SRC[@]}"; do items+=("$i" "${I_LABEL[$i]}" ON); done
  local picked; picked=$(ask_check "What to restore" "Tick what to copy onto $TGT_DEV. (Drive_* folders are not restored automatically: drag them to the right drive in Explorer.)" "${items[@]}") || exit 1
  [ -n "$picked" ] || die "Nothing selected."

  # map old user names to profiles that exist on the target
  declare -A UMAP=()
  local tusers=() t
  for d in "$TGT"/Users/*/; do t=$(basename "$d"); case "$t" in Default|"Default User"|"All Users"|Public|defaultuser0|WDAGUtilityAccount) continue;; esac; tusers+=("$t"); done
  while IFS= read -r i; do
    [ -n "$i" ] || continue
    [[ "${I_DST[$i]}" == Users/* ]] || continue
    u=${I_DST[$i]#Users/}; u=${u%%/*}
    [ -n "${UMAP[$u]:-}" ] && continue
    items=()
    for t in "${tusers[@]}"; do items+=("$t" "$( [ "$t" = "$u" ] && echo '(same name)' )"); done
    items+=("__same__" "(create Users\\$u on the target)")
    t=$(ask_menu "User mapping" "Backed-up profile Users\\$u -> which profile on the new install?" "${items[@]}") || exit 1
    [ "$t" = "__same__" ] && t=$u
    UMAP[$u]=$t
  done <<<"$picked"

  local POLICY; POLICY=$(ask_menu "Existing files" "If a file already exists on the target:" \
    overwrite "Overwrite it with the backup copy" \
    skip      "Keep the target's version (only add missing files)" \
    newer     "Overwrite only if the backup copy is newer") || exit 1
  local POL=(); case $POLICY in skip) POL=(--ignore-existing);; newer) POL=(--update);; esac

  # estimate
  local TOT=0 N=0 s dst est
  echo "Scanning..."
  local J_SRC=() J_DST=()
  while IFS= read -r i; do
    [ -n "$i" ] || continue
    dst=${I_DST[$i]}
    if [[ "$dst" == Users/* ]]; then u=${dst#Users/}; u=${u%%/*}; dst="Users/${UMAP[$u]}/${dst#Users/$u/}"; fi
    J_SRC+=("${I_SRC[$i]}"); J_DST+=("$TGT/$dst")
  done <<<"$picked"
  for i in "${!J_SRC[@]}"; do
    s=${J_SRC[$i]}; dst=${J_DST[$i]}
    if [ -d "$s" ]; then rsync "${RS_BASE[@]}" -n --stats "${POL[@]}" "$s/" "$dst/" >"$WORK/rest_$i" 2>/dev/null
    else rsync "${RS_BASE[@]}" -n --stats "${POL[@]}" "$s" "$dst" >"$WORK/rest_$i" 2>/dev/null; fi
    TOT=$((TOT + $(stat_num "$WORK/rest_$i" 'Total transferred file size')))
    N=$((N + $(stat_num "$WORK/rest_$i" 'Number of regular files transferred')))
  done
  local FREE; FREE=$(df -B1 --output=avail "$TGT" | tail -1)
  ask_yesno "Confirm restore" "From:  $BK
To:    $TGT_DEV ($(part_label "$TGT_DEV"))
Items: ${#J_SRC[@]}   Policy: $POLICY
Will copy $(hr "$TOT") in $N files.  Free on target: $(hr "$FREE")

Start?" || exit 1
  [ "$TOT" -lt "$FREE" ] || die "Not enough free space on the target."

  local LOG="$TGT/winbackup_restore_$(date +%Y-%m-%d_%H%M).log" offset=0 FAILED=0 rc
  echo "winbackup restore $(now)  from $BK" >"$LOG"
  clear 2>/dev/null; echo "Restoring -> $TGT"; echo
  for i in "${!J_SRC[@]}"; do
    s=${J_SRC[$i]}; dst=${J_DST[$i]}
    echo "== ${dst#"$TGT"/}"
    if [ -d "$s" ]; then
      mkdir -p "$dst"
      rsync "${RS_BASE[@]}" "${POL[@]}" --info=progress2,name1 --stats "$s/" "$dst/" 2>>"$LOG" \
        | python3 -c "$PY_PROGRESS" "[restore]" "$offset" "$TOT" "$WORK/rst_$i"
      rc=${PIPESTATUS[0]}
    else
      mkdir -p "$(dirname "$dst")"; rsync "${RS_BASE[@]}" "${POL[@]}" "$s" "$dst" 2>>"$LOG"; rc=$?
    fi
    [ "$rc" = 0 ] || { FAILED=$((FAILED+1)); echo "   rsync exit $rc (see $LOG)"; }
    offset=$((offset + $(stat_num "$WORK/rst_$i" 'Total transferred file size')))
  done
  sync
  ask_msg "Restore done" "Restored ${#J_SRC[@]} item(s) onto $TGT_DEV. Items with errors: $FAILED
Log: $(basename "$LOG") in the root of the target drive.

If Windows complains about permissions on restored folders: Properties > Security > Advanced > take ownership."
}

if [ "$MODE" = restore ]; then restore_main; else backup_main; fi
