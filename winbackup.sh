#!/usr/bin/env bash
# winbackup.sh -- back up Windows user data from a Linux live USB into a plain folder tree.
#
#   sudo bash winbackup.sh                 interactive backup (menus)
#   sudo bash winbackup.sh --dry-run       do everything except the copy; nothing is written to the destination
#   sudo bash winbackup.sh --restore       copy categories from a previous backup back onto a Windows drive
#   sudo bash winbackup.sh --other-drives  also mount the other NTFS drives read-only and offer their folders
#                                          and Steam libraries (default: only the one source drive is touched)
#   sudo bash winbackup.sh --jobs N        number of rsync workers for the "parallel" start option (default 4)
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
cd / || exit 1   # never keep a cwd on a drive we may unmount; rsync aborts if getcwd() fails
VERSION="2.0"

# ---------------------------------------------------------------- args
DRY=0; MODE=backup; SRC_OVERRIDE=""; DST_OVERRIDE=""; EXTRA_OVERRIDES=(); ANSWERS=""; EXCL_SUMMARY=1; OTHER=0; JOBS=4; PARALLEL=0
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1;;
    --restore) MODE=restore;;
    --src) SRC_OVERRIDE=$2; shift;;
    --dst) DST_OVERRIDE=$2; shift;;
    --extra) EXTRA_OVERRIDES+=("$2"); OTHER=1; shift;;
    --other-drives) OTHER=1;;
    --jobs) JOBS=$2; shift;;
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
# Diagnostics: everything the run generated (mount log, rsync rules, rsync commands + errors) is
# copied next to the script at exit, so a failed run on the live USB can be examined elsewhere.
DIAG="$SCRIPT_DIR/logs/$(date +%Y-%m-%d_%H%M%S)"
mkdir -p "$DIAG" 2>/dev/null || DIAG=""
OUR_MOUNTS=()      # mountpoints we created: unmounted at exit
OUR_DEVS=()        # the device behind each of those, so we can hand it back to the desktop
REMOUNT_RW=()      # desktop mounts we flipped read-only: flipped back at exit
STAMP_DATE=$(date +%Y-%m-%d)

cleanup() {
  local rc=$?
  sync
  # whatever was answered so far is kept, even after a cancel or Ctrl-C
  [ "$MODE" = backup ] && save_prefs
  if [ -n "$DIAG" ]; then
    cp "$WORK"/mount.log "$WORK"/commands.log "$WORK"/errors.log "$WORK"/filter_* "$WORK"/stats_* "$WORK"/size_breakdown.txt "$WORK"/excluded_summary.txt "$DIAG"/ 2>/dev/null
    for f in "$WORK"/est_*; do [ -f "$f" ] && { grep -v '^\[sender\] \(hiding\|showing\)' "$f" | head -200 >"$DIAG/$(basename "$f").txt"; }; done
    [ -n "${DST:-}" ] && cp "$DST"/_errors.log "$DST"/_summary.txt "$DIAG"/ 2>/dev/null
    echo "exit code $rc at $(now)" >>"$DIAG/commands.log"
    sync
  fi
  # unmount in reverse order of mounting; lazy unmount as a fallback so we never hang at exit
  local i
  for (( i=${#OUR_MOUNTS[@]}-1; i>=0; i-- )); do
    umount "${OUR_MOUNTS[$i]}" 2>/dev/null || umount -l "${OUR_MOUNTS[$i]}" 2>/dev/null
  done
  for i in "${REMOUNT_RW[@]}"; do mount -o remount,rw "$i" 2>/dev/null; done
  # Hand the drives we mounted back to the desktop (so they reappear in the file manager).
  # udisksctl must run as the desktop user, not root, for the mount to land under /media/<user>.
  local d back=0
  for d in "${OUR_DEVS[@]}"; do
    [ -n "$d" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] || continue
    sudo -u "$SUDO_USER" udisksctl mount -b "$d" >/dev/null 2>&1 && back=$((back+1))
  done
  [ ${#OUR_MOUNTS[@]} -gt 0 ] && echo "Unmounted the ${#OUR_MOUNTS[@]} drive(s) this tool mounted; $back re-mounted for the desktop. Drives the desktop had open were left alone."
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM

# ---------------------------------------------------------------- saved preferences
# Every answer is remembered under the dialog title in winbackup-prefs.txt next to the script.
# Next run: "review" pre-selects them in the menus, "auto" skips the menus (Confirm is always shown).
PREFS_FILE=${WB_PREFS:-$SCRIPT_DIR/winbackup-prefs.txt}
PREFS_MODE=fresh
declare -A PREF=()
ASK_DEFAULT=""     # one-shot default for the next ask_menu (used by pick_part for device matching)
load_prefs() {
  [ -f "$PREFS_FILE" ] || return 1
  local k v; while IFS=$'\t' read -r k v; do [[ -n "$k" && "$k" != \#* ]] && PREF[$k]=$v; done <"$PREFS_FILE"
  [ ${#PREF[@]} -gt 0 ]
}
# remember/forget append to files because the prompts run inside $(...) subshells,
# where a plain variable assignment would be lost.
remember() { [ -n "$NOPREF" ] || printf '%s\t%s\n' "$1" "$2" >>"$WORK/prefs.new"; }
forget()   { printf '%s\n' "$1" >>"$WORK/prefs.forget"; }
NOPREF=""          # set while in the size browser: those menus are neither saved nor auto-answered
saved() { [ -z "$NOPREF" ] && [ "$PREFS_MODE" != fresh ] && [ -n "${PREF[$1]+x}" ] && printf '%s\n' "${PREF[$1]}"; }
auto_ok() { [ -z "$NOPREF" ] && [ "$PREFS_MODE" = auto ] && [ "$1" != "Confirm" ] && [ -n "${PREF[$1]+x}" ]; }
save_prefs() {
  [ -s "$WORK/prefs.new" ] || return 0
  [ "$PREFS_MODE" = fresh ] || [ ! -f "$PREFS_FILE" ] || { local k v; while IFS=$'\t' read -r k v; do [[ -n "$k" && "$k" != \#* ]] && printf '%s\t%s\n' "$k" "$v"; done <"$PREFS_FILE" | cat - "$WORK/prefs.new" >"$WORK/prefs.merged" && mv "$WORK/prefs.merged" "$WORK/prefs.new"; }
  local -A n=(); local k v
  while IFS=$'\t' read -r k v; do [ -n "$k" ] && n[$k]=$v; done <"$WORK/prefs.new"      # last answer wins
  [ -f "$WORK/prefs.forget" ] && while read -r k; do unset "n[$k]"; done <"$WORK/prefs.forget"
  { echo "# winbackup saved answers ($(now)). One line per dialog: title<TAB>answer. Delete to start fresh."
    for k in "${!n[@]}"; do printf '%s\t%s\n' "$k" "${n[$k]}"; done | sort; } >"$PREFS_FILE" 2>/dev/null \
    && note "Saved your choices to $PREFS_FILE"
}

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
  local a sv; sv=${ASK_DEFAULT:-$(saved "$t")}; ASK_DEFAULT=""
  if auto_ok "$t"; then echo "[$t] -> $sv (saved)" >&2; remember "$t" "$sv"; printf '%s\n' "$sv"; return; fi
  if [ -n "$ANSWERS" ]; then a=$(next_answer); printf '   %s\n' "$@" >&2; echo "[$t] -> $a" >&2; remember "$t" "$a"; printf '%s\n' "$a"; return; fi
  local n=$(( $# / 2 )) h; h=$(( n < 12 ? n : 12 )) def=()
  [ -n "$sv" ] && def=(--default-item "$sv")
  a=$(whiptail --title "$t" "${def[@]}" --menu "$m" "$(dlg_h $(( h + 7 + $(text_lines "$m") )))" 90 "$h" "$@" 3>&1 1>&2 2>&3) || return 1
  remember "$t" "$a"; printf '%s\n' "$a"
}
ask_check() {  # title text tag item ON|OFF ...  -> chosen tags, one per line
  local t=$1 m=$2; shift 2
  local a out sv k j
  if auto_ok "$t"; then sv=${PREF[$t]}; echo "[$t] -> $sv (saved)" >&2; remember "$t" "$sv"; [ -n "$sv" ] && tr ';' '\n' <<<"$sv"; return 0; fi
  if [ -n "$ANSWERS" ]; then
    a=$(next_answer)
    if [ "$a" = "@all" ]; then out=$(for (( k=1; k<=$#; k+=3 )); do printf '%s\n' "${!k}"; done)
    elif [ "$a" = "@default" ]; then out=$(for (( k=1; k<=$#; k+=3 )); do j=$((k+2)); [ "${!j}" = ON ] && printf '%s\n' "${!k}"; done)
    else out=$(tr ';' '\n' <<<"$a"); fi
    remember "$t" "$(tr '\n' ';' <<<"$out" | sed 's/;$//')"; [ -n "$out" ] && printf '%s\n' "$out"; return 0
  fi
  # review mode: pre-tick exactly what was chosen last time
  if [ -n "${PREF[$t]+x}" ] && [ "$PREFS_MODE" = review ]; then
    local items=() sel=";${PREF[$t]};"
    for (( k=1; k<=$#; k+=3 )); do j=$((k+1)); items+=("${!k}" "${!j}" "$( [[ "$sel" == *";${!k};"* ]] && echo ON || echo OFF )"); done
    set -- "${items[@]}"
  fi
  local n=$(( $# / 3 )) h; h=$(( n < 12 ? n : 12 ))
  out=$(whiptail --title "$t" --separate-output --checklist "$m" "$(dlg_h $(( h + 7 + $(text_lines "$m") )))" 90 "$h" "$@" 3>&1 1>&2 2>&3) || return 1
  remember "$t" "$(tr '\n' ';' <<<"$out" | sed 's/;$//')"; [ -n "$out" ] && printf '%s\n' "$out"; return 0
}
ask_input() {  # title text default -> string   (an answer equal to the default is saved as @default,
  local a sv def=$3 #  so e.g. WinBackup_<date> re-derives today's date next time)
  sv=$(saved "$1"); [ "$sv" = "@default" ] && sv=$def
  if auto_ok "$1"; then echo "[$1] -> $sv (saved)" >&2; a=$sv
  elif [ -n "$ANSWERS" ]; then a=$(next_answer); [ "$a" = "@default" ] && a=$def
  else a=$(whiptail --title "$1" --inputbox "$2" "$(dlg_h $(( 8 + $(text_lines "$2") )))" 80 "${sv:-$def}" 3>&1 1>&2 2>&3) || return 1; fi
  if [ "$a" = "$def" ]; then remember "$1" "@default"; else remember "$1" "$a"; fi
  printf '%s\n' "$a"
}
ask_yesno() {  # title text [--defaultno] -> 0 yes / 1 no
  local a sv; sv=$(saved "$1")
  if auto_ok "$1"; then echo "[$1] -> $sv (saved)" >&2; a=$sv
  elif [ -n "$ANSWERS" ]; then a=$(next_answer)
  else
    local extra=(); [ -n "${3:-}" ] && extra=("$3")
    [ "$sv" = no ] && extra=(--defaultno); [ "$sv" = yes ] && extra=()
    if whiptail --title "$1" --scrolltext --yesno "$2" "$(dlg_h $(( 6 + $(text_lines "$2") )))" 90 "${extra[@]}"; then a=yes; else a=no; fi
  fi
  remember "$1" "$a"; [ "$a" = yes ]
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
# part_free dev -> free bytes. Uses the existing mount if there is one, otherwise mounts
# read-only for a moment (about a second) so the destination menu can show free space.
part_free() {
  local mp; mp=$(current_mount "$1")
  if [ -n "$mp" ]; then df -B1 --output=avail "$mp" 2>/dev/null | tail -1; return; fi
  local p="$WORK/probe"; mkdir -p "$p"
  if mount -o ro "$1" "$p" 2>>"$WORK/mount.log" || mount -t ntfs-3g -o ro "$1" "$p" 2>>"$WORK/mount.log"; then
    df -B1 --output=avail "$p" 2>/dev/null | tail -1
    umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null
  fi
}
# fit_tag free need -> rough verdict. "need" is the worst case (everything in use on C:), and
# user data is typically 30-70% of that, hence the half-way "probably fits" band.
fit_tag() {
  [ -n "$1" ] && [ -n "$2" ] && [ "$2" -gt 0 ] || return 0
  if [ "$1" -ge "$2" ]; then echo "[fits, even worst case]"
  elif [ "$1" -ge $(( $2 / 2 )) ]; then echo "[probably fits]"
  else echo "[MAY BE TOO SMALL]"; fi
}
# pick_part title text fstype-regex [exclude-dev] [need-bytes] -> device
# With need-bytes, each entry also shows free space and a rough fit verdict.
pick_part() {
  local items=() dev fs size label mp desc free
  while IFS='|' read -r dev fs size label mp; do
    [ -n "${4:-}" ] && [ "$dev" = "$4" ] && continue
    desc="${label:-(no label)}  $size  $fs"
    if [ -n "${5:-}" ]; then
      free=$(part_free "$dev")
      desc="$desc  free $( [ -n "$free" ] && hr "$free" || echo '?' )  $(fit_tag "$free" "$5")"
    fi
    [ -n "$mp" ] && desc="$desc  [mounted: $mp]"
    items+=("$dev" "$desc")
  done < <(list_parts "$3")
  [ ${#items[@]} -gt 0 ] || { ask_msg "No partitions" "No suitable partitions found (looked for: $3).\nIs the drive plugged in? Check with: lsblk -f"; return 1; }
  local sv; sv=$(saved "part:$1")
  if [ -n "$sv" ]; then
    local sdev=${sv%%|*} rest=${sv#*|} slabel=${rest%%|*} ssize=${rest#*|}
    while IFS='|' read -r dev fs size label mp; do
      if { [ -n "$slabel" ] && [ "$label" = "$slabel" ] && [ "$size" = "$ssize" ]; } || { [ -z "$slabel" ] && [ "$dev" = "$sdev" ] && [ "$size" = "$ssize" ]; }; then ASK_DEFAULT=$dev; break; fi
    done < <(list_parts "$3")
    [ -n "$ASK_DEFAULT" ] || { note "Saved drive for '$1' ($slabel $ssize) not found; asking."; PREF[$1]=""; }
  fi
  dev=$(ask_menu "$1" "$2" "${items[@]}") || return 1
  local pl ps; pl=$(part_label "$dev"); ps=$(lsblk -no SIZE "$dev" 2>/dev/null | head -1)
  remember "part:$1" "$dev|$pl|$ps"; forget "$1"
  printf '%s\n' "$dev"
}
part_label() { lsblk -no LABEL "$1" 2>/dev/null | head -1; }
part_fstype() { lsblk -no FSTYPE "$1" 2>/dev/null | head -1; }
current_mount() { findmnt -ln -o TARGET -S "$1" 2>/dev/null | head -1; }
current_mount_opts() { findmnt -ln -o OPTIONS -S "$1" 2>/dev/null | head -1; }

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
    # The live desktop auto-mounted it (read-write). Keep that mount so the user's file manager
    # still sees the drive; just flip it read-only in place for the duration (restored at exit).
    if [[ ",$(current_mount_opts "$dev")," == *,rw,* ]] && [ -z "$quiet" ]; then
      if mount -o remount,ro "$cur" 2>>"$WORK/mount.log"; then REMOUNT_RW+=("$cur")
      else note "$dev stays read-write at $cur (remount refused); nothing will be written to it."; fi
    fi
    echo "$cur"; return 0
  fi
  mkdir -p "$mp"
  if [ "$fs" != ntfs ]; then
    try_mount "$dev" "$mp" "" ro && { OUR_MOUNTS+=("$mp"); OUR_DEVS+=("$dev"); echo "$mp"; return 0; }
    return 1
  fi
  local a
  for a in "ntfs-3g|ro" "ntfs3|ro" "ntfs3|ro,force"; do
    try_mount "$dev" "$mp" "${a%%|*}" "${a#*|}" && { OUR_MOUNTS+=("$mp"); OUR_DEVS+=("$dev"); echo "$mp"; return 0; }
  done
  [ -n "$quiet" ] && return 1
  if ask_yesno "Source mount failed" "$(printf 'Could not mount %s read-only.\n\n%s\n\nLast resort 1: run "ntfsfix -d" on it. This clears the NTFS dirty flag and\nresets the journal (a tiny metadata write; no file data is touched). Try it?' "$dev" "$(mount_log_tail)")"; then
    ntfsfix -d "$dev" >>"$WORK/mount.log" 2>&1
    try_mount "$dev" "$mp" ntfs-3g ro && { OUR_MOUNTS+=("$mp"); OUR_DEVS+=("$dev"); echo "$mp"; return 0; }
  fi
  if ask_yesno "Source mount failed" "$(printf 'Still could not mount %s.\n\nLast resort 2: mount once with remove_hiberfile (deletes hiberfil.sys, i.e. the\nsaved hibernation state) and then remount read-only. Try it?' "$dev")"; then
    try_mount "$dev" "$mp" ntfs-3g remove_hiberfile && umount "$mp" 2>>"$WORK/mount.log"
    try_mount "$dev" "$mp" ntfs-3g ro && { OUR_MOUNTS+=("$mp"); OUR_DEVS+=("$dev"); echo "$mp"; return 0; }
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
    try_mount "$dev" "$mp" "" rw && { OUR_MOUNTS+=("$mp"); OUR_DEVS+=("$dev"); echo "$mp"; return 0; }
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
  OUR_MOUNTS+=("$mp"); OUR_DEVS+=("$dev"); echo "$mp"
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
nfiles, lastname, skipped = 0, 0.0, 0
def status():
    ov = min(offset + done, total) if total else 0
    pct = int(100 * ov / total) if total else 100
    el = time.time() - t0
    eta = ''
    if done > 0 and el > 2 and total:
        rem = (total - ov) / (done / el); eta = f'ETA {int(rem//3600)}:{int(rem%3600//60):02d}:{int(rem%60):02d}'
    w = cols()
    l1 = f'{label} {pct:3d}%  {hr(ov)} / {hr(total)}  {rate}  {eta}  files:{nfiles}'
    c = cur if len(cur) < w - 3 else '...' + cur[-(w - 6):]
    return ('\x1b[2K' + l1[:w-1] + '\n\x1b[2K  > ' + c[:w-5] + '\x1b[1A\r')
def draw(): sys.stdout.write('\r' + status()); sys.stdout.flush()
def scroll(name):
    # a finished/started file scrolls past above the two pinned status lines
    global lastname, skipped
    now = time.time()
    if now - lastname < 0.04: skipped += 1; return   # at most ~25 names/s reach the terminal
    extra = f'   (+{skipped} more)' if skipped else ''; skipped = 0; lastname = now
    w = cols(); n = name if len(name) < w - 3 else '...' + name[-(w - 6):]
    sys.stdout.write('\r\x1b[2K' + n[:w-1] + extra + '\n' + status()); sys.stdout.flush()
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
            if not line.endswith('/'): nfiles += 1; scroll(line)
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

# Everything the user leaves unticked is collected here and shown loudly on the confirm screen.
not_backed_up() { printf '  %s\n' "$1" >>"$WORK/not_backed_up.txt"; }

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
  for w in "${!anc[@]}"; do
    # skip if this ancestor, or any folder above it, is itself wanted in full
    p=$w; local covered=0
    while :; do [ -n "${leaf[$p]:-}" ] && { covered=1; break; }; [[ "$p" == */* ]] || break; p=${p%/*}; done
    [ "$covered" = 1 ] || echo "- /$(esc "$w")/*" >>"$f"
  done
  echo "- /*" >>"$f"
}

# rsync options shared by estimate/copy/verify. No -l: junctions show up as symlinks, skip them.
RS_BASE=(-r -t --no-perms --no-owner --no-group --modify-window=2 --partial --info=nonreg0)
# rs: run rsync, recording the exact command line and exit code in $WORK/commands.log
rs() { printf '%s rsync' "$(now)" >>"$WORK/commands.log"; printf ' %q' "$@" >>"$WORK/commands.log"; echo >>"$WORK/commands.log"
       rsync "$@"; local rc=$?; echo "  -> exit $rc" >>"$WORK/commands.log"; return $rc; }

# ---------------------------------------------------------------- parallel copy
# plan_workers drive-index N -> writes $WORK/wfilter_<i>_<w>; prints the number of workers that got work.
# Work units start as the wanted leaves; a unit bigger than total/(2N) is split into its children
# (down to 4 levels), then units are dealt biggest-first onto the least-loaded worker.
# Each worker gets its own rsync filter: the drive's explicit excludes, includes for its units and
# their ancestors, "- ancestor/*" so siblings stay out, and "- /*".
plan_workers() {
  local i=$1 N=$2 est="$WORK/est_$i" root=${DRV_ROOT[$i]} u w c depth b p
  awk '/^[0-9]+ / && !/\/$/ { sz=$1+0; p=substr($0, length($1)+2); n=split(p, a, "/"); k=""
         for (j=1; j<=n && j<=4; j++) { k=(j>1 ? k "/" : "") a[j]; s[k]+=sz } }
       END { for (k in s) printf "%d\t%s\n", s[k], k }' "$est" >"$WORK/psizes_$i"
  local -A SZ=(); while IFS=$'\t' read -r b p; do SZ[$p]=$b; done <"$WORK/psizes_$i"
  local thr=$(( ${EST_XFER[$i]:-0} / (N * 2) + 1 )) units=() q=()
  while IFS= read -r u; do [ -n "$u" ] && q+=("$u"); done <<<"${DRV_WANT[$i]}"
  while [ ${#q[@]} -gt 0 ]; do
    u=${q[0]}; q=("${q[@]:1}")
    depth=$(( $(tr -cd '/' <<<"$u" | wc -c) + 1 ))
    if [ -d "$root/$u" ] && [ "${SZ[$u]:-0}" -gt "$thr" ] && [ "$depth" -lt 4 ]; then
      local any=0; for c in "$root/$u"/* "$root/$u"/.[!.]*; do [ -e "$c" ] || continue; q+=("$u/$(basename "$c")"); any=1; done
      [ "$any" = 1 ] || units+=("$u")
    else units+=("$u"); fi
  done
  # leaves overlap (e.g. Users/x from "everything else" and Users/x/Documents from "docs"): keep a
  # unit only if none of its ancestors is also a unit, otherwise two workers would copy it twice
  local -A pending=() kept=(); local -a uniq=()
  for u in "${units[@]}"; do pending[$u]=1; done
  for u in "${units[@]}"; do
    [ -n "${pending[$u]:-}" ] || continue; unset "pending[$u]"    # exact duplicates: first one wins
    p=$u; local covered=0
    while [[ "$p" == */* ]]; do p=${p%/*}; [ -n "${pending[$p]:-}${kept[$p]:-}" ] && { covered=1; break; }; done
    [ "$covered" = 1 ] || { uniq+=("$u"); kept[$u]=1; }
  done
  units=("${uniq[@]}")
  local -a load=(); for (( w=0; w<N; w++ )); do load[$w]=0; : >"$WORK/wunits_${i}_$w"; done
  while IFS=$'\t' read -r b u; do
    local best=0; for (( w=1; w<N; w++ )); do [ "${load[$w]}" -lt "${load[$best]}" ] && best=$w; done
    printf '%s\n' "$u" >>"$WORK/wunits_${i}_$best"; load[$best]=$(( load[best] + b ))
  done < <(for u in "${units[@]}"; do printf '%s\t%s\n' "${SZ[$u]:-0}" "$u"; done | sort -t$'\t' -k1,1nr)
  local used=0
  for (( w=0; w<N; w++ )); do
    [ -s "$WORK/wunits_${i}_$w" ] || continue
    used=$((used+1))
    local f="$WORK/wfilter_${i}_$w"; : >"$f"
    declare -A leaf=() anc=()
    while IFS= read -r u; do [ -n "$u" ] && echo "- /$u" >>"$f"; done <<<"${DRV_XCL[$i]}"
    while IFS= read -r u; do leaf[$u]=1; p=$u; while [[ "$p" == */* ]]; do p=${p%/*}; anc[$p]=1; done; done <"$WORK/wunits_${i}_$w"
    for u in "${!leaf[@]}"; do if [ -d "$root/$u" ]; then echo "+ /$(esc "$u")/" >>"$f"; else echo "+ /$(esc "$u")" >>"$f"; fi; done
    for u in "${!anc[@]}"; do [ -n "${leaf[$u]:-}" ] || echo "+ /$(esc "$u")/" >>"$f"; done
    for u in "${!anc[@]}"; do [ -n "${leaf[$u]:-}" ] || echo "- /$(esc "$u")/*" >>"$f"; done
    echo "- /*" >>"$f"
    unset leaf anc
  done
  echo "$used"
}

# Per-worker stdin filter: keeps a small state file (bytes<TAB>current file) fresh for the display,
# writes the rsync --stats lines at the end and touches a done marker.
read -r -d '' PY_WORKER <<'PY'
import sys, re, time, os
state, statsfile = sys.argv[1], sys.argv[2]
prog = re.compile(r'^\s*([\d,]+)\s+(\d+)%\s+(\S+)\s+(\d+:\d+:\d+)')
statkeys = ('Number of files', 'Number of regular files transferred', 'Total file size', 'Total transferred file size')
noise = ('sending incremental', 'sent ', 'total size', 'Number of', 'Total ', 'File list', 'Literal data',
         'Matched data', 'skipping', 'created directory', 'rsync', '(DRY RUN)', 'delta-transmission')
stats, cur, done, last, buf = [], '', 0, 0.0, ''
def flush():
    tmp = state + '.tmp'
    with open(tmp, 'w') as f: f.write(f'{done}\t{cur}')
    os.replace(tmp, state)
while True:
    chunk = sys.stdin.buffer.read(8192)
    if not chunk: break
    buf += chunk.decode('utf-8', 'replace')
    parts = re.split(r'[\r\n]', buf); buf = parts.pop()
    for line in parts:
        if not line.strip(): continue
        m = prog.match(line)
        if m: done = int(m.group(1).replace(',', ''))
        elif line.startswith(statkeys): stats.append(line)
        elif not line.startswith(noise): cur = line
        if time.time() - last > 0.2: flush(); last = time.time()
flush()
with open(statsfile, 'w') as f: f.write('\n'.join(stats) + '\n')
open(state + '.done', 'w').close()
PY

# Display for the parallel copy: sums the worker state files, shows overall % + one line per worker.
read -r -d '' PY_MULTI <<'PY'
import sys, os, time, glob
label, sdir, offset, total = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
def hr(n):
    for u in ('B','K','M','G','T'):
        if n < 1024 or u == 'T': return f'{n:.1f}{u}' if u != 'B' else f'{int(n)}B'
        n /= 1024
def cols():
    try: return os.get_terminal_size().columns
    except OSError: return 100
t0 = time.time(); states = sorted(glob.glob(os.path.join(sdir, 'w*.state')))
n = len(states); drawn = 0
while True:
    done = 0; lines = []; finished = 0
    for st in states:
        try:
            b, cur = open(st).read().split('\t', 1)
        except (OSError, ValueError): b, cur = '0', ''
        done += int(b or 0)
        fin = os.path.exists(st + '.done'); finished += fin
        w = cols(); tag = 'done ' if fin else 'copy '
        lines.append(('  ' + tag + (cur if len(cur) < w - 10 else '...' + cur[-(w - 13):]))[:w-1])
    ov = min(offset + done, total) if total else 0
    pct = int(100 * ov / total) if total else 100
    el = time.time() - t0; rate = done / el if el > 0 else 0
    eta = ''
    if rate > 0 and el > 2 and total:
        rem = (total - ov) / rate; eta = f'ETA {int(rem//3600)}:{int(rem%3600//60):02d}:{int(rem%60):02d}'
    l1 = f'{label}  overall {pct:3d}%  {hr(ov)} / {hr(total)}   {hr(rate)}/s  {eta}   ({n} workers)'
    out = '\r\x1b[2K' + l1[:cols()-1] + ''.join('\n\x1b[2K' + l for l in lines)
    sys.stdout.write(out + f'\x1b[{len(lines)}A\r' if lines else out); sys.stdout.flush()
    if finished == n and n > 0: break
    time.sleep(0.3)
sys.stdout.write('\n' * (len(lines) + 1)); sys.stdout.flush()
PY

# copy_parallel drive-index dest offset -> sets P_COPIED P_NCOPIED P_RC
copy_parallel() {
  local i=$1 dest=$2 offset=$3 N=$JOBS used w sdir="$WORK/par_$i"
  mkdir -p "$sdir"; rm -f "$sdir"/*
  used=$(plan_workers "$i" "$N")
  echo "   $used parallel workers"
  local pids=()
  for (( w=0; w<N; w++ )); do
    [ -f "$WORK/wfilter_${i}_$w" ] || continue
    : >"$sdir/w$w.state"
    ( rs "${RS_BASE[@]}" --outbuf=N --info=progress2,name1 --stats $( [ "$DRY" = 1 ] && printf -- '--dry-run' ) \
        --exclude-from="$EXC_USED" --filter="merge $WORK/wfilter_${i}_$w" "${DRV_ROOT[$i]}/" "$dest/" 2>>"$sdir/err$w" \
        | python3 -c "$PY_WORKER" "$sdir/w$w.state" "$sdir/stats$w"
      echo "${PIPESTATUS[0]}" >"$sdir/rc$w" ) &
    pids+=($!)
  done
  python3 -c "$PY_MULTI" "[${DRV_NAME[$i]}]" "$sdir" "$offset" "$TOT_XFER"
  wait "${pids[@]}" 2>/dev/null
  P_RC=0; P_COPIED=0; P_NCOPIED=0
  for (( w=0; w<N; w++ )); do
    [ -f "$sdir/rc$w" ] || continue
    local rc; rc=$(cat "$sdir/rc$w")
    [ "$rc" = 0 ] || { [ "$P_RC" = 0 ] && P_RC=$rc; [ "$rc" != 23 ] && [ "$rc" != 24 ] && P_RC=$rc; }
    { echo "--- worker $w (exit $rc)"; cat "$sdir/err$w"; } >>"$ERRLOG"
    P_COPIED=$((P_COPIED + $(stat_num "$sdir/stats$w" 'Total transferred file size')))
    P_NCOPIED=$((P_NCOPIED + $(stat_num "$sdir/stats$w" 'Number of regular files transferred')))
  done
}

# ================================================================= BACKUP
backup_main() {
  ensure_exclude_file
  if load_prefs; then
    local pm; pm=$(ask_menu "Saved preferences" "Choices from your last run were found in $(basename "$PREFS_FILE"):" \
      review "Go through the menus with last time's answers pre-selected (recommended)" \
      auto   "Skip the menus: reuse last time's answers, show only the size check and Confirm" \
      fresh  "Ignore them and start from the defaults") || exit 1
    PREFS_MODE=$pm; forget "Saved preferences"
  fi
  local SRC SRC_DEV="" DST_DEV="" DSTROOT NAME RESUMED=0 k
  DST=""

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
  # Instant worst-case size: everything in use on C: minus the page/hibernation files.
  # The real (post-exclude) figure is computed after the selections; this is only a guide.
  local WORST f; WORST=$(df -B1 --output=used "$SRC" 2>/dev/null | tail -1); WORST=${WORST:-0}
  for f in pagefile.sys hiberfil.sys swapfile.sys; do [ -f "$SRC/$f" ] && WORST=$(( WORST - $(stat -c %s "$SRC/$f") )); done
  [ "$WORST" -lt 0 ] && WORST=0

  # ---- 2. destination drive + folder ----
  if [ -n "$DST_OVERRIDE" ]; then
    DSTROOT=$(readlink -f "$DST_OVERRIDE"); [ -d "$DSTROOT" ] || die "--dst not a directory: $DSTROOT"
  else
    echo "Checking free space on candidate drives..."
    DST_DEV=$(pick_part "DESTINATION: where should the backup go?" \
      "Pick the partition to write to (e.g. the DrivePool disk). It will be mounted read-write.
Rough guide: C: has $(hr "$WORST") in use; \\Windows (typically 25-40 GB) and caches are never copied,
so the backup is somewhat smaller. The exact size is shown before anything is copied." \
      'ntfs|exfat|vfat|ext4|ext3|xfs|btrfs' "$SRC_DEV" "$WORST") || exit 1
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

  # ---- 3. other NTFS drives (D:, E:), only with --other-drives ----
  local dev fs size label mp x i
  if [ "$OTHER" = 0 ]; then :
  elif [ -n "$SRC_OVERRIDE" ]; then
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
      for (( k=0; k<${#items[@]}; k+=3 )); do grep -qxF -- "${items[$k]}" <<<"$out" || not_backed_up "User profile: Users\\${items[$k]}  (everything in it)"; done
    fi
  fi

  # ---- 5. categories ----
  local CATS
  CATS=$(ask_check "What to back up" "Everything is ticked: this is a full copy of the drives minus junk (caches, temp, registry
hives, Windows itself). Untick only what you are sure you do not want. Space toggles, Enter confirms." \
    docs     "Desktop, Documents, Downloads, Pictures, Videos, Music, Saved Games, Favorites, Contacts" ON \
    roaming  "AppData\\Roaming  (app settings, browser profiles, game saves)" ON \
    local    "AppData\\Local + LocalLow  (bigger: browser/Discord data, Unity saves, app data)" ON \
    dotfiles "Hidden home files (.ssh, .gitconfig, .config, .vscode, ...)" ON \
    other    "Everything else in the profile (OneDrive, misc folders and files)" ON \
    steam    "Steam saves + settings (userdata, config) from every Steam library on this drive" ON \
    steamgames "Installed Steam games (steamapps\\common; often hundreds of GB, re-downloadable)" OFF \
    root     "Everything else on C: (Program Files, app/game folders, Windows.old...; never \\Windows)" ON \
    pdata    "ProgramData (shared app data)" ON \
    ) || exit 1
  has() { grep -qx "$1" <<<"$CATS"; }
  local -A CAT_LABEL=([docs]="Desktop/Documents/Downloads/Pictures/Videos/Music/Saved Games" [roaming]="AppData\\Roaming" [local]="AppData\\Local + LocalLow"
    [dotfiles]="hidden home files (.ssh, .config...)" [other]="everything else in the profiles" [steam]="Steam saves + settings"
    [steamgames]="installed Steam games" [root]="all other folders on C:" [pdata]="ProgramData")
  local ck; for ck in docs roaming local dotfiles other steam steamgames root pdata; do has "$ck" || not_backed_up "Category: ${CAT_LABEL[$ck]}"; done
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

  # ---- 5b. WSL2 / Hyper-V virtual disks (a whole Linux distro lives in one ext4.vhdx) ----
  # Reported explicitly because they are easy to overlook and only copied if AppData\Local is on
  # (Packages\*\LocalState and AppData\Local\wsl) or the containing root/other-drive folder is ticked.
  local VHDX_TXT="" v vsz
  for u in "${USERS[@]}"; do
    while IFS= read -r v; do
      vsz=$(stat -c %s "$v" 2>/dev/null || echo 0)
      VHDX_TXT+="  $(hr "$vsz")  C:\\${v#"$SRC"/}"$'\n'
    done < <(find "$SRC/Users/$u/AppData/Local" -maxdepth 4 -iname '*.vhdx' -not -path '*/Temp/*' 2>/dev/null)
  done
  VHDX_TXT=${VHDX_TXT//\//\\}
  local VHDX_NOTE=""
  if [ -n "$VHDX_TXT" ]; then
    if has local; then VHDX_NOTE="WSL/virtual disks found in AppData\\Local (INCLUDED):"$'\n'"$VHDX_TXT"
    else VHDX_NOTE="WSL/virtual disks found but NOT included (AppData\\Local is unticked):"$'\n'"$VHDX_TXT"; fi
  fi

  # ---- 6. Steam libraries anywhere on any NTFS drive ----
  # saves/settings = userdata (Steam Cloud saves, per-game config) + config (login, library list)
  # games          = steamapps (common/, manifests, workshop). Most games' own saves live in the
  # profile (Documents\My Games, Saved Games, AppData\LocalLow...), which the profile categories cover.
  if has steam || has steamgames; then
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
      for i in "${!S_DRV[@]}"; do grep -qx -- "$i" <<<"$picked" || not_backed_up "Steam library: ${DRV_NAME[${S_DRV[$i]}]}:\\${S_REL[$i]//\//\\}"; done
      local parts=() what="" nots=(); has steam && { parts+=(userdata config); what="userdata + config (saves/settings)"; }
      has steamgames && { parts+=(steamapps); what="${what:+$what, }steamapps (installed games)"; }
      has steamgames || nots+=(steamapps); has steam || nots+=(userdata config)
      # parts of every library that were NOT ticked are excluded explicitly, so they are left out
      # even when the folder containing the library (e.g. Program Files (x86)) is copied whole
      for i in "${!S_DRV[@]}"; do for d in "${nots[@]}"; do xcl "${S_DRV[$i]}" "$(esc "${S_REL[$i]}/$d")/"; done; done
      local picked; picked=$(ask_check "Steam libraries found" "Copy $what from these libraries:" "${items[@]}") || exit 1
      while IFS= read -r i; do
        [ -n "$i" ] || continue
        for d in "${parts[@]}"; do
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
      case "$n" in Windows|Users|ProgramData|'$Recycle.Bin'|'$RECYCLE.BIN'|'System Volume Information'|PerfLogs|Recovery|'$WinREAgent'|'$SysReset'|'$GetCurrent'|'Windows.~BT'|'Windows.~WS'|ESD|Boot|Config.Msi|MSOCache|OneDriveTemp|'Documents and Settings'|found.000) continue;; esac
      items+=("$n" "" ON)
    done
    if [ ${#items[@]} -gt 0 ]; then
      local out; out=$(ask_check "Root folders on C:" "All other folders on the Windows drive (Users and ProgramData are handled by their own categories; \\Windows is never copied). Untick anything you do not want:" "${items[@]}") || exit 1
      while IFS= read -r n; do [ -n "$n" ] && want 0 "$n"; done <<<"$out"
      for (( k=0; k<${#items[@]}; k+=3 )); do grep -qxF -- "${items[$k]}" <<<"$out" || not_backed_up "Root folder: C:\\${items[$k]}"; done
    fi
  fi
  has pdata && [ -d "$SRC/ProgramData" ] && want 0 ProgramData

  # ---- 8. folders on other drives ----
  local O_DRV=() O_NAME=()
  for i in "${!DRV_ROOT[@]}"; do
    [ "$i" = 0 ] && continue
    for d in "${DRV_ROOT[$i]}"/*/; do
      n=$(basename "$d")
      case "$n" in '$RECYCLE.BIN'|'$Recycle.Bin'|'System Volume Information'|Windows|found.000) continue;; esac
      O_DRV+=("$i"); O_NAME+=("$n")
    done
  done
  if [ ${#O_DRV[@]} -gt 0 ]; then
    items=()
    for i in "${!O_DRV[@]}"; do
      n="${O_NAME[$i]}"; local desc="" st=ON
      [[ "$n" == PoolPart.* ]] && { desc="(DrivePool pool data; usually not what you want to back up)"; st=OFF; }
      items+=("$i" "${DRV_NAME[${O_DRV[$i]}]}:\\$n  $desc" "$st")
    done
    local out; out=$(ask_check "Folders on other drives" "Other NTFS drives were found; everything on them is ticked (saved under Drive_<label>\\ in the backup). Untick what you do not want. Steam libraries in these folders are covered either way." "${items[@]}") || exit 1
    while IFS= read -r i; do [ -n "$i" ] && want "${O_DRV[$i]}" "${O_NAME[$i]}"; done <<<"$out"
    for i in "${!O_DRV[@]}"; do grep -qx -- "$i" <<<"$out" || not_backed_up "Other drive folder: ${DRV_NAME[${O_DRV[$i]}]}:\\${O_NAME[$i]}"; done
  fi

  # ---- 8b. optional drill-down: go through a folder item by item (e.g. C:\Temp) ----
  # Untick items become explicit excludes for that folder; everything else in it is still copied.
  local R_DRV=() R_REL=() r
  for i in "${!DRV_ROOT[@]}"; do
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      case "$r" in Users/*|ProgramData|*/steamapps|*/userdata|*/config) continue;; esac
      [ -d "${DRV_ROOT[$i]}/$r" ] && { R_DRV+=("$i"); R_REL+=("$r"); }
    done <<<"${DRV_WANT[$i]}"
  done
  if [ ${#R_DRV[@]} -gt 0 ]; then
    items=()
    for i in "${!R_DRV[@]}"; do items+=("$i" "${DRV_NAME[${R_DRV[$i]}]}:\\${R_REL[$i]//\//\\}" OFF); done
    local out; out=$(ask_check "Go through any folder item by item?" "Optional. Tick a folder (e.g. C:\\Temp) to see what is inside it with sizes and choose piece by piece.
Leave everything unticked to copy those folders whole." "${items[@]}") || exit 1
    while IFS= read -r i; do
      [ -n "$i" ] || continue
      local rroot="${DRV_ROOT[${R_DRV[$i]}]}/${R_REL[$i]}" c cn csz
      items=()
      echo "Sizing ${DRV_NAME[${R_DRV[$i]}]}:\\${R_REL[$i]//\//\\} ..."
      # sizes are a courtesy: give up after 60s for the whole folder rather than stall on a huge one
      local szfile="$WORK/sizes_$i"; : >"$szfile"
      ( cd "$rroot" && timeout 60 du -sb -- * .[!.]* 2>/dev/null ) >"$szfile"
      for c in "$rroot"/* "$rroot"/.[!.]*; do
        [ -e "$c" ] || continue; cn=$(basename "$c")
        csz=$(awk -F'\t' -v n="$cn" '$2==n{print $1; exit}' "$szfile")
        items+=("$cn" "$( [ -d "$c" ] && echo '[dir] ' )${csz:+$(hr "$csz")}${csz:-?}" ON)
      done
      [ ${#items[@]} -gt 0 ] || continue
      local keep; keep=$(ask_check "${DRV_NAME[${R_DRV[$i]}]}:\\${R_REL[$i]//\//\\}" "Untick what you do NOT want. (Junk from the exclude list is still skipped inside what you keep.)" "${items[@]}") || exit 1
      for c in "$rroot"/* "$rroot"/.[!.]*; do
        [ -e "$c" ] || continue; cn=$(basename "$c")
        grep -qxF -- "$cn" <<<"$keep" && continue
        if [ -d "$c" ]; then xcl "${R_DRV[$i]}" "$(esc "${R_REL[$i]}/$cn")/"; else xcl "${R_DRV[$i]}" "$(esc "${R_REL[$i]}/$cn")"; fi
        not_backed_up "Item: ${DRV_NAME[${R_DRV[$i]}]}:\\${R_REL[$i]//\//\\}\\$cn"
      done
    done <<<"$out"
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
    rs "${RS_BASE[@]}" -n --stats --debug=FILTER --out-format='%l %n' --exclude-from="$EXC_USED" --filter="merge $WORK/filter_$i" \
      "${DRV_ROOT[$i]}/" "$dest/" >"$est" 2>>"$ERRLOG"; local src_rc=$?
    if [ "$src_rc" != 0 ] && [ "$src_rc" != 23 ] && [ "$src_rc" != 24 ]; then
      ask_msg "Scan failed" "rsync could not read ${DRV_NAME[$i]} (${DRV_ROOT[$i]}), exit code $src_rc:

$(tail -n 8 "$ERRLOG")

Nothing has been copied. Diagnostics: ${DIAG:-$WORK}"
      exit 1
    fi
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
  if [ "$TOT_SEL" = 0 ]; then
    ask_msg "Nothing found" "The scan found 0 bytes in the selected folders, which is not plausible for a Windows drive.
Source: $SRC
Recent errors:
$(tail -n 6 "$ERRLOG" 2>/dev/null)

Nothing will be copied. Diagnostics: ${DIAG:-$WORK}"
    exit 1
  fi

  # ---- 9b. sizes, size browser, confirm ----
  local BROWSE_XCL="$WORK/browse_xcl.tsv"; : >"$BROWSE_XCL"   # drive-name<TAB>relpath<TAB>d|f
  # exclusions made in the size browser last time (saved in prefs) are applied again
  local sv_bx; sv_bx=$(saved "Browser exclusions")
  if [ -n "$sv_bx" ]; then
    local e; while IFS= read -r e; do
      [ -n "$e" ] || continue; printf '%s\t%s\t%s\n' "${e%%|*}" "$(cut -d'|' -f2 <<<"$e")" "${e##*|}" >>"$BROWSE_XCL"
    done < <(tr ';' '\n' <<<"$sv_bx")
  fi
  local BASE_SEL=(); for i in "${!DRV_ROOT[@]}"; do BASE_SEL[$i]=${EST_SEL[$i]:-0}; done
  local BIG_TXT="" FREE SUMMARY EXCL_TXT="" EXCL_TOTAL=0
  FREE=$(df -B1 --output=avail "$DSTROOT" 2>/dev/null | tail -1); FREE=${FREE:-0}

  # compute_sizes: totals + per-folder breakdown from the dry-run file lists, minus browser exclusions
  compute_sizes() {
    local i r; : >"$WORK/sizes.tsv"; TOT_XFER=0; TOT_SEL=0; TOT_N=0
    for i in "${!DRV_ROOT[@]}"; do
      [ -n "${DRV_WANT[$i]}" ] || continue
      r=$(awk -v drv="${DRV_NAME[$i]}" -v xf="$BROWSE_XCL" -v out="$WORK/sizes.tsv" '
        BEGIN { nx=0; while ((getline l < xf) > 0) { split(l, f, "\t"); if (f[1]==drv) { nx++; xp[nx]=f[2]; xt[nx]=f[3] } } }
        /^[0-9]+ / && !/\/$/ {
          sz=$1+0; p=substr($0, length($1)+2)
          for (j=1; j<=nx; j++) {
            if (xt[j]=="d") { if (substr(p, 1, length(xp[j])+1) == xp[j] "/") { ex+=sz; next } }
            else if (p==xp[j]) { ex+=sz; next } }
          tot+=sz; cnt++; n=split(p, a, "/"); t1[a[1]]+=sz; if (n>2) t2[a[1] "\\" a[2]]+=sz; else t2[a[1]]+=sz }
        END { for (k in t1) printf "1\t%d\t%s:\\%s\n", t1[k], drv, k >> out
              for (k in t2) printf "2\t%d\t%s:\\%s\n", t2[k], drv, k >> out
              printf "%d %d %d\n", tot+0, ex+0, cnt+0 }' "$WORK/est_$i")
      read -r "EST_XFER[$i]" e "EST_NFILES[$i]" <<<"$r"   # quoted: nullglob would eat EST_XFER[0] as a glob
      EST_SEL[$i]=$(( BASE_SEL[i] - e )); [ "${EST_SEL[$i]}" -lt 0 ] && EST_SEL[$i]=0
      TOT_XFER=$((TOT_XFER + EST_XFER[i])); TOT_SEL=$((TOT_SEL + EST_SEL[i])); TOT_N=$((TOT_N + EST_NFILES[i]))
    done
    { echo "Size of what will be copied, by folder (largest first)"; echo
      echo "--- top-level ---"; awk -F'\t' '$1==1' "$WORK/sizes.tsv" | sort -t$'\t' -k2,2nr | while IFS=$'\t' read -r _ b n; do printf '%10s  %s\n' "$(hr "$b")" "$n"; done
      echo; echo "--- second level (top 60) ---"; awk -F'\t' '$1==2' "$WORK/sizes.tsv" | sort -t$'\t' -k2,2nr | head -60 | while IFS=$'\t' read -r _ b n; do printf '%10s  %s\n' "$(hr "$b")" "$n"; done
    } >"$WORK/size_breakdown.txt"
    BIG_TXT=$(awk -F'\t' '$1==2' "$WORK/sizes.tsv" | sort -t$'\t' -k2,2nr | head -10 | while IFS=$'\t' read -r _ b n; do printf '%9s  %s\n' "$(hr "$b")" "$n"; done)
  }
  build_summary() {
    local bx="" nb=""
    [ -s "$WORK/not_backed_up.txt" ] && nb=$(cat "$WORK/not_backed_up.txt")
    [ -s "$BROWSE_XCL" ] && bx=$(awk -F'\t' '{ p=$2; gsub("/", "\\", p); printf "  Size browser: %s:\\%s\n", $1, p }' "$BROWSE_XCL")
    local danger=""
    [ -n "$nb$bx" ] && danger="
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!!  NOT BACKED UP  (you left these unticked or excluded them)   !!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
${nb}${nb:+
}${bx}
(Junk from winbackup-excludes.txt is separate; see the list at the bottom.)
"
    bx=""
    SUMMARY="Source:        ${SRC_DEV:-$SRC} $( [ -n "$SRC_DEV" ] && printf '"%s"' "$(part_label "$SRC_DEV")" ) (read-only)
Destination:   ${DST_DEV:-} $DST$( [ "$RESUMED" = 1 ] && echo '   [RESUMING]' )
Users:         ${USERS[*]:-(none)}
Categories:    $(tr '\n' ' ' <<<"$CATS")$bx

Selected data:      $(hr "$TOT_SEL")
Already there:      $(hr $((TOT_SEL - TOT_XFER)))
To copy now:        $(hr "$TOT_XFER")  ($TOT_N files)
Excluded junk:      $(hr "$EXCL_TOTAL")  (full list: _excluded_summary.txt)
Free on dest:       $(hr "$FREE")   $( [ "$TOT_XFER" -ge "$FREE" ] && echo '<-- NOT ENOUGH SPACE' )
$danger
Biggest folders in the copy (full list: _size_breakdown.txt):
${BIG_TXT:-(none)}${VHDX_NOTE:+

$VHDX_NOTE}"
  }
  # is_bx drive rel -> 0 if that exact path is excluded in the browser
  is_bx() { grep -qF -- "$1"$'\t'"$2"$'\t' "$BROWSE_XCL"; }
  bx_toggle() {  # drive rel d|f : add or remove a browser exclusion
    if is_bx "$1" "$2"; then grep -vF -- "$1"$'\t'"$2"$'\t' "$BROWSE_XCL" >"$BROWSE_XCL.tmp"; mv "$BROWSE_XCL.tmp" "$BROWSE_XCL"
    else printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$BROWSE_XCL"; fi
  }
  # size_browser drive-index: WinDirStat-style walk of what would be copied, largest first
  size_browser() {
    local i=$1 rel="" b n t tag act mark items est="$WORK/est_$i"
    NOPREF=1
    while :; do
      items=()
      [ -n "$rel" ] && items+=("<up" "..  (back up one level)")
      while IFS=$'\t' read -r b n t; do
        mark=""; is_bx "${DRV_NAME[$i]}" "${rel:+$rel/}$n" && mark="  EXCLUDED"
        items+=("$n" "$(printf '%9s' "$(hr "$b")")  $( [ "$t" = d ] && echo '[folder]' || echo '[file]  ' )$mark")
      done < <(awk -v pre="$rel" 'BEGIN { pl=length(pre) }
        /^[0-9]+ / && !/\/$/ {
          sz=$1+0; p=substr($0, length($1)+2)
          if (pl) { if (substr(p, 1, pl+1) != pre "/") next; p=substr(p, pl+2) }
          k=index(p, "/"); if (k) { nm=substr(p, 1, k-1); ty="d" } else { nm=p; ty="f" }
          s[nm]+=sz; T[nm]=ty }
        END { for (nm in s) printf "%d\t%s\t%s\n", s[nm], nm, T[nm] }' "$est" | sort -t$'\t' -k1,1nr | head -80)
      items+=("<done" "Finish browsing")
      tag=$(ask_menu "Size browser  ${DRV_NAME[$i]}:\\${rel//\//\\}" "Largest first, sizes are what would be copied (junk already removed). Pick an item to open or exclude it." "${items[@]}") || { NOPREF=""; return; }
      case "$tag" in
        "<done") NOPREF=""; return;;
        "<up") if [[ "$rel" == */* ]]; then rel=${rel%/*}; else rel=""; fi; continue;;
      esac
      local p="${rel:+$rel/}$tag" isdir=0
      grep -q "^[0-9]* $p/" "$est" && isdir=1
      if is_bx "${DRV_NAME[$i]}" "$p"; then
        act=$(ask_menu "$tag" "This item is currently EXCLUDED." include "Put it back into the backup" back "Back") || continue
        [ "$act" = include ] && bx_toggle "${DRV_NAME[$i]}" "$p" d
      elif [ "$isdir" = 1 ]; then
        act=$(ask_menu "$tag" "Folder ${DRV_NAME[$i]}:\\${p//\//\\}" open "Open (look inside)" exclude "EXCLUDE this folder from the backup" back "Back") || continue
        case "$act" in open) rel=$p;; exclude) bx_toggle "${DRV_NAME[$i]}" "$p" d;; esac
      else
        act=$(ask_menu "$tag" "File ${DRV_NAME[$i]}:\\${p//\//\\}" exclude "EXCLUDE this file from the backup" back "Back") || continue
        [ "$act" = exclude ] && bx_toggle "${DRV_NAME[$i]}" "$p" f
      fi
    done
  }

  if [ "$EXCL_SUMMARY" = 1 ] && [ -s "$HIDDEN" ]; then
    echo "Sizing excluded junk folders..."
    local out; out=$(python3 -c "$PY_EXCL" "$HIDDEN" "$WORK/excluded_summary.txt" 40)
    EXCL_TOTAL=$(head -1 <<<"$out"); EXCL_TXT=$(tail -n +2 <<<"$out")
  fi
  compute_sizes
  while :; do
    build_summary
    local c; c=$(ask_menu "Confirm" "$SUMMARY

Largest excluded junk:
${EXCL_TXT:-(none)}
$( [ "$DRY" = 1 ] && echo 'DRY RUN: nothing will be written.' )" \
      start  "$( [ "$DRY" = 1 ] && echo 'Continue (dry run)' || echo 'START the copy' )" \
      startp "$( [ "$DRY" = 1 ] && echo 'Continue (dry run)' || echo 'START' ) with $JOBS parallel copies (faster on lots of small files; resume-safe)" \
      browse "Browse sizes largest-first and exclude things (like WinDirStat)" \
      cancel "Quit without copying") || exit 1
    [ "$c" = yes ] && c=start
    [ "$c" = startp ] && { c=start; PARALLEL=1; }
    case "$c" in
      start)
        if [ "$TOT_XFER" -ge "$FREE" ] && [ "$DRY" = 0 ]; then ask_msg "Not enough space" "Not enough free space on the destination ($(hr "$TOT_XFER") needed, $(hr "$FREE") free). Exclude more in the size browser or pick another drive."; continue; fi
        break;;
      browse)
        local bi=0
        if [ ${#DRV_ROOT[@]} -gt 1 ]; then
          items=(); for i in "${!DRV_ROOT[@]}"; do [ -n "${DRV_WANT[$i]}" ] && items+=("$i" "${DRV_NAME[$i]}  $(hr "${EST_XFER[$i]}")"); done
          NOPREF=1; bi=$(ask_menu "Size browser" "Which drive?" "${items[@]}") || { NOPREF=""; continue; }; NOPREF=""
        fi
        size_browser "$bi"; compute_sizes;;
      cancel) exit 1;;
    esac
  done
  forget Confirm; forget "Folder exists"
  # browser exclusions become explicit rsync rules and are saved with the preferences
  if [ -s "$BROWSE_XCL" ]; then
    local bxd bxp bxt bxs=""
    while IFS=$'\t' read -r bxd bxp bxt; do
      for i in "${!DRV_ROOT[@]}"; do
        [ "${DRV_NAME[$i]}" = "$bxd" ] || continue
        if [ "$bxt" = d ]; then xcl "$i" "$(esc "$bxp")/"; else xcl "$i" "$(esc "$bxp")"; fi
        gen_filter "$i"
      done
      bxs+="${bxs:+;}$bxd|$bxp|$bxt"
    done <"$BROWSE_XCL"
    remember "Browser exclusions" "$bxs"
  else
    remember "Browser exclusions" ""
  fi
  save_prefs

  # ---- 10. copy ----
  local ZIP=no
  [ "$DRY" = 0 ] && ask_yesno "Zip" "Also pack the finished backup into ONE .zip next to the folder?
(store-only, no compression: fast. The folder is kept too. Needs another $(hr "$TOT_SEL") free.)" --defaultno && ZIP=yes

  local T_START; T_START=$(now)
  if [ "$DRY" = 0 ]; then
    ERRLOG="$DST/_errors.log"; cp "$WORK/errors.log" "$ERRLOG" 2>/dev/null || : >"$ERRLOG"
    cp "$EXC_USED" "$DST/_excludes_used.txt"
    [ -f "$WORK/excluded_summary.txt" ] && cp "$WORK/excluded_summary.txt" "$DST/_excluded_summary.txt"
    [ -f "$WORK/size_breakdown.txt" ] && cp "$WORK/size_breakdown.txt" "$DST/_size_breakdown.txt"
    { echo "Deliberately NOT backed up (unticked / excluded by hand):"; cat "$WORK/not_backed_up.txt" 2>/dev/null
      awk -F'\t' '{ p=$2; gsub("/", "\\", p); printf "  Size browser: %s:\\%s\n", $1, p }' "$BROWSE_XCL" 2>/dev/null; } >"$DST/_not_backed_up.txt"
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
    if [ "$PARALLEL" = 1 ] && [ "$JOBS" -gt 1 ]; then
      copy_parallel "$i" "$dest" "$offset"; rc=$P_RC
      printf 'Total transferred file size: %s bytes\nNumber of regular files transferred: %s\n' "$P_COPIED" "$P_NCOPIED" >"$st"
    else
      rs "${RS_BASE[@]}" --outbuf=N --info=progress2,name1 --stats \
        $( [ "$DRY" = 1 ] && printf -- '--dry-run' ) \
        --exclude-from="$EXC_USED" --filter="merge $WORK/filter_$i" "${DRV_ROOT[$i]}/" "$dest/" 2>>"$ERRLOG" \
        | python3 -c "$PY_PROGRESS" "[${DRV_NAME[$i]}]" "$offset" "$TOT_XFER" "$st"
      rc=${PIPESTATUS[0]}
    fi
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
Excluded:   $(hr "$EXCL_TOTAL") of junk (see _excluded_summary.txt); size-browser exclusions: $(grep -c . "$BROWSE_XCL" 2>/dev/null || echo 0)
Errors:     $ERRN lines in _errors.log
Verify:     $VRES
On disk:    $(hr "$MAN_B") in $MAN_N files (_manifest.tsv)
${VHDX_NOTE:-WSL/virtual disks: none found in the selected profiles}
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
  save_prefs; sync
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
  This folder mirrors the Windows C: drive, so   Users\\alice\\Documents\\x.docx   here was
  C:\\Users\\alice\\Documents\\x.docx   on the old install.
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
  WSL2 distro:     the whole distro is the ext4.vhdx under AppData\\Local\\Packages\\<distro>\\LocalState
                   or AppData\\Local\\wsl\\<guid>. After installing WSL on the new system, copy the
                   .vhdx somewhere permanent (e.g. C:\\WSL\\opensuse\\ext4.vhdx) and run in PowerShell:
                     wsl --import-in-place openSUSE-Leap C:\\WSL\\opensuse\\ext4.vhdx
                   Then: wsl -d openSUSE-Leap   (and  wsl --manage openSUSE-Leap --set-default-user <name>)
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
      rsync "${RS_BASE[@]}" "${POL[@]}" --outbuf=N --info=progress2,name1 --stats "$s/" "$dst/" 2>>"$LOG" \
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
