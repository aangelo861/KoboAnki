#!/usr/bin/env bash
#
# deploy-usb.sh - install dist/kanki.koplugin on a Kobo mounted over USB (macOS).
#
# Writes:
#   /Volumes/KOBOeReader/.adds/koreader/plugins/kanki.koplugin/   (mirrors dist/kanki.koplugin)
#   /Volumes/KOBOeReader/.adds/nm/kanki                            (NickelMenu entry, if the plugin
#                                                                    ships nickelmenu-entry.txt)
# then removes macOS "._*" AppleDouble files from what it wrote and flushes with sync.
# It does not eject the device.
#
# Usage: scripts/deploy-usb.sh          (run scripts/package.sh first)
#
# Environment:
#   KOBO_VOLUME   mount point (default /Volumes/KOBOeReader)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VOL="${KOBO_VOLUME:-/Volumes/KOBOeReader}"
SRC="$ROOT/dist/kanki.koplugin"
PLUGINS="$VOL/.adds/koreader/plugins"
DEST="$PLUGINS/kanki.koplugin"
NM_DIR="$VOL/.adds/nm"

die() { echo "deploy-usb.sh: $*" >&2; exit 1; }

# --- Safety checks: only ever write to a mounted Kobo that has KOReader installed. ---------------
# An unmounted /Volumes/KOBOeReader could still exist as a plain directory on the Mac's disk, so
# check the mount table, not just whether the path exists.
mount | grep -q " on ${VOL} (" || die "$VOL is not mounted (connect the Kobo and tap Connect)"
[[ -f "$VOL/.kobo/version" ]] || die "$VOL does not look like a Kobo (no .kobo/version)"
[[ -d "$PLUGINS" ]] || die "KOReader is not installed on the device (no $PLUGINS)"

[[ -f "$SRC/bin/kanki" ]] || die "$SRC/bin/kanki missing (run scripts/package.sh first)"
desc="$(file -b "$SRC/bin/kanki")"
[[ "$desc" == *"ELF 32-bit LSB"*"ARM"* ]] || die "$SRC/bin/kanki is not an ARM binary: $desc"

echo "Kobo: $(cut -d, -f1,3 "$VOL/.kobo/version")  (serial,firmware)"

# --- Plugin -------------------------------------------------------------------------------------
# rsync options for FAT32:
#   -r -t               recurse and keep mtimes, but no permissions/owners (FAT32 has none)
#   --modify-window=1   FAT32 stores mtimes with 2 s granularity; don't recopy for that
#   --delete            drop files that were removed from the plugin (stale Lua modules)
# The plugin keeps no user data in its own folder (that is /mnt/onboard/.adds/kanki), so --delete
# is safe. COPYFILE_DISABLE=1 stops macOS from creating ._* files for extended attributes.
mkdir -p "$DEST"
COPYFILE_DISABLE=1 rsync -r -t --modify-window=1 --delete \
    --exclude '._*' --exclude '.DS_Store' \
    "$SRC/" "$DEST/"
echo "plugin   -> $DEST"

# --- NickelMenu entry ---------------------------------------------------------------------------
# Prefer the packaged copy (it is what we just deployed) and fall back to the plugin sources.
NM_ENTRY=""
for f in "$SRC/nickelmenu-entry.txt" "$ROOT/koplugin/kanki.koplugin/nickelmenu-entry.txt"; do
    if [[ -f "$f" ]]; then NM_ENTRY="$f"; break; fi
done
if [[ -n "$NM_ENTRY" ]]; then
    mkdir -p "$NM_DIR"
    # NickelMenu wants plain LF line endings; strip any CRs an editor might have added.
    tr -d '\r' < "$NM_ENTRY" > "$NM_DIR/kanki"
    rm -f "$NM_DIR/._kanki"
    echo "menu     -> $NM_DIR/kanki"
else
    echo "menu     -> skipped (no nickelmenu-entry.txt in the plugin)"
fi

# --- Clean up macOS metadata and flush ------------------------------------------------------------
# dot_clean -m merges and then always deletes ._* files. The find is a second pass in case
# dot_clean leaves any behind on FAT32. Both are limited to what this script wrote.
dot_clean -m "$DEST" || true
find "$DEST" -name '._*' -type f -delete
rm -f "$PLUGINS/._kanki.koplugin"
sync

echo "Done. Eject the Kobo (diskutil eject \"$VOL\"), then restart KOReader to load the plugin."
