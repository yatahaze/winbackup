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
name to **resume**) -> user profiles -> categories -> Steam libraries found on any NTFS drive ->
root folders on C: -> folders on other drives -> size estimate + biggest excluded junk -> confirm.

Output folder mirrors `C:\` (`Users\<name>\Documents\...`, `Program Files (x86)\Steam\steamapps`,
other drives under `Drive_<label>\`). Also written: `README_RESTORE.txt`, `_manifest.tsv`
(size, path), `_errors.log`, `_summary.txt`, `_excluded_summary.txt`, `_excludes_used.txt`,
`_verify.log`, and optionally `<folder>.zip` (store-only, zip64).

* The Windows drive is only ever mounted read-only. Unclean/hibernated NTFS is handled by trying
  ntfs-3g, then the kernel ntfs3 driver (with `force`); `ntfsfix` / `remove_hiberfile` are only
  offered if all read-only attempts fail, and ask first.
* `winbackup-excludes.txt` (next to the script) is the skip list. Patterns are rsync excludes
  matched from the drive root, so `AppData/Local/Temp/` and `AppData/**/Cache/` work as expected.
* Steam: "saves + settings" (userdata, config) is on by default; "installed Steam games" (steamapps) is a separate category, off by default.
* Resume: rerun with the same destination folder; rsync skips files already copied (size+mtime).
* Verify step at the end: quick (presence + size/mtime) or full (checksums).

Tests: `bash tests/selftest.sh` builds a fake `Users/` tree in a temp dir and runs backup,
resume, dry-run, category selection and restore through the scripted-answers mode
(`--answers FILE` plus `--src/--dst/--extra DIR` to skip mounting).
