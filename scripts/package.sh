#!/usr/bin/env bash
#
# package.sh - assemble the installable KOReader plugin in dist/.
#
#   dist/kanki.koplugin/            copy of koplugin/kanki.koplugin/ (the Lua UI), minus devtools/
#                                   and macOS junk (.DS_Store, ._* AppleDouble files)
#   dist/kanki.koplugin/bin/kanki   the static armv7 server binary (from scripts/build-kobo.sh)
#   dist/README-install.txt         manual install instructions
#
# Usage:
#   scripts/package.sh                     package the binary that is already built
#   scripts/package.sh --build [ARGS...]   run scripts/build-kobo.sh ARGS... first
#                                          (e.g. --build --small for a release package)
#
# Environment:
#   KANKI_BIN    package this binary instead of the default build output
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="armv7-unknown-linux-musleabihf"
SRC="$ROOT/koplugin/kanki.koplugin"
DIST="$ROOT/dist"
OUT="$DIST/kanki.koplugin"

die() { echo "package.sh: $*" >&2; exit 1; }

if [[ "${1:-}" == "--build" ]]; then
    shift
    # build-kobo.sh prints the binary path as its last stdout line.
    KANKI_BIN="$("$ROOT/scripts/build-kobo.sh" "$@" | tail -n 1)"
fi
BIN="${KANKI_BIN:-${CARGO_TARGET_DIR:-$ROOT/target-arm}/$TARGET/release/kanki}"

[[ -d "$SRC" ]] || die "plugin sources not found at $SRC"
[[ -f "$BIN" ]] || die "binary not found at $BIN (run scripts/build-kobo.sh, or pass --build)"

# Refuse to package a host (macOS) binary by mistake: it must be a static 32-bit ARM ELF.
desc="$(file -b "$BIN")"
[[ "$desc" == *"ELF 32-bit LSB"*"ARM"* && "$desc" == *"statically linked"* ]] \
    || die "$BIN is not a static 32-bit ARM ELF: $desc"

# Start from a clean tree so files deleted from the plugin sources don't linger in dist/.
rm -rf "$OUT"
mkdir -p "$OUT"

# Copy the Lua plugin as-is. COPYFILE_DISABLE stops macOS tools from emitting ._* files;
# devtools/ holds development helpers that must not be shipped to the device.
COPYFILE_DISABLE=1 rsync -r -t \
    --exclude 'devtools/' --exclude '.DS_Store' --exclude '._*' \
    --exclude '.git*' --exclude '*.swp' --exclude '*~' \
    "$SRC/" "$OUT/"

# The server binary. FAT32 on the Kobo has no permission bits (every file is executable there),
# but keep +x so the tree also works from a Linux filesystem / over SSH.
mkdir -p "$OUT/bin"
cp "$BIN" "$OUT/bin/kanki"
chmod 0755 "$OUT/bin/kanki"

VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$ROOT/kanki/Cargo.toml" | head -n 1)"
SHA256="$(shasum -a 256 "$OUT/bin/kanki" | cut -d' ' -f1)"
SIZE="$(stat -f %z "$OUT/bin/kanki")"

cat > "$DIST/README-install.txt" <<EOF
kanki - Anki for KOReader on Kobo
=================================

Package: kanki ${VERSION}, built $(date -u +%Y-%m-%dT%H:%MZ)
Server binary: kanki.koplugin/bin/kanki (static ARMv7 hard-float musl, ${SIZE} bytes)
  sha256 ${SHA256}
Built for: Kobo Libra Colour (and other 32-bit ARM Kobos) running KOReader.

Install over USB (manual)
-------------------------
1. Connect the Kobo with USB and choose "Connect" so it mounts as KOBOeReader.
2. The folders you need start with a dot, so they are hidden. In the macOS Finder press
   Cmd+Shift+. to show them.
3. Copy the folder "kanki.koplugin" into
       KOBOeReader/.adds/koreader/plugins/
   so that you end up with
       KOBOeReader/.adds/koreader/plugins/kanki.koplugin/main.lua
       KOBOeReader/.adds/koreader/plugins/kanki.koplugin/bin/kanki
   If an older kanki.koplugin is already there, delete it first.
4. Optional, to get an "Anki" entry in the Kobo home-screen menu (needs NickelMenu):
   copy kanki.koplugin/nickelmenu-entry.txt (if it exists) to
       KOBOeReader/.adds/nm/kanki
   (the file is named just "kanki", with no extension).
5. On a Mac, remove the "._*" files Finder leaves on FAT32 drives:
       dot_clean -m /Volumes/KOBOeReader/.adds
6. Eject the Kobo, then start (or restart) KOReader.

From this repository, scripts/deploy-usb.sh does steps 3-5, and scripts/deploy-ssh.sh HOST
does the same over KOReader's SSH server.

Notes
-----
* Nothing needs chmod: the Kobo's FAT32 partition is mounted with every file executable,
  the same way KOReader runs its own bundled luajit, fbink and dropbear from there.
* Your Anki data lives in /mnt/onboard/.adds/kanki/ (collection.anki2, collection.media/,
  auth.json, kanki.log). It is separate from the plugin, so upgrading or deleting the plugin
  keeps your collection. Delete that folder as well for a full uninstall.
* Before you connect USB, leave the Anki screen or quit KOReader, so that the collection is
  closed cleanly.
EOF

echo "packaged: $OUT" >&2
(cd "$DIST" && find kanki.koplugin README-install.txt -type f | sort | sed 's/^/  /') >&2
echo "$OUT"
