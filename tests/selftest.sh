#!/usr/bin/env bash
# Self-test for winbackup.sh: builds a fake Windows tree in a temp dir and drives the script
# with --answers (scripted menus). No root, no mounting. Run: bash tests/selftest.sh
set -u
cd "$(dirname "$0")/.." || exit 1
SCRIPT=$PWD/winbackup.sh
T=${KEEP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/winbackup-test.XXXXXX")}; [ -n "${KEEP_DIR:-}" ] || trap 'rm -rf "$T"' EXIT
export LC_ALL=C.UTF-8
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
exists()  { [ -e "$1" ] && ok || fail "missing: $1"; }
absent()  { [ ! -e "$1" ] && ok || fail "should not exist: $1"; }
mk() { mkdir -p "$(dirname "$1")"; printf '%s' "${2:-data}" >"$1"; }

# ---------- fake C: drive ----------
S=$T/src
mk "$S/Users/bob/Documents/report.docx" "report"
mk "$S/Users/bob/Documents/proj/src/main.c" "int main(){}"
mk "$S/Users/bob/Documents/proj/node_modules/left-pad/index.js"
mk "$S/Users/bob/Documents/Cache/keep-me.txt" "a folder called Cache outside AppData must be kept"
mk "$S/Users/bob/Desktop/todo.txt"
mk "$S/Users/bob/Pictures/Thumbs.db"
mk "$S/Users/bob/Pictures/cat.jpg"
mk "$S/Users/bob/Saved Games/game/slot1.sav"
mk "$S/Users/bob/OneDrive/cloud.txt"
mk "$S/Users/bob/stray.txt"
mk "$S/Users/bob/NTUSER.DAT"
mk "$S/Users/bob/ntuser.dat.LOG1"
mk "$S/Users/bob/.ssh/id_ed25519"
mk "$S/Users/bob/.gitconfig"
mk "$S/Users/bob/AppData/Roaming/SomeApp/settings.json" '{"x":1}'
mk "$S/Users/bob/AppData/Roaming/discord/Cache/junk"
mk "$S/Users/bob/AppData/Roaming/discord/Code Cache/junk"
mk "$S/Users/bob/AppData/Roaming/Microsoft/Teams/junk"
mk "$S/Users/bob/AppData/Local/Temp/x.tmp"
mk "$S/Users/bob/AppData/Local/Temp/y.txt"
mk "$S/Users/bob/AppData/Local/Google/Chrome/User Data/Default/History" "history"
mk "$S/Users/bob/AppData/Local/Google/Chrome/User Data/Default/Cache/data_0"
mk "$S/Users/bob/AppData/Local/Google/Chrome/User Data/Default/Service Worker/CacheStorage/x"
mk "$S/Users/bob/AppData/Local/Microsoft/Windows/Explorer/thumbcache_256.db"
mk "$S/Users/bob/AppData/Local/Microsoft/Windows/UsrClass.dat"
mk "$S/Users/bob/AppData/Local/Packages/MSTeams_8wekyb3d8bbwe/LocalCache/x"
mk "$S/Users/bob/AppData/Local/Packages/MSTeams_8wekyb3d8bbwe/LocalState/keep"
mk "$S/Users/bob/AppData/Local/NVIDIA/DXCache/x"
mk "$S/Users/bob/AppData/LocalLow/Unity/Game/save.dat" "unity"
mk "$S/Users/bob/AppData/Local/Packages/46932SUSE.openSUSELeap15.6_022rs5jcyhyac/LocalState/ext4.vhdx" "wsl-disk"
mk "$S/Users/bob/AppData/Local/wsl/{1234}/ext4.vhdx" "wsl-disk2"
mk "$S/Users/Alice Smith/Documents/notes [v2].txt" "brackets in a name"
mk "$S/Users/Alice Smith/AppData/Roaming/App/x"
mk "$S/Users/Public/Documents/shared.txt"
mk "$S/Users/Default/NTUSER.DAT"
mk "$S/Users/Default/Documents/x"
mk "$S/Program Files (x86)/Steam/steamapps/common/Game/game.exe" "exe"
mk "$S/Program Files (x86)/Steam/steamapps/appmanifest_1.acf"
mk "$S/Program Files (x86)/Steam/steamapps/shadercache/1/x"
mk "$S/Program Files (x86)/Steam/userdata/1/remote/save"
mk "$S/Program Files (x86)/Steam/config/loginusers.vdf"
mk "$S/Program Files (x86)/Steam/steam.exe"
mk "$S/Program Files (x86)/Other/x"
mk "$S/ProgramData/App/data"
mk "$S/ProgramData/Package Cache/big.msi"
mk "$S/Windows/System32/x"
mk "$S/Custom/thing.txt"
mk "$S/Unwanted/x"
mk "$S/pagefile.sys"
mk '$S/$RECYCLE.BIN/S-1/junk'
ln -s Documents "$S/Users/bob/My Documents"   # junction-style link: must be skipped
mkdir -p "$S/Users/bob/Videos"; head -c 40000000 /dev/urandom >"$S/Users/bob/Videos/big.mp4"

# ---------- fake D: drive ----------
X=$T/Data
mk "$X/Games/SteamLibrary/steamapps/common/Game2/g2.exe"
mk "$X/Games/SteamLibrary/steamapps/downloading/x"
mk "$X/Games/other.txt"
mk "$X/Photos/p.jpg"
mk "$X/System Volume Information/x"

# ---------- destination ----------
D=$T/dst; mkdir -p "$D/PoolPart.abc123" "$D/Other"
DATE=$(date +%Y-%m-%d)

echo "=== run 1: full backup"
cat >"$T/a1" <<A
__type__
poolpart.ABC123/Backups
@default
bob;Alice Smith;Public
docs;roaming;local;dotfiles;other;steam;steamgames;root;pdata
@all
Custom
1
yes
yes
quick
A
bash "$SCRIPT" --src "$S" --dst "$D" --extra "$X" --answers "$T/a1" >"$T/out1" 2>"$T/err1"; rc=$?
[ $rc = 0 ] && ok || { fail "run 1 exit $rc"; tail -20 "$T/err1"; }
B=$D/PoolPart.abc123/Backups/WinBackup_$DATE
exists "$B"
exists "$B/Users/bob/Documents/report.docx"
exists "$B/Users/bob/Documents/proj/src/main.c"
absent "$B/Users/bob/Documents/proj/node_modules"
exists "$B/Users/bob/Documents/Cache/keep-me.txt"
absent "$B/Users/bob/Pictures/Thumbs.db"
exists "$B/Users/bob/Pictures/cat.jpg"
exists "$B/Users/bob/Saved Games/game/slot1.sav"
exists "$B/Users/bob/OneDrive/cloud.txt"
exists "$B/Users/bob/stray.txt"
absent "$B/Users/bob/NTUSER.DAT"
absent "$B/Users/bob/ntuser.dat.LOG1"
exists "$B/Users/bob/.ssh/id_ed25519"
exists "$B/Users/bob/.gitconfig"
absent "$B/Users/bob/My Documents"
exists "$B/Users/bob/Videos/big.mp4"
exists "$B/Users/bob/AppData/Roaming/SomeApp/settings.json"
absent "$B/Users/bob/AppData/Roaming/discord/Cache"
absent "$B/Users/bob/AppData/Roaming/discord/Code Cache"
absent "$B/Users/bob/AppData/Roaming/Microsoft/Teams"
absent "$B/Users/bob/AppData/Local/Temp"
exists "$B/Users/bob/AppData/Local/Google/Chrome/User Data/Default/History"
absent "$B/Users/bob/AppData/Local/Google/Chrome/User Data/Default/Cache"
absent "$B/Users/bob/AppData/Local/Google/Chrome/User Data/Default/Service Worker/CacheStorage"
absent "$B/Users/bob/AppData/Local/Microsoft/Windows/Explorer/thumbcache_256.db"
absent "$B/Users/bob/AppData/Local/Microsoft/Windows/UsrClass.dat"
absent "$B/Users/bob/AppData/Local/Packages/MSTeams_8wekyb3d8bbwe/LocalCache"
exists "$B/Users/bob/AppData/Local/Packages/MSTeams_8wekyb3d8bbwe/LocalState/keep"
absent "$B/Users/bob/AppData/Local/NVIDIA"
exists "$B/Users/bob/AppData/LocalLow/Unity/Game/save.dat"
exists "$B/Users/bob/AppData/Local/Packages/46932SUSE.openSUSELeap15.6_022rs5jcyhyac/LocalState/ext4.vhdx"
exists "$B/Users/bob/AppData/Local/wsl/{1234}/ext4.vhdx"
grep -q 'INCLUDED' "$B/_summary.txt" && grep -q 'openSUSELeap15.6.*ext4.vhdx' "$B/_summary.txt" && ok || { fail "WSL disk not reported in summary"; grep -i wsl "$B/_summary.txt"; }
grep -q 'import-in-place' "$B/README_RESTORE.txt" && ok || fail "README lacks WSL restore note"
exists "$B/Users/Alice Smith/Documents/notes [v2].txt"
exists "$B/Users/Alice Smith/AppData/Roaming/App/x"
exists "$B/Users/Public/Documents/shared.txt"
absent "$B/Users/Default"
exists "$B/Program Files (x86)/Steam/steamapps/common/Game/game.exe"
exists "$B/Program Files (x86)/Steam/steamapps/appmanifest_1.acf"
absent "$B/Program Files (x86)/Steam/steamapps/shadercache"
exists "$B/Program Files (x86)/Steam/userdata/1/remote/save"
exists "$B/Program Files (x86)/Steam/config/loginusers.vdf"
absent "$B/Program Files (x86)/Steam/steam.exe"
absent "$B/Program Files (x86)/Other"
exists "$B/ProgramData/App/data"
absent "$B/ProgramData/Package Cache"
absent "$B/Windows"
exists "$B/Custom/thing.txt"
absent "$B/Unwanted"
absent "$B/pagefile.sys"
absent "$B/\$RECYCLE.BIN"
exists "$B/Drive_Data/Games/SteamLibrary/steamapps/common/Game2/g2.exe"
absent "$B/Drive_Data/Games/SteamLibrary/steamapps/downloading"
absent "$B/Drive_Data/Games/other.txt"
exists "$B/Drive_Data/Photos/p.jpg"
absent "$B/Drive_Data/System Volume Information"
for f in README_RESTORE.txt _manifest.tsv _errors.log _summary.txt _excludes_used.txt _excluded_summary.txt _verify.log; do exists "$B/$f"; done
grep -q 'Users/bob/Documents/report.docx' "$B/_manifest.tsv" && ok || fail "manifest lacks report.docx"
grep -q '^Verify:     OK' "$B/_summary.txt" && ok || { fail "verify not OK"; cat "$B/_summary.txt"; cat "$B/_verify.log"; }
[ -s "$B/_errors.log" ] && { grep -q '^rsync:' "$B/_errors.log" && fail "rsync errors logged: $(grep '^rsync:' "$B/_errors.log" | head -3)"; }
grep -q 'AppData/Local/Temp' "$B/_excluded_summary.txt" && ok || fail "excluded summary lacks Temp"
grep -q 'node_modules' "$B/_excluded_summary.txt" && ok || fail "excluded summary lacks node_modules"
exists "$B.zip"
python3 - "$B.zip" <<'PY' && ok || fail "zip content"
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); names = z.namelist()
assert any(n.endswith('Users/bob/Documents/report.docx') for n in names), names[:5]
assert all(i.compress_type == zipfile.ZIP_STORED for i in z.infolist())
assert z.testzip() is None
PY
cmp -s "$S/Users/bob/Videos/big.mp4" "$B/Users/bob/Videos/big.mp4" && ok || fail "big file differs"
grep -q 'overall 100%' "$T/out1" && ok || fail "progress line not rendered"

echo "=== run 2: resume (adds one file, expects only it to be copied)"
mk "$S/Users/bob/Documents/new-after-run1.txt" "new"
cat >"$T/a2" <<A
PoolPart.abc123
Backups/WinBackup_$DATE
yes
bob;Alice Smith;Public
docs;roaming;local;dotfiles;other;steam;steamgames;root;pdata
@all
Custom
1
yes
no
skip
A
bash "$SCRIPT" --src "$S" --dst "$D" --extra "$X" --answers "$T/a2" >"$T/out2" 2>"$T/err2"; rc=$?
[ $rc = 0 ] && ok || { fail "run 2 exit $rc"; tail -20 "$T/err2"; }
exists "$B/Users/bob/Documents/new-after-run1.txt"
grep -q ", resumed)" "$B/_summary.txt" && ok || fail "resume not detected"
grep -q 'copied this run: 3.0B in 1 files' "$B/_summary.txt" && ok || { fail "resume copied more than the new file"; grep 'copied this run' "$B/_summary.txt"; }
[ "$(grep -c '^Run:' "$B/_summary.txt")" = 2 ] && ok || fail "summary should list two runs"

echo "=== run 3: dry run writes nothing"
D3=$T/dst3; mkdir -p "$D3"
cat >"$T/a3" <<A
/
@default
bob
docs
yes
A
bash "$SCRIPT" --dry-run --src "$S" --dst "$D3" --answers "$T/a3" >"$T/out3" 2>"$T/err3"; rc=$?
[ $rc = 0 ] && ok || { fail "run 3 exit $rc"; tail -20 "$T/err3"; }
[ -z "$(ls -A "$D3")" ] && ok || fail "dry run wrote to destination: $(ls -A "$D3")"
grep -q 'DRY RUN complete' "$T/out3" && ok || fail "dry run summary missing"

echo "=== run 4: category off is honoured (docs + Steam saves only: no AppData, no installed games)"
D4=$T/dst4; mkdir -p "$D4"
cat >"$T/a4" <<A
/
@default
bob
docs;steam
@all
yes
no
skip
A
bash "$SCRIPT" --src "$S" --dst "$D4" --answers "$T/a4" >"$T/out4" 2>"$T/err4"; rc=$?
[ $rc = 0 ] && ok || { fail "run 4 exit $rc"; tail -20 "$T/err4"; }
exists "$D4/WinBackup_$DATE/Users/bob/Documents/report.docx"
absent "$D4/WinBackup_$DATE/Users/bob/AppData"
absent "$D4/WinBackup_$DATE/Users/bob/stray.txt"
absent "$D4/WinBackup_$DATE/Users/bob/.ssh"
exists "$D4/WinBackup_$DATE/Program Files (x86)/Steam/userdata/1/remote/save"
exists "$D4/WinBackup_$DATE/Program Files (x86)/Steam/config/loginusers.vdf"
absent "$D4/WinBackup_$DATE/Program Files (x86)/Steam/steamapps"
absent "$D4/WinBackup_$DATE/Drive_Data"

echo "=== run 5: restore into a fresh Windows drive, mapping bob -> ryan"
W=$T/newwin; mk "$W/Users/ryan/Desktop/existing.txt" "keep"; mk "$W/Windows/x"
cat >"$T/a5" <<A
PoolPart.abc123/Backups/WinBackup_$DATE
@all
__same__
__same__
ryan
overwrite
yes
A
bash "$SCRIPT" --restore --src "$D" --dst "$W" --answers "$T/a5" >"$T/out5" 2>"$T/err5"; rc=$?
[ $rc = 0 ] && ok || { fail "run 5 exit $rc"; tail -20 "$T/err5"; }
exists "$W/Users/ryan/Documents/report.docx"
exists "$W/Users/ryan/AppData/Roaming/SomeApp/settings.json"
exists "$W/Users/ryan/.gitconfig"
exists "$W/Users/ryan/Desktop/existing.txt"
exists "$W/Users/Alice Smith/Documents/notes [v2].txt"
exists "$W/Users/Public/Documents/shared.txt"
exists "$W/Program Files (x86)/Steam/steamapps/common/Game/game.exe"
exists "$W/ProgramData/App/data"
absent "$W/Users/bob"
absent "$W/Drive_Data"
absent "$W/_manifest.tsv"
ls "$W"/winbackup_restore_*.log >/dev/null 2>&1 && ok || fail "restore log missing"

echo; echo "passed: $PASS  failed: $FAIL"
[ $FAIL = 0 ]
