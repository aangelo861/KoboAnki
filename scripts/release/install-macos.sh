#!/bin/bash
#
# Install KoboAnki on a Kobo connected to this Mac over USB:
#   bash install-macos.sh
# Copies kanki.koplugin into KOReader's plugins folder (replacing an older version; your cards in
# .adds/kanki are not touched), adds the NickelMenu entry if NickelMenu is installed, removes the
# hidden "._*" files macOS writes onto the Kobo, and ejects it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KOBO="${KOBO:-/Volumes/KOBOeReader}"

say() { printf '%s\n' "$*"; }
fail() { say ""; say "Stopped: $*"; exit 1; }

[[ -d "$HERE/kanki.koplugin" ]] || fail "run this from the unzipped KoboAnki folder (kanki.koplugin not found next to it)."
[[ -d "$KOBO" ]] || fail "no Kobo at $KOBO. Connect it with USB and tap Connect on the Kobo, then run this again."
[[ -d "$KOBO/.adds/koreader/plugins" ]] || fail "KOReader isn't installed on this Kobo. Install it first:
  https://github.com/koreader/koreader/wiki/Installation-on-Kobo-devices"

say "Installing KoboAnki on $KOBO ..."
PLUGINS="$KOBO/.adds/koreader/plugins"
rm -rf "$PLUGINS/kanki.koplugin.new"
COPYFILE_DISABLE=1 cp -R "$HERE/kanki.koplugin" "$PLUGINS/kanki.koplugin.new"
rm -rf "$PLUGINS/kanki.koplugin"
mv "$PLUGINS/kanki.koplugin.new" "$PLUGINS/kanki.koplugin"
say "  plugin -> .adds/koreader/plugins/kanki.koplugin"

if [[ -d "$KOBO/.adds/nm" ]]; then
    COPYFILE_DISABLE=1 cp "$HERE/NickelMenu/kanki" "$KOBO/.adds/nm/kanki"
    say "  NickelMenu entry -> .adds/nm/kanki (\"Anki\" in the Kobo's menu)"
else
    say "  NickelMenu not found: skipped its menu entry (open Anki from KOReader's menu instead)."
fi

find "$KOBO/.adds/koreader/plugins/kanki.koplugin" "$KOBO/.adds/nm" -name '._*' -delete 2>/dev/null || true
sync

say "Ejecting the Kobo ..."
if diskutil eject "$KOBO" >/dev/null 2>&1; then
    say "Done. On the Kobo: open KOReader, then ☰ → Anki → Log in."
else
    say "Installed, but the Kobo couldn't be ejected (a Finder window may be using it). Eject it in Finder."
fi
