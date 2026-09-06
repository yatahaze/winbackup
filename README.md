# winbackup

Back up Windows user data from a Pop!_OS live USB into a plain folder tree you can browse
and drag-restore from Windows Explorer. Bash + rsync + whiptail; nothing to install.

```
sudo bash winbackup.sh              # interactive backup
sudo bash winbackup.sh --dry-run    # everything except the copy; writes nothing to the destination
sudo bash winbackup.sh --restore    # copy a backup back onto a (new) Windows drive
```

Menus: source partition -> destination partition (shows free space per drive and a rough fit verdict against everything in use on C:) -> destination folder (PoolPart.* folders are
listed; typed paths match case-insensitively) -> backup folder name (`WinBackup_<date>`; reuse the
name to **resume**) -> user profiles -> categories -> Steam libraries on the drive ->
root folders on C: -> optional item-by-item drill-down -> size estimate + biggest excluded junk -> confirm.

Only the one source drive is read. `--other-drives` additionally mounts the other NTFS drives
read-only and offers their folders and Steam libraries (saved under `Drive_<label>\`).

Output folder mirrors `C:\` (`Users\<name>\Documents\...`, `Program Files (x86)\Steam\steamapps`,
other drives under `Drive_<label>\`). Also written: `README_RESTORE.txt`, `_manifest.tsv`
(size, path), `_errors.log`, `_summary.txt`, `_excluded_summary.txt`, `_excludes_used.txt`,
`_verify.log`, and optionally `<folder>.zip` (store-only, zip64).

* The Windows drive is only ever mounted read-only. Unclean/hibernated NTFS is handled by trying
  ntfs-3g, then the kernel ntfs3 driver (with `force`); `ntfsfix` / `remove_hiberfile` are only
  offered if all read-only attempts fail, and ask first.
* `winbackup-excludes.txt` (next to the script) is the skip list. Patterns are rsync excludes
  matched from the drive root, so `AppData/Local/Temp/` and `AppData/**/Cache/` work as expected.
* Defaults are a full copy of the drive: every profile, every other folder on C: (never \Windows), ProgramData, Steam. Untick what you do not want.
* Saved preferences: every answer is written to winbackup-prefs.txt next to the script; the next run offers to pre-select them (review) or skip the menus entirely (auto). Delete the file to start fresh.
* Packing (default on for HDD/SMR and NAS destinations, toggle on the confirm screen, --pack/--no-pack): folders with huge numbers of small files (AppData\Local\<app> with 500+ files, other folders with 50k+ files) are written as one store-only .zip each instead of a tree. Shingled (SMR) drives and SMB shares crawl on small files; a zip is a single sequential stream. Zips open in Explorer, are listed in _packed.txt and _manifest.tsv, and --restore unpacks them.
* NAS destination: pick "Network share" in the destination menu, enter IP/user/password, choose the share from a list (smbclient) or type it.
* Parallel copy: the confirm screen offers "START with 4 parallel copies" (--jobs N to change); work is split by folder size across N rsync workers, useful for trees of many small files. Output is identical to the single-rsync path (the selftest compares manifests).
* Size browser: on the confirm screen, "Browse sizes" walks what would be copied largest-first (WinDirStat-style) and lets you exclude folders/files; those exclusions are saved with the preferences.
* Drill-down: after the folder lists you can pick any folder (e.g. C:\Temp) and tick/untick its contents item by item, with sizes.
* Steam: "saves + settings" (userdata, config) is on by default; "installed Steam games" (steamapps) is a separate category, off by default.
* Crash recovery: if a run ended abruptly (power loss, hard reset), the next resume deletes leftover rsync temp files and checksum-rechecks everything written in the last 10 minutes before the cut.
* Resume: rerun with the same destination folder; rsync skips files already copied (size+mtime).
* Verify step at the end: quick (presence + size/mtime) or full (checksums).

Tests: `bash tests/selftest.sh` builds a fake `Users/` tree in a temp dir and runs backup,
resume, dry-run, category selection and restore through the scripted-answers mode
(`--answers FILE` plus `--src/--dst/--extra DIR` to skip mounting).
